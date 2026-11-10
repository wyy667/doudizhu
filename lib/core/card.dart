/// 牌面点数（顺序值）。数值越大牌越大，比较时直接用 [value]。
///
/// 参见 docs/04-game-rules.md §2。
enum Rank {
  c3(3, '3'),
  c4(4, '4'),
  c5(5, '5'),
  c6(6, '6'),
  c7(7, '7'),
  c8(8, '8'),
  c9(9, '9'),
  c10(10, '10'),
  cJ(11, 'J'),
  cQ(12, 'Q'),
  cK(13, 'K'),
  cA(14, 'A'),
  c2(15, '2'),
  bj(16, '小王'),
  rj(17, '大王');

  final int value;
  final String label;
  const Rank(this.value, this.label);

  /// 是否为大小王。王不参与顺子/连对/飞机等连续牌型。
  bool get isJoker => this == Rank.bj || this == Rank.rj;

  /// 是否可参与顺子（3~A，不含 2 与王）。
  bool get canBeInStraight => value >= Rank.c3.value && value <= Rank.cA.value;
}

/// 花色。斗地主中花色不影响大小，仅用于 UI 区分。
enum Suit { spade, heart, diamond, club, jokerSmall, jokerBig }

/// 一张牌的不可变表示。
///
/// [Rank.bj] 只能配 [Suit.jokerSmall]，[Rank.rj] 只能配 [Suit.jokerBig]。
class Card implements Comparable<Card> {
  final Rank rank;
  final Suit suit;

  const Card(this.rank, this.suit);

  /// 标准构造：按点数与花色序号生成（0~51 为 3~2 的四花色，52/53 为小/大王）。
  factory Card.fromIndex(int index) {
    assert(index >= 0 && index < 54, 'Card index must be 0..53');
    if (index == 52) return const Card(Rank.bj, Suit.jokerSmall);
    if (index == 53) return const Card(Rank.rj, Suit.jokerBig);
    const normalRanks = [
      Rank.c3,
      Rank.c4,
      Rank.c5,
      Rank.c6,
      Rank.c7,
      Rank.c8,
      Rank.c9,
      Rank.c10,
      Rank.cJ,
      Rank.cQ,
      Rank.cK,
      Rank.cA,
      Rank.c2,
    ];
    const suits = [Suit.spade, Suit.heart, Suit.diamond, Suit.club];
    return Card(normalRanks[index ~/ 4], suits[index % 4]);
  }

  /// 唯一索引（0..53），便于序列化与排序。
  int get index {
    switch (rank) {
      case Rank.bj:
        return 52;
      case Rank.rj:
        return 53;
      default:
        const normalRanks = [
          Rank.c3,
          Rank.c4,
          Rank.c5,
          Rank.c6,
          Rank.c7,
          Rank.c8,
          Rank.c9,
          Rank.c10,
          Rank.cJ,
          Rank.cQ,
          Rank.cK,
          Rank.cA,
          Rank.c2,
        ];
        final rankIdx = normalRanks.indexOf(rank);
        final suitIdx = const [
          Suit.spade,
          Suit.heart,
          Suit.diamond,
          Suit.club,
        ].indexOf(suit);
        return rankIdx * 4 + suitIdx;
    }
  }

  @override
  int compareTo(Card other) => index.compareTo(other.index);

  @override
  bool operator ==(Object other) =>
      other is Card && rank == other.rank && suit == other.suit;

  @override
  int get hashCode => Object.hash(rank, suit);

  @override
  String toString() => rank.label;
}
