import 'package:shared_preferences/shared_preferences.dart';

/// 运行时后端配置（用户自填，存 SharedPreferences）。
class AppConfig {
  static const _keyUrl = 'supabase_url';
  static const _keyAnonKey = 'supabase_anon_key';
  static const _keyIsAuthor = 'is_author_config';

  final String supabaseUrl;
  final String supabaseAnonKey;
  final bool isAuthorConfig;

  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.isAuthorConfig = false,
  });

  static const AppConfig empty = AppConfig(
    supabaseUrl: '',
    supabaseAnonKey: '',
  );

  bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// 从 SharedPreferences 读取配置。
  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_keyUrl) ?? '';
    final key = prefs.getString(_keyAnonKey) ?? '';
    final isAuthor = prefs.getBool(_keyIsAuthor) ?? false;
    // 旧版本的共享后端配置不再使用，用户需自行配置后端。
    if (isAuthor) {
      await clear();
      return empty;
    }
    return AppConfig(
      supabaseUrl: url,
      supabaseAnonKey: key,
      isAuthorConfig: isAuthor,
    );
  }

  /// 保存配置到 SharedPreferences。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUrl, supabaseUrl);
    await prefs.setString(_keyAnonKey, supabaseAnonKey);
    await prefs.setBool(_keyIsAuthor, isAuthorConfig);
  }

  /// 清除配置。
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUrl);
    await prefs.remove(_keyAnonKey);
    await prefs.remove(_keyIsAuthor);
  }
}
