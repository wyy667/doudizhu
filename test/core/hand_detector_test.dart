import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/hand_type.dart';
import 'package:landlord/core/hand_detector.dart';
import 'package:landlord/core/hand_compare.dart';

// ---------- 测试辅助：快速造牌 ----------
// 形如 c('3')、c('A')、c('BJ')、c('RJ')。
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

List<Card> L(List<Card> cards) => cards;
HandType? type(List<Card> cards) => HandDetector.detect(cards)?.type;

void main() {
  group('detectHand · 基础牌型', () {
    test('单牌', () {
      expect(type([c('7')]), HandType.single);
    });
    test('对子', () {
      expect(type([c('5', 0), c('5', 1)]), HandType.pair);
    });
    test('三张', () {
      expect(type([c('J', 0), c('J', 1), c('J', 2)]), HandType.triple);
    });
    test('三带一', () {
      expect(
        type([c('8', 0), c('8', 1), c('8', 2), c('3')]),
        HandType.tripleSingle,
      );
    });
    test('三带二', () {
      expect(
        type([c('9', 0), c('9', 1), c('9', 2), c('4', 0), c('4', 1)]),
        HandType.triplePair,
      );
    });
    test('炸弹', () {
      expect(type([c('K', 0), c('K', 1), c('K', 2), c('K', 3)]), HandType.bomb);
    });
    test('火箭', () {
      expect(type([c('BJ'), c('RJ')]), HandType.rocket);
    });
  });

  group('detectHand · 顺子', () {
    test('5 张顺子', () {
      expect(type([c('3'), c('4'), c('5'), c('6'), c('7')]), HandType.straight);
    });
    test('A 可作为顺子最大牌（10-J-Q-K-A）', () {
      expect(
        type([c('10'), c('J'), c('Q'), c('K'), c('A')]),
        HandType.straight,
      );
    });
    test('2 不能参与顺子', () {
      expect(type([c('4'), c('5'), c('6'), c('7'), c('2')]), isNull);
    });
    test('不连续返回 null', () {
      expect(type([c('3'), c('4'), c('5'), c('6'), c('8')]), isNull);
    });
    test('长度不足 5 返回 null', () {
      expect(type([c('3'), c('4'), c('5')]), isNull);
    });
    test('12 张长顺子', () {
      final cards = [
        for (final r in [
          '3',
          '4',
          '5',
          '6',
          '7',
          '8',
          '9',
          '10',
          'J',
          'Q',
          'K',
          'A',
        ])
          c(r),
      ];
      expect(type(cards), HandType.straight);
    });
  });

  group('detectHand · 连对', () {
    test('3 连对（33 44 55）', () {
      expect(
        type([
          c('3', 0),
          c('3', 1),
          c('4', 0),
          c('4', 1),
          c('5', 0),
          c('5', 1),
        ]),
        HandType.pairStraight,
      );
    });
    test('含 2 非法', () {
      expect(
        type([
          c('K', 0),
          c('K', 1),
          c('A', 0),
          c('A', 1),
          c('2', 0),
          c('2', 1),
        ]),
        isNull,
      );
    });
    test('只有 2 对长度不足', () {
      expect(type([c('3', 0), c('3', 1), c('4', 0), c('4', 1)]), isNull);
    });
  });

  group('detectHand · 飞机', () {
    test('飞机不带（777 888）', () {
      expect(
        type([
          c('7', 0),
          c('7', 1),
          c('7', 2),
          c('8', 0),
          c('8', 1),
          c('8', 2),
        ]),
        HandType.plane,
      );
    });
    test('飞机带单（777 888 + 3 5）', () {
      expect(
        type([
          c('7', 0),
          c('7', 1),
          c('7', 2),
          c('8', 0),
          c('8', 1),
          c('8', 2),
          c('3'),
          c('5'),
        ]),
        HandType.planeSingle,
      );
    });
    test('飞机带对（777 888 + 33 55）', () {
      expect(
        type([
          c('7', 0),
          c('7', 1),
          c('7', 2),
          c('8', 0),
          c('8', 1),
          c('8', 2),
          c('3', 0),
          c('3', 1),
          c('5', 0),
          c('5', 1),
        ]),
        HandType.planePair,
      );
    });
    test('飞机不连续（777 999）非飞机', () {
      expect(
        type([
          c('7', 0),
          c('7', 1),
          c('7', 2),
          c('9', 0),
          c('9', 1),
          c('9', 2),
        ]),
        isNull,
      );
    });
    test('飞机含 2 非法', () {
      expect(
        type([
          c('A', 0),
          c('A', 1),
          c('A', 2),
          c('2', 0),
          c('2', 1),
          c('2', 2),
        ]),
        isNull,
      );
    });
  });

  group('detectHand · 四带二', () {
    test('四带二单（6666 + 3 + 8）', () {
      expect(
        type([c('6', 0), c('6', 1), c('6', 2), c('6', 3), c('3'), c('8')]),
        HandType.bombTwoSingle,
      );
    });
    test('四带两对（6666 + 33 + 88）', () {
      expect(
        type([
          c('6', 0),
          c('6', 1),
          c('6', 2),
          c('6', 3),
          c('3', 0),
          c('3', 1),
          c('8', 0),
          c('8', 1),
        ]),
        HandType.bombTwoPair,
      );
    });
  });

  group('detectHand · 非法组合', () {
    test('单张 2 + 王 不是顺子也不是合法组合', () {
      expect(type([c('2'), c('BJ')]), isNull);
    });
    test('四张但非同点（不是炸弹）', () {
      expect(type([c('3'), c('4'), c('5'), c('6')]), isNull);
    });
    test('空牌返回 null', () {
      expect(HandDetector.detect([]), isNull);
    });
  });

  group('canBeat · 普通牌型比较', () {
    test('大单压小单', () {
      final small = HandDetector.detect([c('5')])!;
      final big = HandDetector.detect([c('K')])!;
      expect(HandCompare.canBeat(big, small), true);
      expect(HandCompare.canBeat(small, big), false);
    });
    test('同型同长顺子比较', () {
      final s1 = HandDetector.detect([c('3'), c('4'), c('5'), c('6'), c('7')])!;
      final s2 = HandDetector.detect([c('5'), c('6'), c('7'), c('8'), c('9')])!;
      expect(HandCompare.canBeat(s2, s1), true);
      expect(HandCompare.canBeat(s1, s2), false);
    });
    test('不同型不能压（单牌 vs 对子）', () {
      final single = HandDetector.detect([c('A')])!;
      final pair = HandDetector.detect([c('5', 0), c('5', 1)])!;
      expect(HandCompare.canBeat(single, pair), false);
    });
    test('不同长度顺子不能压', () {
      final s5 = HandDetector.detect([c('3'), c('4'), c('5'), c('6'), c('7')])!;
      final s6 = HandDetector.detect([
        c('3'),
        c('4'),
        c('5'),
        c('6'),
        c('7'),
        c('8'),
      ])!;
      expect(HandCompare.canBeat(s6, s5), false);
    });
  });

  group('canBeat · 炸弹与火箭', () {
    test('炸弹压单牌', () {
      final bomb = HandDetector.detect([
        c('K', 0),
        c('K', 1),
        c('K', 2),
        c('K', 3),
      ])!;
      final single = HandDetector.detect([c('A')])!;
      expect(HandCompare.canBeat(bomb, single), true);
    });
    test('大炸弹压小炸弹', () {
      final smallBomb = HandDetector.detect([
        c('5', 0),
        c('5', 1),
        c('5', 2),
        c('5', 3),
      ])!;
      final bigBomb = HandDetector.detect([
        c('K', 0),
        c('K', 1),
        c('K', 2),
        c('K', 3),
      ])!;
      expect(HandCompare.canBeat(bigBomb, smallBomb), true);
      expect(HandCompare.canBeat(smallBomb, bigBomb), false);
    });
    test('火箭压一切', () {
      final rocket = HandDetector.detect([c('BJ'), c('RJ')])!;
      final bomb = HandDetector.detect([
        c('A', 0),
        c('A', 1),
        c('A', 2),
        c('A', 3),
      ])!;
      expect(HandCompare.canBeat(rocket, bomb), true);
    });
    test('炸弹压不了火箭', () {
      final bomb = HandDetector.detect([
        c('A', 0),
        c('A', 1),
        c('A', 2),
        c('A', 3),
      ])!;
      final rocket = HandDetector.detect([c('BJ'), c('RJ')])!;
      expect(HandCompare.canBeat(bomb, rocket), false);
    });
  });

  group('canBeat · 自由出牌', () {
    test('last 为 null 时任意合法牌型可通过', () {
      final any = HandDetector.detect([c('3')])!;
      expect(HandCompare.canBeat(any, null), true);
    });
  });
}
