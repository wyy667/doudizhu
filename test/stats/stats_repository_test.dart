import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/stats/stats_record.dart';
import 'package:landlord/stats/stats_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // setUp：用 SharedPreferences.setMockInitialValues 提供内存版实例。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('StatsRepository · 持久化', () {
    test('append 后 loadAll 能读回', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = StatsRepository(prefs);
      await repo.append(
        StatsRecord(
          playedAt: DateTime(2026, 7, 7),
          humanWon: true,
          humanIsLandlord: true,
          multiplier: 4,
          score: 4,
          turns: 32,
        ),
      );
      final list = repo.loadAll();
      expect(list.length, 1);
      expect(list.first.humanWon, true);
      expect(list.first.multiplier, 4);
    });

    test('多条按时间顺序保留（升序）', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = StatsRepository(prefs);
      for (var i = 0; i < 5; i++) {
        await repo.append(
          StatsRecord(
            playedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
            humanWon: i.isEven,
            humanIsLandlord: true,
            multiplier: 1,
            score: 1,
            turns: 10,
          ),
        );
      }
      final list = repo.loadAll();
      expect(list.length, 5);
      expect(list.first.playedAt.day, 1);
      expect(list.last.playedAt.day, 5);
    });

    test('超过 maxReplayKeep 不删除记录，仅剥离旧记录回放数据', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = StatsRepository(prefs);
      for (var i = 0; i < StatsRepository.maxReplayKeep + 10; i++) {
        await repo.append(
          StatsRecord(
            playedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
            humanWon: true,
            humanIsLandlord: false,
            multiplier: 1,
            score: 1,
            turns: 1,
            deckSeed: i,
            actionLog: [
              {'type': 'pass', 'bySeat': 0},
            ],
          ),
        );
      }
      final list = repo.loadAll();
      // 全部保留，不删除
      expect(list.length, StatsRepository.maxReplayKeep + 10);
      // 最旧的记录（超 50 局的）回放数据被剥离
      expect(list.first.hasReplay, false);
      // 最近 50 局保留回放数据
      expect(list.last.hasReplay, true);
    });

    test('clear 清空所有记录', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = StatsRepository(prefs);
      await repo.append(
        StatsRecord(
          playedAt: DateTime.now(),
          humanWon: true,
          humanIsLandlord: false,
          multiplier: 1,
          score: 1,
          turns: 1,
        ),
      );
      await repo.clear();
      expect(repo.loadAll(), isEmpty);
    });

    test('损坏的 JSON 不影响可用性（返回空）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(StatsRepository.storageKey, 'not a valid json');
      final repo = StatsRepository(prefs);
      expect(repo.loadAll(), isEmpty);
    });
  });

  group('StatsSummary · 聚合', () {
    StatsRecord rec({
      bool won = true,
      bool landlord = false,
      int mult = 1,
      int score = 1,
    }) => StatsRecord(
      playedAt: DateTime.now(),
      humanWon: won,
      humanIsLandlord: landlord,
      multiplier: mult,
      score: score,
      turns: 20,
    );

    test('空记录返回 empty', () {
      final s = StatsSummary.fromRecords([]);
      expect(s.totalGames, 0);
      expect(s.winRate, 0);
    });

    test('胜率、地主胜率、农民胜率计算', () {
      final s = StatsSummary.fromRecords([
        rec(won: true, landlord: true),
        rec(won: true, landlord: false),
        rec(won: false, landlord: true),
        rec(won: false, landlord: false),
      ]);
      expect(s.totalGames, 4);
      expect(s.humanWins, 2);
      expect(s.asLandlord, 2);
      expect(s.asLandlordWins, 1);
      expect(s.asFarmerWins, 1);
      expect(s.winRate, 0.5);
      expect(s.landlordWinRate, 0.5);
      expect(s.farmerWinRate, 0.5);
    });

    test('连胜：3 连胜后 bestStreak=3', () {
      final s = StatsSummary.fromRecords([
        rec(won: true),
        rec(won: true),
        rec(won: true),
      ]);
      expect(s.currentStreak, 3);
      expect(s.bestStreak, 3);
    });

    test('连胜中断：胜胜胜负胜 → bestStreak=3, currentStreak=1', () {
      final s = StatsSummary.fromRecords([
        rec(won: true),
        rec(won: true),
        rec(won: true),
        rec(won: false),
        rec(won: true),
      ]);
      expect(s.bestStreak, 3);
      expect(s.currentStreak, 1);
    });

    test('连败：currentStreak 为负数', () {
      final s = StatsSummary.fromRecords([rec(won: false), rec(won: false)]);
      expect(s.currentStreak, -2);
      expect(s.bestStreak, 0);
    });

    test('平均倍数与最高倍数', () {
      final s = StatsSummary.fromRecords([
        rec(mult: 1),
        rec(mult: 2),
        rec(mult: 8),
      ]);
      expect(s.avgMultiplier, closeTo(11 / 3, 0.01));
      expect(s.maxMultiplier, 8);
    });

    test('累计得分（胜+ 负-）', () {
      final s = StatsSummary.fromRecords([
        rec(won: true, score: 4),
        rec(won: false, score: 2), // -2
        rec(won: true, score: 1),
      ]);
      expect(s.totalScore, 3); // 4 - 2 + 1
    });
  });
}
