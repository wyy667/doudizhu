import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/ai/ai_model.dart';
import 'package:landlord/ai/battle_engine.dart';

/// AI 对战自动化测试：DouZero WP 自身对比（地主 vs 农民）。
///
/// 结果写入 logs/ai-battle-results.txt。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rounds = 10;
  const gamesPerRound = 500;

  final logLines = <String>[];
  void log(String msg) {
    if (kDebugMode) {
      print(msg);
    }
    logLines.add(msg);
  }

  group('AI Battle', () {
    test('DouZero WP self-matchup', () async {
      final overallStart = DateTime.now();
      log('');
      log('================================================================');
      log('  AI 对战测试  开始: ${overallStart.toString()}');
      log('  WP（地主）vs WP（农民）');
      log('  $rounds 轮 × $gamesPerRound 局/轮 = ${rounds * gamesPerRound} 局');
      log('================================================================');
      log('');

      for (var round = 1; round <= rounds; round++) {
        final seed = round * 1000000;
        final config = BattleConfig(
          landlordModel: AIModel.douzeroWP,
          farmerModel: AIModel.douzeroWP,
          totalGames: gamesPerRound,
          seed: seed,
          keepReplays: false,
        );
        final engine = BattleEngine(config: config);

        final sw = Stopwatch()..start();
        final stats = await engine.run();
        sw.stop();

        final llWinRate = (stats.landlordWinRate * 100).toStringAsFixed(1);
        final avgMult = stats.avgMultiplier.toStringAsFixed(1);
        final avgMoves = stats.avgMoves.toStringAsFixed(0);

        log(
          '  第 ${round.toString().padLeft(2)} 轮: 地主胜 ${stats.landlordWins}/${stats.gamesPlayed}'
          ' ($llWinRate%) | 倍数 $avgMult× | 回合 $avgMoves | '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
        );
      }

      final overallEnd = DateTime.now();
      final totalSec = overallEnd.difference(overallStart).inSeconds;
      log('');
      log('  总耗时: ${totalSec ~/ 60}m ${totalSec % 60}s');

      final logDir = Directory('logs');
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final logFile = File('logs/ai-battle-results.txt');
      logFile.writeAsStringSync(logLines.join('\n'));
      if (kDebugMode) {
        print('\n结果已保存至 logs/ai-battle-results.txt');
      }
    }, timeout: const Timeout(Duration(hours: 1)));
  });
}
