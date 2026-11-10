import 'hand_pattern.dart';
import 'hand_type.dart';

/// 牌型比较。参见 docs/04-game-rules.md §4。
///
/// 核心规则：
/// - 火箭 > 任意。
/// - 炸弹 > 任意非炸弹/非火箭；炸弹之间比点数。
/// - 普通牌型只能同型同长比较主体点数。
class HandCompare {
  /// [played] 能否压住 [last]。
  /// [last] 为 null 表示自由出牌，任意合法牌型都可。
  static bool canBeat(HandPattern played, HandPattern? last) {
    if (last == null) return true; // 自由出牌

    // 火箭压一切
    if (played.type == HandType.rocket) return true;

    // 炸弹压制
    if (played.type == HandType.bomb) {
      if (last.type == HandType.rocket) return false;
      if (last.type == HandType.bomb) {
        return played.mainRank > last.mainRank;
      }
      return true; // 炸弹压普通牌型
    }

    // 普通牌型：必须同型同长，主体点数更大
    if (played.type != last.type) return false;
    if (played.length != last.length) return false;
    return played.mainRank > last.mainRank;
  }
}
