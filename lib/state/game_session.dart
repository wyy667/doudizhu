import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/ai_debug_log.dart';
import '../ai/ai_player.dart';
import '../ai/douzero_ai.dart';
import '../audio/sfx_player.dart';
import '../core/card.dart';
import '../core/deck.dart';
import '../core/game_action.dart';
import '../core/game_engine.dart';
import '../core/game_phase.dart';
import '../core/game_state.dart';
import '../core/hand_detector.dart';
import '../core/hand_type.dart';
import '../core/rule_variant.dart';
import '../stats/stats_record.dart';
import '../stats/bankroll.dart';
import '../stats/stats_repository.dart';
import 'settings.dart';

/// 人类玩家座位固定为 0。
const humanSeat = 0;

/// 会话抽象基类：单机 GameSession 和联网 NetGameSession 共用。
/// GameScreen 通过 gameSessionProvider 读取状态、调用方法，无感知单机/联网。
abstract class SessionNotifier extends Notifier<GameState> {
  void bid(int score);
  void play(List<Card> cards);
  void pass();
  void newGame();
  void bright();

  /// 联网模式（默认单机）。
  bool get isOnlineMode => false;

  /// 是否房主（单机默认 true）。
  bool get isHost => true;

  /// 各座位准备状态（单机默认全 true）。
  List<bool> get readySeats => [true, true, true];

  /// 本玩家是否已准备。
  bool get amReady => true;

  /// 切换准备状态（联网用）。
  void toggleReady() {}

  /// 退出托管模式（联网用，玩家触摸手牌时调用）。
  void disableAutoPlay() {}
}

/// 单机对局编排器：接收人类动作 + 调度 AI，驱动 [GameState] 流转。
class GameSession extends SessionNotifier {
  late final GameEngine _engine = const GameEngine();
  late final AiPlayer _ai = DouZeroAi();
  Timer? _aiTimer;
  int _seed = 0;
  int _turns = 0;
  int _settleRecordedForSeed = -1;
  final List<GameAction> _actionLog = [];
  late RuleVariant _variant;

  @override
  GameState build() {
    ref.onDispose(() => _aiTimer?.cancel());
    AiDebugLog.instance
      ..activeAiType = 'douzero'
      ..enabled = true
      ..clearForNewGame();
    final initial = _dealFresh();
    scheduleMicrotask(_maybeScheduleAi);
    return initial;
  }

  GameState _dealFresh() {
    _seed = math.Random().nextInt(1 << 30);
    _turns = 0;
    _settleRecordedForSeed = -1;
    _actionLog.clear();
    _variant = ref.read(ruleVariantProvider);
    final deal = _variant.shuffle
        ? Deck.deal(_seed)
        : Deck.dealNoShuffle(_seed);
    final action = DealAction(deal.hands, deal.bottom, _seed);
    var state = _engine.apply(GameState.initial(), action);
    state = state.copyWith(ruleVariant: _variant);
    return state;
  }

  @override
  void newGame() {
    _aiTimer?.cancel();
    AiDebugLog.instance.clearForNewGame();
    state = _dealFresh();
    _maybeScheduleAi();
  }

  @override
  void bid(int score) {
    if (state.phase != GamePhase.bidding || state.currentPlayer != humanSeat) {
      return;
    }
    _applyAction(BidAction(humanSeat, score));
  }

  @override
  void play(List<Card> cards) {
    if (state.phase != GamePhase.playing || state.currentPlayer != humanSeat) {
      return;
    }
    _applyAction(PlayAction(humanSeat, cards));
  }

  @override
  void pass() {
    if (state.phase != GamePhase.playing || state.currentPlayer != humanSeat) {
      return;
    }
    _applyAction(PassAction(humanSeat));
  }

  @override
  void bright() {
    // 明牌仅联网模式支持，单机为纯斗地主。
  }

  void _applyAction(GameAction action) {
    if (!_engine.validate(state, action).ok) return;
    _actionLog.add(action);
    if (action is PlayAction || action is PassAction) {
      _turns++;
    }
    state = _engine.apply(state, action);
    _playSfxForAction(action);
    _handleBidDeadlock();
    _maybeRecordSettlement();
    _maybeScheduleAi();
  }

  void _playSfxForAction(GameAction action) {
    final sfx = ref.read(sfxPlayerProvider);
    if (state.phase == GamePhase.settled) {
      final winner = state.winnerSeat;
      final landlord = state.landlordSeat;
      if (winner != null && landlord != null) {
        final humanWon =
            (winner == landlord && humanSeat == landlord) ||
            (winner != landlord && humanSeat != landlord);
        sfx.play(humanWon ? Sfx.win : Sfx.lose);
      }
      return;
    }
    // 出牌 / 不出 / 叫分的声音改由 GameScreen 调用系统 TTS 报牌，这里只保留震动。
    switch (action) {
      case PlayAction(:final cards):
        final pattern = HandDetector.detect(cards);
        if (pattern?.type == HandType.rocket) {
          sfx.haptic(Sfx.rocket);
        } else if (pattern?.type == HandType.bomb) {
          sfx.haptic(Sfx.bomb);
        } else {
          sfx.haptic(Sfx.play);
        }
      case PassAction():
        sfx.haptic(Sfx.pass);
      case BidAction():
        sfx.haptic(Sfx.bid);
      default:
        break;
    }
  }

  void _maybeScheduleAi() {
    _aiTimer?.cancel();
    if (state.phase == GamePhase.settled) return;
    if (state.players.isEmpty) return;
    final cur = state.players[state.currentPlayer];
    if (cur.isHuman) return;
    _aiTimer = Timer(const Duration(milliseconds: 700), _runAiTurn);
  }

  Future<void> _runAiTurn() async {
    if (state.phase == GamePhase.settled) return;
    final seat = state.currentPlayer;
    if (state.players[seat].isHuman) return;

    final action = await _ai.chooseAction(state, seat);
    if (state.currentPlayer != seat) return;

    if (_engine.validate(state, action).ok) {
      _applyAction(action);
    } else {
      if (state.phase == GamePhase.bidding) {
        _applyAction(BidAction(seat, 0));
      } else {
        final pass = PassAction(seat);
        if (_engine.validate(state, pass).ok) {
          _applyAction(pass);
        }
      }
    }
  }

  void _handleBidDeadlock() {
    if (state.phase == GamePhase.bidding &&
        state.bidParticipants >= 3 &&
        state.currentMaxBid == 0) {
      final seat = state.currentPlayer;
      final action = BidAction(seat, 1);
      _actionLog.add(action);
      state = _engine.apply(state, action);
    }
  }

  void _maybeRecordSettlement() {
    if (state.phase != GamePhase.settled) return;
    if (_settleRecordedForSeed == _seed) return;
    _settleRecordedForSeed = _seed;

    final winner = state.winnerSeat;
    final landlord = state.landlordSeat;
    if (winner == null || landlord == null) return;

    final humanWon =
        (winner == landlord && humanSeat == landlord) ||
        (winner != landlord && humanSeat != landlord);

    final humanIsLandlord = humanSeat == landlord;
    final baseScore = state.multiplier * (humanIsLandlord ? 2 : 1);

    final record = StatsRecord(
      playedAt: DateTime.now(),
      humanWon: humanWon,
      humanIsLandlord: humanIsLandlord,
      multiplier: state.multiplier,
      score: baseScore,
      turns: _turns,
      isSpring: state.isSpring,
      isAntiSpring: state.isAntiSpring,
      deckSeed: _seed,
      actionLog: _actionLog.map((a) => a.toJson()).toList(),
      variantId: _variant.id,
    );

    _writeRecord(record);
    ref
        .read(bankrollProvider.notifier)
        .settle(humanWon ? baseScore : -baseScore);
  }

  Future<void> _writeRecord(StatsRecord record) async {
    try {
      final repo = await ref.read(statsRepositoryProvider.future);
      await repo.append(record);
      ref.invalidate(statsRecordsProvider);
    } catch (_) {}
  }
}

/// 顶层 Provider（可通过 ProviderScope override 替换为 NetGameSession）。
final gameSessionProvider = NotifierProvider<SessionNotifier, GameState>(
  GameSession.new,
);
