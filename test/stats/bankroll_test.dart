import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/stats/bankroll.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('积分初始 1000，结算累加并持久化，可重置', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    expect(c.read(bankrollProvider), kInitialBankroll);

    await c.read(bankrollProvider.notifier).settle(6); // 地主 ×3 胜
    expect(c.read(bankrollProvider), 1000 + 6 * kScoreUnit);
    await c.read(bankrollProvider.notifier).settle(-3);
    expect(c.read(bankrollProvider), 1000 + 3 * kScoreUnit);
    c.dispose();

    // 新容器（模拟重启）读回持久化值
    final c2 = ProviderContainer();
    c2.read(bankrollProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c2.read(bankrollProvider), 1000 + 3 * kScoreUnit);

    await c2.read(bankrollProvider.notifier).reset();
    expect(c2.read(bankrollProvider), kInitialBankroll);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(BankrollNotifier.storageKey), kInitialBankroll);
    c2.dispose();
  });
}
