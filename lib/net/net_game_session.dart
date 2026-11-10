import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/card.dart';
import '../../core/game_action.dart';
import '../../core/game_engine.dart';
import '../../core/game_phase.dart';
import '../../core/game_state.dart';
import '../../core/deck.dart';
import '../../core/hand_detector.dart';
import '../../core/rule_variant.dart';
import '../../state/game_session.dart';
import '../../state/settings.dart';
import '../../ai/ai_player.dart';
import '../../ai/douzero_ai.dart';
import '../../stats/stats_record.dart';
import '../../stats/bankroll.dart';
import '../../stats/stats_repository.dart';
import 'protocol.dart';
import 'room_client.dart';

/// 联网对局所需的房间上下文（由 UI 传入）。
class NetRoomContext {
  final String roomId;
  final int mySeat;
  final String myUid;
  final bool isHost;
  final bool chatEnabled;
  final Set<int> aiSeats;

  const NetRoomContext({
    required this.roomId,
    required this.mySeat,
    required this.myUid,
    required this.isHost,
    required this.chatEnabled,
    this.aiSeats = const {},
  });
}

/// 当前联网房间上下文 Provider（由 NetGameScreen 通过 override 注入）。
final netRoomContextProvider = Provider<NetRoomContext>((ref) {
  throw UnimplementedError('Must be overridden');
});

/// 联网对局会话。
///
/// 房主模式：运行 GameEngine，处理所有玩家的动作，广播公共状态。
/// 非房主模式：提交动作到 RTDB，监听公共状态变化更新本地视图。
class NetGameSession extends SessionNotifier {
  late final RoomClientBase _client;
  late final NetRoomContext _ctx;
  final GameEngine _engine = const GameEngine();

  // 房主权威状态
  GameState? _authState;

  // 最近一次收到的公共状态数据（客户端用，_onMyHand 时重建显示）
  Map<dynamic, dynamic>? _lastStateData;

  // 本地显示状态
  List<Card> _myHand = [];

  // 房主记录本局动作日志（用于复盘）
  final List<GameAction> _actionLog = [];
  int _seed = 0;
  RuleVariant _variant = RuleVariant.classic;

  // 座位玩家昵称（显示用）
  List<String> _seatNicks = ['', '', ''];

  // 准备状态
  List<bool> _readySeats = [false, false, false];

  // AI 座位集合（仅房主使用，用于 AI 自动出牌）
  Set<int> _aiSeats = {};
  final AiPlayer _ai = DouZeroAi();
  Timer? _aiTimer;

  // 托管座位（超时后 AI 接管的人类座位）
  final Set<int> _autoPlaySeats = {};

  // 各实际座位的在线状态（watchRoom 追踪）
  final List<bool> _seatOnline = [true, true, true];

  // 可变房主身份（房主迁移用）
  bool _isHost = false;
  Timer? _migrationTimer;

  // 监听订阅
  StreamSubscription? _gameStateSub;
  StreamSubscription? _handSub;
  StreamSubscription? _pendingSub;
  StreamSubscription? _readySub;
  StreamSubscription? _connectedSub;
  StreamSubscription? _roomSub;

  // 非房主乐观更新（出牌后本地标记 pending，10 秒未确认则清除 + 提示）
  Set<int> _pendingCardIndices = {};
  Timer? _pendingTimer;

  // 出牌超时定时器（仅房主，联网模式 60s）
  Timer? _turnTimer;
  int? _turnDeadline; // UTC 毫秒时间戳，广播给客户端显示倒计时

  static const _turnTimeoutSeconds = 30;

  // 战绩记录
  int _turns = 0;
  int? _settleRecordedForSeed;

  @override
  GameState build() {
    _ctx = ref.read(netRoomContextProvider);
    _aiSeats = Set.from(_ctx.aiSeats);
    _isHost = _ctx.isHost;
    _client = ref
        .read(roomClientProvider)
        .maybeWhen(
          data: (c) => c,
          orElse: () => throw StateError('RoomClient not ready'),
        );

    // 监听公共游戏状态
    _gameStateSub = _client.watchGameState(_ctx.roomId).listen(_onGameState);

    // 监听房间数据（座位在线状态变化 + 房主迁移检测）
    _roomSub = _client.watchRoom(_ctx.roomId).listen((snapshot) {
      var seatChanged = false;
      final wentOffline = <int>[];
      for (var s = 0; s < 3; s++) {
        final seat = snapshot.seats[s];
        final online = seat?.online ?? false;
        if (_seatOnline[s] != online) {
          debugPrint(
            '[NetGameSession] seat $s online: ${_seatOnline[s]} → $online',
          );
          if (!online && seat != null) wentOffline.add(s);
          _seatOnline[s] = online;
          seatChanged = true;
        }
      }

      // 房主：真人掉线 → 立即由本机人机托管（不必等出牌超时）
      if (_isHost && _authState != null && wentOffline.isNotEmpty) {
        _takeOverOfflineSeats(wentOffline);
      }

      // 房主迁移检测
      _checkHostMigration(snapshot);

      // isHost 变化检测
      final newIsHost = snapshot.meta.hostUid == _ctx.myUid;
      if (newIsHost != _isHost) {
        if (newIsHost) {
          debugPrint('[NetGameSession] 房主迁移 → 我成为新房主');
          _activateHost();
        } else {
          debugPrint('[NetGameSession] 房主迁移 → 我降级为非房主');
          _deactivateHost();
        }
      }

      if (seatChanged || newIsHost != _isHost) {
        if (_authState != null) {
          state = _buildDisplayFromAuth();
        } else if (_lastStateData != null) {
          state = _buildDisplayState(_lastStateData!);
        }
      }
    });

    // 监听自己的手牌
    _handSub = _client.watchMyHand(_ctx.roomId, _ctx.mySeat).listen(_onMyHand);

    // 监听准备状态（结算后用于再来一局）
    _readySub = _client.watchReady(_ctx.roomId).listen(_onReadyChange);

    // 监听连接状态（断线标记 offline + 重连恢复 + 重新同步）
    var wasConnected = true;
    _connectedSub = _client.watchConnected().listen((connected) {
      if (connected) {
        if (!wasConnected) {
          debugPrint('[NetGameSession] reconnected → setOnline + resync');
          wasConnected = true;
        }
        _client.setOnline(_ctx.roomId, _ctx.mySeat, true).catchError((e) {
          debugPrint('[NetGameSession] setOnline(true) failed: $e');
        });
        // 断线重连后强制重新拉取最新数据（可能错过了出牌/结算广播）
        Future.delayed(const Duration(milliseconds: 500), () {
          _client.resync(_ctx.roomId);
        });
      } else {
        if (wasConnected) {
          debugPrint(
            '[NetGameSession] disconnected → best-effort setOnline(false)',
          );
          wasConnected = false;
          // HTTP API 可能仍可用（WebSocket 断 ≠ HTTP 断），尝试一次标记离线
          _client.setOnline(_ctx.roomId, _ctx.mySeat, false).catchError((e) {
            debugPrint(
              '[NetGameSession] setOnline(false) failed (expected offline): $e',
            );
          });
        }
      }
    });

    // 房主：监听待处理动作
    if (_isHost) {
      _pendingSub = _client
          .watchPendingAction(_ctx.roomId)
          .listen(_onPendingAction);
    }

    ref.onDispose(() {
      _gameStateSub?.cancel();
      _handSub?.cancel();
      _pendingSub?.cancel();
      _readySub?.cancel();
      _connectedSub?.cancel();
      _roomSub?.cancel();
      _pendingTimer?.cancel();
      _turnTimer?.cancel();
      _aiTimer?.cancel();
      _migrationTimer?.cancel();
    });

    // 房主：检查是否有进行中的对局可恢复，否则开新局
    if (_isHost) {
      Future.microtask(() => _hostInitOrResume());
    }

    return GameState.initial();
  }

  // ── 联网模式属性 ──

  @override
  bool get isOnlineMode => true;

  @override
  bool get isHost => _isHost;

  @override
  List<bool> get readySeats {
    final result = List<bool>.from(_readySeats);
    // 房主永远视为已准备（用实际座位号，迁移后也正确）
    if (_ctx.mySeat < result.length) result[_ctx.mySeat] = true;
    // AI 座位、托管座位、离线座位均自动准备（不应阻塞再来一局）
    for (var s = 0; s < 3 && s < result.length; s++) {
      if (_aiSeats.contains(s) ||
          _autoPlaySeats.contains(s) ||
          !_seatOnline[s]) {
        result[s] = true;
      }
    }
    return result;
  }

  @override
  bool get amReady =>
      _readySeats.length > _ctx.mySeat && _readySeats[_ctx.mySeat];

  @override
  void toggleReady() {
    if (_isHost) return; // 房主不需要准备
    _client.setReady(_ctx.roomId, _ctx.mySeat, !amReady);
  }

  @override
  void disableAutoPlay() {
    if (_isHost) {
      _hostDisableAutoPlay(_ctx.mySeat);
    } else {
      _submitAction({'type': 'disableAutoPlay', 'bySeat': _ctx.mySeat});
    }
  }

  /// 房主处理：清除指定座位的托管状态。
  void _hostDisableAutoPlay(int seat) {
    if (!_autoPlaySeats.contains(seat)) return;
    _autoPlaySeats.remove(seat);
    state = _buildDisplayFromAuth();
    _syncThenBroadcast();
  }

  /// 房主处理：掉线的真人座位立即转为人机托管（推理在房主本机执行）。
  /// 玩家重连后点击手牌区即可取消托管。
  void _takeOverOfflineSeats(List<int> seats) {
    final auth = _authState;
    if (auth == null || auth.phase == GamePhase.settled) return;
    var changed = false;
    for (final s in seats) {
      if (s == _ctx.mySeat || _aiSeats.contains(s)) continue;
      if (_autoPlaySeats.add(s)) changed = true;
    }
    if (!changed) return;
    debugPrint('[NetGameSession] 掉线托管 → $_autoPlaySeats');
    _maybeScheduleAi();
    state = _buildDisplayFromAuth();
    _syncThenBroadcast();
  }

  // ── 房主迁移 ──

  /// 检测房主离线 → 触发迁移（15s 延迟，避免网络抖断误触发）。
  void _checkHostMigration(RoomSnapshot snapshot) {
    final hostUid = snapshot.meta.hostUid;
    // 找到房主所在座位
    int? hostSeat;
    for (var s = 0; s < 3; s++) {
      if (snapshot.seats[s]?.uid == hostUid) {
        hostSeat = s;
        break;
      }
    }

    // 房主在线 → 取消迁移计时器
    if (hostSeat != null && _seatOnline[hostSeat]) {
      _migrationTimer?.cancel();
      _migrationTimer = null;
      return;
    }

    // 房主离线 → 启动迁移计时器（15s 后执行）
    if (_migrationTimer != null) return; // 已在等待

    // 只有非房主才需要触发迁移
    if (hostUid == _ctx.myUid) return;

    _migrationTimer = Timer(const Duration(seconds: 15), () {
      _migrationTimer = null;
      _performMigration(snapshot);
    });
  }

  /// 执行迁移：选最小在线真人座位号 → 写 meta.hostUid。
  void _performMigration(RoomSnapshot snapshot) {
    // 重新检查房主是否已恢复
    int? hostSeat;
    for (var s = 0; s < 3; s++) {
      if (snapshot.seats[s]?.uid == snapshot.meta.hostUid) {
        hostSeat = s;
        break;
      }
    }
    if (hostSeat != null && _seatOnline[hostSeat]) return;

    // 找最小在线真人座位
    for (var s = 0; s < 3; s++) {
      final seat = snapshot.seats[s];
      if (seat != null && seat.online && !seat.isAI) {
        // 候选人：写 meta.hostUid
        debugPrint('[NetGameSession] 房主迁移 → seat $s (${seat.uid})');
        _client.updateHostUid(_ctx.roomId, seat.uid);
        return;
      }
    }
  }

  /// 成为新房主：激活引擎 + 托管旧房主 + 回捞 pendingAction。
  void _activateHost() {
    _isHost = true;

    // 订阅 pendingAction
    _pendingSub = _client
        .watchPendingAction(_ctx.roomId)
        .listen(_onPendingAction);

    // 标记所有离线人类座位为托管（旧房主）
    for (var s = 0; s < 3; s++) {
      if (s != _ctx.mySeat && !_aiSeats.contains(s) && !_seatOnline[s]) {
        _autoPlaySeats.add(s);
      }
    }

    // 从 RTDB 恢复权威状态
    Future.microtask(
      () => _hostInitOrResume().then((_) {
        // 恢复完成后回捞 pendingAction
        _recoverPendingAction();
      }),
    );
  }

  /// 降级为非房主：停止引擎/定时器/AI。
  void _deactivateHost() {
    _isHost = false;
    _pendingSub?.cancel();
    _pendingSub = null;
    _turnTimer?.cancel();
    _turnTimer = null;
    _aiTimer?.cancel();
    _aiTimer = null;
    _authState = null;
    _autoPlaySeats.clear();
  }

  /// 回捞 pendingAction（迁移时旧房主可能遗留未处理的动作）。
  Future<void> _recoverPendingAction() async {
    try {
      final pending = await _client
          .watchPendingAction(_ctx.roomId)
          .first
          .timeout(const Duration(seconds: 3));
      if (pending != null && _authState != null) {
        debugPrint('[NetGameSession] 回捞 pendingAction: ${pending['type']}');
        _onPendingAction(pending);
      }
    } catch (_) {}
  }

  /// 结算时记录战绩（房主 + 非房主各自记录自己的结果）。
  void _maybeRecordSettlement() {
    final s = state;
    if (s.phase != GamePhase.settled) return;
    final seed = _seed > 0 ? _seed : s.deckSeed;
    if (seed == 0) return;
    if (_settleRecordedForSeed == seed) return;
    _settleRecordedForSeed = seed;

    final winnerDisplay = s.winnerSeat;
    final landlordDisplay = s.landlordSeat;
    if (winnerDisplay == null || landlordDisplay == null) return;

    final myDisplaySeat = 0;
    final iWon =
        (winnerDisplay == landlordDisplay &&
            myDisplaySeat == landlordDisplay) ||
        (winnerDisplay != landlordDisplay && myDisplaySeat != landlordDisplay);
    final iAmLandlord = myDisplaySeat == landlordDisplay;
    final baseScore = s.multiplier * (iAmLandlord ? 2 : 1);

    debugPrint(
      '[NetGameSession] 记录联网战绩: won=$iWon landlord=$iAmLandlord '
      'mult=×${s.multiplier} turns=$_turns seed=$seed',
    );

    final record = StatsRecord(
      playedAt: DateTime.now(),
      humanWon: iWon,
      humanIsLandlord: iAmLandlord,
      multiplier: s.multiplier,
      score: iWon ? baseScore : baseScore,
      turns: _turns > 0 ? _turns : _estimateTurnsFromActionLog(),
      isSpring: s.isSpring,
      isAntiSpring: s.isAntiSpring,
      isOnline: true,
      variantId: _variant.id,
    );

    _writeRecord(record);
    ref.read(bankrollProvider.notifier).settle(iWon ? baseScore : -baseScore);
  }

  /// 非房主没有 _turns 计数器，从 actionLog 估算回合数。
  int _estimateTurnsFromActionLog() {
    return _actionLog.where((a) => a is PlayAction || a is PassAction).length;
  }

  Future<void> _writeRecord(StatsRecord record) async {
    try {
      final repo = await ref.read(statsRepositoryProvider.future);
      await repo.append(record);
      ref.invalidate(statsRecordsProvider);
    } catch (e) {
      debugPrint('[NetGameSession] stats record failed: $e');
    }
  }

  void _onReadyChange(List<bool> ready) {
    _readySeats = ready;
    // 触发 UI 重建（准备状态变化需要刷新按钮）
    state = state.copyWith();
  }

  // ── 公开接口（与 GameSession 相同）──

  @override
  void bid(int score) {
    _submitAction({'type': 'bid', 'bySeat': _ctx.mySeat, 'score': score});
  }

  @override
  void bright() {
    _submitAction({'type': 'bright', 'bySeat': _ctx.mySeat});
  }

  @override
  void play(List<Card> cards) {
    // 非房主乐观更新：标记 pending 牌（灰显 + 禁用按钮），不修改 _myHand
    if (!_isHost && cards.isNotEmpty) {
      _pendingCardIndices = cards.map((c) => c.index).toSet();
      _pendingTimer?.cancel();
      _pendingTimer = Timer(const Duration(seconds: 10), _rollbackPending);
      if (_lastStateData != null) {
        state = _buildDisplayState(
          _lastStateData!,
        ).copyWith(pendingCardIndices: _pendingCardIndices);
      }
    }
    _submitAction({
      'type': 'play',
      'bySeat': _ctx.mySeat,
      'cards': cards.map((c) => c.index).toList(),
    });
  }

  @override
  void pass() {
    _submitAction({'type': 'pass', 'bySeat': _ctx.mySeat});
  }

  @override
  void newGame() {
    if (!_isHost) return;
    // 房主：检查所有人是否已准备（房主自己不需要准备）
    if (!readySeats.every((r) => r)) return;
    _startNewGame();
  }

  // ── 动作提交流 ──

  void _submitAction(Map<String, dynamic> action) {
    if (_isHost) {
      // 房主直接本地处理
      _hostProcessAction(action);
    } else {
      // 非房主提交到 RTDB
      _client.submitAction(_ctx.roomId, action);
    }
  }

  // ── 房主逻辑 ──

  void _onPendingAction(Map<dynamic, dynamic>? data) {
    if (data == null) return;
    final action = Map<String, dynamic>.from(data);
    // 退出托管：特殊 action，不走引擎
    if (action['type'] == 'disableAutoPlay') {
      _hostDisableAutoPlay(action['bySeat'] as int);
      _client.clearPendingAction(_ctx.roomId);
      return;
    }
    _hostProcessAction(action);
    // clearPendingAction 由 _syncThenBroadcast 内的 batchUpdate 不处理，
    // 单独清除（轻量操作）
    _client.clearPendingAction(_ctx.roomId);
  }

  void _hostProcessAction(Map<String, dynamic> actionData) {
    if (_authState == null) return;

    final action = GameAction.fromJson(actionData);
    if (!_engine.validate(_authState!, action).ok) return;

    _authState = _engine.apply(_authState!, action);
    _actionLog.add(action);
    if (action is PlayAction || action is PassAction) {
      _turns++;
    }

    // 处理流局
    if (_authState!.phase == GamePhase.bidding &&
        _authState!.bidParticipants >= 3 &&
        _authState!.currentMaxBid == 0) {
      final seat = _authState!.currentPlayer;
      final fallback = BidAction(seat, 1);
      _authState = _engine.apply(_authState!, fallback);
      _actionLog.add(fallback);
    }

    // 更新自己的手牌（从权威状态同步）
    _myHand = List.from(_authState!.players[_ctx.mySeat].hand);
    _myHand.sort((a, b) => b.rank.value.compareTo(a.rank.value));

    // 先调度下一轮定时器（设置 _turnDeadline），再构建显示状态和广播，
    // 确保 deadline 在 display state 和广播数据中是最新的
    _maybeScheduleAi();
    _scheduleTurnTimeout();

    // 立即更新显示状态（不等 RTDB 回环）
    state = _buildDisplayFromAuth();

    // 广播公共状态 + 同步手牌到 RTDB（先写手牌，再写状态，确保顺序）
    _syncThenBroadcast();

    // 如果进入结算，更新房间状态 + 记录战绩
    if (_authState!.phase == GamePhase.settled) {
      _client.updateStatus(_ctx.roomId, 'settled');
      _maybeRecordSettlement();
    }
  }

  /// 房主初始化：检查 RTDB 是否有进行中的对局，有则恢复，否则开新局。
  Future<void> _hostInitOrResume() async {
    try {
      final gs = await _client
          .watchGameState(_ctx.roomId)
          .first
          .timeout(const Duration(seconds: 5));

      if (gs != null &&
          gs['phase'] != null &&
          gs['phase'] != 'waiting' &&
          gs['phase'] != 'dealing') {
        // 有进行中的对局，尝试恢复
        await _resumeFromRtdb(gs);
        return;
      }
    } catch (_) {}

    // 没有进行中的对局，开新局
    await _startNewGame();
  }

  /// 房主从 RTDB 数据恢复 _authState（重连/重进场景）。
  Future<void> _resumeFromRtdb(Map<dynamic, dynamic> gs) async {
    final seed = gs['deckSeed'] as int? ?? 0;
    final actionLogRaw = gs['actionLog'] as List?;
    if (seed == 0 || actionLogRaw == null) {
      // 数据不完整，无法恢复
      await _startNewGame();
      return;
    }

    _seed = seed;
    _actionLog.clear();

    // 获取座位玩家昵称
    try {
      final roomSnap = await _client
          .watchRoom(_ctx.roomId)
          .first
          .timeout(const Duration(seconds: 5));
      _seatNicks = roomSnap.seats.map((s) => s?.nick ?? '').toList();
      _aiSeats = roomSnap.aiSeats;
    } catch (_) {}

    // 重放引擎恢复完整状态
    _variant = RuleVariant.byId(gs['ruleVariant'] as String?);
    final deal = _variant.shuffle
        ? Deck.deal(_seed)
        : Deck.dealNoShuffle(_seed);
    _authState = _engine.apply(
      GameState.initial(),
      DealAction(deal.hands, deal.bottom, _seed),
    );
    _authState = _authState!.copyWith(ruleVariant: _variant);
    for (final json in actionLogRaw) {
      final action = GameAction.fromJson(Map<String, dynamic>.from(json));
      _authState = _engine.apply(_authState!, action);
      _actionLog.add(action);
    }

    // 恢复自己的手牌
    _myHand = List.from(_authState!.players[_ctx.mySeat].hand);
    _myHand.sort((a, b) => b.rank.value.compareTo(a.rank.value));

    // 先调度定时器（设置 _turnDeadline），再构建显示和广播
    _maybeScheduleAi();
    _scheduleTurnTimeout();

    _lastStateData = null;
    state = _buildDisplayFromAuth();

    // 同步手牌到 RTDB（其他玩家可能需要更新）
    final handsMap = <int, List<int>>{};
    for (var s = 0; s < 3; s++) {
      handsMap[s] = _authState!.players[s].hand.map((c) => c.index).toList();
    }
    await _client.batchUpdate(
      _ctx.roomId,
      hands: handsMap,
      gameState: _buildGameStateMap(),
    );
  }

  Future<void> _startNewGame() async {
    _seed = DateTime.now().millisecondsSinceEpoch % (1 << 30);
    _actionLog.clear();
    _autoPlaySeats.clear();
    // 仍处于离线的真人座位，新局直接由人机托管
    for (var s = 0; s < 3; s++) {
      if (s != _ctx.mySeat && !_aiSeats.contains(s) && !_seatOnline[s]) {
        _autoPlaySeats.add(s);
      }
    }
    _turns = 0;
    _variant = ref.read(ruleVariantProvider);
    final deal = _variant.shuffle
        ? Deck.deal(_seed)
        : Deck.dealNoShuffle(_seed);

    _authState = _engine.apply(
      GameState.initial(),
      DealAction(deal.hands, deal.bottom, _seed),
    );
    _authState = _authState!.copyWith(ruleVariant: _variant);

    // 仅首次获取座位玩家昵称（后续复用）
    if (_seatNicks.every((n) => n.isEmpty)) {
      try {
        final roomSnap = await _client
            .watchRoom(_ctx.roomId)
            .first
            .timeout(const Duration(seconds: 5));
        _seatNicks = roomSnap.seats.map((s) => s?.nick ?? '').toList();
        _aiSeats = roomSnap.aiSeats;
      } catch (_) {}
    }

    // 更新自己的手牌
    _myHand = List.from(_authState!.players[_ctx.mySeat].hand);
    _myHand.sort((a, b) => b.rank.value.compareTo(a.rank.value));

    // 先调度定时器（设置 _turnDeadline），再构建显示和广播
    _maybeScheduleAi();
    _scheduleTurnTimeout();

    _lastStateData = null;
    state = _buildDisplayFromAuth();

    // 一次批量写入：status + ready + hands + game_state（1 次网络往返）
    final handsMap = <int, List<int>>{};
    for (var s = 0; s < 3; s++) {
      handsMap[s] = deal.hands[s].map((c) => c.index).toList();
    }
    await _client.batchUpdate(
      _ctx.roomId,
      status: 'playing',
      clearReady: true,
      hands: handsMap,
      gameState: _buildGameStateMap(),
    );
  }

  /// 房主处理动作后：一次批量写入手牌 + 游戏状态（1 次网络往返）。
  Future<void> _syncThenBroadcast() async {
    if (_authState == null) return;
    final handsMap = <int, List<int>>{};
    for (var s = 0; s < 3; s++) {
      handsMap[s] = _authState!.players[s].hand.map((c) => c.index).toList();
    }
    await _client.batchUpdate(
      _ctx.roomId,
      hands: handsMap,
      gameState: _buildGameStateMap(),
    );
  }

  /// 从 _authState 构建要广播的游戏状态 Map。
  Map<String, dynamic> _buildGameStateMap() {
    final s = _authState!;
    final lastAction = s.lastValidPlay;
    return {
      'phase': s.phase.name,
      'currentPlayer': s.currentPlayer,
      'landlordSeat': s.landlordSeat ?? -1,
      'multiplier': s.multiplier,
      'isSpring': s.isSpring,
      'isAntiSpring': s.isAntiSpring,
      'handCounts': s.players.map((p) => p.handCount).toList(),
      'passCount': s.passCount,
      'winnerSeat': s.winnerSeat ?? -1,
      'lastPlaySeat': lastAction?.seat ?? -1,
      'lastPlayCards': lastAction?.cards.map((c) => c.index).toList() ?? [],
      'lastPlayType': lastAction?.pattern.type.name ?? '',
      'lastPlayMainRank': lastAction?.pattern.mainRank ?? 0,
      'bidParticipants': s.bidParticipants,
      'currentMaxBid': s.currentMaxBid,
      'seatNicks': _seatNicks,
      'actedSeats': s.actedSeats.toList(),
      if (_turnDeadline != null) 'turnDeadline': _turnDeadline,
      'autoPlaySeats': _autoPlaySeats.toList(),
      'lastMoveBySeat': s.lastMoveBySeat.map(
        (k, v) => MapEntry('$k', v.map((c) => c.index).toList()),
      ),
      if (s.bottomCards.isNotEmpty)
        'bottomCards': s.bottomCards.map((c) => c.index).toList(),
      if (s.playedCards.isNotEmpty)
        'playedCards': s.playedCards.map((c) => c.index).toList(),
      // 始终广播 deckSeed + actionLog，房主重连时可重建 _authState
      'deckSeed': _seed,
      'actionLog': _actionLog.map((a) => a.toJson()).toList(),
      'ruleVariant': _variant.id,
      'brightSeats': s.brightSeats.toList(),
      if (s.phase == GamePhase.settled) ...{
        'allHands': s.players
            .map((p) => p.hand.map((c) => c.index).toList())
            .toList(),
      } else if (s.brightSeats.isNotEmpty) ...{
        'brightHands': {
          for (final seat in s.brightSeats)
            '$seat': s.players[seat].hand.map((c) => c.index).toList(),
        },
      },
    };
  }

  /// 房主从权威状态直接构建显示状态（座位重映射）。
  GameState _buildDisplayFromAuth() {
    final s = _authState!;
    final my = _ctx.mySeat;
    int toDisplay(int actual) => (actual - my + 3) % 3;
    final isSettled = s.phase == GamePhase.settled;

    final players = <PlayerState>[];
    for (var displaySeat = 0; displaySeat < 3; displaySeat++) {
      final actualSeat = (displaySeat + my) % 3;
      final isMe = displaySeat == 0;
      final authPlayer = s.players[actualSeat];
      // 自己 / 结算 / 明牌座位 → 显示真实手牌
      final showRealHand =
          isMe || isSettled || s.brightSeats.contains(actualSeat);
      final hand = showRealHand
          ? (isMe ? List<Card>.from(_myHand) : List<Card>.from(authPlayer.hand))
          : List<Card>.filled(authPlayer.handCount, Card.fromIndex(0));
      players.add(
        PlayerState(
          seat: displaySeat,
          role: authPlayer.role,
          hand: hand,
          isHuman: isMe,
          playCount: authPlayer.playCount,
          name: actualSeat < _seatNicks.length ? _seatNicks[actualSeat] : '',
        ),
      );
    }

    PlayFrame? lastPlay;
    if (s.lastValidPlay != null) {
      lastPlay = PlayFrame(
        toDisplay(s.lastValidPlay!.seat),
        s.lastValidPlay!.pattern,
        s.lastValidPlay!.cards,
      );
    }

    return GameState(
      phase: s.phase,
      players: players,
      currentPlayer: toDisplay(s.currentPlayer),
      landlordSeat: s.landlordSeat != null ? toDisplay(s.landlordSeat!) : null,
      bottomCards: s.bottomCards,
      lastValidPlay: lastPlay,
      passCount: s.passCount,
      multiplier: s.multiplier,
      isSpring: s.isSpring,
      isAntiSpring: s.isAntiSpring,
      deckSeed: _seed,
      winnerSeat: s.winnerSeat != null ? toDisplay(s.winnerSeat!) : null,
      currentMaxBid: s.currentMaxBid,
      bidParticipants: s.bidParticipants,
      replayLog: s.replayLog,
      playedCards: s.playedCards,
      actedSeats: s.actedSeats.map(toDisplay).toSet(),
      lastMoveBySeat: {
        for (final e in s.lastMoveBySeat.entries) toDisplay(e.key): e.value,
      },
      turnDeadline: _turnDeadline,
      autoPlaySeats: _autoPlaySeats.map(toDisplay).toSet(),
      seatOnline: [for (var d = 0; d < 3; d++) _seatOnline[(d + my) % 3]],
      ruleVariant: s.ruleVariant,
      brightSeats: s.brightSeats.map(toDisplay).toSet(),
    );
  }

  // ── AI 玩家调度 + 出牌超时（仅房主）──

  /// 检查当前轮到的玩家是否是 AI 或托管座位，如果是则延迟调度 AI 出牌。
  void _maybeScheduleAi() {
    _aiTimer?.cancel();
    if (_authState == null) return;
    if (_authState!.phase == GamePhase.settled) return;
    final cur = _authState!.currentPlayer;
    if (!_aiSeats.contains(cur) && !_autoPlaySeats.contains(cur)) return;
    _aiTimer = Timer(const Duration(milliseconds: 800), _runAiTurn);
  }

  /// 调度出牌超时定时器（60s，仅人类玩家）。
  void _scheduleTurnTimeout() {
    _turnTimer?.cancel();
    _turnDeadline = null;
    if (_authState == null) return;
    if (_authState!.phase == GamePhase.settled) return;
    final cur = _authState!.currentPlayer;
    if (_aiSeats.contains(cur)) return; // AI 有自己的调度
    _turnDeadline =
        DateTime.now().millisecondsSinceEpoch + _turnTimeoutSeconds * 1000;
    _turnTimer = Timer(Duration(seconds: _turnTimeoutSeconds), _onTurnTimeout);
  }

  /// 超时：进入托管模式，AI 立即接管出牌。
  void _onTurnTimeout() {
    if (_authState == null || _authState!.phase == GamePhase.settled) return;
    final seat = _authState!.currentPlayer;
    if (_aiSeats.contains(seat)) return;

    // 标记托管 + 广播 + 立即调度 AI
    _autoPlaySeats.add(seat);
    state = _buildDisplayFromAuth();
    _syncThenBroadcast();
    _maybeScheduleAi();
    _scheduleTurnTimeout();
  }

  /// 执行 AI/A托管的回合：调用 DouZero 决策，然后走房主处理管道。
  Future<void> _runAiTurn() async {
    if (_authState == null || _authState!.phase == GamePhase.settled) return;
    final seat = _authState!.currentPlayer;
    if (!_aiSeats.contains(seat) && !_autoPlaySeats.contains(seat)) return;

    final action = await _ai.chooseAction(_authState!, seat);

    // 期间状态可能已变（极端竞态），校验仍是该 AI 的回合
    if (_authState == null || _authState!.currentPlayer != seat) return;

    final json = action.toJson();
    if (!_engine.validate(_authState!, action).ok) {
      // AI 返回非法动作，兜底：叫分阶段叫 0，出牌阶段 Pass
      if (_authState!.phase == GamePhase.bidding) {
        json['type'] = 'bid';
        json['score'] = 0;
      } else {
        json['type'] = 'pass';
        json.remove('cards');
      }
    }

    _hostProcessAction(json);
  }

  // ── 客户端逻辑（所有人共用，含房主）──

  void _onGameState(Map<dynamic, dynamic>? data) {
    if (data == null) return;
    _lastStateData = data;
    // 房主使用 _buildDisplayFromAuth 权威显示，跳过 PostgresChanges 回声
    if (_authState != null) return;
    state = _buildDisplayState(data);
    // 非房主检测结算 → 记录战绩
    if (data['phase'] == 'settled') {
      final seed = data['deckSeed'] as int? ?? 0;
      if (seed > 0) _seed = seed;
      final logRaw = data['actionLog'] as List?;
      if (logRaw != null) {
        _actionLog.clear();
        for (final json in logRaw) {
          try {
            _actionLog.add(
              GameAction.fromJson(Map<String, dynamic>.from(json)),
            );
          } catch (_) {}
        }
        _turns = _estimateTurnsFromActionLog();
      }
      _maybeRecordSettlement();
    }
  }

  void _onMyHand(List<int> cardIndices) {
    // 权威手牌到达，清除 pending 状态
    _pendingTimer?.cancel();
    if (_pendingCardIndices.isNotEmpty) {
      _pendingCardIndices = {};
    }

    // 房主手牌从 _authState 同步，跳过 PostgresChanges 回声
    if (_authState != null) return;

    _myHand = cardIndices.map((i) => Card.fromIndex(i)).toList();
    _myHand.sort((a, b) => b.rank.value.compareTo(a.rank.value));
    // 手牌更新后重建显示（确保出牌后手牌立即变化）
    // 但跳过结算阶段（新游戏发牌时 _lastStateData 可能还是旧的 settled 数据）
    if (_lastStateData != null && _lastStateData!['phase'] != 'settled') {
      state = _buildDisplayState(
        _lastStateData!,
      ).copyWith(pendingCardIndices: _pendingCardIndices);
    }
  }

  /// Pending 超时：10 秒内未收到房主确认，清除 pending 状态 + 提示重试。
  void _rollbackPending() {
    if (_pendingCardIndices.isNotEmpty) {
      _pendingCardIndices = {};
      if (_lastStateData != null) {
        state = _buildDisplayState(_lastStateData!);
      }
    }
  }

  /// 根据公共状态 + 自己的手牌，构建本地显示用的 GameState。
  ///
  /// 座位重映射：本地玩家始终显示为 seat 0（与 GameScreen 的 humanSeat=0 对齐）。
  /// 显示座 0 = 我的实际座位；显示座 1 = (mySeat+1)%3；显示座 2 = (mySeat+2)%3。
  GameState _buildDisplayState(Map<dynamic, dynamic> data) {
    final phase = GamePhase.values.firstWhere(
      (p) => p.name == data['phase'],
      orElse: () => GamePhase.dealing,
    );
    final actualCurrent = data['currentPlayer'] as int? ?? 0;
    final actualLandlord = data['landlordSeat'] as int?;
    final multiplier = data['multiplier'] as int? ?? 1;
    final actualHandCounts =
        (data['handCounts'] as List?)?.map((e) => e as int).toList() ??
        [0, 0, 0];
    final actualWinner = data['winnerSeat'] as int?;
    final bottomCardsIdx =
        (data['bottomCards'] as List?)?.map((e) => e as int).toList() ?? [];

    final my = _ctx.mySeat;
    int toDisplay(int actual) => (actual - my + 3) % 3;
    final isSettled = phase == GamePhase.settled;

    // 结算时从广播数据提取三方真实手牌（RTDB 可能把空数组存为 null）
    final allHandsRaw = data['allHands'] as List?;
    final allHandsIdx = allHandsRaw
        ?.map((row) => row is List ? row.cast<int>() : <int>[])
        .toList();

    // 读取座位玩家昵称
    final seatNicksRaw = data['seatNicks'] as List?;
    final seatNicks =
        seatNicksRaw?.map((e) => e?.toString() ?? '').toList() ?? ['', '', ''];

    // 解析明牌玩家手牌（key = 实际座位号）
    final brightHandsRaw = data['brightHands'];
    final brightHandsMap = <int, List<int>>{};
    if (brightHandsRaw is Map) {
      for (final entry in brightHandsRaw.entries) {
        final seat = int.tryParse('${entry.key}') ?? -1;
        if (seat >= 0 && entry.value is List) {
          brightHandsMap[seat] = (entry.value as List)
              .map((e) => e as int)
              .toList();
        }
      }
    }

    // 构建玩家列表（重映射后）
    final players = <PlayerState>[];
    for (var displaySeat = 0; displaySeat < 3; displaySeat++) {
      final actualSeat = (displaySeat + my) % 3;
      final isMe = displaySeat == 0;
      final count = actualHandCounts.length > actualSeat
          ? actualHandCounts[actualSeat]
          : 0;
      List<Card> hand;
      if (isMe) {
        hand = _myHand;
      } else if (isSettled &&
          allHandsIdx != null &&
          actualSeat < allHandsIdx.length) {
        hand = allHandsIdx[actualSeat].map((i) => Card.fromIndex(i)).toList();
      } else if (brightHandsMap.containsKey(actualSeat)) {
        hand = brightHandsMap[actualSeat]!
            .map((i) => Card.fromIndex(i))
            .toList();
      } else {
        hand = List<Card>.filled(count, Card.fromIndex(0));
      }
      final isLandlord = actualLandlord != null && actualLandlord == actualSeat;
      players.add(
        PlayerState(
          seat: displaySeat,
          role: actualLandlord == null
              ? PlayerRole.undecided
              : (isLandlord ? PlayerRole.landlord : PlayerRole.farmer),
          hand: hand,
          isHuman: isMe,
          name: actualSeat < seatNicks.length ? seatNicks[actualSeat] : '',
        ),
      );
    }

    // 构建 lastValidPlay（重映射 seat）
    PlayFrame? lastPlay;
    final lpCards = (data['lastPlayCards'] as List?)
        ?.map((e) => e as int)
        .toList();
    final lpSeat = data['lastPlaySeat'] as int?;
    if (lpCards != null &&
        lpCards.isNotEmpty &&
        lpSeat != null &&
        lpSeat >= 0) {
      final cards = lpCards.map((i) => Card.fromIndex(i)).toList();
      final pattern = HandDetector.detect(cards);
      if (pattern != null) {
        lastPlay = PlayFrame(toDisplay(lpSeat), pattern, cards);
      }
    }

    // 结算时从 deckSeed + actionLog 重建 replayLog
    List<ReplayStep> replayLog = const [];
    int deckSeed = 0;
    if (isSettled) {
      deckSeed = data['deckSeed'] as int? ?? 0;
      final actionLogJson = data['actionLog'] as List?;
      final replayVariant = RuleVariant.byId(data['ruleVariant'] as String?);
      if (actionLogJson != null && deckSeed > 0) {
        final deal = replayVariant.shuffle
            ? Deck.deal(deckSeed)
            : Deck.dealNoShuffle(deckSeed);
        final engine = const GameEngine();
        var replayState = engine.apply(
          GameState.initial(),
          DealAction(deal.hands, deal.bottom, deckSeed),
        );
        replayState = replayState.copyWith(ruleVariant: replayVariant);
        for (final json in actionLogJson) {
          final action = GameAction.fromJson(Map<String, dynamic>.from(json));
          replayState = engine.apply(replayState, action);
        }
        replayLog = replayState.replayLog;
      }
    }

    // 反序列化 actedSeats（重映射）
    final actedSeatsRaw = data['actedSeats'] as List?;
    final actedSeats = actedSeatsRaw != null
        ? actedSeatsRaw.map((e) => toDisplay(e as int)).toSet()
        : <int>{};

    // 反序列化 lastMoveBySeat（重映射 seat + 还原 Card）
    final lastMoveBySeat = <int, List<Card>>{0: [], 1: [], 2: []};
    final lmbsRaw = data['lastMoveBySeat'];
    if (lmbsRaw is Map) {
      for (final entry in lmbsRaw.entries) {
        final actualSeat = int.tryParse('${entry.key}') ?? -1;
        if (actualSeat < 0 || actualSeat > 2) continue;
        final cardsIdx = entry.value as List?;
        lastMoveBySeat[toDisplay(actualSeat)] = cardsIdx != null
            ? cardsIdx.map((i) => Card.fromIndex(i as int)).toList()
            : const [];
      }
    }

    // 反序列化 playedCards（记牌器用）
    final playedCardsIdx = data['playedCards'] as List?;
    final playedCards = playedCardsIdx != null
        ? playedCardsIdx.map((i) => Card.fromIndex(i as int)).toList()
        : const <Card>[];

    final turnDeadline = data['turnDeadline'] as int?;

    // 反序列化 autoPlaySeats（重映射）
    final autoPlayRaw = data['autoPlaySeats'] as List?;
    final autoPlaySeats = autoPlayRaw != null
        ? autoPlayRaw.map((e) => toDisplay(e as int)).toSet()
        : <int>{};

    // 反序列化 brightSeats（重映射）
    final brightRaw = data['brightSeats'] as List?;
    final brightSeats = brightRaw != null
        ? brightRaw.map((e) => toDisplay(e as int)).toSet()
        : <int>{};

    return GameState(
      phase: phase,
      players: players,
      currentPlayer: toDisplay(actualCurrent),
      landlordSeat: actualLandlord != null && actualLandlord >= 0
          ? toDisplay(actualLandlord)
          : null,
      bottomCards: bottomCardsIdx.map((i) => Card.fromIndex(i)).toList(),
      lastValidPlay: lastPlay,
      passCount: data['passCount'] as int? ?? 0,
      multiplier: multiplier,
      isSpring: data['isSpring'] as bool? ?? false,
      isAntiSpring: data['isAntiSpring'] as bool? ?? false,
      deckSeed: deckSeed,
      winnerSeat: actualWinner != null && actualWinner >= 0
          ? toDisplay(actualWinner)
          : null,
      replayLog: replayLog,
      playedCards: playedCards,
      actedSeats: actedSeats,
      lastMoveBySeat: lastMoveBySeat,
      turnDeadline: turnDeadline,
      autoPlaySeats: autoPlaySeats,
      seatOnline: [for (var d = 0; d < 3; d++) _seatOnline[(d + my) % 3]],
      ruleVariant: RuleVariant.byId(data['ruleVariant'] as String?),
      brightSeats: brightSeats,
    );
  }
}
