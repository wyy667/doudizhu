# 02 · 技术栈与选型

## 项目类型

**跨平台移动/桌面游戏**（卡牌类，回合制）。横屏为主，离线优先，逐步引入联网。

## 核心技术

### 主语言与运行时

- **Dart**（随 Flutter SDK 3.x，项目当前 `sdk: ^3.11.4`）
- 平台：Android / iOS 为主，桌面（macOS/Windows/Linux）与 Web 为「能跑即加分」，不为首发优化。

### UI 框架与渲染

| 选型 | 决定 | 理由 |
|------|------|------|
| **Flutter 纯 Widget** | ✅ 采用 | 斗地主本质是 UI 元素的卡牌，无物理/精灵/复杂碰撞，纯 Widget 足够 |
| Flame 引擎 | ❌ 暂不 | 卡牌游戏无需游戏循环；若 Phase 2 需要炫酷动画（粒子/翻牌 3D），可局部引入 Flame 而非整体替换 |
| Rive / Lottie | 📋 Phase 2 | 用于过场与胜负面板动画 |

> 决策：**不为「看起来像游戏」而引入引擎**。纯 Widget 方案在卡牌类被广泛验证（见 [Flutter 卡牌开发讨论](https://medium.com/@krishanvijaybr/why-flutter-is-a-smart-choice-for-card-game-development-3bd363ad0e29)），且更易测试与维护。

### 状态管理

| 候选 | 决定 | 理由 |
|------|------|------|
| **Riverpod**（`flutter_riverpod`） | ✅ 采用 | 编译期安全、易测试、无 `BuildContext` 依赖、社区活跃；适合「领域状态 + UI」分离 |
| BLoC | 备选 | 事件驱动契合游戏，但样板代码多；Riverpod 更轻 |
| Provider / setState | ❌ | 复杂状态（手牌/历史/AI 异步）下力不从心 |

> 游戏状态用 `Notifier`/`AsyncNotifier` 持有；UI 用 `ConsumerWidget` 订阅。详见 [05-architecture.md](./05-architecture.md)。

### 屏幕方向

- **横屏锁定**：在 `main()` 中调用：
  ```dart
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  ```
- 同时在 Android `AndroidManifest.xml` 设置 `android:screenOrientation="sensorLandscape"`，避免转屏闪屏。
- iOS 在 `Info.plist` 配置 `UISupportedInterfaceOrientations` 仅含横屏项。
- 参考：[Flutter 官方 Orientation cookbook](https://docs.flutter.dev/cookbook/design/orientation)、[Stack Overflow 经典解答](https://stackoverflow.com/questions/49418332/flutter-how-to-prevent-device-orientation-changes-and-force-portrait)。

### 持久化

| 数据 | 方案 | 说明 |
|------|------|------|
| 对局进度（断点恢复） | `shared_preferences` + JSON | 单局状态轻量序列化 |
| 战绩统计 | `sqflite`（移动）/ `drift` | Phase 2 引入；移动端 SQLite |
| 设置项 | `shared_preferences` | 音效/难度/主题 |

> Phase 1 暂不持久化战绩，先做内存态；但状态类需**可序列化**（为 Phase 3 断线重连与对局恢复预留）。

## AI 与计算

### AI 引擎（演进路线，详见 [06-ai-strategy.md](./06-ai-strategy.md)）

| 阶段 | 方案 | 说明 |
|------|------|------|
| Phase 1 | **规则启发式 (Heuristic)** | 手牌分解 + 估值函数；响应快、易实现、可解释 |
| Phase 2 | **PIMC 完美信息蒙特卡洛** | 对未知手牌多次采样 → 用启发式打到底 → 投票；明显提升「不像作弊」的智能 |
| Phase 3+ | **DouZero / PerfectDou 风格模型** | 接入预训练权重（如 `tflite_flutter` 或服务端推理）；SOTA 级表现 |

> Phase 1 先做启发式 + 一个抽象 `AiPlayer` 接口，确保后续可热替换。

### AI 调度

- AI 计算放在 `Isolate`（`compute` 函数）中执行，避免阻塞 UI 主线程。
- 普通难度（PIMC）采样+rollout 自带计算延迟；简单难度（启发式）可引入「思考延迟」提升真实感。

## 联网（Phase 3 起，详见 [07-multiplayer-design.md](./07-multiplayer-design.md)）

| 方案 | 决定 | 理由 |
|------|------|------|
| **WebSocket**（自建服务端） | ✅ 主选 | 回合制卡牌天然契合长连接；协议简单；可做权威服务端防作弊 |
| WebRTC | ❌ | 卡牌不需要 P2P 低延迟；服务端中转更利于防作弊与观战 |
| Firebase / Supabase Realtime | 📋 备选 | 快速起步，但锁定 BaaS、月费、国内访问问题 |

- 服务端语言：**Go / Node.js（TypeScript）** 二选一（Phase 3 启动时定）。
- 客户端用 `web_socket_channel`。

## 依赖清单（Phase 1 预期）

```yaml
dependencies:
  flutter: { sdk: flutter }
  flutter_riverpod: ^2.x      # 状态管理
  freezed_annotation: ^2.x    # 不可变模型
  json_annotation: ^4.x       # 序列化
  shared_preferences: ^2.x    # 本地设置

dev_dependencies:
  build_runner: ^2.x
  freezed: ^2.x
  json_serializable: ^4.x
  flutter_test: { sdk: flutter }
  flutter_lints: ^6.0.0
```

> 仅在确有需要时新增依赖；每个依赖需在本文档登记用途。

## 代码质量工具

| 工具 | 用途 |
|------|------|
| `flutter_lints` | 静态分析（已配置） |
| `dart format` | 格式化 |
| `flutter test` | 单元 + Widget 测试 |
| GitHub Actions（可选） | CI：format + analyze + test |

## 测试策略

- **领域层 100% 单测**：规则识别 `detectHand`、比较 `canBeat`、发牌、AI 出牌选择。
- **Widget 测试**：关键交互（选牌/出牌/不出按钮）。
- **集成测试（`integration_test`）**：完整一局流程（发牌 → 叫地主 → 出完牌）。
- AI 用固定种子的随机数，便于复现对局。

## 决策日志

1. **不用 Flame** — 卡牌游戏纯 Widget 即可，降低复杂度与包体。
2. **Riverpod 而非 BLoC** — 更轻、更现代、测试友好。
3. **领域逻辑零 Flutter 依赖** — `core/` 包内不 import `package:flutter`，保证可移植到服务端（Phase 3 权威服务端）。
4. **AI 启发式优先** — 先有可玩性，PIMC/模型作为可选升级路径。
5. **横屏原生配置 + 代码双重锁定** — 避免冷启动闪屏。

## 已知限制 / 暂不处理

- 不支持竖屏（不作为目标形态）。
- Phase 1 不做账号体系。
- 不做内购与广告（个人项目）。
- AI 在 Phase 1 不做队友配合的高级策略（农民之间的协作留待 Phase 2 优化）。
