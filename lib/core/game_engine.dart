import 'card.dart';
import 'game_action.dart';
import 'game_phase.dart';
import 'game_state.dart';
import 'hand_compare.dart';
import 'hand_detector.dart';
import 'hand_type.dart'; // 引入扩展方法 isBombLike

/// 动作校验/执行结果。
class ActionResult {
  final bool ok;
  final String? reason;
  const ActionResult.ok() : ok = true, reason = null;
  const ActionResult.fail(this.reason) : ok = false;
}

/// 游戏引擎：纯函数状态转移。
///
/// - [validate] 仅校验，不改状态，供 UI 灰按钮/联网服务端使用。
/// - [apply] 校验通过则返回新状态，失败抛 [IllegalActionError]。
///
/// 参见 docs/05-architecture.md §2.3。
class IllegalActionError implements Exception {
  final String message;
  const IllegalActionError(this.message);
  @override
  String toString() => 'IllegalActionError: $message';
}

class GameEngine {
  const GameEngine();

  /// 校验 [action] 在 [state] 下是否合法。
  ActionResult validate(GameState state, GameAction action) {
    switch (action) {
      case DealAction():
        if (state.phase != GamePhase.dealing) {
          return const ActionResult.fail('发牌阶段已过');
        }
        if (action.hands.length != 3) {
          return const ActionResult.fail('需要 3 名玩家');
        }
        if (action.hands.any((h) => h.length != 17)) {
          return const ActionResult.fail('每人须 17 张');
        }
        if (action.bottom.length != 3) {
          return const ActionResult.fail('底牌须 3 张');
        }
        // 牌不重复
        final all = [
          ...action.hands[0],
          ...action.hands[1],
          ...action.hands[2],
          ...action.bottom,
        ];
        if (all.toSet().length != 54) return const ActionResult.fail('牌有重复');
        return const ActionResult.ok();

      case BidAction(:final bySeat, :final score):
        if (state.phase != GamePhase.bidding) {
          return const ActionResult.fail('不在叫地主阶段');
        }
        if (bySeat != state.currentPlayer) {
          return const ActionResult.fail('未轮到你叫地主');
        }
        if (score < 0 || score > state.ruleVariant.bidMax) {
          return const ActionResult.fail('叫分超出范围');
        }
        // 叫分必须严格高于当前最高叫
        if (score != 0 && score <= state.currentMaxBid) {
          return const ActionResult.fail('叫分必须高于当前最高叫');
        }
        return const ActionResult.ok();

      case PlayAction(:final bySeat, :final cards):
        if (state.phase != GamePhase.playing) {
          return const ActionResult.fail('不在出牌阶段');
        }
        if (bySeat != state.currentPlayer) {
          return const ActionResult.fail('未轮到你出牌');
        }
        if (cards.isEmpty) return const ActionResult.fail('出牌不能为空');
        final player = state.players[bySeat];
        // 牌必须在手
        final handSet = player.hand.toSet();
        if (!cards.every((c) => handSet.contains(c))) {
          return const ActionResult.fail('出牌包含不在手中的牌');
        }
        final pattern = HandDetector.detect(cards);
        if (pattern == null) return const ActionResult.fail('牌型不合法');
        // 若有上家有效牌，必须能压
        if (state.lastValidPlay != null &&
            state.lastValidPlay!.seat != bySeat) {
          if (!HandCompare.canBeat(pattern, state.lastValidPlay!.pattern)) {
            return const ActionResult.fail('管不上');
          }
        }
        return const ActionResult.ok();

      case PassAction(:final bySeat):
        if (state.phase != GamePhase.playing) {
          return const ActionResult.fail('不在出牌阶段');
        }
        if (bySeat != state.currentPlayer) {
          return const ActionResult.fail('未轮到你');
        }
        // 自由出牌权时（自己是上一手）不能 pass
        if (state.lastValidPlay == null ||
            state.lastValidPlay!.seat == bySeat) {
          return const ActionResult.fail('该你出牌，不能不出');
        }
        return const ActionResult.ok();

      case BrightAction(:final bySeat):
        if (state.phase != GamePhase.playing) {
          return const ActionResult.fail('不在出牌阶段');
        }
        if (bySeat != state.landlordSeat) {
          return const ActionResult.fail('仅地主可明牌');
        }
        if (state.lastValidPlay != null) {
          return const ActionResult.fail('明牌须在首出前');
        }
        if (state.brightSeats.contains(bySeat)) {
          return const ActionResult.fail('已明牌');
        }
        return const ActionResult.ok();
    }
  }

  /// 应用动作到状态。非法时抛 [IllegalActionError]。
  GameState apply(GameState state, GameAction action) {
    final result = validate(state, action);
    if (!result.ok) throw IllegalActionError(result.reason ?? '非法动作');

    switch (action) {
      case DealAction():
        return _applyDeal(state, action);
      case BidAction():
        return _applyBid(state, action);
      case PlayAction():
        return _applyPlay(state, action);
      case PassAction():
        return _applyPass(state, action);
      case BrightAction():
        return state.copyWith(
          brightSeats: {...state.brightSeats, action.bySeat},
          multiplier: state.multiplier * 2,
        );
    }
  }

  // ---------- 各动作的状态转移 ----------

  GameState _applyDeal(GameState state, DealAction action) {
    final players = [
      for (var s = 0; s < 3; s++)
        PlayerState(
          seat: s,
          role: PlayerRole.undecided,
          hand: _sortDesc(action.hands[s]),
          isHuman: s == 0, // 座位 0 为人类，1/2 为 AI
        ),
    ];
    // 起始叫分座位用 seed 决定（公平），避免座位 0 永远先叫
    final startSeat = action.seed % 3;
    final next = state.copyWith(
      phase: GamePhase.bidding,
      players: players,
      bottomCards: action.bottom,
      currentPlayer: startSeat,
      passCount: 0,
      multiplier: 1,
      landlordSeat: null,
      lastValidPlay: null,
      winnerSeat: null,
      playedCards: const [], // 新局清空
      playedBySeat: const {0: [], 1: [], 2: []},
      lastMoveBySeat: const {0: [], 1: [], 2: []},
      actionSeq: const [],
      actedSeats: const {},
      replayLog: [
        ReplayStep(
          phase: state.phase,
          seat: -1,
          kind: ReplayStepKind.deal,
          cards: const [],
          snapshotBefore: state,
        ),
      ],
      currentMaxBid: 0,
      highestBidder: null,
      bidParticipants: 0,
    );
    return next;
  }

  /// 叫分制状态转移。规则：
  /// - score=0：不叫，轮到下一家。
  /// - score>0：必须严格高于 currentMaxBid；记为最高叫者。
  /// - 成交条件：(a) score==3 立即成交；或 (b) 已有 3 人参与叫分。
  /// - 三人都没叫时由上层（GameSession）处理流局重发。
  GameState _applyBid(GameState state, BidAction action) {
    final nextParticipants = state.bidParticipants + 1;
    final newMaxBid = action.score > state.currentMaxBid
        ? action.score
        : state.currentMaxBid;
    final newBidder = action.score > state.currentMaxBid
        ? action.bySeat
        : state.highestBidder;

    // 成交判定
    final immediateSettle = action.score == state.ruleVariant.bidMax;
    final allBid = nextParticipants >= 3 && newMaxBid > 0;

    if (immediateSettle || allBid) {
      final landlord = newBidder!;
      final newPlayers = List<PlayerState>.from(state.players);
      final bottom = state.bottomCards;
      newPlayers[landlord] = newPlayers[landlord].copyWith(
        role: PlayerRole.landlord,
        hand: _sortDesc([...newPlayers[landlord].hand, ...bottom]),
      );
      for (var s = 0; s < 3; s++) {
        if (s != landlord) {
          newPlayers[s] = newPlayers[s].copyWith(role: PlayerRole.farmer);
        }
      }
      // 成交时底牌**公开**——但底牌进入地主手牌后仍属于地主，不是「已打出的牌」。
      // 因此 playedCards 和 playedBySeat 都**不**包含底牌（严格对齐 Python DouZero）。
      // 底牌的公开信息通过 `state.bottomCards` 单独保留（成交后 UI 显示正面），
      // 且地主自己 `my_handcards` 已含底牌——特征编码无需额外字段。
      return state.copyWith(
        phase: GamePhase.playing,
        players: newPlayers,
        landlordSeat: landlord,
        currentPlayer: landlord,
        passCount: 0,
        lastValidPlay: null,
        multiplier: newMaxBid,
        currentMaxBid: newMaxBid,
        highestBidder: newBidder,
        bidParticipants: nextParticipants,
        replayLog: [
          ...state.replayLog,
          ReplayStep(
            phase: state.phase,
            seat: action.bySeat,
            kind: ReplayStepKind.bidSettle,
            cards: List<Card>.from(bottom),
            snapshotBefore: state,
          ),
        ],
      );
    }

    // 未成交：轮到下一家继续叫
    return state.copyWith(
      currentPlayer: (action.bySeat + 1) % 3,
      currentMaxBid: newMaxBid,
      highestBidder: newBidder,
      bidParticipants: nextParticipants,
      replayLog: [
        ...state.replayLog,
        ReplayStep(
          phase: state.phase,
          seat: action.bySeat,
          kind: ReplayStepKind.bid,
          cards: const [],
          snapshotBefore: state,
        ),
      ],
    );
  }

  GameState _applyPlay(GameState state, PlayAction action) {
    final player = state.players[action.bySeat];
    final remaining = player.hand
        .where((c) => !action.cards.contains(c))
        .toList();

    final newPlayers = List<PlayerState>.from(state.players);
    newPlayers[action.bySeat] = player.copyWith(
      hand: _sortDesc(remaining),
      playCount: player.playCount + 1,
    );

    final pattern = HandDetector.detect(action.cards)!;
    var newMultiplier = pattern.type.isBombLike
        ? state.multiplier * state.ruleVariant.bombMultiplier
        : state.multiplier;

    final isWin = remaining.isEmpty;
    final nextSeat = (action.bySeat + 1) % 3;

    // 春天/反春天判定（仅在胜利瞬间触发）：
    // - 春天：地主胜，且两个农民都未出过牌（playCount == 0）
    // - 反春天：农民胜，地主仅出过最初一手牌（playCount == 1），
    //   且另一农民从未出过牌（playCount == 0）
    // 二者均使倍数 ×2
    var isSpring = false;
    var isAntiSpring = false;
    if (isWin && state.ruleVariant.springEnabled) {
      final landlord = state.landlordSeat!;
      final landlordWon = action.bySeat == landlord;
      final farmers = [0, 1, 2].where((s) => s != landlord).toList();
      if (landlordWon) {
        final farmersNeverPlayed = farmers.every(
          (s) => newPlayers[s].playCount == 0,
        );
        if (farmersNeverPlayed) {
          newMultiplier *= 2;
          isSpring = true;
        }
      } else {
        final landlordPlayedOnce = newPlayers[landlord].playCount == 1;
        final otherFarmer = farmers.firstWhere((s) => s != action.bySeat);
        final otherFarmerNeverPlayed = newPlayers[otherFarmer].playCount == 0;
        if (landlordPlayedOnce && otherFarmerNeverPlayed) {
          newMultiplier *= 2;
          isAntiSpring = true;
        }
      }
    }

    // 维护按座位累计出牌 / 最近一手 / 出牌序列
    final newPlayedBySeat = {
      for (final e in state.playedBySeat.entries)
        e.key: List<Card>.from(e.value),
    };
    newPlayedBySeat[action.bySeat] = [
      ...newPlayedBySeat[action.bySeat] ?? const [],
      ...action.cards,
    ];
    final newLastMoveBySeat = {
      for (final e in state.lastMoveBySeat.entries) e.key: e.value,
      action.bySeat: List<Card>.from(action.cards),
    };

    return state.copyWith(
      players: newPlayers,
      lastValidPlay: PlayFrame(action.bySeat, pattern, action.cards),
      passCount: 0,
      multiplier: newMultiplier,
      isSpring: isSpring,
      isAntiSpring: isAntiSpring,
      currentPlayer: nextSeat,
      phase: isWin ? GamePhase.settled : state.phase,
      winnerSeat: isWin ? action.bySeat : null,
      playedCards: [...state.playedCards, ...action.cards],
      playedBySeat: newPlayedBySeat,
      lastMoveBySeat: newLastMoveBySeat,
      actionSeq: [...state.actionSeq, List<Card>.from(action.cards)],
      actedSeats: {...state.actedSeats, action.bySeat},
      replayLog: [
        ...state.replayLog,
        ReplayStep(
          phase: state.phase,
          seat: action.bySeat,
          kind: ReplayStepKind.play,
          cards: List<Card>.from(action.cards),
          snapshotBefore: state,
        ),
      ],
    );
  }

  GameState _applyPass(GameState state, PassAction action) {
    final newPassCount = state.passCount + 1;
    final nextSeat = (action.bySeat + 1) % 3;

    // 出牌序列记录 pass（空列表）
    final newActionSeq = [...state.actionSeq, const <Card>[]];
    final newLastMoveBySeat = {
      for (final e in state.lastMoveBySeat.entries) e.key: e.value,
      action.bySeat: const <Card>[],
    };
    final newReplayLog = [
      ...state.replayLog,
      ReplayStep(
        phase: state.phase,
        seat: action.bySeat,
        kind: ReplayStepKind.pass,
        cards: const [],
        snapshotBefore: state,
      ),
    ];

    // 若另外两家连续 pass（passCount 达到 2），自由出牌权回到 lastValidPlayer
    if (newPassCount >= 2) {
      final freeSeat = state.lastValidPlay!.seat;
      return state.copyWith(
        currentPlayer: freeSeat,
        passCount: 0,
        lastValidPlay: null, // 自由出牌
        lastMoveBySeat: newLastMoveBySeat,
        actionSeq: newActionSeq,
        actedSeats: const {},
        replayLog: newReplayLog,
      );
    }
    return state.copyWith(
      currentPlayer: nextSeat,
      passCount: newPassCount,
      lastMoveBySeat: newLastMoveBySeat,
      actionSeq: newActionSeq,
      actedSeats: {...state.actedSeats, action.bySeat},
      replayLog: newReplayLog,
    );
  }

  static List<Card> _sortDesc(List<Card> cards) {
    final sorted = List<Card>.from(cards);
    sorted.sort((a, b) => b.rank.value.compareTo(a.rank.value));
    return sorted;
  }
}
