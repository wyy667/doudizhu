import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'douzero_encoder.dart';

/// DouZero ONNX 模型加载与推理封装。
///
/// 支持多模型集（ADP/WP 等），按 modelDir 区分：
/// ```
/// final adp = DouZeroModels('assets/models/douzero_adp');
/// final wp  = DouZeroModels('assets/models/douzero_wp');
/// ```
/// 同一个 modelDir 的 session 共享缓存，不同 modelDir 之间隔离。
///
/// 推理策略：模型 <6MB、N（合法动作数）通常 ≤30，单次推理 ~30-80ms。
/// `OrtSession.runAsync` 内部使用持久 isolate，不阻塞 UI。
class DouZeroModels {
  DouZeroModels._(this._modelDir);

  final String _modelDir;

  static final Map<String, DouZeroModels> _instances = {};

  factory DouZeroModels(String modelDir) {
    return _instances.putIfAbsent(modelDir, () => DouZeroModels._(modelDir));
  }

  static DouZeroModels get instance =>
      DouZeroModels('assets/models/douzero_adp');

  final Map<DouZeroRole, OrtSession> _sessions = {};
  final Map<DouZeroRole, Uint8List> _cachedBytes = {};
  bool _envInitialized = false;

  String _assetPath(DouZeroRole role) {
    final name = switch (role) {
      DouZeroRole.landlord => 'landlord',
      DouZeroRole.landlordUp => 'landlord_up',
      DouZeroRole.landlordDown => 'landlord_down',
    };
    return '$_modelDir/$name.onnx';
  }

  Future<void> _ensureEnv() async {
    if (_envInitialized) return;
    OrtEnv.instance.ptr;
    _envInitialized = true;
  }

  Future<Uint8List> _loadAssetBytes(DouZeroRole role) async {
    final cached = _cachedBytes[role];
    if (cached != null) return cached;
    final path = _assetPath(role);
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    _cachedBytes[role] = bytes;
    return bytes;
  }

  Future<OrtSession> _session(DouZeroRole role) async {
    final existing = _sessions[role];
    if (existing != null) return existing;
    await _ensureEnv();
    final bytes = await _loadAssetBytes(role);
    final opts = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    final session = OrtSession.fromBuffer(bytes, opts);
    _sessions[role] = session;
    return session;
  }

  /// 跑一次推理，返回长度 N 的 Q 值列表。
  Future<List<double>> run({
    required DouZeroRole role,
    required Float32List z,
    required Float32List x,
    required int n,
  }) async {
    final session = await _session(role);
    final xDim = role == DouZeroRole.landlord ? 373 : 484;
    if (x.length != n * xDim) {
      throw ArgumentError('x.length=${x.length} != n=$n * xDim=$xDim');
    }
    final zBatch = Float32List(n * 5 * 162);
    for (var i = 0; i < n; i++) {
      zBatch.setRange(i * 5 * 162, (i + 1) * 5 * 162, z);
    }

    List<OrtValue?>? outputs;
    final inputs = <String, OrtValue>{
      'z': OrtValueTensor.createTensorWithDataList(zBatch, [n, 5, 162]),
      'x': OrtValueTensor.createTensorWithDataList(x, [n, xDim]),
    };
    final runOpts = OrtRunOptions();
    try {
      outputs = await session.runAsync(runOpts, inputs);
      if (outputs == null || outputs.isEmpty || outputs[0] == null) {
        throw StateError('DouZero inference returned no output');
      }
      final outTensor = outputs[0] as OrtValueTensor;
      final values = outTensor.value;
      return _flattenToDoubles(values);
    } finally {
      for (final v in inputs.values) {
        v.release();
      }
      runOpts.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  static List<double> _flattenToDoubles(dynamic values) {
    double toNum(dynamic v) {
      if (v is num) return v.toDouble();
      throw StateError('Unexpected output element: ${v.runtimeType} ($v)');
    }

    if (values is List<num>) {
      return values.map(toNum).toList(growable: false);
    }
    if (values is List) {
      final out = <double>[];
      for (final e in values) {
        if (e is num) {
          out.add(e.toDouble());
        } else if (e is List) {
          for (final ee in e) {
            out.add(toNum(ee));
          }
        } else {
          throw StateError('Unexpected output element: ${e.runtimeType} ($e)');
        }
      }
      return out;
    }
    throw StateError('Unexpected output type: ${values.runtimeType}');
  }

  Future<void> release() async {
    for (final s in _sessions.values) {
      await s.release();
    }
    _sessions.clear();
    _cachedBytes.clear();
    _envInitialized = false;
  }
}
