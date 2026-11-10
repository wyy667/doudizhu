import 'card.dart';
import 'hand_pattern.dart';
import 'hand_type.dart';

/// 牌型识别器。纯函数，无副作用。
///
/// 输入一组牌，识别其是否符合某种斗地主牌型。
/// 参见 docs/04-game-rules.md §3 的 14 种牌型。
class HandDetector {
  /// 识别 [cards] 组成的牌型；非法组合返回 null。
  ///
  /// 输入会被排序处理，调用方无需预排序。
  static HandPattern? detect(List<Card> input) {
    if (input.isEmpty) return null;
    final cards = _sortedAsc(input);
    final n = cards.length;

    final groups = _groupByRank(cards); // rank value -> count
    final counts = groups.values.toList()..sort();
    final distinctRanks = groups.keys.toList()..sort();
    final maxCount = counts.isEmpty ? 0 : counts.last;

    // 1. 火箭：小王+大王
    if (n == 2 &&
        cards.any((c) => c.rank == Rank.bj) &&
        cards.any((c) => c.rank == Rank.rj)) {
      return HandPattern(
        type: HandType.rocket,
        mainRank: Rank.rj.value,
        length: 2,
        cards: cards,
      );
    }

    // 2. 炸弹：四张同点
    if (n == 4 && groups.length == 1 && maxCount == 4) {
      return HandPattern(
        type: HandType.bomb,
        mainRank: distinctRanks.first,
        length: 4,
        cards: cards,
      );
    }

    // 3. 单牌
    if (n == 1) {
      return HandPattern(
        type: HandType.single,
        mainRank: cards.first.rank.value,
        length: 1,
        cards: cards,
      );
    }

    // 4. 对子
    if (n == 2 && groups.length == 1 && maxCount == 2) {
      return HandPattern(
        type: HandType.pair,
        mainRank: distinctRanks.first,
        length: 2,
        cards: cards,
      );
    }

    // 5. 三张
    if (n == 3 && groups.length == 1 && maxCount == 3) {
      return HandPattern(
        type: HandType.triple,
        mainRank: distinctRanks.first,
        length: 3,
        cards: cards,
      );
    }

    // 6. 三带一：3+1
    if (n == 4 && groups.length == 2 && counts.contains(3)) {
      final tripleRank = groups.entries.firstWhere((e) => e.value == 3).key;
      return HandPattern(
        type: HandType.tripleSingle,
        mainRank: tripleRank,
        length: 4,
        cards: cards,
      );
    }

    // 7. 三带二：3+2
    if (n == 5 &&
        groups.length == 2 &&
        counts.contains(3) &&
        counts.contains(2)) {
      final tripleRank = groups.entries.firstWhere((e) => e.value == 3).key;
      return HandPattern(
        type: HandType.triplePair,
        mainRank: tripleRank,
        length: 5,
        cards: cards,
      );
    }

    // 8. 顺子：≥5 张连续单牌，不含 2 和王
    if (n >= 5 &&
        groups.length == n &&
        maxCount == 1 &&
        _allNonJokerNonTwo(distinctRanks)) {
      if (_isConsecutive(distinctRanks)) {
        return HandPattern(
          type: HandType.straight,
          mainRank: distinctRanks.first,
          length: n,
          cards: cards,
          seriesCount: n,
        );
      }
    }

    // 9. 连对：≥3 对连续，不含 2 和王
    if (n >= 6 &&
        n % 2 == 0 &&
        groups.length * 2 == n &&
        counts.every((c) => c == 2) &&
        _allNonJokerNonTwo(distinctRanks) &&
        _isConsecutive(distinctRanks)) {
      return HandPattern(
        type: HandType.pairStraight,
        mainRank: distinctRanks.first,
        length: n,
        cards: cards,
        seriesCount: groups.length,
      );
    }

    // 10~12. 飞机系列（不带/带单/带对）：先找出连续三张组
    final tripleRanks =
        groups.entries.where((e) => e.value >= 3).map((e) => e.key).toList()
          ..sort();
    // 飞机的三张组不能含 2 和王；尝试找到最长的连续三张组
    final planeBody = _longestConsecutiveNonTwo(tripleRanks);

    // 10. 飞机不带：所有牌都是三张组，连续，不含 2/王
    if (planeBody != null &&
        planeBody.length >= 2 &&
        n == planeBody.length * 3) {
      final isPurePlane =
          planeBody.every((r) => groups[r] == 3) &&
          groups.length == planeBody.length;
      if (isPurePlane) {
        return HandPattern(
          type: HandType.plane,
          mainRank: planeBody.first,
          length: n,
          cards: cards,
          seriesCount: planeBody.length,
        );
      }
    }

    // 11/12. 飞机带翅膀
    if (planeBody != null && planeBody.length >= 2) {
      final bodyLen = planeBody.length;
      final bodyCardCount = bodyLen * 3;

      // 飞机带单：n == bodyLen*4，翅膀为 bodyLen 张单牌
      if (n == bodyCardCount + bodyLen) {
        if (_tryPlaneWithSingles(groups, planeBody)) {
          return HandPattern(
            type: HandType.planeSingle,
            mainRank: planeBody.first,
            length: n,
            cards: cards,
            seriesCount: bodyLen,
          );
        }
      }
      // 飞机带对：n == bodyLen*5，翅膀为 bodyLen 对
      if (n == bodyCardCount + bodyLen * 2) {
        if (_tryPlaneWithPairs(groups, planeBody)) {
          return HandPattern(
            type: HandType.planePair,
            mainRank: planeBody.first,
            length: n,
            cards: cards,
            seriesCount: bodyLen,
          );
        }
      }
    }

    // 13. 四带二（两单）：四张 + 两张单牌（点数可同）
    if (n == 6 && maxCount == 4) {
      final fourRank = groups.entries.firstWhere((e) => e.value == 4).key;
      return HandPattern(
        type: HandType.bombTwoSingle,
        mainRank: fourRank,
        length: 6,
        cards: cards,
      );
    }

    // 14. 四带两对：四张 + 两对（两对点数必须不同）
    if (n == 8 && maxCount == 4) {
      final pairsCount = groups.values.where((c) => c == 2).length;
      final hasFour = groups.values.any((c) => c == 4);
      if (hasFour && pairsCount == 2) {
        final fourRank = groups.entries.firstWhere((e) => e.value == 4).key;
        return HandPattern(
          type: HandType.bombTwoPair,
          mainRank: fourRank,
          length: 8,
          cards: cards,
        );
      }
    }

    return null;
  }

  // ---------- 辅助 ----------

  static List<Card> _sortedAsc(List<Card> cards) {
    final sorted = List<Card>.from(cards);
    sorted.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return sorted;
  }

  /// 按 rank value 分组计数。
  static Map<int, int> _groupByRank(List<Card> cards) {
    final m = <int, int>{};
    for (final c in cards) {
      m[c.rank.value] = (m[c.rank.value] ?? 0) + 1;
    }
    return m;
  }

  /// 所有 rank 都不含 2(value=15) 和王(16/17)。
  static bool _allNonJokerNonTwo(List<int> ranks) =>
      ranks.every((r) => r >= Rank.c3.value && r <= Rank.cA.value);

  /// 是否连续（差为 1），输入需已升序。
  static bool _isConsecutive(List<int> ranks) {
    for (var i = 1; i < ranks.length; i++) {
      if (ranks[i] - ranks[i - 1] != 1) return false;
    }
    return true;
  }

  /// 从 [ranks] 中找出最长的、不含 2/王 的连续段。
  /// 用于飞机主体识别（例如 333444555 中找出 3,4,5）。
  static List<int>? _longestConsecutiveNonTwo(List<int> ranks) {
    final filtered = ranks.where((r) => r <= Rank.cA.value).toList()..sort();
    if (filtered.isEmpty) return null;
    List<int> best = [];
    List<int> cur = [filtered.first];
    for (var i = 1; i < filtered.length; i++) {
      if (filtered[i] - filtered[i - 1] == 1) {
        cur.add(filtered[i]);
      } else {
        if (cur.length > best.length) best = cur;
        cur = [filtered[i]];
      }
    }
    if (cur.length > best.length) best = cur;
    return best.isEmpty ? null : best;
  }

  /// 飞机带单：校验翅膀。翅膀不能含与飞机连续的三张组、炸弹。
  /// 这里简化为：除主体外，其余每张牌计数 ≤ 1（单牌），允许重复单牌点数。
  static bool _tryPlaneWithSingles(Map<int, int> groups, List<int> body) {
    final bodySet = body.toSet();
    final wingCount = body.length; // 期望 body.length 张单牌
    var singles = 0;
    groups.forEach((rank, count) {
      if (bodySet.contains(rank)) {
        // 主体该点数：应正好 3 张
        if (count != 3) {
          // 主体点数若 >3 视为不纯（如 4444 与飞机混合），不允许
        }
      } else {
        // 翅膀：单牌点数
        singles += count;
      }
    });
    return singles == wingCount;
  }

  /// 飞机带对：校验翅膀为 body.length 对，每对不同点数，且不能含炸弹/王炸。
  static bool _tryPlaneWithPairs(Map<int, int> groups, List<int> body) {
    final bodySet = body.toSet();
    final wingPairs = <int>[];
    groups.forEach((rank, count) {
      if (bodySet.contains(rank)) {
        // 主体该点数应正好 3 张
      } else if (count == 2) {
        wingPairs.add(rank);
      }
    });
    // 翅膀对数 == body 长度，且每对不同点数（map 天然去重）
    return wingPairs.length == body.length;
  }
}
