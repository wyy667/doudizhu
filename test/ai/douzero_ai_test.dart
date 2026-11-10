import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/ai/douzero/douzero_moves.dart';
import 'package:landlord/ai/douzero_ai.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';
import 'package:landlord/core/hand_detector.dart';
import 'package:landlord/core/hand_pattern.dart';
import 'package:landlord/core/hand_type.dart';

void main() {
  group('DouZeroMoves.enumerate', () {
    test('自由出牌时返回所有可识别牌型（含火箭/炸弹），不含 pass', () {
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.c3, Suit.spade),
          Card(Rank.c3, Suit.heart),
          Card(Rank.c3, Suit.diamond),
          Card(Rank.c3, Suit.club),
          Card(Rank.bj, Suit.jokerSmall),
          Card(Rank.rj, Suit.jokerBig),
        ],
        isFreeTurn: true,
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      expect(moves.any((m) => m.isEmpty), isFalse, reason: '自由出牌不含 pass');
      expect(moves.any((m) => _isRocket(m)), isTrue, reason: '应包含火箭');
      expect(moves.any((m) => _isBombOf3(m)), isTrue, reason: '应包含 4 张 3 炸弹');
    });

    test('跟牌场景下包含 pass（空列表）', () {
      final state = _playingStateWithHand(
        hand: const [Card(Rank.c5, Suit.spade)],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.single,
          mainRank: Rank.cA.value,
          length: 1,
          cards: const [Card(Rank.cA, Suit.spade)],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      expect(moves.any((m) => m.isEmpty), isTrue, reason: '跟牌必须含 pass');
      // 手里只有 5，管不上 A，所以唯一候选是 pass
      expect(moves.length, 1);
    });

    test('能管上时返回所有压制组合 + pass', () {
      final state = _playingStateWithHand(
        hand: const [Card(Rank.cA, Suit.spade), Card(Rank.c2, Suit.spade)],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.single,
          mainRank: Rank.cK.value,
          length: 1,
          cards: const [Card(Rank.cK, Suit.spade)],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      // 应包含：单 A、单 2、pass
      expect(moves.length, 3);
      expect(moves.any((m) => m.isEmpty), isTrue);
      expect(
        moves.any((m) => m.length == 1 && m.first.rank == Rank.cA),
        isTrue,
      );
      expect(
        moves.any((m) => m.length == 1 && m.first.rank == Rank.c2),
        isTrue,
      );
    });

    test('自由出牌 17 张全单 → 至少 17 个单牌候选', () {
      // 17 张不重复的单牌
      final hand = <Card>[
        const Card(Rank.c3, Suit.spade),
        const Card(Rank.c4, Suit.spade),
        const Card(Rank.c5, Suit.spade),
        const Card(Rank.c6, Suit.spade),
        const Card(Rank.c7, Suit.spade),
        const Card(Rank.c8, Suit.spade),
        const Card(Rank.c9, Suit.spade),
        const Card(Rank.c10, Suit.spade),
        const Card(Rank.cJ, Suit.spade),
        const Card(Rank.cQ, Suit.spade),
        const Card(Rank.cK, Suit.spade),
        const Card(Rank.cA, Suit.spade),
        const Card(Rank.c2, Suit.spade),
        const Card(Rank.c3, Suit.heart),
        const Card(Rank.c4, Suit.heart),
        const Card(Rank.c5, Suit.heart),
        const Card(Rank.c6, Suit.heart),
      ];
      final state = _playingStateWithHand(hand: hand, isFreeTurn: true);
      final moves = DouZeroMoves.enumerate(state, 0);
      final singles = moves.where((m) => m.length == 1).length;
      expect(singles, greaterThanOrEqualTo(17));
      // 还有连对（无对，跳过）、顺子、连对（无）、飞机（无）
      final straights = moves.where((m) {
        if (m.length < 5) return false;
        final p = HandDetector.detect(m);
        return p?.type == HandType.straight;
      }).length;
      expect(straights, greaterThan(0), reason: '应能识别若干顺子');
    });
  });

  group('DouZeroMoves.enumerate 跟牌翼枚举', () {
    test('三带一跟牌：每个三张点数 × 每个可用单牌翼', () {
      // 手牌：333 555 7 9 → 可用三张：3, 5；可用单牌翼：7, 9, 3(非自身时), 5(非自身时)
      // 对每个 triple_rank > last.mainRank(=3)，枚举所有非自身单牌作为翼
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.c3, Suit.spade),
          Card(Rank.c3, Suit.heart),
          Card(Rank.c3, Suit.diamond),
          Card(Rank.c5, Suit.spade),
          Card(Rank.c5, Suit.heart),
          Card(Rank.c5, Suit.diamond),
          Card(Rank.c7, Suit.spade),
          Card(Rank.c9, Suit.spade),
        ],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.tripleSingle,
          mainRank: Rank.c3.value,
          length: 4,
          cards: const [
            Card(Rank.c3, Suit.spade),
            Card(Rank.c3, Suit.heart),
            Card(Rank.c3, Suit.diamond),
            Card(Rank.c4, Suit.spade),
          ],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      final tripleSingles = moves
          .where((m) => HandDetector.detect(m)?.type == HandType.tripleSingle)
          .toList();

      // 三张 5 可跟，翼可配：3（取一张）、7、9（3 个不同 rank 选项）
      // 注意翼用的是 distinct rank（_enumSingleWings 按 rank 组合）
      // 非三张 5 的可用 rank：3, 7, 9
      expect(
        tripleSingles.length,
        greaterThanOrEqualTo(3),
        reason: '三带一跟牌应枚举所有翼选项',
      );
    });

    test('三带二跟牌：每个三张点数 × 每个可用对子翼', () {
      // 手牌：333 555 77 99 → 可用三张 > last(3)：5；可用对子翼：77, 99
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.c3, Suit.spade),
          Card(Rank.c3, Suit.heart),
          Card(Rank.c3, Suit.diamond),
          Card(Rank.c5, Suit.spade),
          Card(Rank.c5, Suit.heart),
          Card(Rank.c5, Suit.diamond),
          Card(Rank.c7, Suit.spade),
          Card(Rank.c7, Suit.heart),
          Card(Rank.c9, Suit.spade),
          Card(Rank.c9, Suit.heart),
        ],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.triplePair,
          mainRank: Rank.c3.value,
          length: 5,
          cards: const [
            Card(Rank.c3, Suit.spade),
            Card(Rank.c3, Suit.heart),
            Card(Rank.c3, Suit.diamond),
            Card(Rank.c4, Suit.spade),
            Card(Rank.c4, Suit.heart),
          ],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      final triplePairs = moves
          .where((m) => HandDetector.detect(m)?.type == HandType.triplePair)
          .toList();

      // 三张 5 可跟，翼可配：77 或 99（2 个选项）
      expect(
        triplePairs.length,
        greaterThanOrEqualTo(2),
        reason: '三带二跟牌应枚举所有对子翼选项',
      );
    });

    test('四带二跟牌：应返回四带二候选（不再 break）', () {
      // 手牌：5555 7 9 → last 是 3333+4+6（bombTwoSingle, mainRank=3）
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.c5, Suit.spade),
          Card(Rank.c5, Suit.heart),
          Card(Rank.c5, Suit.diamond),
          Card(Rank.c5, Suit.club),
          Card(Rank.c7, Suit.spade),
          Card(Rank.c9, Suit.spade),
        ],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.bombTwoSingle,
          mainRank: Rank.c3.value,
          length: 6,
          cards: const [
            Card(Rank.c3, Suit.spade),
            Card(Rank.c3, Suit.heart),
            Card(Rank.c3, Suit.diamond),
            Card(Rank.c3, Suit.club),
            Card(Rank.c4, Suit.spade),
            Card(Rank.c6, Suit.spade),
          ],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      final bombTwoSingles = moves
          .where((m) => HandDetector.detect(m)?.type == HandType.bombTwoSingle)
          .toList();
      expect(bombTwoSingles, isNotEmpty, reason: '四带二跟牌应生成候选（旧代码直接 break 跳过）');
    });

    test('单牌跟牌：同一 rank 只出一个候选（不按物理牌重复）', () {
      // 手牌：四个 6 → last 是单 5
      // 旧 bug: 按物理牌枚举出 4 个 [6]；修复后: 只 1 个
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.c6, Suit.spade),
          Card(Rank.c6, Suit.heart),
          Card(Rank.c6, Suit.diamond),
          Card(Rank.c6, Suit.club),
        ],
        isFreeTurn: false,
        lastPlay: HandPattern(
          type: HandType.single,
          mainRank: Rank.c5.value,
          length: 1,
          cards: const [Card(Rank.c5, Suit.spade)],
        ),
      );
      final moves = DouZeroMoves.enumerate(state, 0);
      // 4 个 6 的炸弹 + 单 6 + pass = 3 个
      // 但不能有 4 个重复的单 6
      final singles = moves
          .where((m) => m.length == 1 && m.first.rank == Rank.c6)
          .toList();
      expect(singles.length, 1, reason: '同 rank 单牌跟牌不应按物理牌重复');
    });
  });

  group('DouZeroAi end-to-end', () {
    test('chooseAction bidding 阶段使用 BidAi', () async {
      final engine = const GameEngine();
      final deal = Deck.deal(0);
      final state = engine.apply(
        GameState.initial(),
        DealAction(deal.hands, deal.bottom, 0),
      );
      expect(state.phase, GamePhase.bidding);
      final ai = DouZeroAi();
      final action = await ai.chooseAction(state, 0);
      expect(action, isA<BidAction>());
    });

    test('chooseAction playing 阶段推理失败 → 首个候选 fallback 返回 PlayAction', () async {
      // rootBundle 在 unit test 中不可用 → ONNX session 加载会抛错 → fallback 首个候选
      final state = _playingStateWithHand(
        hand: const [
          Card(Rank.cA, Suit.spade),
          Card(Rank.c5, Suit.heart),
          Card(Rank.c8, Suit.diamond),
        ],
        isFreeTurn: true,
      );
      final ai = DouZeroAi();
      final action = await ai.chooseAction(state, 0);
      expect(action, isA<PlayAction>());
      expect((action as PlayAction).bySeat, 0);
      expect(action.cards, isNotEmpty);
    });

    test('chooseAction settled 阶段 → PassAction（防御）', () async {
      final state = GameState(
        phase: GamePhase.settled,
        players: const [],
        currentPlayer: 0,
        bottomCards: const [],
        deckSeed: 0,
      );
      final ai = DouZeroAi();
      final action = await ai.chooseAction(state, 0);
      expect(action, isA<PassAction>());
    });
  });
}

GameState _playingStateWithHand({
  required List<Card> hand,
  required bool isFreeTurn,
  HandPattern? lastPlay,
}) {
  return GameState(
    phase: GamePhase.playing,
    players: [
      PlayerState(
        seat: 0,
        role: PlayerRole.landlord,
        hand: hand,
        isHuman: false,
      ),
      const PlayerState(
        seat: 1,
        role: PlayerRole.farmer,
        hand: [],
        isHuman: false,
      ),
      const PlayerState(
        seat: 2,
        role: PlayerRole.farmer,
        hand: [],
        isHuman: false,
      ),
    ],
    currentPlayer: 0,
    landlordSeat: 0,
    bottomCards: const [],
    deckSeed: 0,
    lastValidPlay: isFreeTurn || lastPlay == null
        ? null
        : PlayFrame(1, lastPlay, lastPlay.cards),
  );
}

bool _isRocket(List<Card> m) =>
    m.length == 2 &&
    m.any((c) => c.rank == Rank.bj) &&
    m.any((c) => c.rank == Rank.rj);

bool _isBombOf3(List<Card> m) =>
    m.length == 4 && m.every((c) => c.rank == Rank.c3);
