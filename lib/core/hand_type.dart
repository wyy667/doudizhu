/// 斗地主 14 种牌型。参见 docs/04-game-rules.md §3。
///
/// 排列顺序便于阅读，不代表大小（大小比较见 hand_compare.dart）。
enum HandType {
  single, // 单牌
  pair, // 对子
  triple, // 三张
  tripleSingle, // 三带一
  triplePair, // 三带二
  straight, // 顺子
  pairStraight, // 连对
  plane, // 飞机（不带）
  planeSingle, // 飞机带单
  planePair, // 飞机带对
  bombTwoSingle, // 四带二（两单）
  bombTwoPair, // 四带两对
  bomb, // 炸弹
  rocket, // 火箭（王炸）
}

/// HandType 的扩展描述。
extension HandTypeX on HandType {
  String get label => switch (this) {
    HandType.single => '单牌',
    HandType.pair => '对子',
    HandType.triple => '三张',
    HandType.tripleSingle => '三带一',
    HandType.triplePair => '三带二',
    HandType.straight => '顺子',
    HandType.pairStraight => '连对',
    HandType.plane => '飞机',
    HandType.planeSingle => '飞机带单',
    HandType.planePair => '飞机带对',
    HandType.bombTwoSingle => '四带二',
    HandType.bombTwoPair => '四带两对',
    HandType.bomb => '炸弹',
    HandType.rocket => '火箭',
  };

  /// 是否为炸弹类（炸弹/火箭可压制任意普通牌型）。
  bool get isBombLike => this == HandType.bomb || this == HandType.rocket;
}
