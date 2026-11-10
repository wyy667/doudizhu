import 'card.dart';
import 'dart:math';

/// 发牌结果：三位玩家各 17 张 + 3 张底牌。
class DealResult {
  final List<Card> hand0;
  final List<Card> hand1;
  final List<Card> hand2;
  final List<Card> bottom;
  DealResult(this.hand0, this.hand1, this.hand2, this.bottom);

  List<List<Card>> get hands => [hand0, hand1, hand2];
}

/// 一副完整 54 张牌的操作工具。
class Deck {
  /// 生成按索引有序的 54 张牌（未洗）。
  static List<Card> full() => [for (var i = 0; i < 54; i++) Card.fromIndex(i)];

  /// 用 [seed] 洗牌，返回洗后的 54 张牌。可种子化便于复现对局。
  static List<Card> shuffled(int seed) {
    final cards = full();
    cards.shuffle(Random(seed));
    return cards;
  }

  /// 按 [seed] 发牌：前 51 张分给三人，后 3 张为底牌。
  /// 每人手牌按 rank 降序排列（便于显示）。
  static DealResult deal(int seed) {
    final cards = shuffled(seed);
    final h0 = _sortDesc(cards.sublist(0, 17));
    final h1 = _sortDesc(cards.sublist(17, 34));
    final h2 = _sortDesc(cards.sublist(34, 51));
    final bottom = _sortDesc(cards.sublist(51, 54));
    return DealResult(h0, h1, h2, bottom);
  }

  /// 不洗牌发牌：牌按自然顺序分块发给三人（每家连续 17 张），
  /// 仅随机选择切牌点。同点数牌更集中 → 更多炸弹/顺子/连对。
  static DealResult dealNoShuffle(int seed) {
    final rng = Random(seed);
    final cards = full();
    final offset = rng.nextInt(54);
    final rotated = [...cards.sublist(offset), ...cards.sublist(0, offset)];
    final h0 = _sortDesc(rotated.sublist(0, 17));
    final h1 = _sortDesc(rotated.sublist(17, 34));
    final h2 = _sortDesc(rotated.sublist(34, 51));
    final bottom = _sortDesc(rotated.sublist(51, 54));
    return DealResult(h0, h1, h2, bottom);
  }

  static List<Card> _sortDesc(List<Card> cards) {
    final sorted = List<Card>.from(cards);
    sorted.sort((a, b) => b.rank.value.compareTo(a.rank.value));
    return sorted;
  }
}
