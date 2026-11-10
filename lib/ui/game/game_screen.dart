import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/ai_debug_log.dart';
import '../../ai/ai_player.dart';
import '../../audio/card_announcer.dart';
import '../../audio/sfx_player.dart';
import '../../core/card.dart';
import '../../core/game_action.dart';
import '../../core/game_engine.dart';
import '../../core/game_phase.dart';
import '../../core/game_state.dart';
import '../../core/hand_detector.dart';
import '../../core/hand_pattern.dart';
import '../../core/hand_type.dart';
import '../../net/net_game_session.dart';
import '../../net/room_client.dart';
import '../../state/game_session.dart';
import '../../state/settings.dart';
import '../../stats/bankroll.dart';
import '../replay/replay_screen.dart';
import 'widgets/card_counter.dart';
import 'widgets/card_widget.dart';
import 'widgets/table_widgets.dart';

/// 座位布局：人类固定 seat 0（底部），下家 seat 1（右侧），上家 seat 2（左侧）。
const _rightSeat = 1;
const _leftSeat = 2;

/// 牌桌几何参数：全部按可用尺寸推导，适配不同横屏分辨率。
class _TableLayout {
  _TableLayout(this.size);

  final Size size;
  double get w => size.width;
  double get h => size.height;

  static const double topH = 52;
  static const double sidePad = 12;

  late final double handH = (h * 0.30).clamp(70.0, 150.0);
  late final double handW = handH * kCardAspect;
  late final double lift = handH * 0.16;
  late final double handTop = h - handH - 6;

  late final double slotH = (h * 0.19).clamp(46.0, 100.0);
  late final double stripH = slotH * 0.66;
  late final double humanSlotTop = handTop - lift - slotH - 2;

  late final double avatar = (h * 0.13).clamp(36.0, 60.0);
  late final double backH = (h * 0.15).clamp(38.0, 72.0);
  late final double seatColW = math.max(avatar + 10, 64);
  late final double seatW = seatColW + 6 + backH * kCardAspect * 1.2;
  late final double seatTop = topH + 4;

  late final double zoneInset = sidePad + seatW + 10;
  late final double zoneWidth = math.max(80.0, w / 2 - zoneInset - 10);
}

/// 对局主界面（横屏）。
///
/// 布局：
/// - 顶栏：记牌器（左）+ 底牌/底分/倍数（中）+ 功能按钮（右）
/// - 左右两侧：上家 / 下家头像、身份、叠放牌背（含剩余张数）与出牌区
/// - 底部：本家出牌区 / 操作按钮 + 重叠手牌
class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key});

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen> {
  /// 当前人类选中的牌（按 card.index）。
  final Set<int> _selected = {};
  bool? _dragSelecting; // true=滑动选中, false=滑动收回, null=未按下

  /// 选牌变化计数：手牌区 / 操作按钮监听它局部重建。
  final _selectionTick = ValueNotifier<int>(0);

  /// 上一次各座位的在线状态（用于检测变化 → 显示通知）。
  List<bool>? _prevSeatOnline;

  /// 炸弹/火箭特效（检测到新出炸弹时设置，1.5s 后自动清除）。
  HandType? _bombEffect;
  String? _lastPlayKey;

  /// 发牌动画（进入画面及每次重新发牌时播放）。
  bool _dealing = true;

  /// 叫分阶段各座位的表态（null=未表态，0=不叫，1~3=叫分）。
  final Map<int, int> _bidBySeat = {};

  /// 结算面板（结算后延迟弹出；「看牌」可收起）。
  bool _resultOpen = false;
  Timer? _resultTimer;

  /// 提示循环：同一局面多次点击「提示」依次切换候选。
  String? _hintKey;
  int _hintCursor = 0;

  /// 「不出」气泡短暂保留（一轮结束时 actedSeats 被清空，仍需让玩家看到最后一家不出）。
  final Map<int, Timer> _passFlash = {};

  void _flashPass(int seat) {
    _passFlash.remove(seat)?.cancel();
    _passFlash[seat] = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _passFlash.remove(seat));
    });
  }

  /// Toast 距离底部的位置（随布局更新）。
  double _toastBottom = 160;

  @override
  void dispose() {
    _selectionTick.dispose();
    _resultTimer?.cancel();
    for (final t in _passFlash.values) {
      t.cancel();
    }
    _topBannerTimer?.cancel();
    _toastTimer?.cancel();
    _topBannerEntry?.remove();
    _toastEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GameState>(gameSessionProvider, _onStateChanged);
    final state = ref.watch(gameSessionProvider);

    _checkSeatOnlineChange(state);
    _checkBombEffect(state);

    final notifier = ref.read(gameSessionProvider.notifier);
    final scaffold = Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: TableColors.feltEdge,
      body: TableFelt(
        child: SafeArea(
          child: state.phase == GamePhase.dealing
              ? const Center(
                  child: CircularProgressIndicator(color: TableColors.gold),
                )
              : LayoutBuilder(
                  builder: (context, c) =>
                      _buildTable(state, _TableLayout(c.biggest)),
                ),
        ),
      ),
    );
    // 联网模式由 NetGameScreen 的 PopScope 处理；单机模式加退出确认
    if (notifier.isOnlineMode) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showExitDialog(context);
      },
      child: scaffold,
    );
  }

  // ---------- 状态变化侦测：报牌 / 叫分气泡 / 发牌动画 / 结算面板 ----------

  void _onStateChanged(GameState? prev, GameState next) {
    if (prev == null) return;
    final announcer = ref.read(cardAnnouncerProvider);

    final newDeal =
        next.deckSeed != prev.deckSeed ||
        (prev.phase == GamePhase.settled && next.phase != GamePhase.settled);
    if (newDeal) {
      _resultTimer?.cancel();
      for (final t in _passFlash.values) {
        t.cancel();
      }
      setState(() {
        _passFlash.clear();
        _bidBySeat.clear();
        _selected.clear();
        _resultOpen = false;
        _dealing = true;
      });
      return;
    }

    if (prev.phase == GamePhase.bidding &&
        (next.bidParticipants > prev.bidParticipants ||
            next.phase != GamePhase.bidding)) {
      final bidder = prev.currentPlayer;
      final score =
          next.currentMaxBid > prev.currentMaxBid &&
              next.highestBidder == bidder
          ? next.currentMaxBid
          : 0;
      announcer.announceBid(bidder, score);
      setState(() {
        if (next.phase == GamePhase.bidding) {
          _bidBySeat[bidder] = score;
        } else {
          _bidBySeat.clear();
        }
      });
    }

    if (prev.phase == GamePhase.playing &&
        prev.players.length == 3 &&
        next.players.length == 3) {
      var anyPlay = false;
      for (var s = 0; s < 3; s++) {
        final before = prev.players[s].handCount;
        final after = next.players[s].handCount;
        if (after < before) {
          anyPlay = true;
          final cards = next.lastMoveBySeat[s] ?? const <Card>[];
          if (cards.isNotEmpty) {
            announcer.announcePlay(s, cards, remaining: after);
          }
        }
      }
      if (!anyPlay &&
          next.phase == GamePhase.playing &&
          next.currentPlayer != prev.currentPlayer) {
        announcer.announcePass(prev.currentPlayer);
        setState(() => _flashPass(prev.currentPlayer));
      }
    }

    if (prev.phase != GamePhase.settled && next.phase == GamePhase.settled) {
      _resultTimer?.cancel();
      _resultTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _resultOpen = true);
      });
    }
  }

  void _showExitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出游戏'),
        content: const Text('确定要退出当前对局吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  /// 检测座位在线状态变化，显示顶部居中通知。
  void _checkSeatOnlineChange(GameState state) {
    final cur = state.seatOnline;
    final prev = _prevSeatOnline;
    _prevSeatOnline = List.from(cur);
    if (prev == null || prev.length < 3 || cur.length < 3) return;
    final messages = <String>[];
    final colors = <Color>[];
    for (var i = 0; i < 3; i++) {
      if (prev[i] != cur[i]) {
        final name = i < state.players.length
            ? (state.players[i].name.isNotEmpty
                  ? state.players[i].name
                  : '玩家${i + 1}')
            : '玩家${i + 1}';
        if (cur[i]) {
          messages.add('$name 重新连接了');
          colors.add(Colors.green);
        } else {
          messages.add('$name 已断开连接');
          colors.add(Colors.orange);
        }
      }
    }
    if (messages.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (var i = 0; i < messages.length; i++) {
          _showTopBanner(messages[i], colors[i]);
        }
      });
    }
  }

  /// 检测炸弹/火箭出牌 → 触发全屏特效。
  void _checkBombEffect(GameState state) {
    final lp = state.lastValidPlay;
    if (lp == null) return;
    final playKey = '${lp.seat}-${lp.cards.map((c) => c.index).join('-')}';
    if (playKey == _lastPlayKey) return;
    _lastPlayKey = playKey;
    if (lp.pattern.type.isBombLike) {
      _bombEffect = lp.pattern.type;
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _bombEffect = null);
      });
    }
  }

  /// 联网模式结算页「离开」按钮：确认后清理房间数据并返回首页。
  void _showOnlineExitDialog(BuildContext context) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开房间'),
        content: const Text('确定要离开当前房间吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('离开'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true) return;
      final ctx2 = ref.read(netRoomContextProvider);
      final client = ref
          .read(roomClientProvider)
          .maybeWhen(data: (c) => c, orElse: () => null);
      if (client != null && context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(
            child: CircularProgressIndicator(color: Colors.amber),
          ),
        );
        try {
          await client.exitRoom(ctx2.roomId, ctx2.mySeat);
        } catch (_) {}
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
    });
  }

  // ---------- 牌桌 ----------

  Widget _buildTable(GameState state, _TableLayout l) {
    final online = ref.read(gameSessionProvider.notifier).isOnlineMode;
    _toastBottom = l.h - l.humanSlotTop + 8;
    final settled = state.phase == GamePhase.settled;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 顶栏
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: _TableLayout.topH,
          child: _buildTopBar(state, l, online),
        ),
        // 左右对手
        _buildOpponent(state, l, _leftSeat, left: true),
        _buildOpponent(state, l, _rightSeat, left: false),
        // 叫地主状态提示
        if (state.phase == GamePhase.bidding)
          Positioned(
            left: 0,
            right: 0,
            top: l.humanSlotTop - 34,
            child: Center(child: _buildBiddingStatus(state)),
          ),
        // 本家头像
        Positioned(
          left: _TableLayout.sidePad,
          top: l.humanSlotTop + (l.slotH - l.avatar) / 2 - 6,
          child: _buildHumanBadge(state, l),
        ),
        // 本家出牌区 / 操作按钮
        Positioned(
          left: l.w * 0.2,
          right: l.w * 0.2,
          top: l.humanSlotTop,
          height: l.slotH,
          child: ValueListenableBuilder<int>(
            valueListenable: _selectionTick,
            builder: (_, _, _) => _buildHumanSlot(state, l),
          ),
        ),
        // 手牌
        Positioned(
          left: 16,
          right: 16,
          top: l.handTop - l.lift,
          height: l.handH + l.lift,
          child: AnimatedOpacity(
            opacity: _dealing ? 0 : 1,
            duration: const Duration(milliseconds: 300),
            child: ValueListenableBuilder<int>(
              valueListenable: _selectionTick,
              builder: (_, _, _) => _buildHand(state, l),
            ),
          ),
        ),
        // 发牌动画
        if (_dealing)
          _DealAnimation(
            layout: l,
            onDone: () {
              if (mounted) setState(() => _dealing = false);
            },
          ),
        if (_bombEffect != null) _buildBombOverlay(_bombEffect!),
        if (settled && _resultOpen) _buildResultPanel(state, l),
      ],
    );
  }

  // ---------- 顶栏 ----------

  Widget _buildTopBar(GameState state, _TableLayout l, bool online) {
    final debugTools = ref.watch(debugToolsEnabledProvider);
    final showHands = ref.watch(debugShowHandsProvider);
    final counterOn =
        ref.watch(cardCounterEnabledProvider) &&
        (state.phase == GamePhase.playing || state.phase == GamePhase.settled);

    const trayW = 212.0;
    final centeredLeft = l.w / 2 - trayW / 2;
    final cellW = ((centeredLeft - 32 - 12) / 15).clamp(16.0, 22.0);
    final counterW = counterOn ? CardCounter.expandedWidth(cellW) : 0.0;
    final trayLeft = math.max(centeredLeft, 8 + counterW + 10);

    return Stack(
      children: [
        Positioned(
          left: 8,
          top: 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (counterOn)
                CardCounter(state: state, mySeat: humanSeat, cellWidth: cellW),
            ],
          ),
        ),
        Positioned(
          left: trayLeft,
          top: 4,
          width: trayW,
          child: _buildBottomTray(state),
        ),
        Positioned(
          right: online ? 48 : 8,
          top: 6,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (debugTools) ...[
                const _AiStatusBadge(),
                const SizedBox(width: 6),
                RoundIconButton(
                  icon: showHands ? Icons.visibility : Icons.visibility_off,
                  color: showHands ? TableColors.gold : Colors.white54,
                  tooltip: '透视',
                  onTap: () => ref.read(debugShowHandsProvider.notifier).state =
                      !ref.read(debugShowHandsProvider),
                ),
                const SizedBox(width: 6),
              ],
              if (!online)
                RoundIconButton(
                  icon: Icons.close,
                  tooltip: '退出',
                  onTap: () => _showExitDialog(context),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 底牌托盘：叫地主前显示牌背，成交后翻开；右侧显示底分与倍数。
  Widget _buildBottomTray(GameState state) {
    final revealed = state.phase != GamePhase.bidding;
    const cardH = 40.0;
    const cardW = cardH * kCardAspect;
    final base = state.phase == GamePhase.bidding
        ? state.currentMaxBid
        : (state.currentMaxBid > 0 ? state.currentMaxBid : state.multiplier);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: TableColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TableColors.gold.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < state.bottomCards.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: CardWidget(
                  key: ValueKey('bottom-$i-$revealed'),
                  card: state.bottomCards[i],
                  faceDown: !revealed,
                  width: cardW,
                  height: cardH,
                ),
              ),
            ),
          const Spacer(),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _trayStat('底分', base > 0 ? '$base' : '-'),
              const SizedBox(height: 2),
              _trayStat('倍数', '×${state.multiplier}', highlight: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _trayStat(String k, String v, {bool highlight = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          k,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 10,
            height: 1,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          v,
          style: TextStyle(
            color: highlight ? TableColors.gold : Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ],
    );
  }

  // ---------- 对手 ----------

  String _seatName(GameState state, int seat) {
    final p = state.players[seat];
    if (p.name.isNotEmpty) return p.name;
    if (seat == humanSeat) return '我';
    return seat == _leftSeat ? '上家' : '下家';
  }

  bool _isOnline(GameState state, int seat) =>
      state.seatOnline.length > seat ? state.seatOnline[seat] : true;

  Widget _buildOpponent(
    GameState state,
    _TableLayout l,
    int seat, {
    required bool left,
  }) {
    final player = state.players[seat];
    final isLandlord = player.role == PlayerRole.landlord;
    final isFarmer = player.role == PlayerRole.farmer;
    final active =
        state.currentPlayer == seat &&
        (state.phase == GamePhase.playing || state.phase == GamePhase.bidding);
    final name = _seatName(state, seat);
    final alarm =
        state.phase == GamePhase.playing &&
        player.handCount > 0 &&
        player.handCount <= 2;

    final avatarCol = SizedBox(
      width: l.seatColW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SeatAvatar(
            label: name.substring(0, 1),
            size: l.avatar,
            isLandlord: isLandlord,
            isFarmer: isFarmer,
            active: active,
            offline: !_isOnline(state, seat),
            autoPlay: state.autoPlaySeats.contains(seat),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
            ),
          ),
        ],
      ),
    );

    final stack = CardBackStack(
      count: player.handCount,
      cardHeight: l.backH,
      alarm: alarm,
    );

    final seatPanel = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: left
          ? [avatarCol, const SizedBox(width: 6), stack]
          : [stack, const SizedBox(width: 6), avatarCol],
    );

    final showFaceUp =
        ref.watch(debugShowHandsProvider) ||
        state.phase == GamePhase.settled ||
        state.brightSeats.contains(seat);
    final faceUpCards = sortForDisplay(player.hand);
    final stripShown = showFaceUp && faceUpCards.isNotEmpty;
    final playTop = l.seatTop + 2 + (stripShown ? l.stripH + 6 : 0);
    final align = left ? Alignment.topLeft : Alignment.topRight;

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: l.seatTop,
            left: left ? _TableLayout.sidePad : null,
            right: left ? null : _TableLayout.sidePad,
            child: Column(
              crossAxisAlignment: left
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                seatPanel,
                const SizedBox(height: 6),
                SizedBox(
                  height: 22,
                  child: active
                      ? (state.turnDeadline != null
                            ? _TurnCountdownBadge(deadline: state.turnDeadline!)
                            : const ThinkingDots(color: TableColors.gold))
                      : null,
                ),
              ],
            ),
          ),
          if (stripShown)
            Positioned(
              top: l.seatTop + 2,
              left: left ? l.zoneInset : null,
              right: left ? null : l.zoneInset,
              width: l.zoneWidth,
              height: l.stripH,
              child: Align(
                alignment: align,
                child: CardFan(
                  cards: faceUpCards,
                  cardHeight: l.stripH,
                  maxWidth: l.zoneWidth,
                  maxStepRatio: 0.34,
                ),
              ),
            ),
          Positioned(
            top: playTop,
            left: left ? l.zoneInset : null,
            right: left ? null : l.zoneInset,
            width: l.zoneWidth,
            height: l.slotH + 4,
            child: _buildPlayZone(
              state,
              seat,
              l,
              maxWidth: l.zoneWidth,
              alignment: left ? Alignment.centerLeft : Alignment.centerRight,
            ),
          ),
        ],
      ),
    );
  }

  /// 某座位的出牌区：最近一手牌 / 「不出」/ 叫分气泡。
  Widget _buildPlayZone(
    GameState state,
    int seat,
    _TableLayout l, {
    required double maxWidth,
    required Alignment alignment,
  }) {
    String key = 'empty';
    Widget child = const SizedBox.shrink();

    if (state.phase == GamePhase.bidding) {
      final bid = _bidBySeat[seat];
      if (bid != null) {
        key = 'bid-$bid';
        child = SpeechBubble(
          text: bid == 0 ? '不叫' : '叫$bid分',
          color: bid == 0 ? Colors.white70 : TableColors.gold,
          fontSize: (l.slotH * 0.26).clamp(13.0, 20.0),
        );
      }
    } else if (state.phase == GamePhase.playing ||
        state.phase == GamePhase.settled) {
      final acted =
          state.phase == GamePhase.settled || state.actedSeats.contains(seat);
      var lastMove = acted ? state.lastMoveBySeat[seat] : null;
      if ((lastMove == null || lastMove.isEmpty) &&
          state.phase == GamePhase.playing &&
          _passFlash.containsKey(seat)) {
        lastMove = const <Card>[];
      }
      if (lastMove != null) {
        if (lastMove.isEmpty) {
          if (state.phase == GamePhase.playing) {
            key = 'pass';
            child = SpeechBubble(
              text: '不出',
              color: Colors.white70,
              fontSize: (l.slotH * 0.26).clamp(13.0, 20.0),
            );
          }
        } else {
          key = lastMove.map((c) => c.index).join('-');
          final isActive = state.lastValidPlay?.seat == seat;
          child = AnimatedOpacity(
            opacity: isActive ? 1.0 : 0.6,
            duration: const Duration(milliseconds: 300),
            child: CardFan(
              cards: sortForDisplay(lastMove),
              cardHeight: l.slotH,
              maxWidth: maxWidth,
            ),
          );
        }
      }
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: Tween<double>(begin: 0.6, end: 1.0).animate(animation),
        alignment: alignment,
        child: FadeTransition(opacity: animation, child: child),
      ),
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      child: Align(key: ValueKey(key), alignment: alignment, child: child),
    );
  }

  Widget _buildBiddingStatus(GameState state) {
    final isHumanTurn = state.currentPlayer == humanSeat;
    if (isHumanTurn) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: TableColors.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.currentMaxBid > 0
                ? '${_seatName(state, state.currentPlayer)} 叫分中 · 当前 ${state.currentMaxBid} 分'
                : '${_seatName(state, state.currentPlayer)} 叫分中',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(width: 6),
          const ThinkingDots(size: 4, color: TableColors.gold),
        ],
      ),
    );
  }

  // ---------- 本家 ----------

  Widget _buildHumanBadge(GameState state, _TableLayout l) {
    final me = state.players[humanSeat];
    final active =
        state.currentPlayer == humanSeat &&
        (state.phase == GamePhase.playing || state.phase == GamePhase.bidding);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SeatAvatar(
          label: _seatName(state, humanSeat).substring(0, 1),
          size: l.avatar,
          isLandlord: me.role == PlayerRole.landlord,
          isFarmer: me.role == PlayerRole.farmer,
          active: active,
          autoPlay: state.autoPlaySeats.contains(humanSeat),
        ),
        const SizedBox(width: 6),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TableColors.panel,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '剩 ${me.handCount} 张',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            BankrollChip(value: ref.watch(bankrollProvider)),
          ],
        ),
      ],
    );
  }

  Widget _buildHumanSlot(GameState state, _TableLayout l) {
    final isHumanTurn = state.currentPlayer == humanSeat;
    final btnH = (l.slotH * 0.5).clamp(32.0, 42.0);

    if (state.phase == GamePhase.bidding) {
      if (isHumanTurn) {
        return Center(child: _buildBidButtons(state, btnH));
      }
      return _buildPlayZone(
        state,
        humanSeat,
        l,
        maxWidth: l.w * 0.6,
        alignment: Alignment.center,
      );
    }

    if (state.phase == GamePhase.settled) {
      if (_resultOpen) {
        return _buildPlayZone(
          state,
          humanSeat,
          l,
          maxWidth: l.w * 0.6,
          alignment: Alignment.center,
        );
      }
      return Center(child: _buildSettlementBar(state, btnH));
    }

    final isAutoPlaying = state.autoPlaySeats.contains(humanSeat);
    if (isAutoPlaying) {
      return Center(
        child: TableButton(
          label: '托管中 · 点击取消',
          icon: Icons.smart_toy,
          style: TableButtonStyle.accent,
          height: btnH,
          onTap: () => ref.read(gameSessionProvider.notifier).disableAutoPlay(),
        ),
      );
    }
    if (isHumanTurn && state.phase == GamePhase.playing) {
      return Center(child: _buildActionBar(state, btnH));
    }
    return _buildPlayZone(
      state,
      humanSeat,
      l,
      maxWidth: l.w * 0.6,
      alignment: Alignment.center,
    );
  }

  Widget _buildBidButtons(GameState state, double btnH) {
    final n = ref.read(gameSessionProvider.notifier);
    final max = state.ruleVariant.bidMax;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TableButton(label: '不叫', height: btnH, onTap: () => n.bid(0)),
        for (var s = 1; s <= max; s++) ...[
          const SizedBox(width: 10),
          TableButton(
            label: '$s分',
            height: btnH,
            style: s == max
                ? TableButtonStyle.primary
                : TableButtonStyle.accent,
            enabled: state.currentMaxBid < s,
            onTap: () => n.bid(s),
          ),
        ],
        if (state.turnDeadline != null) ...[
          const SizedBox(width: 10),
          _TurnCountdownBadge(deadline: state.turnDeadline!),
        ],
      ],
    );
  }

  Widget _buildActionBar(GameState state, double btnH) {
    final human = state.players[humanSeat];
    final selectedCards = human.hand
        .where((c) => _selected.contains(c.index))
        .toList();
    final isPending = state.pendingCardIndices.isNotEmpty;
    final canPlay =
        !isPending &&
        selectedCards.isNotEmpty &&
        _canPlay(state, selectedCards);
    final mustLead =
        state.lastValidPlay == null || state.lastValidPlay!.seat == humanSeat;
    final canPass = !isPending && !mustLead;

    final online = ref.read(gameSessionProvider.notifier).isOnlineMode;
    final canBright =
        online &&
        humanSeat == state.landlordSeat &&
        state.lastValidPlay == null &&
        !state.brightSeats.contains(humanSeat);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canBright) ...[
          TableButton(
            label: '明牌×2',
            height: btnH,
            style: TableButtonStyle.accent,
            onTap: () => ref.read(gameSessionProvider.notifier).bright(),
          ),
          const SizedBox(width: 10),
        ],
        if (!mustLead) ...[
          TableButton(
            label: '不出',
            height: btnH,
            enabled: canPass,
            onTap: _pass,
          ),
          const SizedBox(width: 10),
        ],
        TableButton(
          label: '提示',
          height: btnH,
          style: TableButtonStyle.accent,
          enabled: !isPending,
          onTap: () => _hint(state),
        ),
        const SizedBox(width: 10),
        TableButton(
          label: '出牌',
          height: btnH,
          style: TableButtonStyle.primary,
          enabled: canPlay,
          onTap: _play,
        ),
        if (state.turnDeadline != null) ...[
          const SizedBox(width: 10),
          _TurnCountdownBadge(deadline: state.turnDeadline!),
        ],
      ],
    );
  }

  // ---------- 手牌 ----------

  Widget _buildHand(GameState state, _TableLayout l) {
    final human = state.players[humanSeat];
    final hand = human.hand; // 已按 rank 降序
    final isHumanTurn =
        state.currentPlayer == humanSeat && state.phase == GamePhase.playing;
    final isPending = state.pendingCardIndices.isNotEmpty;
    final isAutoPlaying = state.autoPlaySeats.contains(humanSeat);
    final canInteract = isHumanTurn && !isPending && !isAutoPlaying;

    // 地主刚拿到底牌时高亮底牌，首次出牌后取消
    final bottomIdx =
        state.phase == GamePhase.playing &&
            state.landlordSeat == humanSeat &&
            human.playCount == 0
        ? state.bottomCards.map((c) => c.index).toSet()
        : const <int>{};

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = hand.length;
        final cardW = l.handW;
        final avail = constraints.maxWidth;
        final step = total <= 1
            ? 0.0
            : math.min(cardW * 0.52, (avail - cardW) / (total - 1));
        final totalWidth = total <= 1 ? cardW : (total - 1) * step + cardW;
        final offset = math.max(0.0, (avail - totalWidth) / 2);

        int indexAt(double x) => _cardIndexAtX(x, offset, step, total, cardW);

        void applyAt(double x) {
          final mode = _dragSelecting;
          if (mode == null) return;
          final idx = indexAt(x);
          if (idx < 0) return;
          final cardIdx = hand[idx].index;
          final changed = mode
              ? _selected.add(cardIdx)
              : _selected.remove(cardIdx);
          if (changed) _onSelectionChanged();
        }

        // 用原始指针事件代替 GestureDetector：按下即响应，
        // 无双击判定 / 手势竞技场带来的 ~300ms 延迟。
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (isAutoPlaying) {
              ref.read(gameSessionProvider.notifier).disableAutoPlay();
              return;
            }
            if (!canInteract) return;
            final idx = indexAt(e.localPosition.dx);
            if (idx < 0) return;
            // 起始牌未选中 → 本次按下/滑动为选中模式；已选中 → 收回模式
            _dragSelecting = !_selected.contains(hand[idx].index);
            applyAt(e.localPosition.dx);
          },
          onPointerMove: canInteract
              ? (e) => applyAt(e.localPosition.dx)
              : null,
          onPointerUp: (_) => _dragSelecting = null,
          onPointerCancel: (_) => _dragSelecting = null,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < total; i++)
                AnimatedPositioned(
                  key: ValueKey(hand[i].index),
                  left: offset + i * step,
                  top: _selected.contains(hand[i].index) ? 0 : l.lift,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: RepaintBoundary(
                    child: CardWidget(
                      card: hand[i],
                      width: cardW,
                      height: l.handH,
                      selected: _selected.contains(hand[i].index),
                      liftOnSelect: false,
                      highlight: bottomIdx.contains(hand[i].index),
                      dimmed:
                          isPending &&
                          state.pendingCardIndices.contains(hand[i].index),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 根据 x 坐标计算对应的手牌索引（最后一张占满整张牌宽）。
  int _cardIndexAtX(
    double x,
    double offset,
    double step,
    int total,
    double cardW,
  ) {
    final relX = x - offset;
    if (relX < 0 || total == 0) return -1;
    if (step <= 0) return relX <= cardW ? 0 : -1;
    final idx = (relX / step).floor();
    if (idx < total) return idx;
    return relX <= (total - 1) * step + cardW ? total - 1 : -1;
  }

  /// 选牌变化：只重建手牌区与操作按钮（不重建整张牌桌），触感反馈代替音频播放。
  void _onSelectionChanged() {
    _selectionTick.value++;
    ref.read(sfxPlayerProvider).haptic(Sfx.select);
  }

  bool _canPlay(GameState state, List<Card> cards) {
    final pattern = HandDetector.detect(cards);
    if (pattern == null) return false;
    final result = const GameEngine().validate(
      state,
      PlayAction(humanSeat, cards),
    );
    return result.ok;
  }

  void _play() {
    final human = ref.read(gameSessionProvider).players[humanSeat];
    final cards = human.hand.where((c) => _selected.contains(c.index)).toList();
    if (cards.isEmpty) return;
    ref.read(gameSessionProvider.notifier).play(cards);
    setState(_selected.clear);
  }

  void _pass() {
    ref.read(gameSessionProvider.notifier).pass();
    setState(_selected.clear);
  }

  /// 提示候选重排：会拆散炸弹 / 王炸的组合放到最后（其余保持原顺序）。
  static List<HandPattern> _preferIntact(
    List<Card> hand,
    List<HandPattern> beats,
  ) {
    final counts = <Rank, int>{};
    for (final c in hand) {
      counts[c.rank] = (counts[c.rank] ?? 0) + 1;
    }
    final hasRocket = (counts[Rank.bj] ?? 0) > 0 && (counts[Rank.rj] ?? 0) > 0;
    bool breaks(HandPattern p) {
      final used = <Rank, int>{};
      for (final c in p.cards) {
        used[c.rank] = (used[c.rank] ?? 0) + 1;
      }
      for (final e in used.entries) {
        if (counts[e.key] == 4 && e.value < 4) return true;
      }
      if (hasRocket) {
        final jokers = (used[Rank.bj] ?? 0) + (used[Rank.rj] ?? 0);
        if (jokers == 1) return true;
      }
      return false;
    }

    return [...beats.where((p) => !breaks(p)), ...beats.where(breaks)];
  }

  void _hint(GameState state) {
    final human = state.players[humanSeat];
    final last = state.lastValidPlay;
    final lead = last == null || last.seat == humanSeat;
    final beats = _preferIntact(
      human.hand,
      AiHandSearch.findBeats(human.hand, lead ? null : last.pattern),
    );
    if (beats.isEmpty) {
      _showToast('没有能大过上家的牌');
      return;
    }
    final key =
        '${human.handCount}-${last?.seat}-${last?.cards.map((c) => c.index).join(',')}';
    if (key != _hintKey) {
      _hintKey = key;
      _hintCursor = 0;
    } else {
      _hintCursor = (_hintCursor + 1) % beats.length;
    }
    final pick = beats[_hintCursor];
    setState(() {
      _selected
        ..clear()
        ..addAll(pick.cards.map((c) => c.index));
    });
  }

  // ---------- 浮层提示 ----------

  OverlayEntry? _topBannerEntry;
  Timer? _topBannerTimer;
  void _showTopBanner(String message, Color color) {
    _topBannerEntry?.remove();
    _topBannerTimer?.cancel();
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 52,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _topBannerEntry = entry;
    Overlay.of(context).insert(entry);
    _topBannerTimer = Timer(const Duration(milliseconds: 2500), () {
      entry.remove();
      if (_topBannerEntry == entry) _topBannerEntry = null;
    });
  }

  OverlayEntry? _toastEntry;
  Timer? _toastTimer;
  void _showToast(String message) {
    _toastEntry?.remove();
    _toastTimer?.cancel();
    final bottom = _toastBottom;
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: bottom,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  message,
                  style: const TextStyle(
                    color: TableColors.gold,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _toastEntry = entry;
    Overlay.of(context).insert(entry);
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      entry.remove();
      if (_toastEntry == entry) _toastEntry = null;
    });
  }

  // ---------- 特效 ----------

  /// 炸弹/火箭全屏特效：径向渐变闪光 + 大字提示。
  Widget _buildBombOverlay(HandType type) {
    final isRocket = type == HandType.rocket;
    final flashColor = isRocket ? Colors.purpleAccent : Colors.deepOrangeAccent;
    return Positioned.fill(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 1500),
          builder: (context, t, child) {
            final opacity = t < 0.25
                ? t / 0.25
                : (t > 0.75 ? (1 - t) / 0.25 : 1.0);
            final scale =
                0.6 +
                0.4 * Curves.elasticOut.transform((t * 2).clamp(0.0, 1.0));
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.8,
                colors: [
                  flashColor.withValues(alpha: 0.35),
                  Colors.transparent,
                ],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isRocket
                        ? Icons.rocket_launch
                        : Icons.local_fire_department,
                    size: 44,
                    color: flashColor,
                    shadows: const [
                      Shadow(blurRadius: 8, color: Colors.black54),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isRocket ? '王 炸' : '炸 弹',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6,
                      color: flashColor,
                      shadows: const [
                        Shadow(
                          offset: Offset(2, 2),
                          blurRadius: 6,
                          color: Colors.black87,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 结算 ----------

  Widget _buildResultPanel(GameState state, _TableLayout l) {
    final winnerSeat = state.winnerSeat!;
    final landlordSeat = state.landlordSeat!;
    final landlordWon = winnerSeat == landlordSeat;
    final humanWon = landlordWon == (humanSeat == landlordSeat);
    final m = state.multiplier;
    final btnH = (l.slotH * 0.48).clamp(32.0, 40.0);
    final panelW = math.min(440.0, l.w * 0.62);

    int scoreOf(int seat) {
      final isLandlord = seat == landlordSeat;
      final mag = isLandlord ? 2 * m : m;
      final won = isLandlord ? landlordWon : !landlordWon;
      return (won ? mag : -mag) * kScoreUnit;
    }

    final bankroll = ref.watch(bankrollProvider);

    final titleColors = humanWon
        ? const [Color(0xFFFFF59D), Color(0xFFFFB300)]
        : const [Color(0xFFCFD8DC), Color(0xFF78909C)];

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        alignment: Alignment.center,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1.0),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutBack,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Container(
            width: panelW,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xF0173A2A), Color(0xF00A2018)],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: titleColors.last.withValues(alpha: 0.8),
                width: 1.5,
              ),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 18),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (r) =>
                        LinearGradient(colors: titleColors).createShader(r),
                    child: Text(
                      humanWon ? '胜 利' : '失 败',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 8,
                        height: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _resultChip(
                        landlordWon ? '地主获胜' : '农民获胜',
                        landlordWon ? TableColors.landlord : TableColors.farmer,
                      ),
                      _resultChip('倍数 ×$m', TableColors.gold),
                      if (state.isSpring) _resultChip('春天', Colors.pinkAccent),
                      if (state.isAntiSpring)
                        _resultChip('反春天', Colors.pinkAccent),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final seat in const [humanSeat, _rightSeat, _leftSeat])
                    _resultRow(state, seat, scoreOf(seat), landlordSeat),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '我的积分',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      BankrollChip(value: bankroll, large: true),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TableButton(
                        label: '看牌',
                        height: btnH,
                        minWidth: 70,
                        onTap: () => setState(() => _resultOpen = false),
                      ),
                      const SizedBox(width: 10),
                      ..._settlementButtons(state, btnH),
                    ],
                  ),
                  ..._settlementWaitingHint(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _resultRow(GameState state, int seat, int score, int landlordSeat) {
    final isMe = seat == humanSeat;
    final isLandlord = seat == landlordSeat;
    final positive = score > 0;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isMe
            ? TableColors.gold.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isLandlord ? Icons.workspace_premium : Icons.agriculture,
            size: 16,
            color: isLandlord ? TableColors.landlord : TableColors.farmer,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _seatName(state, seat),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: isMe ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              isLandlord ? '地主' : '农民',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '剩${state.players[seat].handCount}张',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              positive ? '+$score' : '$score',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: positive ? const Color(0xFFFFD54F) : Colors.white54,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 结算后（收起面板时）出牌区位置显示的按钮栏。
  Widget _buildSettlementBar(GameState state, double btnH) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TableButton(
              label: '战绩',
              height: btnH,
              minWidth: 70,
              onTap: () => setState(() => _resultOpen = true),
            ),
            const SizedBox(width: 10),
            ..._settlementButtons(state, btnH),
          ],
        ),
        ..._settlementWaitingHint(),
      ],
    );
  }

  List<Widget> _settlementButtons(GameState state, double btnH) {
    final notifier = ref.read(gameSessionProvider.notifier);
    final online = notifier.isOnlineMode;
    final host = notifier.isHost;
    final allReady = notifier.readySeats.every((r) => r);
    final amReady = notifier.amReady;

    void restart() {
      setState(() {
        _selected.clear();
        _resultOpen = false;
      });
      notifier.newGame();
    }

    return [
      TableButton(
        label: '复盘',
        height: btnH,
        minWidth: 70,
        style: TableButtonStyle.accent,
        enabled: state.replayLog.isNotEmpty,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ReplayScreen(
                replayLog: List<ReplayStep>.from(state.replayLog),
                finalState: state,
              ),
            ),
          );
        },
      ),
      const SizedBox(width: 10),
      if (!online || host)
        TableButton(
          label: '再来一局',
          height: btnH,
          style: TableButtonStyle.primary,
          enabled: !online || allReady,
          onTap: restart,
        )
      else
        TableButton(
          label: amReady ? '已准备' : '准备',
          height: btnH,
          style: TableButtonStyle.primary,
          enabled: !amReady,
          onTap: notifier.toggleReady,
        ),
      if (online) ...[
        const SizedBox(width: 10),
        TableButton(
          label: '离开',
          height: btnH,
          minWidth: 64,
          style: TableButtonStyle.danger,
          onTap: () => _showOnlineExitDialog(context),
        ),
      ],
    ];
  }

  List<Widget> _settlementWaitingHint() {
    final notifier = ref.read(gameSessionProvider.notifier);
    if (!notifier.isOnlineMode || !notifier.isHost) return const [];
    final ready = notifier.readySeats.where((r) => r).length;
    if (ready == 3) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '等待所有玩家准备…（$ready/3）',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
    ];
  }
}

/// 联网模式倒计时徽标：显示当前回合剩余秒数。
class _TurnCountdownBadge extends StatefulWidget {
  final int deadline;
  const _TurnCountdownBadge({required this.deadline});

  @override
  State<_TurnCountdownBadge> createState() => _TurnCountdownBadgeState();
}

class _TurnCountdownBadgeState extends State<_TurnCountdownBadge> {
  Timer? _timer;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didUpdateWidget(_TurnCountdownBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline) _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = ((widget.deadline - now) / 1000).ceil();
    if (diff != _remaining) {
      setState(() => _remaining = diff < 0 ? 0 : diff);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_remaining <= 0) return const SizedBox.shrink();
    final isUrgent = _remaining <= 10;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isUrgent ? Colors.redAccent : Colors.amber).withValues(
          alpha: 0.2,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUrgent ? Colors.redAccent : Colors.amber,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_outlined,
            size: 14,
            color: isUrgent ? Colors.redAccent : Colors.amber,
          ),
          const SizedBox(width: 3),
          Text(
            '${_remaining}s',
            style: TextStyle(
              color: isUrgent ? Colors.redAccent : Colors.amber,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// AI 状态徽标：左上角显示当前 AI 类型 + ONNX 状态。
/// 点击弹出决策日志面板，便于排查 AI 是否在用 ONNX、推理是否失败。
class _AiStatusBadge extends StatefulWidget {
  const _AiStatusBadge();

  @override
  State<_AiStatusBadge> createState() => _AiStatusBadgeState();
}

class _AiStatusBadgeState extends State<_AiStatusBadge> {
  String _lastSummary = '';

  @override
  void initState() {
    super.initState();
    AiDebugLog.instance.addListener(_onChange);
    _onChange();
  }

  @override
  void dispose() {
    AiDebugLog.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final s = AiDebugLog.instance.statusSummary;
    if (s != _lastSummary) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _lastSummary = s);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = AiDebugLog.instance;
    final isDouzero = log.activeAiType == 'douzero';
    final isOnnxError = log.onnxOk == false;
    final color = !isDouzero
        ? Colors.white54
        : (isOnnxError ? Colors.red : Colors.lightGreenAccent);
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showLogDialog(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOnnxError
                    ? Icons.error_outline
                    : (isDouzero ? Icons.psychology : Icons.smart_toy),
                size: 12,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                _lastSummary.isEmpty ? log.statusSummary : _lastSummary,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLogDialog(BuildContext context) {
    showDialog<void>(context: context, builder: (_) => const _AiLogDialog());
  }
}

/// AI 决策日志面板：列出最近决策 + ONNX 错误详情。
class _AiLogDialog extends StatefulWidget {
  const _AiLogDialog();

  @override
  State<_AiLogDialog> createState() => _AiLogDialogState();
}

class _AiLogDialogState extends State<_AiLogDialog> {
  @override
  void initState() {
    super.initState();
    AiDebugLog.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    AiDebugLog.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final log = AiDebugLog.instance;
    final decisions = log.decisions;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F2A1F),
      title: Row(
        children: [
          const Icon(Icons.psychology, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI 决策日志（${log.statusSummary}）',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            // ONNX 状态条
            if (log.activeAiType == 'douzero') ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: log.onnxOk == false
                    ? Colors.red.withValues(alpha: 0.3)
                    : log.onnxOk == true
                    ? Colors.green.withValues(alpha: 0.2)
                    : Colors.orange.withValues(alpha: 0.2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      log.onnxOk == false
                          ? '❌ ONNX 推理失败 — 已 fallback 到 PIMC'
                          : log.onnxOk == true
                          ? '✅ ONNX 推理正常'
                          : '⏳ ONNX 未调用过（可能尚未轮到 AI 出牌）',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (log.onnxError != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            log.onnxError!,
                            style: TextStyle(
                              color: Colors.red.shade100,
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
            // 决策列表
            Expanded(
              child: decisions.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无 AI 决策',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      reverse: true,
                      itemCount: decisions.length,
                      itemBuilder: (_, i) {
                        // 反向显示：最新的在顶部
                        final d = decisions[decisions.length - 1 - i];
                        return _DecisionTile(
                          decision: d,
                          index: decisions.length - i,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecisionTile extends StatelessWidget {
  const _DecisionTile({required this.decision, required this.index});
  final AiDecision decision;
  final int index;

  @override
  Widget build(BuildContext context) {
    final isFallback = decision.note?.contains('fallback') ?? false;
    final chosenLabel = decision.chosen.isEmpty
        ? 'PASS'
        : decision.chosen.map((c) => c.rank.label).join(' ');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isFallback
            ? Colors.red.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isFallback
              ? Colors.red.withValues(alpha: 0.4)
              : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#$index',
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
              const SizedBox(width: 6),
              Text(
                '座位${decision.seat}',
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (decision.role != null) ...[
                const SizedBox(width: 4),
                Text(
                  '·${decision.role}',
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 10,
                  ),
                ),
              ],
              const Spacer(),
              if (decision.decisionMs != null)
                Text(
                  '${decision.decisionMs}ms',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '候选 ${decision.candidatesCount}',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              const SizedBox(width: 12),
              Text(
                '→ $chosenLabel',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (decision.note != null) ...[
            const SizedBox(height: 3),
            Text(
              decision.note!,
              style: TextStyle(
                color: isFallback ? Colors.red.shade200 : Colors.white54,
                fontSize: 9,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (decision.snapshot != null) ...[
            const SizedBox(height: 4),
            _SnapshotBlock(snapshot: decision.snapshot!),
          ],
          if (decision.topQ != null && decision.topQ!.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text(
              'Q 值 top-5:',
              style: TextStyle(color: Colors.white54, fontSize: 9),
            ),
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final q in decision.topQ!)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '${q.cards.map((c) => c.rank.label).join("")}=${q.q.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: Colors.greenAccent[100],
                        fontSize: 9,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 局面快照块：显示模型实际看到的局面（手牌、对手剩牌、最近一手等）。
/// 用户对照「模型看到了什么」是否与游戏状态一致。
class _SnapshotBlock extends StatelessWidget {
  const _SnapshotBlock({required this.snapshot});
  final SnapshotContext snapshot;

  @override
  Widget build(BuildContext context) {
    final myHandLabel = snapshot.myHand.isEmpty
        ? '空'
        : snapshot.myHand.map((c) => c.rank.label).join(' ');
    final lastMoveLabel = snapshot.lastMove.isEmpty
        ? '空（自由出牌）'
        : snapshot.lastMove.map((c) => c.rank.label).join(' ');
    // 根据角色显示不同字段
    final roleSpecific = <String>[];
    if (snapshot.upLeft >= 0) {
      // 地主视角
      roleSpecific.add('上家剩 ${snapshot.upLeft}');
      roleSpecific.add('下家剩 ${snapshot.downLeft}');
    } else {
      // 农民视角
      roleSpecific.add('地主剩 ${snapshot.landlordLeft}');
      roleSpecific.add('队友剩 ${snapshot.teammateLeft}');
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '模型视角：',
            style: TextStyle(
              color: Colors.cyan.shade100,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          _kv('我的手牌', '$myHandLabel  (${snapshot.myHandCount}张)'),
          _kv('最近一手', lastMoveLabel),
          _kv('炸弹数', '${snapshot.bombNum}'),
          _kv('对手', roleSpecific.join('  ·  ')),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
        children: [
          TextSpan(
            text: '$k: ',
            style: const TextStyle(color: Colors.white54),
          ),
          TextSpan(
            text: v,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}

/// 发牌动画：牌堆在桌面中央，牌背依次飞向左、右、本家三个座位。
class _DealAnimation extends StatefulWidget {
  final _TableLayout layout;
  final VoidCallback onDone;
  const _DealAnimation({required this.layout, required this.onDone});

  @override
  State<_DealAnimation> createState() => _DealAnimationState();
}

class _DealAnimationState extends State<_DealAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _totalCards = 18;
  static const _cardStagger = 0.042;
  static const _cardFlyDuration = 0.12;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1700),
      vsync: this,
    );
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value;
            final fade = t < 0.88 ? 1.0 : (1.0 - (t - 0.88) / 0.12);
            return Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: _buildScene(t),
            );
          },
        ),
      ),
    );
  }

  Widget _buildScene(double t) {
    final l = widget.layout;
    final cardH = l.backH;
    final cardW = cardH * kCardAspect;
    final center = Offset(l.w / 2, l.h * 0.42);
    final targets = [
      Offset(l.w / 2, l.handTop + l.handH / 2), // 本家
      Offset(
        l.w - _TableLayout.sidePad - l.seatW / 2,
        l.seatTop + l.avatar / 2,
      ), // 下家
      Offset(_TableLayout.sidePad + l.seatW / 2, l.seatTop + l.avatar / 2),
    ];

    final children = <Widget>[];
    final deckLeft = 1.0 - (t / 0.8).clamp(0.0, 1.0);
    final deckLayers = (deckLeft * 6).ceil();
    for (var i = 0; i < deckLayers; i++) {
      children.add(
        Positioned(
          left: center.dx - cardW / 2 - i * 0.8,
          top: center.dy - cardH / 2 - i * 0.8,
          child: CardBack(width: cardW, height: cardH),
        ),
      );
    }

    for (var i = 0; i < _totalCards; i++) {
      final delay = i * _cardStagger;
      final cardT = ((t - delay) / _cardFlyDuration).clamp(0.0, 1.0);
      if (cardT <= 0) continue;
      final eased = Curves.easeOutCubic.transform(cardT);
      final target = targets[i % 3];
      final pos = Offset.lerp(center, target, eased)!;
      final op = cardT >= 1.0
          ? (1.0 - (t - delay - _cardFlyDuration) / 0.18).clamp(0.0, 1.0)
          : 1.0;
      children.add(
        Positioned(
          left: pos.dx - cardW / 2,
          top: pos.dy - cardH / 2,
          child: Opacity(
            opacity: op,
            child: Transform.rotate(
              angle: (1 - eased) * (i.isEven ? 0.5 : -0.5),
              child: CardBack(width: cardW, height: cardH),
            ),
          ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }
}
