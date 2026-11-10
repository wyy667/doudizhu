import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../state/settings.dart';
import '../../stats/bankroll.dart';
import '../battle/battle_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = '${info.version}+${info.buildNumber}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final soundEnabled = ref.watch(soundEnabledProvider);
    final vibrationEnabled = ref.watch(vibrationEnabledProvider);
    final debugTools = ref.watch(debugToolsEnabledProvider);
    final cardCounter = ref.watch(cardCounterEnabledProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20),
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF0D3F12),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        children: [
          _sectionHeader('音效与反馈'),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up, color: Colors.amber),
            title: const Text('音效', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              '出牌、炸弹、胜利等音效',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            value: soundEnabled,
            activeTrackColor: Colors.amber.withValues(alpha: 0.4),
            activeThumbColor: Colors.amber,
            onChanged: (v) => ref.read(soundEnabledProvider.notifier).state = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration, color: Colors.amber),
            title: const Text('震动', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              '出牌时的触觉反馈',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            value: vibrationEnabled,
            activeTrackColor: Colors.amber.withValues(alpha: 0.4),
            activeThumbColor: Colors.amber,
            onChanged: (v) =>
                ref.read(vibrationEnabledProvider.notifier).state = v,
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.analytics_outlined,
              color: Colors.amber,
            ),
            title: const Text('记牌器', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              '游戏中显示各点数剩余张数',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            value: cardCounter,
            activeTrackColor: Colors.amber.withValues(alpha: 0.4),
            activeThumbColor: Colors.amber,
            onChanged: (v) =>
                ref.read(cardCounterEnabledProvider.notifier).state = v,
          ),
          _sectionHeader('积分'),
          ListTile(
            leading: const Icon(Icons.monetization_on, color: Colors.amber),
            title: Text(
              '当前积分 ${ref.watch(bankrollProvider)}',
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              '初始 $kInitialBankroll；每局按 倍数 × 身份(地主2/农民1) × $kScoreUnit 增减',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: _confirmResetBankroll,
              child: const Text('重置'),
            ),
          ),
          _sectionHeader('局域网联机'),
          const ListTile(
            leading: Icon(Icons.wifi, color: Colors.amber),
            title: Text('无需配置', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              '与朋友连接同一 Wi-Fi 或房主手机热点，在首页「局域网联机」开房 / 加入；人机运行在房主设备上',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),

          _sectionHeader('调试'),
          SwitchListTile(
            secondary: const Icon(Icons.bug_report, color: Colors.blueAccent),
            title: const Text('调试工具', style: TextStyle(color: Colors.white)),
            subtitle: const Text(
              '对局中显示 AI 决策日志和透视按钮（影响公平性）',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            value: debugTools,
            activeTrackColor: Colors.amber.withValues(alpha: 0.4),
            activeThumbColor: Colors.amber,
            onChanged: (v) {
              ref.read(debugToolsEnabledProvider.notifier).state = v;
              if (!v) ref.read(debugShowHandsProvider.notifier).state = false;
            },
          ),
          if (debugTools)
            ListTile(
              leading: const Icon(Icons.smart_toy, color: Colors.amber),
              title: const Text('AI 对战', style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                'WP 地主 vs WP 农民自动对战',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white38),
              onTap: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const BattleScreen()));
              },
            ),

          const SizedBox(height: 24),
          Center(
            child: Text(
              'Landlord v$_version',
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetBankroll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置积分'),
        content: const Text('确定将积分重置为 $kInitialBankroll 吗？战绩记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(bankrollProvider.notifier).reset();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('积分已重置为 $kInitialBankroll')));
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.amber,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
