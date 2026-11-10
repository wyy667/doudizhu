import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 长期积分初始值（设置中可重置回此值）。
const kInitialBankroll = 1000;

/// 每局结算点数（倍数 × 地主 2 / 农民 1）换算成积分的单位。
const kScoreUnit = 10;

/// 长期积分：持久化于 SharedPreferences，单机与局域网对局结算时累加。
class BankrollNotifier extends Notifier<int> {
  static const storageKey = 'landlord.bankroll.v1';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  int build() {
    _load();
    return kInitialBankroll;
  }

  Future<void> _load() async {
    final v = (await _prefs).getInt(storageKey);
    if (v != null) state = v;
  }

  /// 结算：[points] 为本局点数（胜正负负），按 [kScoreUnit] 换算后累加。
  Future<void> settle(int points) async {
    final p = await _prefs;
    final next =
        (p.getInt(storageKey) ?? kInitialBankroll) + points * kScoreUnit;
    await p.setInt(storageKey, next);
    state = next;
  }

  /// 重置回 [kInitialBankroll]。
  Future<void> reset() async {
    await (await _prefs).setInt(storageKey, kInitialBankroll);
    state = kInitialBankroll;
  }
}

final bankrollProvider = NotifierProvider<BankrollNotifier, int>(
  BankrollNotifier.new,
);
