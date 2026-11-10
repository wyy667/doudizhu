import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stats/stats_record.dart';
import '../../stats/stats_repository.dart';
import '../replay/replay_screen.dart';

/// 战绩筛选维度。
enum StatsFilter { all, classic, noShuffle, online }

/// 战绩模式筛选状态。
final _statsFilterProvider = StateProvider<StatsFilter>(
  (ref) => StatsFilter.classic,
);

/// 战绩面板。展示累计统计 + 对局历史（含回放/删除）。
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordsAsync = ref.watch(statsRecordsProvider);
    final filter = ref.watch(_statsFilterProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20),
      appBar: AppBar(
        title: const Text('战绩', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF0D3F12),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: recordsAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: Colors.amber)),
        error: (e, _) => Center(
          child: Text('读取失败：$e', style: const TextStyle(color: Colors.white70)),
        ),
        data: (allRecords) {
          // 按筛选维度过滤
          List<StatsRecord> records;
          switch (filter) {
            case StatsFilter.all:
              records = allRecords.toList();
              break;
            case StatsFilter.classic:
              records = allRecords
                  .where((r) => !r.noShuffle && !r.isOnline)
                  .toList();
              break;
            case StatsFilter.noShuffle:
              records = allRecords.where((r) => r.noShuffle).toList();
              break;
            case StatsFilter.online:
              records = allRecords.where((r) => r.isOnline).toList();
              break;
          }
          if (records.isEmpty) {
            return Column(
              children: [
                _modeSelector(ref, filter),
                const Expanded(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '还没有对战记录\n开始你的第一局吧！',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          final summary = StatsSummary.fromRecords(records);
          final reversed = records.reversed.toList(); // 新→旧
          final replayCount = records.where((r) => r.hasReplay).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _modeSelector(ref, filter),
              const SizedBox(height: 12),
              _winRateCard(summary),
              const SizedBox(height: 12),
              _streakCard(summary),
              const SizedBox(height: 12),
              _roleCard(summary),
              const SizedBox(height: 12),
              _extraCard(summary),
              const SizedBox(height: 20),
              // 对局历史
              Row(
                children: [
                  const Icon(Icons.history, color: Colors.amber, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '对局历史（$replayCount 局可回放 / 共 ${records.length} 局）',
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < reversed.length; i++)
                _historyItem(context, ref, reversed[i]),
            ],
          );
        },
      ),
    );
  }

  Widget _modeSelector(WidgetRef ref, StatsFilter filter) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _segBtn(ref, filter, StatsFilter.classic, '经典'),
            const SizedBox(width: 4),
            _segBtn(ref, filter, StatsFilter.noShuffle, '不洗牌'),
            const SizedBox(width: 4),
            _segBtn(ref, filter, StatsFilter.online, '联机'),
            const SizedBox(width: 4),
            _segBtn(ref, filter, StatsFilter.all, '全部'),
          ],
        ),
      ),
    );
  }

  Widget _segBtn(
    WidgetRef ref,
    StatsFilter current,
    StatsFilter target,
    String label,
  ) {
    final selected = current == target;
    return GestureDetector(
      onTap: () => ref.read(_statsFilterProvider.notifier).state = target,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _historyItem(BuildContext context, WidgetRef ref, StatsRecord r) {
    final time =
        '${r.playedAt.month}/${r.playedAt.day} '
        '${r.playedAt.hour.toString().padLeft(2, '0')}:'
        '${r.playedAt.minute.toString().padLeft(2, '0')}';
    return Card(
      color: Colors.black.withValues(alpha: 0.25),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // 胜负指示
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: r.humanWon ? Colors.lightGreen : Colors.redAccent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        r.humanWon ? '胜' : '负',
                        style: TextStyle(
                          color: r.humanWon
                              ? Colors.lightGreen
                              : Colors.redAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        r.humanIsLandlord ? '地主' : '农民',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '×${r.multiplier}',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (r.isSpring) ...[
                        const SizedBox(width: 6),
                        _badge('春天', Colors.pinkAccent),
                      ],
                      if (r.isAntiSpring) ...[
                        const SizedBox(width: 6),
                        _badge('反春天', Colors.purpleAccent),
                      ],
                      if (r.noShuffle) ...[
                        const SizedBox(width: 6),
                        _badge('不洗牌', Colors.deepOrange),
                      ],
                      if (r.isOnline) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.public,
                          size: 12,
                          color: Colors.lightBlueAccent,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$time  ·  ${r.turns}手',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            // 回放按钮
            if (r.hasReplay)
              IconButton(
                icon: const Icon(
                  Icons.play_circle_outline,
                  color: Colors.amber,
                  size: 22,
                ),
                tooltip: '回放',
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(6),
                onPressed: () {
                  final (replayLog, finalState) = r.reconstructReplay();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReplayScreen(
                        replayLog: replayLog,
                        finalState: finalState,
                      ),
                    ),
                  );
                },
              ),
            // 删除按钮
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 18),
              tooltip: '删除',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
              onPressed: () async {
                final repo = await ref.read(statsRepositoryProvider.future);
                await repo.deleteByTime(r.playedAt);
                ref.invalidate(statsRecordsProvider);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _winRateCard(StatsSummary s) {
    return Card(
      color: Colors.black.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '总胜率',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(s.winRate * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${s.humanWins} 胜',
                  style: const TextStyle(
                    color: Colors.lightGreen,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.humanLosses} 负',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  '共 ${s.totalGames} 局',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _streakCard(StatsSummary s) {
    final streakLabel = s.currentStreak > 0
        ? '${s.currentStreak} 连胜'
        : s.currentStreak < 0
        ? '${-s.currentStreak} 连败'
        : '—';
    final streakColor = s.currentStreak > 0
        ? Colors.lightGreen
        : s.currentStreak < 0
        ? Colors.redAccent
        : Colors.white70;
    return Card(
      color: Colors.black.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _metric('当前', streakLabel, streakColor),
            const SizedBox(width: 24),
            _metric('最长连胜', '${s.bestStreak}', Colors.amber),
            const SizedBox(width: 24),
            _metric(
              '累计得分',
              s.totalScore > 0 ? '+${s.totalScore}' : '${s.totalScore}',
              s.totalScore >= 0 ? Colors.lightGreen : Colors.redAccent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleCard(StatsSummary s) {
    return Card(
      color: Colors.black.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _metricBlock(
                '地主',
                '${(s.landlordWinRate * 100).toStringAsFixed(0)}%',
                '${s.asLandlordWins}/${s.asLandlord}',
              ),
            ),
            Container(width: 1, height: 40, color: Colors.white24),
            Expanded(
              child: _metricBlock(
                '农民',
                '${(s.farmerWinRate * 100).toStringAsFixed(0)}%',
                '${s.asFarmerWins}/${s.totalGames - s.asLandlord}',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _extraCard(StatsSummary s) {
    return Card(
      color: Colors.black.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                _metric(
                  '平均倍数',
                  '×${s.avgMultiplier.toStringAsFixed(1)}',
                  Colors.amber,
                ),
                const SizedBox(width: 24),
                _metric('最高倍数', '×${s.maxMultiplier}', Colors.orangeAccent),
                const SizedBox(width: 24),
                _metric('平均回合', s.avgTurns.toStringAsFixed(0), Colors.white),
                const SizedBox(width: 24),
                _metric('春天', '${s.springCount}', Colors.pinkAccent),
                const SizedBox(width: 24),
                _metric('反春天', '${s.antiSpringCount}', Colors.purpleAccent),
              ],
            ),
            // if (s.springCount > 0 || s.antiSpringCount > 0) ...[
            //   const SizedBox(height: 12),
            //   Container(height: 1, color: Colors.white12),
            //   const SizedBox(height: 12),
            //   Row(
            //     children: [
            //       _metric('春天', '${s.springCount}', Colors.pinkAccent),
            //       const SizedBox(width: 24),
            //       _metric('反春天', '${s.antiSpringCount}', Colors.purpleAccent),
            //     ],
            //   ),
            // ],
          ],
        ),
      ),
    );
  }

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold),
    ),
  );

  Widget _metric(String label, String value, Color color) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  Widget _metricBlock(String label, String rate, String detail) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 4),
      Text(
        rate,
        style: const TextStyle(
          color: Colors.amber,
          fontSize: 26,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 2),
      Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ],
  );

  // Future<bool?> _confirmClear(BuildContext context) {
  //   return showDialog<bool>(
  //     context: context,
  //     builder: (ctx) => AlertDialog(
  //       title: const Text('清除战绩'),
  //       content: const Text('确定要清空所有对战记录吗？此操作不可撤销。'),
  //       actions: [
  //         TextButton(
  //           onPressed: () => Navigator.pop(ctx, false),
  //           child: const Text('取消'),
  //         ),
  //         TextButton(
  //           onPressed: () => Navigator.pop(ctx, true),
  //           style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
  //           child: const Text('清除'),
  //         ),
  //       ],
  //     ),
  //   );
  // }
}
