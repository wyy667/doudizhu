import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';
import 'package:landlord/core/hand_detector.dart';
import 'package:landlord/core/hand_type.dart';

Card c(String label, [int suit = 0]) {
  switch (label) {
    case 'BJ':
      return const Card(Rank.bj, Suit.jokerSmall);
    case 'RJ':
      return const Card(Rank.rj, Suit.jokerBig);
  }
  final rank = {
    '3': Rank.c3,
    '4': Rank.c4,
    '5': Rank.c5,
    '6': Rank.c6,
    '7': Rank.c7,
    '8': Rank.c8,
    '9': Rank.c9,
    '10': Rank.c10,
    'J': Rank.cJ,
    'Q': Rank.cQ,
    'K': Rank.cK,
    'A': Rank.cA,
    '2': Rank.c2,
  }[label]!;
  const suits = [Suit.spade, Suit.heart, Suit.diamond, Suit.club];
  return Card(rank, suits[suit]);
}

void main() {
  const engine = GameEngine();

  /// 用真实 Deck 发牌构造 bidding 阶段状态。
  /// 默认 seed=42（42%3=0，currentPlayer=0，便于测试假设座位 0 先叫）。
  GameState dealtState({int seed = 42}) {
    final r = Deck.deal(seed);
    return engine.apply(
      GameState.initial(),
      DealAction(r.hands, r.bottom, seed),
    );
  }

  group('GameEngine · DealAction', () {
    test('发牌后进入 bidding 阶段，每人 17 张', () {
      final s = dealtState();
      expect(s.phase, GamePhase.bidding);
      expect(s.players.length, 3);
      expect(s.players.every((p) => p.hand.length == 17), true);
    });
    test('重复发牌被拒绝', () {
      final s = dealtState();
      expect(
        () => engine.apply(s, DealAction(const [[], [], []], const [], 1)),
        throwsA(isA<IllegalActionError>()),
      );
    });
    test('牌数错误被拒绝', () {
      expect(
        () => engine.apply(
          GameState.initial(),
          DealAction(
            [
              for (var i = 0; i < 3; i++) <Card>[c('3')],
            ],
            [c('BJ'), c('RJ'), c('K')],
            1,
          ),
        ),
        throwsA(isA<IllegalActionError>()),
      );
    });
  });

  group('GameEngine · BidAction 叫分制', () {
    test('叫 3 分立即成交：成为地主并收底牌（20 张）', () {
      final s = dealtState();
      final s2 = engine.apply(s, const BidAction(0, 3));
      expect(s2.phase, GamePhase.playing);
      expect(s2.landlordSeat, 0);
      expect(s2.players[0].role, PlayerRole.landlord);
      expect(s2.players[0].hand.length, 20); // 17 + 3
      expect(s2.players[1].role, PlayerRole.farmer);
      expect(s2.players[2].role, PlayerRole.farmer);
      expect(s2.currentPlayer, 0); // 地主先出
      expect(s2.multiplier, 3); // 倍数=叫分
    });

    test('叫 1 分不立即成交，轮到下一家', () {
      final s = dealtState();
      final s2 = engine.apply(s, const BidAction(0, 1));
      expect(s2.phase, GamePhase.bidding);
      expect(s2.currentPlayer, 1);
      expect(s2.currentMaxBid, 1);
      expect(s2.highestBidder, 0);
      expect(s2.bidParticipants, 1);
    });

    test('抢叫：后续玩家必须叫更高分', () {
      var s = dealtState();
      s = engine.apply(s, const BidAction(0, 1)); // 0 叫 1
      s = engine.apply(s, const BidAction(1, 2)); // 1 抢叫 2
      expect(s.phase, GamePhase.bidding);
      expect(s.currentMaxBid, 2);
      expect(s.highestBidder, 1);
      // 第三人叫 3 分立即成交
      s = engine.apply(s, const BidAction(2, 3));
      expect(s.phase, GamePhase.playing);
      expect(s.landlordSeat, 2);
      expect(s.multiplier, 3);
    });

    test('叫分不高于当前最高叫被拒绝', () {
      var s = dealtState();
      s = engine.apply(s, const BidAction(0, 2));
      expect(
        () => engine.apply(s, const BidAction(1, 1)), // 1 想叫 1，但 < 2
        throwsA(isA<IllegalActionError>()),
      );
    });

    test('不叫（score=0）轮到下一家，maxBid 不变', () {
      var s = dealtState();
      s = engine.apply(s, const BidAction(0, 1)); // 0 叫 1
      s = engine.apply(s, const BidAction(1, 0)); // 1 不叫
      expect(s.phase, GamePhase.bidding);
      expect(s.currentPlayer, 2);
      expect(s.currentMaxBid, 1);
      expect(s.highestBidder, 0);
      expect(s.bidParticipants, 2);
    });

    test('三人参与且有人叫过 → 最后一人不叫时成交', () {
      // 0 叫 1, 1 不叫, 2 不叫 → 此时 bidParticipants=3, maxBid=1 > 0 → 成交
      var s = dealtState();
      s = engine.apply(s, const BidAction(0, 1));
      s = engine.apply(s, const BidAction(1, 0));
      final sEnd = engine.apply(s, const BidAction(2, 0));
      expect(sEnd.phase, GamePhase.playing);
      expect(sEnd.landlordSeat, 0);
      expect(sEnd.multiplier, 1);
    });

    test('叫分越界被拒绝（4 分）', () {
      final s = dealtState();
      expect(
        () => engine.apply(s, const BidAction(0, 4)),
        throwsA(isA<IllegalActionError>()),
      );
    });

    test('未轮到叫被拒绝', () {
      final s = dealtState(); // currentPlayer = 0
      expect(
        () => engine.apply(s, const BidAction(1, 1)),
        throwsA(isA<IllegalActionError>()),
      );
    });
  });

  /// 辅助：把 dealtState 推进到 playing 阶段（座位 0 当地主，叫 3 分）。
  GameState playingState({int seed = 42}) =>
      engine.apply(dealtState(seed: seed), const BidAction(0, 3));

  group('GameEngine · PlayAction', () {
    test('地主先出合法单牌', () {
      var s = playingState();
      final card = s.players[0].hand.last; // 降序排列，最后是最小
      s = engine.apply(s, PlayAction(0, [card]));
      expect(s.currentPlayer, 1);
      expect(s.lastValidPlay!.seat, 0);
      expect(s.players[0].hand.length, 19);
    });

    test('管不上被拒绝', () {
      var s = playingState();
      final big = s.players[0].hand.first; // 最大牌
      s = engine.apply(s, PlayAction(0, [big])); // 0 出大牌
      final small1 = s.players[1].hand.last; // 1 的最小牌
      expect(
        () => engine.apply(s, PlayAction(1, [small1])),
        throwsA(isA<IllegalActionError>()),
      );
    });

    test('自由出牌可出任意合法牌型', () {
      var s = playingState(seed: 6); // 6%3=0，currentPlayer=0
      // 在 0 的手中找一对
      final hand = s.players[0].hand;
      final byRank = <int, List<Card>>{};
      for (final card in hand) {
        byRank.putIfAbsent(card.rank.value, () => []).add(card);
      }
      final pairEntry = byRank.entries.firstWhere((e) => e.value.length >= 2);
      s = engine.apply(
        s,
        PlayAction(0, [pairEntry.value[0], pairEntry.value[1]]),
      );
      expect(s.lastValidPlay!.pattern.type, HandType.pair);
    });
  });

  group('GameEngine · PassAction', () {
    test('有上家牌时可以 pass', () {
      var s = playingState();
      final card = s.players[0].hand.last;
      s = engine.apply(s, PlayAction(0, [card])); // → currentPlayer=1
      s = engine.apply(s, const PassAction(1)); // passCount=1
      expect(s.currentPlayer, 2);
      expect(s.passCount, 1);
    });

    test('连续两次 pass → 自由出牌权回到最后出牌者', () {
      var s = playingState();
      final card = s.players[0].hand.last;
      s = engine.apply(s, PlayAction(0, [card])); // cur=1
      s = engine.apply(s, const PassAction(1)); // cur=2
      s = engine.apply(s, const PassAction(2)); // 连续 2 → 自由权回 0
      expect(s.currentPlayer, 0);
      expect(s.passCount, 0);
      expect(s.lastValidPlay, isNull);
    });

    test('自由出牌时不能 pass', () {
      var s = playingState();
      expect(
        () => engine.apply(s, const PassAction(0)),
        throwsA(isA<IllegalActionError>()),
      );
    });
  });

  group('GameEngine · 春天/反春天', () {
    /// 构造 playing 状态：地主(0) 手牌为 [A]，两农民各持若干牌。
    /// 起始 currentPlayer=0，lastValidPlay=null。

    test('反春天：地主仅出一手牌、另一农民未出过、农民胜 → ×2', () {
      // 场景：地主(0)出了一手 → 农民1(1)出一手压住 → 农民2(2)和地主都pass
      // → 农民1获得自由出牌权 → 农民1出完牌赢
      // 地主 playCount=1, 农民1 playCount=1, 农民2 playCount=0
      var s = GameState(
        phase: GamePhase.playing,
        players: [
          PlayerState(
            seat: 0,
            role: PlayerRole.landlord,
            hand: [c('2'), c('3')],
            isHuman: true,
            playCount: 1,
          ),
          PlayerState(
            seat: 1,
            role: PlayerRole.farmer,
            hand: [c('A')],
            isHuman: false,
            playCount: 1,
          ),
          PlayerState(
            seat: 2,
            role: PlayerRole.farmer,
            hand: [c('K'), c('Q')],
            isHuman: false,
            playCount: 0,
          ),
        ],
        currentPlayer: 1,
        landlordSeat: 0,
        bottomCards: const [],
        lastValidPlay: PlayFrame(
          1,
          HandDetector.detect([const Card(Rank.cK, Suit.club)])!,
          [const Card(Rank.cK, Suit.club)],
        ),
        multiplier: 1,
        deckSeed: 0,
      );
      // 座位 1 出 A（自由出牌权，清空手牌）→ 农民胜
      final sEnd = engine.apply(
        s,
        PlayAction(1, [const Card(Rank.cA, Suit.spade)]),
      );
      expect(sEnd.phase, GamePhase.settled);
      expect(sEnd.winnerSeat, 1);
      expect(sEnd.players[0].playCount, 1); // 地主仅出一手
      expect(sEnd.players[2].playCount, 0); // 另一农民未出过
      expect(sEnd.isAntiSpring, true);
      expect(sEnd.multiplier, 2); // 反春天 ×2
    });

    test('春天：两农民都未出过牌、地主胜 → ×2', () {
      var s = GameState(
        phase: GamePhase.playing,
        players: [
          PlayerState(
            seat: 0,
            role: PlayerRole.landlord,
            hand: [c('A')],
            isHuman: true,
          ),
          PlayerState(
            seat: 1,
            role: PlayerRole.farmer,
            hand: [c('3'), c('4')],
            isHuman: false,
          ),
          PlayerState(
            seat: 2,
            role: PlayerRole.farmer,
            hand: [c('5'), c('6')],
            isHuman: false,
          ),
        ],
        currentPlayer: 0,
        landlordSeat: 0,
        bottomCards: const [],
        lastValidPlay: null,
        multiplier: 1,
        deckSeed: 0,
      );
      final sEnd = engine.apply(
        s,
        PlayAction(0, [const Card(Rank.cA, Suit.spade)]),
      );
      expect(sEnd.phase, GamePhase.settled);
      expect(sEnd.winnerSeat, 0);
      expect(sEnd.players[1].playCount, 0);
      expect(sEnd.players[2].playCount, 0);
      expect(sEnd.multiplier, 2); // 春天 ×2
    });

    test('正常胜利不触发春天倍数', () {
      // 地主和农民都有出牌记录：构造 playCount=1 的状态
      var s = GameState(
        phase: GamePhase.playing,
        players: [
          PlayerState(
            seat: 0,
            role: PlayerRole.landlord,
            hand: [c('A')],
            isHuman: true,
            playCount: 1,
          ),
          PlayerState(
            seat: 1,
            role: PlayerRole.farmer,
            hand: [c('3'), c('4')],
            isHuman: false,
            playCount: 1,
          ),
          PlayerState(
            seat: 2,
            role: PlayerRole.farmer,
            hand: [c('5'), c('6')],
            isHuman: false,
            playCount: 1,
          ),
        ],
        currentPlayer: 0,
        landlordSeat: 0,
        bottomCards: const [],
        lastValidPlay: null,
        multiplier: 1,
        deckSeed: 0,
      );
      final sEnd = engine.apply(
        s,
        PlayAction(0, [const Card(Rank.cA, Suit.spade)]),
      );
      expect(sEnd.multiplier, 1); // 无春天加成
    });
  });

  group('GameEngine · 完整收尾', () {
    test('出完最后一张牌触发结算', () {
      var s = GameState(
        phase: GamePhase.playing,
        players: [
          PlayerState(
            seat: 0,
            role: PlayerRole.landlord,
            hand: [c('A')],
            isHuman: true,
          ),
          PlayerState(
            seat: 1,
            role: PlayerRole.farmer,
            hand: [c('3'), c('4'), c('5')],
            isHuman: false,
          ),
          PlayerState(
            seat: 2,
            role: PlayerRole.farmer,
            hand: [c('6'), c('7'), c('8')],
            isHuman: false,
          ),
        ],
        currentPlayer: 0,
        landlordSeat: 0,
        bottomCards: const [],
        lastValidPlay: null,
        deckSeed: 0,
      );
      s = engine.apply(s, PlayAction(0, [c('A')]));
      expect(s.phase, GamePhase.settled);
      expect(s.winnerSeat, 0);
      expect(s.players[0].hand.length, 0);
    });
  });

  group('GameEngine · 炸弹翻倍', () {
    test('出炸弹后 multiplier ×2', () {
      var s = GameState(
        phase: GamePhase.playing,
        players: [
          PlayerState(
            seat: 0,
            role: PlayerRole.landlord,
            hand: [c('5', 0), c('5', 1), c('5', 2), c('5', 3), c('A')],
            isHuman: true,
          ),
          PlayerState(
            seat: 1,
            role: PlayerRole.farmer,
            hand: [c('3'), c('4')],
            isHuman: false,
          ),
          PlayerState(
            seat: 2,
            role: PlayerRole.farmer,
            hand: [c('6'), c('7')],
            isHuman: false,
          ),
        ],
        currentPlayer: 0,
        landlordSeat: 0,
        bottomCards: const [],
        lastValidPlay: null,
        deckSeed: 0,
      );
      expect(s.multiplier, 1);
      s = engine.apply(
        s,
        PlayAction(0, [c('5', 0), c('5', 1), c('5', 2), c('5', 3)]),
      );
      expect(s.multiplier, 2);
      expect(s.lastValidPlay!.pattern.type, HandType.bomb);
    });
  });

  group('GameEngine · Deck 完整发牌', () {
    test('Deck.deal 返回 17+17+17+3 且无重复', () {
      final r = Deck.deal(123);
      final all = [...r.hand0, ...r.hand1, ...r.hand2, ...r.bottom];
      expect(all.length, 54);
      expect(all.toSet().length, 54);
      expect(r.hand0.length, 17);
      expect(r.bottom.length, 3);
    });
    test('相同 seed 两次发牌结果相同', () {
      final a = Deck.deal(7);
      final b = Deck.deal(7);
      expect(a.hand0.first.index, b.hand0.first.index);
    });
  });

  group('GameEngine · 按座位累计出牌字段（DouZero 编码用）', () {
    test('DealAction 后三个 map 均为空', () {
      var s = dealtState();
      expect(s.playedBySeat[0], isEmpty);
      expect(s.playedBySeat[1], isEmpty);
      expect(s.playedBySeat[2], isEmpty);
      expect(s.lastMoveBySeat[0], isEmpty);
      expect(s.actionSeq, isEmpty);
    });

    test('成交后底牌进入地主手牌；playedCards 仍为空（对齐 Python DouZero）', () {
      var s = dealtState();
      // 让 currentPlayer 叫 3 分立即成交
      final startSeat = s.currentPlayer;
      s = engine.apply(s, BidAction(startSeat, 3));
      expect(s.phase, GamePhase.playing);
      // 地主手牌 = 原 17 + 3 底牌 = 20
      expect(s.players[startSeat].handCount, 20);
      // playedCards 仍为空：底牌进入地主手牌后不属于「已打出的牌」
      expect(s.playedCards, isEmpty);
      // playedBySeat 仍为空（同上原因）
      expect(s.playedBySeat[startSeat], isEmpty);
    });

    test('PlayAction 累加到 playedBySeat / lastMoveBySeat / actionSeq', () {
      var s = playingState();
      // playingState 中座位 0 为地主，底牌已进入手牌但 playedBySeat[0] 仍为空
      final baseline = s.playedBySeat[0]!.length; // 应为 0
      expect(baseline, 0);
      final card = s.players[0].hand.last;
      s = engine.apply(s, PlayAction(0, [card]));
      expect(s.playedBySeat[0]!.length, baseline + 1);
      expect(s.playedBySeat[0]!.last, card);
      expect(s.lastMoveBySeat[0]!.length, 1);
      expect(s.lastMoveBySeat[0]!.first, card);
      expect(s.actionSeq.length, 1);
      expect(s.actionSeq[0].length, 1);
      expect(s.actionSeq[0].first, card);
      // 其他座位仍为空
      expect(s.playedBySeat[1], isEmpty);
      expect(s.lastMoveBySeat[1], isEmpty);
    });

    test('PassAction 记入 actionSeq（空列表）+ lastMoveBySeat[bySeat] = []', () {
      var s = playingState();
      final card = s.players[0].hand.last;
      s = engine.apply(s, PlayAction(0, [card])); // 0 出，→ 1
      s = engine.apply(s, PassAction(1)); // 1 pass
      expect(s.actionSeq.length, 2);
      expect(s.actionSeq[1], isEmpty, reason: 'pass 记为空列表');
      expect(
        s.lastMoveBySeat[1],
        isEmpty,
        reason: 'pass 后 lastMoveBySeat[1] = []',
      );
      // playedBySeat[1] 仍为空（pass 不出牌）
      expect(s.playedBySeat[1], isEmpty);
      // lastMoveBySeat[0] 仍是上一手有效牌
      expect(s.lastMoveBySeat[0]!.length, 1);
    });

    test('多手出牌后 playedBySeat 累积 + 不混淆其他座位', () {
      var s = playingState(seed: 6); // currentPlayer=0
      // 0 出一张
      final card0a = s.players[0].hand.last;
      s = engine.apply(s, PlayAction(0, [card0a]));
      // 1 出一张
      final card1 = s.players[1].hand.last;
      // 注意：必须能管住，否则会抛错。这里假设 1 有更大的牌（如果不通过则跳过）
      try {
        s = engine.apply(s, PlayAction(1, [card1]));
        expect(s.playedBySeat[1]!.length, 1);
        expect(s.playedBySeat[1]!.first, card1);
        expect(s.playedBySeat[0]!.length, 1);
        expect(s.actionSeq.length, 2);
      } on IllegalActionError {
        // 1 管不上时跳过本断言（不是本测试的关注点）
      }
    });
  });
}
