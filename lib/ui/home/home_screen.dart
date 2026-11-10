import 'package:flutter/material.dart' hide Card;
import '../../core/card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../state/game_session.dart';
import '../../state/settings.dart';
import '../../stats/bankroll.dart';
import '../../core/rule_variant.dart';
import '../game/game_screen.dart';
import '../game/widgets/card_widget.dart';
import '../game/widgets/table_widgets.dart';
import '../lobby/lobby_screen.dart';
import '../settings/settings_screen.dart';
import '../stats/stats_screen.dart';

/// 主菜单。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
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

  /// 进入局域网联机大厅（无需配置后端，也不需要外网）。
  void _enterOnline() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LobbyScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(ruleVariantProvider);
    return Scaffold(
      backgroundColor: TableColors.feltEdge,
      body: TableFelt(
        child: SafeArea(
          child: Stack(
            children: [
              const Positioned(left: 24, bottom: 8, child: _DecorFan()),
              const Positioned(
                right: 24,
                bottom: 8,
                child: _DecorFan(mirrored: true),
              ),
              Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShaderMask(
                        shaderCallback: (r) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFFFFF3B0), Color(0xFFFFB300)],
                        ).createShader(r),
                        child: const Text(
                          '经典斗地主',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 50,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 14,
                            shadows: [
                              Shadow(
                                color: Colors.black54,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'DouZero AI · 单机对战 · 局域网联机',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            '我的积分',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 8),
                          BankrollChip(
                            value: ref.watch(bankrollProvider),
                            large: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: TableColors.panel,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: TableColors.panelBorder),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final v in RuleVariant.presets) ...[
                              _modeBtn(mode, v),
                              const SizedBox(width: 4),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TableButton(
                            label: '开始游戏',
                            icon: Icons.play_arrow_rounded,
                            style: TableButtonStyle.primary,
                            height: 48,
                            minWidth: 170,
                            onTap: () {
                              ref.invalidate(gameSessionProvider);
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const GameScreen(),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 18),
                          TableButton(
                            label: '局域网联机',
                            icon: Icons.wifi_rounded,
                            style: TableButtonStyle.accent,
                            height: 48,
                            minWidth: 170,
                            onTap: _enterOnline,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _linkBtn(Icons.bar_chart_rounded, '战绩', () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const StatsScreen(),
                              ),
                            );
                          }),
                          const SizedBox(width: 16),
                          _linkBtn(Icons.settings_rounded, '设置', () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            );
                          }),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'https://github.com/wyy667/doudizhu   v$_version',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linkBtn(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white70, size: 17),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeBtn(RuleVariant current, RuleVariant target) {
    final selected = current.id == target.id;
    return GestureDetector(
      onTap: () => ref.read(ruleVariantProvider.notifier).state = target,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          target.label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 首页装饰：一手扇形展开的牌。
class _DecorFan extends StatelessWidget {
  const _DecorFan({this.mirrored = false});
  final bool mirrored;

  static const _cards = [
    Card(Rank.cA, Suit.spade),
    Card(Rank.cK, Suit.heart),
    Card(Rank.rj, Suit.jokerBig),
    Card(Rank.bj, Suit.jokerSmall),
  ];

  @override
  Widget build(BuildContext context) {
    const h = 96.0;
    const w = h * kCardAspect;
    final cards = mirrored ? _cards.reversed.toList() : _cards;
    return IgnorePointer(
      child: Opacity(
        opacity: 0.85,
        child: SizedBox(
          width: w + 3 * 26 + 20,
          height: h + 24,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < cards.length; i++)
                Positioned(
                  left: i * 26.0,
                  top: 12,
                  child: Transform.rotate(
                    angle: (i - 1.5) * 0.16 * (mirrored ? -1 : 1),
                    alignment: Alignment.bottomCenter,
                    child: mirrored && i == 0
                        ? const CardBack(width: w, height: h)
                        : CardWidget(card: cards[i], width: w, height: h),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
