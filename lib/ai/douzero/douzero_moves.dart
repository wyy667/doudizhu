import '../../core/card.dart';
import '../../core/game_state.dart';
import '../ai_player.dart';
import 'douzero_encoder.dart';

/// DouZero 合法动作枚举器。
///
/// - 跟牌：调用 [AiHandSearch.findBeats]（与现有逻辑一致），并附加 pass（空列表）。
/// - 自由出牌：调用 [AiHandSearch._enumAllPatterns] 的补全版（含连对/飞机/四带）。
/// - 火箭：始终包含（若手中有双王），由 [AiHandSearch] 自动加上。
///
/// 注意：**顺序无关紧要**——`x_batch[i]` ↔ argmax[i] 内部一致即可。
class DouZeroMoves {
  DouZeroMoves._();

  /// 枚举所有合法出牌动作（每个动作是已 sort 的牌列表）。
  /// 跟牌场景会附加 `[]`（pass）。自由出牌场景不会包含 pass。
  static List<List<Card>> enumerate(GameState state, int seat) {
    final hand = state.players[seat].hand;
    final lastPattern = DouZeroEncoder.lastPatternForEncoding(state, seat);
    final isFreeTurn = lastPattern == null;

    final candidates = AiHandSearch.findBeats(hand, lastPattern);
    final moves = <List<Card>>[
      for (final p in candidates) _sortedCopy(p.cards),
    ];

    if (!isFreeTurn) {
      // 跟牌场景：允许 pass（作为空列表，编码为全 0 的 54-dim）
      moves.add(const <Card>[]);
    }
    return moves;
  }

  static List<Card> _sortedCopy(List<Card> cards) {
    final out = List<Card>.from(cards);
    out.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return out;
  }
}
