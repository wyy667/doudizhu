import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:landlord/core/app_config.dart';

void main() {
  test('fresh installations have no shared backend configuration', () async {
    SharedPreferences.setMockInitialValues({});
    expect((await AppConfig.load()).isConfigured, isFalse);
  });

  test('legacy shared backend configuration is removed on load', () async {
    SharedPreferences.setMockInitialValues({
      'supabase_url': 'https://example.invalid',
      'supabase_anon_key': 'test-placeholder',
      'is_author_config': true,
    });
    expect((await AppConfig.load()).isConfigured, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('supabase_url'), isFalse);
    expect(prefs.containsKey('supabase_anon_key'), isFalse);
    expect(prefs.containsKey('is_author_config'), isFalse);
  });

  test('user supplied backend configuration is preserved', () async {
    SharedPreferences.setMockInitialValues({
      'supabase_url': 'https://example.invalid',
      'supabase_anon_key': 'test-placeholder',
    });
    final config = await AppConfig.load();
    expect(config.isConfigured, isTrue);
    expect(config.supabaseUrl, 'https://example.invalid');
    expect(config.supabaseAnonKey, 'test-placeholder');
  });
}
