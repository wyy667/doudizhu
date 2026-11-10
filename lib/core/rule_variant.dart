/// 规则变体配置（不可变）。
///
/// 将引擎中的魔法数字参数化，通过预设组合实现不同玩法。
/// 存入 [GameState.ruleVariant] 随状态序列化，引擎/回放/联网天然支持。
class RuleVariant {
  final String id;
  final String label;
  final bool shuffle;
  final int bidMax;
  final int bombMultiplier;
  final bool springEnabled;

  const RuleVariant({
    required this.id,
    this.label = '',
    this.shuffle = true,
    this.bidMax = 3,
    this.bombMultiplier = 2,
    this.springEnabled = true,
  });

  static const classic = RuleVariant(id: 'classic', label: '经典');
  static const noShuffle = RuleVariant(
    id: 'noShuffle',
    label: '不洗牌',
    shuffle: false,
  );

  static const _presets = {classic, noShuffle};
  static const _byId = {'classic': classic, 'noShuffle': noShuffle};

  static List<RuleVariant> get presets => _presets.toList();

  static RuleVariant byId(String? id) => _byId[id] ?? classic;

  Map<String, dynamic> toJson() => {'id': id};
}
