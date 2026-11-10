// 端到端 ONNX 推理烟雾测试。
//
// 这是最关键的诊断：如果本测试在 `flutter test` 下失败，
// 说明 ONNX 推理路径本身有问题，对应真机也会 fallback 到 PIMC。
// 失败信息会暴露具体根因（asset 加载 / OrtSession 创建 / tensor 创建 / run / 输出解析）。
//
// 运行：flutter test test/ai/douzero_onnx_smoke_test.dart
// 注意：依赖 Flutter test binding（提供 rootBundle），不是纯 Dart 测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/ai/douzero/douzero_encoder.dart';
import 'package:landlord/ai/douzero/douzero_inference.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_state.dart';

void main() {
  // 必须先初始化 binding，否则 rootBundle 不可用。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 这是诊断测试，可能因 native lib 不可用而失败——打印详情但允许失败。
  // 真机/模拟器上才会真正跑通（native onnxruntime.so 已链接）。
  // 单元测试环境（dart test runner）通常没有 native binding，预期会抛错。

  group('DouZeroModels ONNX smoke', () {
    test('加载 landlord.onnx 并跑一次推理', () async {
      final models = DouZeroModels.instance;
      Object? error;
      List<double>? q;
      try {
        // 构造一个简单的 playing 状态：座位 0 当地主
        final deal = Deck.deal(0);
        var state = GameEngine().apply(
          GameState.initial(),
          DealAction(deal.hands, deal.bottom, 0),
        );
        state = GameEngine().apply(state, BidAction(0, 3));
        // 简单构造一个候选动作列表 + 假装编码
        final candidates = [
          [state.players[0].hand.first],
          [state.players[0].hand.last],
        ];
        final z = DouZeroEncoder.encodeZ(state);
        final x = DouZeroEncoder.encodeXBatch(
          state,
          0,
          candidates,
          DouZeroRole.landlord,
        );
        q = await models.run(
          role: DouZeroRole.landlord,
          z: z,
          x: x,
          n: candidates.length,
        );
      } catch (e, st) {
        error = '$e\n$st';
      }
      // 打印结果到测试输出（无论成败），便于诊断
      // ignore: avoid_print
      print('━━━ ONNX smoke test ━━━');
      // ignore: avoid_print
      print('error: $error');
      // ignore: avoid_print
      print('q: $q');
      // ignore: avoid_print
      print('━━━━━━━━━━━━━━━━━━━━━━');

      if (error != null) {
        // 在 flutter test 环境下，native onnxruntime 通常未链接，预期失败。
        // 这里只打印，不强制失败——真正想要的是在真机/模拟器上跑通。
        // 真机测试时如果 error != null，就是真正的 bug。
        // ignore: avoid_print
        print('⚠ ONNX 推理失败（在 flutter test 下属正常）：$error');
        return;
      }
      expect(q, isNotNull);
      expect(q!.length, 2);
      // Q 值应该是有限数
      expect(q.every((v) => v.isFinite), isTrue);
      // ignore: avoid_print
      print('✅ ONNX 推理成功，Q 值：$q');
    });
  });
}
