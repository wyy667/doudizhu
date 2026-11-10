import 'dart:math' as math;

import '../core/deck.dart';
import '../core/game_action.dart';
import '../core/game_engine.dart';
import '../core/game_phase.dart';
import '../core/game_state.dart';
import 'ai_model.dart';
import 'bid_ai.dart';
import 'douzero_ai.dart';

/// 对战配置。
class BattleConfig {
  final AIModel landlordModel;
  final AIModel farmerModel;
  final int totalGames;
  final int seed;
  final bool keepReplays;

  const BattleConfig({
    this.landlordModel = AIModel.douzeroWP,
    this.farmerModel = AIModel.douzeroWP,
    this.totalGames = 50,
    this.seed = 0,
    this.keepReplays = true,
  });

  String get id =>
      '${landlordModel.name}_vs_${farmerModel.name}_${totalGames}g_s$seed';

  String get displayName =>
      AIModel.describeConfig(landlord: landlordModel, farmer: farmerModel);
}

/// 单局对战结果（含回放数据）。
class BattleGameResult {
  final bool landlordWin;
  final int winnerSeat;
  final int multiplier;
  final int moveCount;
  final List<ReplayStep> replayLog;
  final GameState finalState;

  const BattleGameResult({
    required this.landlordWin,
    required this.winnerSeat,
    required this.multiplier,
    required this.moveCount,
    required this.replayLog,
    required this.finalState,
  });
}

/// 对战汇总统计。
class BattleStats {
  final BattleConfig config;
  final int gamesPlayed;
  final int landlordWins;
  final int farmerWins;
  final double avgMultiplier;
  final double avgMoves;
  final List<BattleGameResult> details;

  const BattleStats({
    required this.config,
    required this.gamesPlayed,
    required this.landlordWins,
    required this.farmerWins,
    required this.avgMultiplier,
    required this.avgMoves,
    required this.details,
  });

  double get landlordWinRate =>
      gamesPlayed > 0 ? landlordWins / gamesPlayed : 0;
  double get farmerWinRate => gamesPlayed > 0 ? farmerWins / gamesPlayed : 0;
}

/// AI 对战引擎：自动运行 N 局 AI vs AI，统计胜率。
class BattleEngine {
  final BattleConfig config;

  BattleStats? _stats;
  BattleStats? get stats => _stats;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  int _completedGames = 0;
  int get completedGames => _completedGames;

  BattleEngine({required this.config});

  void cancel() => _cancelled = true;

  Future<BattleStats> run({
    void Function(int completed, int total)? onProgress,
    void Function(BattleGameResult result)? onGameDone,
  }) async {
    _cancelled = false;
    _completedGames = 0;
    final results = <BattleGameResult>[];
    final rng = math.Random(config.seed);
    final seeds = List<int>.generate(
      config.totalGames,
      (_) => rng.nextInt(1 << 30),
    );

    final engine = const GameEngine();

    for (var i = 0; i < config.totalGames; i++) {
      if (_cancelled) break;
      try {
        final result = await _runOneGame(engine, seeds[i]);
        results.add(result);
        _completedGames = i + 1;
        onProgress?.call(i + 1, config.totalGames);
        onGameDone?.call(result);
      } catch (_) {
        _completedGames = i + 1;
        onProgress?.call(i + 1, config.totalGames);
      }
    }

    final landlordWins = results.where((r) => r.landlordWin).length;
    final farmerWins = results.where((r) => !r.landlordWin).length;
    _stats = BattleStats(
      config: config,
      gamesPlayed: results.length,
      landlordWins: landlordWins,
      farmerWins: farmerWins,
      avgMultiplier: results.isEmpty
          ? 0
          : results.map((r) => r.multiplier).reduce((a, b) => a + b) /
                results.length,
      avgMoves: results.isEmpty
          ? 0
          : results.map((r) => r.moveCount).reduce((a, b) => a + b) /
                results.length,
      details: results,
    );
    return _stats!;
  }

  Future<BattleGameResult> _runOneGame(GameEngine engine, int seed) async {
    final deal = Deck.deal(seed);
    var state = engine.apply(
      GameState.initial(),
      DealAction(deal.hands, deal.bottom, seed),
    );

    for (var r = 0; r < 3; r++) {
      if (state.phase == GamePhase.bidding) {
        final action = BidAi.chooseBid(state, state.currentPlayer);
        state = engine.apply(state, action);
      }
    }

    if (state.phase != GamePhase.playing) {
      return BattleGameResult(
        landlordWin: false,
        winnerSeat: -1,
        multiplier: 0,
        moveCount: 0,
        replayLog: config.keepReplays
            ? List<ReplayStep>.from(state.replayLog)
            : const [],
        finalState: config.keepReplays ? state : _placeholderState,
      );
    }

    final landlordSeat = state.landlordSeat!;
    var moveCount = 0;
    final ai = DouZeroAi();

    while (state.phase == GamePhase.playing) {
      final seat = state.currentPlayer;
      final action = await ai.chooseAction(state, seat);
      state = engine.apply(state, action);
      moveCount++;
    }

    final winnerSeat = state.winnerSeat!;

    return BattleGameResult(
      landlordWin: winnerSeat == landlordSeat,
      winnerSeat: winnerSeat,
      multiplier: state.multiplier,
      moveCount: moveCount,
      replayLog: config.keepReplays
          ? List<ReplayStep>.from(state.replayLog)
          : const [],
      finalState: config.keepReplays ? state : _placeholderState,
    );
  }
}

final _placeholderState = GameState(
  phase: GamePhase.settled,
  players: const [],
  currentPlayer: 0,
  bottomCards: const [],
  deckSeed: 0,
);
