import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rule_variant.dart';

/// 设置：规则变体（经典/不洗牌/明牌）。
final ruleVariantProvider = StateProvider<RuleVariant>(
  (ref) => RuleVariant.classic,
);

/// 设置：调试工具（AI 决策日志 + 透视按钮），默认关闭。
final debugToolsEnabledProvider = StateProvider<bool>((ref) => false);

/// 设置：透视模式（对家手牌正面显示），默认关闭。
final debugShowHandsProvider = StateProvider<bool>((ref) => false);

/// 设置：音效（默认开）。
final soundEnabledProvider = StateProvider<bool>((ref) => true);

/// 设置：震动（默认开）。
final vibrationEnabledProvider = StateProvider<bool>((ref) => true);

/// 设置：记牌器（默认开）。
final cardCounterEnabledProvider = StateProvider<bool>((ref) => true);
