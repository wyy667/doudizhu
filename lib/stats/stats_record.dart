import '../core/deck.dart';
import '../core/game_action.dart';
import '../core/game_engine.dart';
import '../core/game_state.dart';
import '../core/rule_variant.dart';

/// 单局对战结果记录（不可变）。
///
/// 除聚合统计信息外，可选存储 [deckSeed] + [actionLog] 用于回放重建。
/// 回放通过事件溯源重建：seed → DealAction → 逐步 apply actionLog。
class StatsRecord {
  final DateTime playedAt;
  final bool humanWon;
  final bool humanIsLandlord;
  final int multiplier;
  final int score;
  final int turns;

  /// 是否春天（地主胜 + 两农民都未出过牌）。
  final bool isSpring;

  /// 是否反春天（农民胜 + 地主仅出过第一手）。
  final bool isAntiSpring;

  /// 回放数据：发牌种子（null = 旧记录无回放）。
  final int? deckSeed;

  /// 回放数据：除 DealAction 外的所有动作序列（JSON）。
  final List<Map<String, dynamic>>? actionLog;

  /// 规则变体 ID（'classic' | 'noShuffle' | 'bright'）。
  /// 旧记录可能为 null，此时按 [noShuffle] 推断。
  final String? variantId;

  /// 旧字段：是否为不洗牌模式（向下兼容，由 [variantId] 派生）。
  bool get noShuffle =>
      variantId == 'noShuffle' || (variantId == null && _legacyNoShuffle);
  final bool _legacyNoShuffle;

  /// 是否为联网对局。
  final bool isOnline;

  RuleVariant get variant => RuleVariant.byId(variantId);

  const StatsRecord({
    required this.playedAt,
    required this.humanWon,
    required this.humanIsLandlord,
    required this.multiplier,
    required this.score,
    required this.turns,
    this.isSpring = false,
    this.isAntiSpring = false,
    this.deckSeed,
    this.actionLog,
    this.variantId,
    bool legacyNoShuffle = false,
    this.isOnline = false,
  }) : _legacyNoShuffle = legacyNoShuffle;

  /// 是否有回放数据。
  bool get hasReplay => deckSeed != null && actionLog != null;

  /// 重建回放（replayLog + finalState）。无回放数据时抛异常。
  (List<ReplayStep>, GameState) reconstructReplay() {
    final v = variant;
    final deal = v.shuffle
        ? Deck.deal(deckSeed!)
        : Deck.dealNoShuffle(deckSeed!);
    final engine = const GameEngine();
    var state = engine.apply(
      GameState.initial(),
      DealAction(deal.hands, deal.bottom, deckSeed!),
    );
    state = state.copyWith(ruleVariant: v);
    for (final json in actionLog!) {
      final action = GameAction.fromJson(json);
      state = engine.apply(state, action);
    }
    return (state.replayLog, state);
  }

  Map<String, dynamic> toJson() => {
    'playedAt': playedAt.toIso8601String(),
    'humanWon': humanWon,
    'humanIsLandlord': humanIsLandlord,
    'multiplier': multiplier,
    'score': score,
    'turns': turns,
    if (isSpring) 'isSpring': true,
    if (isAntiSpring) 'isAntiSpring': true,
    if (deckSeed != null) 'deckSeed': deckSeed,
    if (actionLog != null) 'actionLog': actionLog,
    if (variantId != null) 'variantId': variantId,
    if (noShuffle) 'noShuffle': true,
    if (isOnline) 'isOnline': true,
  };

  factory StatsRecord.fromJson(Map<String, dynamic> json) => StatsRecord(
    playedAt: DateTime.parse(json['playedAt'] as String),
    humanWon: json['humanWon'] as bool,
    humanIsLandlord: json['humanIsLandlord'] as bool,
    multiplier: json['multiplier'] as int,
    score: json['score'] as int,
    turns: json['turns'] as int,
    isSpring: json['isSpring'] as bool? ?? false,
    isAntiSpring: json['isAntiSpring'] as bool? ?? false,
    deckSeed: json['deckSeed'] as int?,
    actionLog: (json['actionLog'] as List?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
    variantId: json['variantId'] as String?,
    legacyNoShuffle: json['noShuffle'] as bool? ?? false,
    isOnline: json['isOnline'] as bool? ?? false,
  );

  @override
  String toString() =>
      'StatsRecord(humanWon=$humanWon, landlord=$humanIsLandlord, '
      'mult=×$multiplier, score=$score, turns=$turns'
      '${variantId != null ? ', $variantId' : ''}'
      '${isOnline ? ', 联网' : ''}'
      '${isSpring ? ', 春天' : ''}'
      '${isAntiSpring ? ', 反春天' : ''})';
}
