import '../core/card.dart';
import '../core/game_action.dart';
import '../core/game_state.dart';

/// 叫地主策略：基于手牌强度评估。
///
/// DouZero 不负责 bidding，需要独立的叫地主逻辑。
class BidAi {
  static GameAction chooseBid(GameState state, int seat) {
    return BidAction(
      seat,
      _chooseBid(state.players[seat].hand, state.currentMaxBid),
    );
  }

  static int _chooseBid(List<Card> hand, int currentMaxBid) {
    final strength = _evaluateHandStrength(hand);
    int target;
    if (strength >= 18) {
      target = 3;
    } else if (strength >= 12) {
      target = 2;
    } else if (strength >= 7) {
      target = 1;
    } else {
      target = 0;
    }
    if (target <= currentMaxBid) {
      return strength >= 20 ? 3 : 0;
    }
    return target;
  }

  static int _evaluateHandStrength(List<Card> hand) {
    final byRank = <int, int>{};
    for (final c in hand) {
      byRank[c.rank.value] = (byRank[c.rank.value] ?? 0) + 1;
    }
    final hasBigJoker = hand.any((c) => c.rank == Rank.rj);
    final hasSmallJoker = hand.any((c) => c.rank == Rank.bj);
    final bombs = byRank.values.where((c) => c == 4).length;
    final twos = byRank[Rank.c2.value] ?? 0;
    final aces = byRank[Rank.cA.value] ?? 0;

    var s = 0;
    if (hasBigJoker) s += 4;
    if (hasSmallJoker) s += 3;
    if (hasBigJoker && hasSmallJoker) s += 4;
    s += bombs * 8;
    s += twos * 3;
    s += aces;
    return s;
  }
}
