/// AI 模型标识（当前仅保留 DouZero WP）。
enum AIModel {
  douzeroWP;

  String get assetDir => 'assets/models/douzero_wp';

  String get displayName => 'DouZero WP';

  String get shortName => 'WP';

  static const all = AIModel.values;

  static String describeConfig({
    required AIModel landlord,
    required AIModel farmer,
  }) =>
      '${landlord.displayName}\uff08\u5730\u4e3b\uff09vs ${farmer.displayName}\uff08\u519c\u6c11\uff09';
}
