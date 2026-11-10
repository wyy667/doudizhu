import 'dart:developer' as dev;

import '../core/card.dart';
import 'douzero/douzero_encoder.dart';

/// AI 决策调试记录。每次 AI 选择动作时追加一条，UI 可读取实时显示。
///
/// 这不是性能关键路径：每局 ~30-80 次决策，单条记录内存 <1KB。
class AiDecision {
  final int seat;
  final String aiType; // 'douzero' / 'pimc' / 'heuristic'
  final String? role; // 'landlord' / 'landlord_down' / 'landlord_up'（仅 douzero）
  final int candidatesCount;
  final List<Card> chosen; // 最终选择的牌（空 = pass）
  final String? note; // 备注（如「fallback: onnx 加载失败」「单一候选直接返回」）

  /// DouZero 推理 Q 值 top-3（仅 douzero 路径有）
  final List<QValueRank>? topQ;
  final int? decisionMs; // 推理耗时

  /// 局面快照（仅 douzero）：让用户对照模型看到的输入是否正确
  final SnapshotContext? snapshot;

  AiDecision({
    required this.seat,
    required this.aiType,
    this.role,
    required this.candidatesCount,
    required this.chosen,
    this.note,
    this.topQ,
    this.decisionMs,
    this.snapshot,
  });

  @override
  String toString() {
    final buf = StringBuffer('[#$seat $aiType');
    if (role != null) buf.write('/$role');
    buf.write('] 候选 $candidatesCount');
    if (decisionMs != null) buf.write(' ${decisionMs}ms');
    if (note != null) buf.write('  备注: $note');
    buf.write(
      '  → ${chosen.isEmpty ? "PASS" : chosen.map((c) => c.rank.label).join(" ")}',
    );
    if (topQ != null && topQ!.isNotEmpty) {
      buf.write('  topQ: ');
      buf.write(
        topQ!
            .take(3)
            .map(
              (q) =>
                  '${q.cards.map((c) => c.rank.label).join("")}'
                  '=${q.q.toStringAsFixed(2)}',
            )
            .join(', '),
      );
    }
    return buf.toString();
  }
}

class QValueRank {
  final List<Card> cards;
  final double q;
  QValueRank(this.cards, this.q);
}

/// 模型视角的当前局面摘要：用户对照「模型看到了什么」是否正确。
class SnapshotContext {
  final List<Card> myHand; // 自己手牌
  final int myHandCount;
  final List<Card> lastMove; // 模型看到的「最近一手」（含跳过 pass）
  final int landlordLeft;
  final int teammateLeft; // 农民视角的队友；地主视角 = -1
  final int upLeft; // 地主视角的 landlord_up 剩牌
  final int downLeft; // 地主视角的 landlord_down 剩牌
  final int bombNum;

  SnapshotContext({
    required this.myHand,
    required this.myHandCount,
    required this.lastMove,
    required this.landlordLeft,
    required this.teammateLeft,
    required this.upLeft,
    required this.downLeft,
    required this.bombNum,
  });
}

/// AI 决策日志：滚动列表 + 错误状态。
class AiDebugLog {
  AiDebugLog._();
  static final AiDebugLog instance = AiDebugLog._();

  /// 当前生效的 AI 类型（由 GameSession 在 _makeAi 后写入）
  String activeAiType = 'unknown';

  /// ONNX 状态：null = 未尝试，true = 成功，false = 失败（含错误信息）
  bool? _onnxOk;
  String? _onnxError;

  /// 全局开关：是否记录详细日志（默认关，避免 non-debug 时的内存增长）
  bool enabled = false;

  /// 当前局决策记录（newGame 时清空）
  final List<AiDecision> _decisions = [];

  /// 监听器（UI 订阅决策变化）
  final _listeners = <void Function()>[];
  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) =>
      _listeners.removeWhere((f) => f == fn);
  void _notify() {
    for (final fn in _listeners) {
      fn();
    }
  }

  List<AiDecision> get decisions => List.unmodifiable(_decisions);
  bool? get onnxOk => _onnxOk;
  String? get onnxError => _onnxError;

  void setActiveAi(String type) {
    activeAiType = type;
    _notify();
  }

  /// ONNX 推理成功一次，更新状态（仅首次需要更新，之后幂等）。
  void markOnnxOk() {
    if (_onnxOk != true) {
      _onnxOk = true;
      _onnxError = null;
      _notify();
    }
  }

  /// ONNX 推理失败，记录错误（每次都更新，便于看最新错误）。
  void markOnnxError(String message) {
    _onnxOk = false;
    _onnxError = message;
    _notify();
  }

  void clearForNewGame() {
    _decisions.clear();
    _notify();
  }

  void record(AiDecision d) {
    if (!enabled) return;
    _decisions.add(d);
    // 同时打到 logcat（flutter run 时可见）
    dev.log(d.toString());
    _notify();
  }

  /// 生成给 UI 显示的简短状态摘要，如「DouZero ✓ 5 次推理」或「❌ ONNX 失败 (已 fallback PIMC)」。
  String get statusSummary {
    final aiName = switch (activeAiType) {
      'douzero' => 'DouZero',
      'pimc' => 'PIMC',
      'heuristic' => '启发式',
      _ => activeAiType,
    };
    if (activeAiType != 'douzero') return aiName;
    return switch (_onnxOk) {
      true => '$aiName ✓',
      false => '$aiName ✗',
      null => '$aiName …',
    };
  }
}

/// 辅助：把 DouZero 推理结果转换为 top-Q 候选列表（用于日志）。
List<QValueRank> rankTopQ(
  List<List<Card>> candidates,
  List<double> qValues, {
  int topN = 3,
}) {
  if (qValues.length != candidates.length) return const [];
  final indexed = <int, double>{
    for (var i = 0; i < qValues.length; i++) i: qValues[i],
  };
  final keys = indexed.keys.toList()
    ..sort((a, b) => indexed[b]!.compareTo(indexed[a]!));
  return keys
      .take(topN)
      .map((k) => QValueRank(candidates[k], qValues[k]))
      .toList();
}

/// 用于编码徽标的角色名称（让 UI 显示更友好）。
String roleDisplayName(DouZeroRole role) => switch (role) {
  DouZeroRole.landlord => '地主',
  DouZeroRole.landlordUp => '地主上',
  DouZeroRole.landlordDown => '地主下',
};
