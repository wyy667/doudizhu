import 'card.dart';
import 'hand_type.dart';

/// 一次牌型识别的结果。不可变。
///
/// 字段语义参见 docs/04-game-rules.md §7 与 docs/05-architecture.md §2.1。
class HandPattern {
  final HandType type;

  /// 主体点数。比较时使用：
  /// - 单/对/三/三带/炸弹：该牌的 rank value。
  /// - 顺子/连对/飞机：连续序列起点的 rank value（最小一张主体）。
  /// - 火箭：固定为 [Rank.rj.value]（最大）。
  final int mainRank;

  /// 张数。用于校验同型同长。
  final int length;

  /// 实际的牌（按 rank 排序）。
  final List<Card> cards;

  /// 飞机/连对/顺子的「连续段数」：对飞机=三张组个数，连对=对子个数，顺子=单牌个数。
  /// 其余牌型为 0。用于飞机带翅膀的长度校验。
  final int seriesCount;

  const HandPattern({
    required this.type,
    required this.mainRank,
    required this.length,
    required this.cards,
    this.seriesCount = 0,
  });

  @override
  String toString() =>
      'HandPattern(${type.label}, mainRank=$mainRank, len=$length, series=$seriesCount)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HandPattern &&
          type == other.type &&
          mainRank == other.mainRank &&
          length == other.length &&
          seriesCount == other.seriesCount;

  @override
  int get hashCode => Object.hash(type, mainRank, length, seriesCount);
}
