import '../core/card.dart';
import '../core/game_action.dart';
import '../core/game_phase.dart';
import '../core/game_state.dart';
import 'ai_debug_log.dart';
import 'ai_player.dart';
import 'bid_ai.dart';
import 'douzero/douzero_encoder.dart';
import 'douzero/douzero_inference.dart';
import 'douzero/douzero_moves.dart';

/// DouZero WP（ICML 2021）驱动的 AI 实现。
///
/// - 叫地主阶段：用 [BidAi]（手牌强度评估）。
/// - 出牌阶段：枚举所有合法动作 → 编码 (z, x) batch → ONNX 推理 → argmax Q。
/// - 推理失败：选首个候选（保守降级），保证游戏不卡死。
class DouZeroAi implements AiPlayer {
  DouZeroAi();

  static const _modelDir = 'assets/models/douzero_wp';

  @override
  Future<GameAction> chooseAction(GameState state, int seat) async {
    if (state.phase == GamePhase.bidding) {
      final action = BidAi.chooseBid(state, seat);
      AiDebugLog.instance.record(
        AiDecision(
          seat: seat,
          aiType: 'douzero',
          role: null,
          candidatesCount: 1,
          chosen: const [],
          note: '叫地主阶段',
        ),
      );
      return action;
    }
    if (state.phase != GamePhase.playing) {
      return PassAction(seat);
    }
    final landlord = state.landlordSeat;
    if (landlord == null) {
      return PassAction(seat);
    }

    final role = _roleForSeat(landlord, seat);
    final candidates = DouZeroMoves.enumerate(state, seat);
    if (candidates.isEmpty) {
      AiDebugLog.instance.record(
        AiDecision(
          seat: seat,
          aiType: 'douzero',
          role: roleDisplayName(role),
          candidatesCount: 0,
          chosen: const [],
          note: '无合法动作 → PASS',
        ),
      );
      return PassAction(seat);
    }
    if (candidates.length == 1) {
      AiDebugLog.instance.record(
        AiDecision(
          seat: seat,
          aiType: 'douzero',
          role: roleDisplayName(role),
          candidatesCount: 1,
          chosen: candidates.single,
          note: '单一候选直接返回',
        ),
      );
      return _toAction(seat, candidates.single);
    }

    final z = DouZeroEncoder.encodeZ(state);
    final x = DouZeroEncoder.encodeXBatch(state, seat, candidates, role);
    final snapshot = _buildSnapshot(state, seat, role);

    final sw = Stopwatch()..start();
    try {
      final q = await DouZeroModels(
        _modelDir,
      ).run(role: role, z: z, x: x, n: candidates.length);
      sw.stop();
      AiDebugLog.instance.markOnnxOk();
      final best = _argmax(q);
      final action = _toAction(seat, candidates[best]);
      _log(
        seat,
        role: role,
        candidatesCount: candidates.length,
        chosen: candidates[best],
        note: 'ONNX 推理',
        qValues: (q, candidates),
        ms: sw.elapsedMilliseconds,
        snapshot: snapshot,
      );
      return action;
    } catch (e, st) {
      sw.stop();
      final errMsg = e.toString();
      AiDebugLog.instance.markOnnxError('$errMsg\n$st');
      final fallback = _toAction(seat, candidates.first);
      _log(
        seat,
        role: role,
        candidatesCount: candidates.length,
        chosen: candidates.first,
        note: '⚠ ONNX 失败 → 首个候选: $errMsg',
        qValues: null,
        ms: sw.elapsedMilliseconds,
        snapshot: snapshot,
      );
      return fallback;
    }
  }

  SnapshotContext _buildSnapshot(GameState state, int seat, DouZeroRole role) {
    final landlord = state.landlordSeat!;
    final teammate = _otherFarmer(landlord, seat);
    final up = (landlord + 1) % 3;
    final down = (landlord + 2) % 3;
    return SnapshotContext(
      myHand: List<Card>.from(state.players[seat].hand),
      myHandCount: state.players[seat].handCount,
      lastMove: DouZeroEncoder.lastMove(state),
      landlordLeft: state.players[landlord].handCount,
      teammateLeft: role == DouZeroRole.landlord
          ? -1
          : state.players[teammate].handCount,
      upLeft: role == DouZeroRole.landlord ? state.players[down].handCount : -1,
      downLeft: role == DouZeroRole.landlord ? state.players[up].handCount : -1,
      bombNum: DouZeroEncoder.countBombs(state),
    );
  }

  void _log(
    int seat, {
    required DouZeroRole? role,
    required int candidatesCount,
    required List<Card> chosen,
    required String note,
    required (List<double>, List<List<Card>>)? qValues,
    required int? ms,
    required SnapshotContext? snapshot,
  }) {
    AiDebugLog.instance.record(
      AiDecision(
        seat: seat,
        aiType: 'douzero',
        role: role == null ? null : roleDisplayName(role),
        candidatesCount: candidatesCount,
        chosen: chosen,
        note: note,
        topQ: qValues == null
            ? null
            : rankTopQ(qValues.$2, qValues.$1, topN: 5),
        decisionMs: ms,
        snapshot: snapshot,
      ),
    );
  }

  static DouZeroRole _roleForSeat(int landlord, int seat) {
    if (seat == landlord) return DouZeroRole.landlord;
    final offset = (seat - landlord) % 3;
    if (offset == 1) return DouZeroRole.landlordDown;
    return DouZeroRole.landlordUp;
  }

  static int _otherFarmer(int landlord, int mySeat) {
    for (var s = 0; s < 3; s++) {
      if (s != landlord && s != mySeat) return s;
    }
    throw StateError('Impossible: no other farmer');
  }

  static int _argmax(List<double> values) {
    var best = 0;
    var bestVal = values[0];
    for (var i = 1; i < values.length; i++) {
      if (values[i] > bestVal) {
        bestVal = values[i];
        best = i;
      }
    }
    return best;
  }

  static GameAction _toAction(int seat, List<Card> cards) {
    if (cards.isEmpty) return PassAction(seat);
    return PlayAction(seat, cards);
  }
}
