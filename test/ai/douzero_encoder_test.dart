import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/ai/douzero/douzero_encoder.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';

void main() {
  group('DouZeroEncoder.cardsToArray', () {
    test('空手牌 → 全 0 的 54 维向量', () {
      final arr = DouZeroEncoder.cardsToArray(const <Card>[]);
      expect(arr.length, 54);
      expect(arr.every((v) => v == 0), isTrue);
    });

    test('单张 3 → col 0 的第一位为 1', () {
      // Card(Rank.c3) → DouZero card 3 → column 0 → bit 0
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.c3, Suit.spade),
      ]);
      expect(arr[0], 1); // col 0, row 0
      expect(arr[1], 0);
      expect(arr[2], 0);
      expect(arr[3], 0);
    });

    test('三张 5 → col 2 的前 3 位为 1', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.c5, Suit.spade),
        const Card(Rank.c5, Suit.heart),
        const Card(Rank.c5, Suit.diamond),
      ]);
      // column 2 → indices 8,9,10,11
      expect(arr[8], 1);
      expect(arr[9], 1);
      expect(arr[10], 1);
      expect(arr[11], 0);
    });

    test('四张 A (14) → col 11 全 1', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.cA, Suit.spade),
        const Card(Rank.cA, Suit.heart),
        const Card(Rank.cA, Suit.diamond),
        const Card(Rank.cA, Suit.club),
      ]);
      // column 11 → indices 44,45,46,47
      expect(arr[44], 1);
      expect(arr[45], 1);
      expect(arr[46], 1);
      expect(arr[47], 1);
    });

    test('"2" (rank 15) → col 12', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.c2, Suit.spade),
      ]);
      // column 12 → indices 48,49,50,51
      expect(arr[48], 1);
      expect(arr[49], 0);
      expect(arr[50], 0);
      expect(arr[51], 0);
    });

    test('小王 → bit 52', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.bj, Suit.jokerSmall),
      ]);
      expect(arr[52], 1);
      expect(arr[53], 0);
    });

    test('大王 → bit 53', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.rj, Suit.jokerBig),
      ]);
      expect(arr[52], 0);
      expect(arr[53], 1);
    });

    test('火箭（双王）→ bit 52 和 53 均为 1', () {
      final arr = DouZeroEncoder.cardsToArray([
        const Card(Rank.bj, Suit.jokerSmall),
        const Card(Rank.rj, Suit.jokerBig),
      ]);
      expect(arr[52], 1);
      expect(arr[53], 1);
    });
  });

  group('DouZeroEncoder oneHot helpers', () {
    test('oneHotNumLeft(n=17, max=17) → bit 16', () {
      final v = DouZeroEncoder.oneHotNumLeft(17, 17);
      expect(v.length, 17);
      expect(v[16], 1);
      expect(v.where((x) => x == 1).length, 1);
    });

    test('oneHotNumLeft(n=20, max=20) → bit 19（地主）', () {
      final v = DouZeroEncoder.oneHotNumLeft(20, 20);
      expect(v.length, 20);
      expect(v[19], 1);
    });

    test('oneHotBombNum(3) → bit 3', () {
      final v = DouZeroEncoder.oneHotBombNum(3);
      expect(v.length, 15);
      expect(v[3], 1);
      expect(v.where((x) => x == 1).length, 1);
    });
  });

  group('DouZeroEncoder.lastMove', () {
    final card3 = const Card(Rank.c3, Suit.spade);
    final card5 = const Card(Rank.c5, Suit.spade);

    GameState makeState(List<List<Card>> seq) => GameState(
      phase: GamePhase.playing,
      players: const [],
      currentPlayer: 0,
      bottomCards: const [],
      deckSeed: 0,
      actionSeq: seq,
    );

    test('空序列 → []', () {
      expect(DouZeroEncoder.lastMove(makeState([])), isEmpty);
    });

    test('最后一步非空 → 返回最后一步', () {
      final m = DouZeroEncoder.lastMove(
        makeState([
          [card3],
          [card5],
        ]),
      );
      expect(m, [card5]);
    });

    test('最后一步是 pass（[]）→ 返回倒数第二步', () {
      final m = DouZeroEncoder.lastMove(
        makeState([
          [card3],
          [card5],
          [],
        ]),
      );
      expect(m, [card5]);
    });

    test('自由出牌（两连 pass）→ 返回 []（不扫描更早的历史）', () {
      // seq = [X, [], []] → Python get_last_move: seq[-1]=[] → seq[-2]=[] → []
      // 旧 bug: 扫描到 X；修复后: 对齐 Python 返回 []
      final m = DouZeroEncoder.lastMove(
        makeState([
          [card3],
          [],
          [],
        ]),
      );
      expect(m, isEmpty, reason: '自由出牌时 last_action 应为空（对齐 Python）');
    });

    test('三连 pass 不应发生（游戏引擎不允许），但即使发生也只看 [-2]', () {
      final m = DouZeroEncoder.lastMove(
        makeState([
          [card3],
          [card5],
          [],
          [],
        ]),
      );
      // seq[-1]=[] → seq[-2]=[] → 返回 []
      expect(m, isEmpty);
    });
  });

  group('DouZeroEncoder.encodeZ', () {
    test('空 actionSeq → 810 维全 0', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: const [],
      );
      final z = DouZeroEncoder.encodeZ(state);
      expect(z.length, 5 * 162);
      expect(z.every((v) => v == 0), isTrue);
    });

    test('1 步出牌 → 最后位置（index 809-54+某位）有值', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [const Card(Rank.c3, Suit.spade)],
        ],
      );
      final z = DouZeroEncoder.encodeZ(state);
      expect(z.length, 5 * 162);
      // 最后一步在第 5 行（index 4）的第 3 个 54 段（index 4*162 + 2*54 = 756）
      // 即 z[756..810) 包含这一手牌的 54-dim
      expect(z[756], 1); // c3 → col 0 row 0
      // 其余位置应全 0（左填空 + 第 5 行的另两段也空）
      final before = z.sublist(0, 756);
      expect(before.every((v) => v == 0), isTrue);
    });
  });

  group('DouZeroEncoder.encodeXBatch', () {
    test('地主维度 = 373', () {
      // 构造一个简单的 playing 状态
      final engine = const GameEngine();
      final deal = Deck.deal(42);
      var state = engine.apply(
        GameState.initial(),
        DealAction(deal.hands, deal.bottom, 42),
      );
      // 让座位 0 叫 3 分立即成交
      state = engine.apply(state, BidAction(0, 3));
      expect(state.phase, GamePhase.playing);
      expect(state.landlordSeat, 0);

      final candidates = [
        [state.players[0].hand.first],
      ];
      final x = DouZeroEncoder.encodeXBatch(
        state,
        0,
        candidates,
        DouZeroRole.landlord,
      );
      expect(x.length, 1 * 373);

      final xNoAction = Float32List(373 - 54);
      xNoAction.setRange(0, 319, x.sublist(0, 319));
      // my_action 部分应该是 candidates[0] 的 cardsToArray
      final actionPart = x.sublist(319, 373);
      final expected = DouZeroEncoder.cardsToArray(candidates[0]);
      for (var i = 0; i < 54; i++) {
        expect(actionPart[i], expected[i]);
      }
    });

    test('农民维度 = 484', () {
      final engine = const GameEngine();
      // seed 0 → startSeat = 0，让座位 0 能立刻叫 3 分
      final deal = Deck.deal(0);
      var state = engine.apply(
        GameState.initial(),
        DealAction(deal.hands, deal.bottom, 0),
      );
      state = engine.apply(state, BidAction(0, 3));
      // 座位 1 是农民
      final candidates = [
        [state.players[1].hand.first],
      ];
      final x = DouZeroEncoder.encodeXBatch(
        state,
        1,
        candidates,
        DouZeroRole.landlordDown,
      );
      expect(x.length, 1 * 484);
    });
  });

  group('DouZeroEncoder.countBombs', () {
    test('无炸弹 → 0', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [Card(Rank.c3, Suit.spade)],
          [Card(Rank.c5, Suit.heart)],
        ],
      );
      expect(DouZeroEncoder.countBombs(state), 0);
    });

    test('出过炸弹动作 → 1', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [Card(Rank.c5, Suit.spade)],
          [
            Card(Rank.c7, Suit.spade),
            Card(Rank.c7, Suit.heart),
            Card(Rank.c7, Suit.diamond),
            Card(Rank.c7, Suit.club),
          ],
        ],
      );
      expect(DouZeroEncoder.countBombs(state), 1);
    });

    test('出过火箭动作 → 1', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [Card(Rank.bj, Suit.jokerSmall), Card(Rank.rj, Suit.jokerBig)],
        ],
      );
      expect(DouZeroEncoder.countBombs(state), 1);
    });

    test('4 张同点拆散在多个非炸弹动作中 → 0（不误计）', () {
      // 先出单张 3，再出三张 3——playedCards 中有 4 张 3 但无炸弹动作
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [Card(Rank.c3, Suit.spade)],
          [
            Card(Rank.c3, Suit.heart),
            Card(Rank.c3, Suit.diamond),
            Card(Rank.c3, Suit.club),
          ],
        ],
      );
      expect(DouZeroEncoder.countBombs(state), 0);
    });

    test('多个炸弹累计 → 正确计数', () {
      final state = GameState(
        phase: GamePhase.playing,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
        actionSeq: [
          [
            Card(Rank.c5, Suit.spade),
            Card(Rank.c5, Suit.heart),
            Card(Rank.c5, Suit.diamond),
            Card(Rank.c5, Suit.club),
          ],
          [Card(Rank.bj, Suit.jokerSmall), Card(Rank.rj, Suit.jokerBig)],
        ],
      );
      expect(DouZeroEncoder.countBombs(state), 2);
    });
  });

  group('DouZeroEncoder no-cheating 等价性', () {
    test('unknownCardsUnion 与对手手牌并集在 multiset 上等价', () {
      // 构造 playing 状态：seed=0，座位 0 当地主
      final engine = const GameEngine();
      final deal = Deck.deal(0);
      var state = engine.apply(
        GameState.initial(),
        DealAction(deal.hands, deal.bottom, 0),
      );
      state = engine.apply(state, BidAction(0, 3));
      // 验证 4 种视角：3 个 seat 都对
      for (var seat = 0; seat < 3; seat++) {
        // 真实对手手牌并集
        final realOpponents = <Card>[
          for (var s = 0; s < 3; s++)
            if (s != seat) ...state.players[s].hand,
        ];
        // 通过 _unknownCardsUnion 得到的「未公开牌」（私有 API 不能直接测，
        // 但 cardsToArray 的结果应该等价——通过编码后的向量对比验证）
        // 构造两个 GameState 的并集，比较 54-dim 编码
        final myHand = state.players[seat].hand;
        // 模拟 _unknownCardsUnion 的逻辑（公开测试）
        final known = <int>{
          ...myHand.map((c) => c.index),
          ...state.playedCards.map((c) => c.index),
        };
        final unknown = <Card>[
          for (var i = 0; i < 54; i++)
            if (!known.contains(i)) Card.fromIndex(i),
        ];
        final arrReal = DouZeroEncoder.cardsToArray(realOpponents);
        final arrUnknown = DouZeroEncoder.cardsToArray(unknown);
        expect(
          arrUnknown,
          orderedEquals(arrReal),
          reason: 'seat=$seat: 未公开牌应与对手手牌并集在 multiset 上等价',
        );
      }
    });

    test('出过牌后等价性仍然成立', () {
      final engine = const GameEngine();
      final deal = Deck.deal(0);
      var state = engine.apply(
        GameState.initial(),
        DealAction(deal.hands, deal.bottom, 0),
      );
      state = engine.apply(state, BidAction(0, 3));
      // 地主出一张
      final card = state.players[0].hand.last;
      state = engine.apply(state, PlayAction(0, [card]));

      // 对 seat 1 验证
      final realOpponents = <Card>[
        ...state.players[0].hand,
        ...state.players[2].hand,
      ];
      final myHand = state.players[1].hand;
      final known = <int>{
        ...myHand.map((c) => c.index),
        ...state.playedCards.map((c) => c.index),
      };
      final unknown = <Card>[
        for (var i = 0; i < 54; i++)
          if (!known.contains(i)) Card.fromIndex(i),
      ];
      final arrReal = DouZeroEncoder.cardsToArray(realOpponents);
      final arrUnknown = DouZeroEncoder.cardsToArray(unknown);
      expect(arrUnknown, orderedEquals(arrReal));
    });
  });
}
