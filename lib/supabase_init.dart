import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_config.dart';

/// Supabase 初始化服务（从用户配置读取，不再硬编码）。
class SupabaseService {
  static bool _initialized = false;

  /// 初始化 Supabase。调用前需确保用户已通过 [AppConfig] 配置。
  /// 如果尚未配置则抛出 [StateError]。
  static Future<void> ensureInitialized() async {
    if (_initialized) return;

    final config = await AppConfig.load();
    if (!config.isConfigured) {
      throw StateError('Supabase 尚未配置，请先进入联机模式完成配置。');
    }

    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
    );
    _initialized = true;
  }

  static bool get isInitialized => _initialized;
}
