import '../core/card.dart';
import '../core/game_action.dart';
import '../core/game_state.dart';
import '../core/hand_compare.dart';
import '../core/hand_detector.dart';
import '../core/hand_pattern.dart';
import '../core/hand_type.dart';

/// AI 玩家抽象。所有实现必须只使用 [GameState] 中的**可见信息**，
/// 不得读取非自身玩家的手牌。参见 docs/06-ai-strategy.md §2。
abstract class AiPlayer {
  Future<GameAction> chooseAction(GameState state, int seat);
}

/// AI 工具：枚举当前局面下 [seat] 所有合法出牌组合（含炸弹/火箭）。
///
/// 当 [lastPlay] 为 null（自由出牌）时，返回所有可识别牌型。
/// 否则返回所有能压住 [lastPlay] 的组合。
class AiHandSearch {
  /// 枚举手牌中所有「能压住 [last]」的合法组合。
  /// [last] 为 null 时，返回所有可识别的牌型组合。
  static List<HandPattern> findBeats(List<Card> hand, HandPattern? last) {
    final results = <HandPattern>[];
    final byRank = _groupByRank(hand);

    // 火箭
    final hasSmallJoker = hand.any((c) => c.rank == Rank.bj);
    final hasBigJoker = hand.any((c) => c.rank == Rank.rj);
    if (hasSmallJoker && hasBigJoker) {
      final rocket = HandDetector.detect([
        const Card(Rank.bj, Suit.jokerSmall),
        const Card(Rank.rj, Suit.jokerBig),
      ]);
      if (rocket != null && HandCompare.canBeat(rocket, last)) {
        results.add(
          HandPattern(
            type: rocket.type,
            mainRank: rocket.mainRank,
            length: 2,
            cards: [
              const Card(Rank.bj, Suit.jokerSmall),
              const Card(Rank.rj, Suit.jokerBig),
            ],
          ),
        );
      }
    }

    // 炸弹（四张同点）
    for (final entry in byRank.entries) {
      if (entry.value.length == 4) {
        final bomb = HandDetector.detect(entry.value);
        if (bomb != null && HandCompare.canBeat(bomb, last)) {
          results.add(bomb);
        }
      }
    }

    // 普通牌型：若 last 是炸弹/火箭，普通牌型无法压（除非也是炸弹），跳过
    if (last != null && last.type.isBombLike) {
      // 仅炸弹/火箭可压，已在上面枚举
      _sort(results);
      return results;
    }

    // 同型压制：枚举与 last 同型、mainRank 更大的组合
    if (last != null) {
      results.addAll(_enumSameTypeBeats(hand, last));
    } else {
      // 自由出牌：枚举所有可识别牌型（供 AI 选择最优）
      results.addAll(_enumAllPatterns(hand));
    }

    _sort(results);
    return results;
  }

  static void _sort(List<HandPattern> list) {
    list.sort((a, b) {
      // 非炸弹优先（保守），同分类按 mainRank 升序（先出小的）
      final aBomb = a.type.isBombLike ? 1 : 0;
      final bBomb = b.type.isBombLike ? 1 : 0;
      final c = aBomb.compareTo(bBomb);
      if (c != 0) return c;
      return a.mainRank.compareTo(b.mainRank);
    });
  }

  /// 枚举与 [last] 同型且能压住的组合。
  ///
  /// 对齐 Python `MovesGener.gen_type_*()` + `move_selector.filter_type_*()`：
  /// 对带牌型（三带一/三带二/四带二/四带两对）枚举**全部**合法翼组合，
  /// 让模型可以评估每种翼选择。
  static List<HandPattern> _enumSameTypeBeats(
    List<Card> hand,
    HandPattern last,
  ) {
    final results = <HandPattern>[];
    final byRank = _groupByRank(hand);

    switch (last.type) {
      case HandType.single:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank) {
            results.add(_patternOf([entry.value.first]));
          }
        }
      case HandType.pair:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length >= 2) {
            results.add(_patternOf(entry.value.sublist(0, 2)));
          }
        }
      case HandType.triple:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length >= 3) {
            results.add(_patternOf(entry.value.sublist(0, 3)));
          }
        }
      case HandType.tripleSingle:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length >= 3) {
            final triple = entry.value.sublist(0, 3);
            final usedRanks = <int>{entry.key};
            for (final wing in _enumSingleWings(hand, usedRanks, 1)) {
              results.add(_patternOf([...triple, ...wing]));
            }
          }
        }
      case HandType.triplePair:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length >= 3) {
            final triple = entry.value.sublist(0, 3);
            final usedRanks = <int>{entry.key};
            for (final wingPair in _enumPairWings(byRank, usedRanks, 1)) {
              results.add(_patternOf([...triple, ...wingPair]));
            }
          }
        }
      case HandType.straight:
      case HandType.pairStraight:
      case HandType.plane:
      case HandType.planeSingle:
      case HandType.planePair:
        // 连续牌型：贪心枚举同长度的连续序列
        results.addAll(_enumSeriesBeats(hand, last));
      case HandType.bombTwoSingle:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length == 4) {
            final four = entry.value.sublist(0, 4);
            final usedRanks = <int>{entry.key};
            for (final wings in _enumSingleWings(hand, usedRanks, 2)) {
              final p = _pattern([...four, ...wings]);
              if (p != null && p.type == HandType.bombTwoSingle) results.add(p);
            }
          }
        }
      case HandType.bombTwoPair:
        for (final entry in byRank.entries) {
          if (entry.key > last.mainRank && entry.value.length == 4) {
            final four = entry.value.sublist(0, 4);
            final usedRanks = <int>{entry.key};
            for (final wings in _enumPairWings(byRank, usedRanks, 2)) {
              final p = _pattern([...four, ...wings]);
              if (p != null && p.type == HandType.bombTwoPair) results.add(p);
            }
          }
        }
      case HandType.bomb:
      case HandType.rocket:
        // 已在 findBeats 顶层处理
        break;
    }
    return results;
  }

  /// 枚举连续牌型（顺子/连对/飞机）能压住 [last] 的组合。
  static List<HandPattern> _enumSeriesBeats(List<Card> hand, HandPattern last) {
    final results = <HandPattern>[];
    final byRank = _groupByRank(hand);

    final requiredLen = last.seriesCount; // 连续段数
    if (requiredLen < 1) return results;

    // 候选起点：3..(15-requiredLen)，且不含 2/王
    final maxStart = Rank.cA.value - requiredLen + 1;
    for (var start = last.mainRank + 1; start <= maxStart; start++) {
      final combo = <Card>[];
      var ok = true;
      for (var i = 0; i < requiredLen; i++) {
        final r = start + i;
        final group = byRank[r];
        if (group == null) {
          ok = false;
          break;
        }
        switch (last.type) {
          case HandType.straight:
            if (group.isEmpty) ok = false;
            combo.add(group.first);
          case HandType.pairStraight:
            if (group.length < 2) {
              ok = false;
            } else {
              combo.addAll(group.sublist(0, 2));
            }
          case HandType.plane:
            if (group.length < 3) {
              ok = false;
            } else {
              combo.addAll(group.sublist(0, 3));
            }
          case HandType.planeSingle:
          case HandType.planePair:
            if (group.length < 3) {
              ok = false;
            } else {
              combo.addAll(group.sublist(0, 3));
            }
            break;
          default:
            ok = false;
        }
        if (!ok) break;
      }
      if (!ok) continue;

      // 飞机带翅膀：补全翅膀
      if (last.type == HandType.planeSingle) {
        final wings = _pickWings(hand, combo, requiredLen, isPair: false);
        if (wings != null) {
          combo.addAll(wings);
        } else {
          continue;
        }
      } else if (last.type == HandType.planePair) {
        final wings = _pickWings(hand, combo, requiredLen, isPair: true);
        if (wings != null) {
          combo.addAll(wings);
        } else {
          continue;
        }
      }

      final p = _pattern(combo);
      if (p != null && p.type == last.type && HandCompare.canBeat(p, last)) {
        results.add(p);
      }
    }
    return results;
  }

  /// 从手牌 [hand] 中挑出 [count] 张翅膀（单牌或对），排除已用主体 [used]。
  static List<Card>? _pickWings(
    List<Card> hand,
    List<Card> used,
    int count, {
    required bool isPair,
  }) {
    final usedSet = used.toSet();
    final remaining = hand.where((c) => !usedSet.contains(c)).toList();
    final byRank = _groupByRank(remaining);
    final wings = <Card>[];

    if (isPair) {
      var collected = 0;
      for (final entry in byRank.entries) {
        if (entry.value.length >= 2 && collected < count) {
          wings.addAll(entry.value.sublist(0, 2));
          collected++;
        }
      }
      return collected == count ? wings : null;
    } else {
      // 单牌翅膀：取最小的 count 张
      remaining.sort((a, b) => a.rank.value.compareTo(b.rank.value));
      if (remaining.length >= count) {
        wings.addAll(remaining.sublist(0, count));
        return wings;
      }
      return null;
    }
  }

  /// 自由出牌时枚举所有可识别牌型。
  ///
  /// 覆盖 14 种牌型：单/对/三/三带一/三带二/顺子/连对/飞机（含带翅）/四带二单/四带两对/炸弹/火箭。
  /// 对齐 DouZero `MovesGener.gen_moves()` 的候选集合，让模型可评估全部合法主动出牌。
  static List<HandPattern> _enumAllPatterns(List<Card> hand) {
    final results = <HandPattern>[];
    final byRank = _groupByRank(hand);

    // 单牌
    for (final card in hand) {
      final p = _pattern([card]);
      if (p != null) results.add(p);
    }
    // 对子
    for (final entry in byRank.entries) {
      if (entry.value.length >= 2) {
        final p = _pattern(entry.value.sublist(0, 2));
        if (p != null) results.add(p);
      }
    }
    // 三张 / 三带一 / 三带二
    for (final entry in byRank.entries) {
      if (entry.value.length >= 3) {
        final triple = entry.value.sublist(0, 3);
        final p3 = _pattern(triple);
        if (p3 != null) results.add(p3);
        // 三带一（配每张可能的单牌）
        final usedRanks = <int>{entry.key};
        for (final wing in _enumSingleWings(hand, usedRanks, 1)) {
          final p3s = _pattern([...triple, ...wing]);
          if (p3s != null) results.add(p3s);
        }
        // 三带二（配每对可能的对子）
        for (final wingPair in _enumPairWings(byRank, usedRanks, 1)) {
          final p3p = _pattern([...triple, ...wingPair]);
          if (p3p != null) results.add(p3p);
        }
      }
    }
    // 顺子（长度 5..12，仅 rank 3..A）
    final singleRanks = byRank.keys.where((r) => r <= Rank.cA.value).toList()
      ..sort();
    for (var len = 5; len <= singleRanks.length; len++) {
      for (var start = 0; start + len <= singleRanks.length; start++) {
        final seq = singleRanks.sublist(start, start + len);
        if (_isConsecutive(seq)) {
          final cards = seq.map((r) => byRank[r]!.first).toList();
          final p = _pattern(cards);
          if (p != null) results.add(p);
        }
      }
    }
    // 连对（长度 ≥3 对，仅 rank 3..A）
    final pairRanks =
        byRank.entries
            .where((e) => e.value.length >= 2 && e.key <= Rank.cA.value)
            .map((e) => e.key)
            .toList()
          ..sort();
    for (var len = 3; len <= pairRanks.length; len++) {
      for (var start = 0; start + len <= pairRanks.length; start++) {
        final seq = pairRanks.sublist(start, start + len);
        if (_isConsecutive(seq)) {
          final cards = <Card>[];
          for (final r in seq) {
            cards.addAll(byRank[r]!.sublist(0, 2));
          }
          final p = _pattern(cards);
          if (p != null) results.add(p);
        }
      }
    }
    // 飞机不带翅（连续 ≥2 个三张，仅 rank 3..A）
    final tripleRanks =
        byRank.entries
            .where((e) => e.value.length >= 3 && e.key <= Rank.cA.value)
            .map((e) => e.key)
            .toList()
          ..sort();
    for (var len = 2; len <= tripleRanks.length; len++) {
      for (var start = 0; start + len <= tripleRanks.length; start++) {
        final seq = tripleRanks.sublist(start, start + len);
        if (_isConsecutive(seq)) {
          final body = <Card>[];
          for (final r in seq) {
            body.addAll(byRank[r]!.sublist(0, 3));
          }
          final p = _pattern(body);
          if (p != null) results.add(p);

          // 飞机带单翅（每段配 1 张单牌）
          final usedRanks = seq.toSet();
          final singleWings = _enumSingleWings(hand, usedRanks, len);
          for (final wings in singleWings) {
            final p2 = _pattern([...body, ...wings]);
            if (p2 != null && p2.type == HandType.planeSingle) results.add(p2);
          }
          // 飞机带对翅（每段配 1 对）
          final pairWings = _enumPairWings(byRank, usedRanks, len);
          for (final wings in pairWings) {
            final p3 = _pattern([...body, ...wings]);
            if (p3 != null && p3.type == HandType.planePair) results.add(p3);
          }
        }
      }
    }
    // 四带二（单）/ 四带两对
    for (final entry in byRank.entries) {
      if (entry.value.length == 4) {
        final four = entry.value.sublist(0, 4);
        final usedRanks = <int>{entry.key};
        // 四带两单：枚举所有 ≥2 张可用单牌组合（用 rank 区分）
        final singles = _enumSingleWings(hand, usedRanks, 2);
        for (final wing in singles) {
          final p = _pattern([...four, ...wing]);
          if (p != null && p.type == HandType.bombTwoSingle) results.add(p);
        }
        // 四带两对
        final pairWings = _enumPairWings(byRank, usedRanks, 2);
        for (final wing in pairWings) {
          final p = _pattern([...four, ...wing]);
          if (p != null && p.type == HandType.bombTwoPair) results.add(p);
        }
      }
    }

    // 去重（按 cards 标识）
    final seen = <String>{};
    final unique = <HandPattern>[];
    for (final p in results) {
      final key = p.cards.map((c) => c.index).toList()..sort();
      final k = key.toString();
      if (seen.add(k)) unique.add(p);
    }
    return unique;
  }

  /// 枚举 [count] 张不与 [excludeRanks] 同点的单牌组合（按 rank 选，单牌只能用 1 张/段）。
  /// 返回每组的实际牌（取每组第一张）。
  static List<List<Card>> _enumSingleWings(
    List<Card> hand,
    Set<int> excludeRanks,
    int count,
  ) {
    final candidateRanks = <int, Card>{};
    for (final c in hand) {
      if (!excludeRanks.contains(c.rank.value)) {
        candidateRanks.putIfAbsent(c.rank.value, () => c);
      }
    }
    final ranks = candidateRanks.keys.toList()..sort();
    final out = <List<Card>>[];
    _combine(ranks, count, 0, <int>[], (combo) {
      out.add(combo.map((r) => candidateRanks[r]!).toList());
    });
    return out;
  }

  /// 枚举 [count] 对不与 [excludeRanks] 同点的对子组合。
  static List<List<Card>> _enumPairWings(
    Map<int, List<Card>> byRank,
    Set<int> excludeRanks,
    int count,
  ) {
    final candidateRanks =
        byRank.entries
            .where((e) => !excludeRanks.contains(e.key) && e.value.length >= 2)
            .map((e) => e.key)
            .toList()
          ..sort();
    final out = <List<Card>>[];
    _combine(candidateRanks, count, 0, <int>[], (combo) {
      final cards = <Card>[];
      for (final r in combo) {
        cards.addAll(byRank[r]!.sublist(0, 2));
      }
      out.add(cards);
    });
    return out;
  }

  /// C(n, k) 组合回调。
  static void _combine(
    List<int> ranks,
    int k,
    int start,
    List<int> current,
    void Function(List<int>) onCombo,
  ) {
    if (current.length == k) {
      onCombo(List.of(current));
      return;
    }
    for (var i = start; i < ranks.length; i++) {
      current.add(ranks[i]);
      _combine(ranks, k, i + 1, current, onCombo);
      current.removeLast();
    }
  }

  static bool _isConsecutive(List<int> ranks) {
    for (var i = 1; i < ranks.length; i++) {
      if (ranks[i] - ranks[i - 1] != 1) return false;
    }
    return true;
  }

  static Map<int, List<Card>> _groupByRank(List<Card> cards) {
    final m = <int, List<Card>>{};
    for (final c in cards) {
      m.putIfAbsent(c.rank.value, () => []).add(c);
    }
    return m;
  }

  static HandPattern? _pattern(List<Card> cards) => HandDetector.detect(cards);

  /// 断言版本：用于已知合法的组合。
  static HandPattern _patternOf(List<Card> cards) =>
      HandDetector.detect(cards)!;
}
