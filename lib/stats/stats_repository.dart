import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stats_record.dart';

/// 战绩持久化仓储。基于 [SharedPreferences] 存 JSON 数组。
///
/// 设计：每局结束 append 一条记录；统计时全量读出计算。
/// 所有记录永久保留用于统计；仅最近 [maxReplayKeep] 局保留回放数据（deckSeed + actionLog），
/// 超出的旧记录剥离回放数据以控制存储量。
class StatsRepository {
  /// SharedPreferences 键。
  static const storageKey = 'landlord.stats.records.v1';

  /// 回放数据保留上限：超过此数的旧记录剥离 deckSeed + actionLog。
  static const maxReplayKeep = 50;

  final SharedPreferences _prefs;
  StatsRepository(this._prefs);

  /// 读取全部记录（按时间升序，旧→新）。
  /// 返回可变 list，便于调用方追加/裁剪。
  List<StatsRecord> loadAll() {
    final raw = _prefs.getString(storageKey);
    if (raw == null) return <StatsRecord>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => StatsRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 损坏数据直接丢弃，避免影响应用可用性
      return <StatsRecord>[];
    }
  }

  /// 追加一条记录。超过 [maxReplayKeep] 的旧记录剥离回放数据（统计仍保留）。
  Future<void> append(StatsRecord record) async {
    final list = loadAll()..add(record);
    // 剥离超出上限的旧记录的回放数据
    if (list.length > maxReplayKeep) {
      for (var i = 0; i < list.length - maxReplayKeep; i++) {
        if (list[i].hasReplay) {
          list[i] = StatsRecord(
            playedAt: list[i].playedAt,
            humanWon: list[i].humanWon,
            humanIsLandlord: list[i].humanIsLandlord,
            multiplier: list[i].multiplier,
            score: list[i].score,
            turns: list[i].turns,
            variantId: list[i].variantId,
            isOnline: list[i].isOnline,
          );
        }
      }
    }
    final raw = jsonEncode(list.map((r) => r.toJson()).toList());
    await _prefs.setString(storageKey, raw);
  }

  /// 清空所有战绩（设置页「清除战绩」用）。
  Future<void> clear() async {
    await _prefs.remove(storageKey);
  }

  /// 删除指定时间的记录（按 playedAt 精确匹配）。
  Future<void> deleteByTime(DateTime playedAt) async {
    final list = loadAll();
    list.removeWhere((r) => r.playedAt == playedAt);
    final raw = jsonEncode(list.map((r) => r.toJson()).toList());
    await _prefs.setString(storageKey, raw);
  }
}

/// 战绩统计快照（不可变）。所有字段由 [StatsRepository.loadAll] 聚合得到。
class StatsSummary {
  final int totalGames; // 总局数
  final int humanWins; // 人类获胜局数
  final int humanLosses; // 失败局数
  final int asLandlord; // 当地主局数
  final int asLandlordWins; // 当地主且胜局数
  final int asFarmerWins; // 当农民且胜局数
  final int currentStreak; // 当前连胜（>0 胜连胜，<0 连败）
  final int bestStreak; // 历史最长连胜
  final double avgMultiplier; // 平均倍数
  final int maxMultiplier; // 最高单局倍数
  final int totalScore; // 累计得分（胜+ | 负-）
  final double avgTurns; // 平均回合数
  final int springCount; // 春天次数
  final int antiSpringCount; // 反春天次数

  const StatsSummary({
    required this.totalGames,
    required this.humanWins,
    required this.humanLosses,
    required this.asLandlord,
    required this.asLandlordWins,
    required this.asFarmerWins,
    required this.currentStreak,
    required this.bestStreak,
    required this.avgMultiplier,
    required this.maxMultiplier,
    required this.totalScore,
    required this.avgTurns,
    required this.springCount,
    required this.antiSpringCount,
  });

  /// 空快照（无记录）。
  const StatsSummary.empty()
    : totalGames = 0,
      humanWins = 0,
      humanLosses = 0,
      asLandlord = 0,
      asLandlordWins = 0,
      asFarmerWins = 0,
      currentStreak = 0,
      bestStreak = 0,
      avgMultiplier = 0,
      maxMultiplier = 0,
      totalScore = 0,
      avgTurns = 0,
      springCount = 0,
      antiSpringCount = 0;

  double get winRate => totalGames == 0 ? 0 : humanWins / totalGames;
  double get landlordWinRate =>
      asLandlord == 0 ? 0 : asLandlordWins / asLandlord;
  double get farmerWinRate {
    final farmerGames = totalGames - asLandlord;
    return farmerGames == 0 ? 0 : asFarmerWins / farmerGames;
  }

  /// 由原始记录列表聚合。
  factory StatsSummary.fromRecords(List<StatsRecord> records) {
    if (records.isEmpty) return const StatsSummary.empty();

    var wins = 0,
        losses = 0,
        asLandlord = 0,
        asLandlordWins = 0,
        asFarmerWins = 0;
    var totalMult = 0, maxMult = 0, totalScore = 0, totalTurns = 0;
    var bestStreak = 0;
    var curStreak = 0;
    var springCount = 0, antiSpringCount = 0;

    for (final r in records) {
      totalMult += r.multiplier;
      if (r.multiplier > maxMult) maxMult = r.multiplier;
      totalScore += r.humanWon ? r.score : -r.score;
      totalTurns += r.turns;
      if (r.humanIsLandlord) asLandlord++;
      if (r.isSpring) springCount++;
      if (r.isAntiSpring) antiSpringCount++;
      if (r.humanWon) {
        wins++;
        if (r.humanIsLandlord) {
          asLandlordWins++;
        } else {
          asFarmerWins++;
        }
        curStreak = curStreak >= 0 ? curStreak + 1 : 1;
      } else {
        losses++;
        curStreak = curStreak <= 0 ? curStreak - 1 : -1;
      }
      if (curStreak > bestStreak) bestStreak = curStreak;
    }

    return StatsSummary(
      totalGames: records.length,
      humanWins: wins,
      humanLosses: losses,
      asLandlord: asLandlord,
      asLandlordWins: asLandlordWins,
      asFarmerWins: asFarmerWins,
      currentStreak: curStreak,
      bestStreak: bestStreak,
      avgMultiplier: totalMult / records.length,
      maxMultiplier: maxMult,
      totalScore: totalScore,
      avgTurns: totalTurns / records.length,
      springCount: springCount,
      antiSpringCount: antiSpringCount,
    );
  }
}

/// Provider：SharedPreferences 单例。
final sharedPreferencesProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

/// Provider：战绩仓储（异步，依赖 SharedPreferences）。
final statsRepositoryProvider = FutureProvider<StatsRepository>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  return StatsRepository(prefs);
});

/// Provider：战绩记录列表（按时间升序，旧→新）。
final statsRecordsProvider = FutureProvider<List<StatsRecord>>((ref) async {
  final repo = await ref.watch(statsRepositoryProvider.future);
  return repo.loadAll();
});

/// Provider：当前战绩汇总（依赖 recordsProvider，刷新时联动）。
final statsSummaryProvider = FutureProvider<StatsSummary>((ref) async {
  final records = await ref.watch(statsRecordsProvider.future);
  return StatsSummary.fromRecords(records);
});
