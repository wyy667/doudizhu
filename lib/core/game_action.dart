import 'card.dart';

/// 一次玩家动作。密封类，按阶段对应不同动作。
///
/// 采用动作建模（事件溯源风格）：所有状态变化都通过动作驱动，
/// 便于单机/联网/AI 共用同一套规则，并可重放。参见 docs/05-architecture.md §2.2。
sealed class GameAction {
  const GameAction();

  /// 动作的发起座位（0/1/2）。
  int get bySeat;

  Map<String, dynamic> toJson();

  /// 反序列化（不含 DealAction，由 seed 重建）。
  factory GameAction.fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'bid' => BidAction(json['bySeat'] as int, json['score'] as int),
      'bright' => BrightAction(json['bySeat'] as int),
      'play' => PlayAction(
        json['bySeat'] as int,
        (json['cards'] as List).map((i) => Card.fromIndex(i as int)).toList(),
      ),
      'pass' => PassAction(json['bySeat'] as int),
      _ => throw FormatException('Unknown action type: ${json['type']}'),
    };
  }
}

/// 发牌。携带完整牌局（仅由系统/服务端产生，玩家不会发起）。
class DealAction extends GameAction {
  final List<List<Card>> hands; // 3 名玩家手牌
  final List<Card> bottom; // 3 张底牌
  final int seed;

  const DealAction(this.hands, this.bottom, this.seed);

  @override
  int get bySeat => -1; // 系统动作

  @override
  Map<String, dynamic> toJson() => {
    'type': 'deal',
    'seed': seed,
    'hands': hands.map((h) => h.map((c) => c.index).toList()).toList(),
    'bottom': bottom.map((c) => c.index).toList(),
  };
}

/// 叫分（叫地主）。[score]=0 表示不叫；1/2/3 表示叫分，必须高于当前最高叫。
/// 叫 3 分立即成交，该玩家成为地主。
class BidAction extends GameAction {
  @override
  final int bySeat;
  final int score; // 0=不叫, 1/2/3=叫分
  const BidAction(this.bySeat, this.score);

  bool get pass => score == 0;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'bid',
    'bySeat': bySeat,
    'score': score,
  };
}

/// 出牌。
class PlayAction extends GameAction {
  @override
  final int bySeat;
  final List<Card> cards;
  const PlayAction(this.bySeat, this.cards);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'play',
    'bySeat': bySeat,
    'cards': cards.map((c) => c.index).toList(),
  };
}

/// 不出（Pass）。
class PassAction extends GameAction {
  @override
  final int bySeat;
  const PassAction(this.bySeat);

  @override
  Map<String, dynamic> toJson() => {'type': 'pass', 'bySeat': bySeat};
}

/// 明牌（叫地主阶段主动公开手牌，倍数 ×2/人）。
class BrightAction extends GameAction {
  @override
  final int bySeat;
  const BrightAction(this.bySeat);

  @override
  Map<String, dynamic> toJson() => {'type': 'bright', 'bySeat': bySeat};
}
