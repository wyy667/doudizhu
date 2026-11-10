import 'dart:typed_data';

import '../../core/card.dart';
import '../../core/game_state.dart';
import '../../core/hand_pattern.dart';

/// DouZero 特征编码器（纯 Dart，无 Flutter 依赖，便于 isolate）。
///
/// 严格对齐 `kwai/DouZero/douzero/env/env.py`：
/// - `_cards2array`：54-dim（13 个普通 rank × 4 unary bit + 2 个 joker bit），列优先。
/// - 地主 x 宽度 373，农民 x 宽度 484。
/// - z：5×162（取最后 15 步出牌，左填空，每步 54-dim，C-order reshape）。
///
/// 关键映射：项目 [Card.rank.value] ∈ {3..14, 15, 16, 17}，对应 DouZero 卡牌整数
/// {3..14, 17, 20, 30}（17 = "2"，20 = 小王，30 = 大王）。
class DouZeroEncoder {
  DouZeroEncoder._();

  /// 项目 Rank.value → DouZero 卡牌整数。
  /// 注意 DouZero 用 17 表示 "2"，20/30 表示小/大王。
  static int rankToDouZeroCard(int rankValue) {
    if (rankValue >= 3 && rankValue <= 14) return rankValue; // 3..A
    if (rankValue == 15) return 17; // "2"
    if (rankValue == 16) return 20; // 小王
    if (rankValue == 17) return 30; // 大王
    throw ArgumentError('Unexpected rank value: $rankValue');
  }

  /// DouZero `Card2Column`：rank → 13 列矩阵的列号（0..12）。
  /// rank 3..14 → 0..11，rank 17（"2"）→ 12。
  static int _card2Column(int douZeroCard) {
    return switch (douZeroCard) {
      3 => 0,
      4 => 1,
      5 => 2,
      6 => 3,
      7 => 4,
      8 => 5,
      9 => 6,
      10 => 7,
      11 => 8,
      12 => 9,
      13 => 10,
      14 => 11,
      17 => 12,
      _ => throw ArgumentError('Not a column-mapped card: $douZeroCard'),
    };
  }

  /// 复刻 `_cards2array`：54-dim 列优先 unary 编码 + 2 个 joker bit。
  static Float32List cardsToArray(List<Card> cards) {
    final out = Float32List(54);
    if (cards.isEmpty) return out;

    // 统计每个 DouZero rank 的张数
    final countByCard = <int, int>{};
    for (final c in cards) {
      final dz = rankToDouZeroCard(c.rank.value);
      countByCard[dz] = (countByCard[dz] ?? 0) + 1;
    }

    countByCard.forEach((dzCard, n) {
      if (dzCard < 20) {
        final col = _card2Column(dzCard);
        // 列优先：col*4 + row
        if (n >= 1) out[col * 4 + 0] = 1;
        if (n >= 2) out[col * 4 + 1] = 1;
        if (n >= 3) out[col * 4 + 2] = 1;
        if (n >= 4) out[col * 4 + 3] = 1;
      } else if (dzCard == 20) {
        out[52] = 1; // 小王
      } else if (dzCard == 30) {
        out[53] = 1; // 大王
      }
    });
    return out;
  }

  /// one-hot 长度 [max]，bit 在 [n-1] 位置（对齐 `_get_one_hot_array`）。
  static Float32List oneHotNumLeft(int n, int max) {
    final out = Float32List(max);
    if (n >= 1 && n <= max) out[n - 1] = 1;
    return out;
  }

  /// one-hot 长度 15，bit 在 [b] 位置（对齐 `_get_one_hot_bomb`）。
  /// b 范围 0..14。
  static Float32List oneHotBombNum(int b) {
    final out = Float32List(15);
    if (b >= 0 && b < 15) out[b] = 1;
    return out;
  }

  /// 统计本局已打出的炸弹数（4-of-a-kind + 火箭），对齐 Python `bomb_num`。
  ///
  /// Python 在 `GameEnv.step()` 中每当 `action in bombs` 就 `bomb_num += 1`，
  /// 其中 bombs = 所有 [r,r,r,r] 和 [20,30]。
  ///
  /// **不能**从 playedCards 中数 4-of-a-kind——当 4 张同点牌被拆散在
  /// 多个非炸弹动作中（如先出单 3 再出三张 3）时会误计。
  /// 正确做法：扫描 `actionSeq` 中的每个动作，判断其是否为炸弹动作。
  static int countBombs(GameState state) {
    var bombs = 0;
    for (final action in state.actionSeq) {
      if (action.isEmpty) continue;
      if (_isBombAction(action)) bombs++;
    }
    return bombs.clamp(0, 14);
  }

  /// 判断一组牌是否为炸弹动作（4-of-a-kind 或火箭）。
  static bool _isBombAction(List<Card> cards) {
    if (cards.length == 4) {
      final rank = cards.first.rank;
      return cards.every((c) => c.rank == rank);
    }
    if (cards.length == 2) {
      return cards.every((c) => c.rank.isJoker);
    }
    return false;
  }

  /// 编码 z 张量（5×162=810），按 C-order reshape。
  /// 取 `state.actionSeq` 最后 15 步，左填空。
  static Float32List encodeZ(GameState state) {
    const seqLen = 15;
    const lastMoveLen = 54;
    final seq = state.actionSeq;
    // 左填空：若不足 15 步，前缀补 []
    final padded = List<List<Card>>.filled(
      seqLen,
      const <Card>[],
      growable: false,
    );
    final available = seq.length > seqLen
        ? seq.sublist(seq.length - seqLen)
        : seq;
    final offset = seqLen - available.length;
    for (var i = 0; i < available.length; i++) {
      padded[offset + i] = available[i];
    }
    // 15×54 → reshape 5×162（C-order：连续 3 行拼成 1 行 = 162）
    // 即 row r ∈ [0,5) 由 padded[r*3 .. r*3+3) 三步的 54-dim 拼接
    final out = Float32List(5 * 162);
    for (var r = 0; r < 5; r++) {
      for (var k = 0; k < 3; k++) {
        final moveArr = cardsToArray(padded[r * 3 + k]);
        final base = r * 162 + k * 54;
        out.setRange(base, base + 54, moveArr);
      }
    }
    // 静态分析：lastMoveLen 仅作文档用，保留以便阅读
    assert(lastMoveLen == 54);
    return out;
  }

  /// 对齐 Python `get_last_move`：只看最后 1~2 步。
  ///
  /// Python 逻辑（`game.py` get_last_move）：
  /// ```
  /// if seq[-1] is empty:  last_move = seq[-2]   # 上家 pass → 看再上一手
  /// else:                 last_move = seq[-1]   # 上家出了牌 → 就是他
  /// ```
  /// 注意：**不**扫描全部历史。自由出牌（两连 pass）时 seq[-2] 也为空，
  /// last_move = []（全零编码），模型据此判断当前是自由出牌。
  static List<Card> lastMove(GameState state) {
    final seq = state.actionSeq;
    if (seq.isEmpty) return const <Card>[];
    if (seq.last.isNotEmpty) return List<Card>.from(seq.last);
    if (seq.length >= 2) return List<Card>.from(seq[seq.length - 2]);
    return const <Card>[];
  }

  /// 计算地主模型的 x_no_action（319-dim）。
  static Float32List _landlordXNoAction(GameState state, int seat) {
    final landlord = state.landlordSeat!;
    final myHand = state.players[seat].hand;

    // other_hand_cards = 未知牌并集（54 - 我的手牌 - 已公开牌）。
    // **重要**：这与 Python 中「两家对手手牌并集」在 multiset 上**数学等价**，
    // 但代码上不读取对手手牌——AI 没有作弊，只用公开可推算的信息。
    final otherHand = _unknownCardsUnion(state, seat);

    final up = _farmerOffsetSeat(landlord, 1); // landlord_down
    final down = _farmerOffsetSeat(landlord, 2); // landlord_up

    final lastAction = lastMove(state);

    final upPlayed = state.playedBySeat[up] ?? const <Card>[]; // landlord_down
    final downPlayed =
        state.playedBySeat[down] ?? const <Card>[]; // landlord_up
    // Python 顺序：先 landlord_up，后 landlord_down
    final upLeft = state.players[down].handCount; // landlord_up
    final downLeft = state.players[up].handCount; // landlord_down
    final bombNum = countBombs(state);

    return _concatFloats([
      cardsToArray(myHand),
      cardsToArray(otherHand),
      cardsToArray(lastAction),
      cardsToArray(downPlayed), // landlord_up_played
      cardsToArray(upPlayed), // landlord_down_played
      oneHotNumLeft(upLeft, 17), // landlord_up_cards_left
      oneHotNumLeft(downLeft, 17), // landlord_down_cards_left
      oneHotBombNum(bombNum),
    ]);
  }

  /// 计算农民模型的 x_no_action（430-dim）。
  static Float32List _farmerXNoAction(GameState state, int seat) {
    final landlord = state.landlordSeat!;
    final myHand = state.players[seat].hand;
    final teammate = _otherFarmer(landlord, seat);
    final otherHand = _unknownCardsUnion(state, seat);

    final lastAction = lastMove(state);
    final lastLandlordAction = state.lastMoveBySeat[landlord] ?? const <Card>[];
    final lastTeammateAction = state.lastMoveBySeat[teammate] ?? const <Card>[];
    final landlordPlayed = state.playedBySeat[landlord] ?? const <Card>[];
    final teammatePlayed = state.playedBySeat[teammate] ?? const <Card>[];
    final landlordLeft = state.players[landlord].handCount;
    final teammateLeft = state.players[teammate].handCount;
    final bombNum = countBombs(state);

    return _concatFloats([
      cardsToArray(myHand),
      cardsToArray(otherHand),
      cardsToArray(landlordPlayed),
      cardsToArray(teammatePlayed),
      cardsToArray(lastAction),
      cardsToArray(lastLandlordAction),
      cardsToArray(lastTeammateAction),
      oneHotNumLeft(landlordLeft, 20),
      oneHotNumLeft(teammateLeft, 17),
      oneHotBombNum(bombNum),
    ]);
  }

  /// 「未公开 + 不在自己手中」的牌的并集——AI 只用公开可推算的信息。
  ///
  /// **关键**：这与「两家对手手牌并集」在 multiset 上**数学等价**：
  /// 总牌 54 = 我的手牌 + 已打出的牌 + 对手手牌，
  /// 所以「54 - 我 - 已打出」= 对手手牌并集。
  ///
  /// 但代码上不直接读 `players[*].hand`——AI 严格只用：
  /// - 自己手牌（合法）
  /// - 已打出的牌（合法：`playedCards`，PlayAction 累加；不含底牌，
  ///   因为底牌进入地主手牌后由 PlayAction 自然加入）
  ///
  /// 这等价于一个细心的人类玩家能推算出的所有信息。
  static List<Card> _unknownCardsUnion(GameState state, int seat) {
    final known = <int>{
      ...state.players[seat].hand.map((c) => c.index),
      ...state.playedCards.map((c) => c.index),
    };
    final out = <Card>[];
    for (var i = 0; i < 54; i++) {
      if (!known.contains(i)) {
        out.add(Card.fromIndex(i));
      }
    }
    return out;
  }

  /// 拼接 x_batch：N × 373（地主）或 N × 484（农民）。
  /// 每一行 = x_no_action + my_action（候选动作）。
  static Float32List encodeXBatch(
    GameState state,
    int seat,
    List<List<Card>> candidates,
    DouZeroRole role,
  ) {
    final noAction = role == DouZeroRole.landlord
        ? _landlordXNoAction(state, seat)
        : _farmerXNoAction(state, seat);
    final xDim = role == DouZeroRole.landlord ? 373 : 484;
    final n = candidates.length;
    final out = Float32List(n * xDim);
    for (var i = 0; i < n; i++) {
      final base = i * xDim;
      out.setRange(base, base + noAction.length, noAction);
      final actionArr = cardsToArray(candidates[i]);
      out.setRange(
        base + noAction.length,
        base + noAction.length + 54,
        actionArr,
      );
    }
    return out;
  }

  /// 从地主出发，按 `+offset % 3` 算座位。+1 = landlord_down，+2 = landlord_up。
  static int _farmerOffsetSeat(int landlord, int offset) {
    return (landlord + offset) % 3;
  }

  /// 另一名农民（与自己不同的 farmer）。
  static int _otherFarmer(int landlord, int mySeat) {
    for (var s = 0; s < 3; s++) {
      if (s != landlord && s != mySeat) return s;
    }
    throw StateError('Impossible: no other farmer');
  }

  static Float32List _concatFloats(List<Float32List> parts) {
    var total = 0;
    for (final p in parts) {
      total += p.length;
    }
    final out = Float32List(total);
    var off = 0;
    for (final p in parts) {
      out.setRange(off, off + p.length, p);
      off += p.length;
    }
    return out;
  }

  /// 给定 `state.lastValidPlay`，返回模型应感知的「上一手牌」pattern。
  /// 若 lastValidPlay 为 null 或属于自己（即自由出牌），返回 null。
  static HandPattern? lastPatternForEncoding(GameState state, int seat) {
    final last = state.lastValidPlay;
    if (last == null || last.seat == seat) return null;
    return last.pattern;
  }
}

/// DouZero 三种角色。
enum DouZeroRole { landlord, landlordUp, landlordDown }
