# 03 · 项目结构

> 配合 [02-tech-stack.md](./02-tech-stack.md) 与 [05-architecture.md](./05-architecture.md) 阅读。
> 核心原则：**领域逻辑与表现层严格分层**，`core/` 不依赖 Flutter。

## 顶层目录

```
landlord/
├── docs/                       # 设计文档（本目录）
├── lib/                        # Flutter 应用代码
│   ├── main.dart               # 入口：方向锁定、ProviderScope、MaterialApp
│   ├── app/                    # 应用层：路由、主题、全局配置
│   ├── core/                   # ★ 领域核心（纯 Dart，无 Flutter 依赖）
│   ├── ui/                     # 表现层（Flutter Widget）
│   ├── state/                  # 应用/游戏状态（Riverpod Notifier）
│   ├── ai/                     # AI 策略实现（依赖 core）
│   ├── net/                    # 联网层（Phase 3，依赖 core）
│   ├── voice/                  # 语音群聊（LiveKit Cloud，Phase 3）
│   ├── audio/                  # 音效与报牌
│   │   ├── sfx_player.dart     # SfxPlayer：选牌/胜利/失败音色 + HapticFeedback
│   │   └── card_announcer.dart # CardAnnouncer：flutter_tts 系统 TTS 报牌（牌型/不要/叫分/报警）
│   └── util/                   # 通用工具
├── test/                       # 单元测试（镜像 lib 结构）
├── integration_test/           # 集成测试
├── assets/                     # 图片、音效、字体
├── android/ ios/ ...           # 平台工程
└── pubspec.yaml
```

## `lib/core/` —— 领域核心（最重要）

**不 import `package:flutter/**`。** 这是规则的事实来源，可被：
- UI 直接使用（Phase 1）
- AI 引擎使用（Phase 1/2）
- 服务端复用（Phase 3，权威校验）

```
lib/core/
├── card.dart                   # Card / Rank / Suit
├── deck.dart                   # 洗牌、发牌
├── hand_type.dart              # HandType 枚举
├── hand_pattern.dart           # HandPattern（识别结果）
├── hand_detector.dart          # ★ detectHand(List<Card>) -> HandPattern?
├── hand_compare.dart           # ★ canBeat(played, last) -> bool
├── player.dart                 # Player / Seat / Role(landlord/farmer)
├── game_state.dart             # 不可变游戏状态快照
├── game_action.dart            # 动作：Deal / Bid / Play / Pass（sealed class）
├── game_engine.dart            # ★ 状态转移：apply(state, action) -> state
├── game_phase.dart             # 状态机 + AiDifficulty 枚举
├── replay_log.dart             # ReplayStep 回放数据（每步快照）
├── serializer.dart             # 状态 ↔ JSON（断点恢复/联网）
└── errors.dart                 # 领域异常（IllegalActionError 等）
```

> ★ 标记的是核心算法文件，必须有完整单元测试。

## `lib/ui/` —— 表现层

按「屏幕 / 组件」两级组织，组件可复用：

```
lib/ui/
├── game/
│   ├── game_screen.dart            # 对局页（横屏主界面，单机/联网共用）
│   └── widgets/
│       ├── card_widget.dart        # 单张牌渲染（牌面 / CardBack 牌背）
│       ├── table_widgets.dart      # 牌桌组件：绒布背景、立体按钮、CardFan、叠放牌背、头像、气泡
│       └── card_counter.dart       # 记牌器（顶栏单行，显示对手手中剩余）
├── home/
│   └── home_screen.dart            # 主菜单（开始/难度/战绩/AI对战/联机）
├── lobby/                          # 联机大厅 + 房间（Phase 3）
│   ├── lobby_screen.dart           # 创建/加入房间（左右并排）
│   ├── room_screen.dart            # 等待室（座位 + 玩家名 + 开始按钮）
│   └── net_game_screen.dart        # 联网对局（ProviderScope override + PopScope）
├── chat/                           # 聊天面板（Phase 3）
│   └── chat_overlay.dart           # 悬浮聊天（高度限 60%，含系统消息+返回按钮）
├── game/widgets/
│   └── voice_controls.dart       # 语音控制组：加入/离开语音 + 推麦（条件显示）
├── battle/
│   └── battle_screen.dart          # AI 对战页（模型选择+胜率统计+复盘）
├── replay/
│   └── replay_screen.dart          # 复盘页（逐帧回放+倍速+三方手牌）
├── stats/
│   └── stats_screen.dart           # 战绩统计页
└── settings/
    └── settings_screen.dart        # 设置页（音效/震动/调试工具开关）
```

## `lib/state/` —— Riverpod 状态

```
lib/state/
├── game_session.dart           # GameSessionNotifier：持有 GameState，驱动一局
├── settings.dart               # 设置 Notifier
└── providers.dart              # 全局 Provider 定义（difficulty、sound 等）
```

`GameSessionNotifier` 是 UI 与 `core/game_engine` 之间的胶水层，负责：
- 接收 UI 动作 → 调用 `engine.apply`
- 触发 AI 行动（异步）
- 维护出牌历史、倍数、胜负判定

## `lib/ai/` —— AI 策略

```
lib/ai/
├── ai_player.dart              # AiPlayer 抽象接口 + AiHandSearch 工具类（合法动作枚举）
├── ai_model.dart               # AIModel 枚举（AI 对战模型标识：ADP/WP/SL/PIMC/启发式）
├── heuristic_ai.dart           # 启发式（简单难度）：bidding 评估 + 出牌委托 RolloutPolicy
├── rollout_policy.dart         # RolloutPolicy + HandDecomposer（PIMC rollout 与启发式共用）
├── pimc_ai.dart                # PIMC 完美信息蒙特卡洛（普通难度，samples=200）
├── douzero_ai.dart             # DouZero ONNX AI（困难难度）
├── battle_engine.dart          # AI 对战引擎（N 局自动对战 + 胜率统计 + 回放）
├── ai_debug_log.dart           # AI 决策调试日志
└── douzero/                    # DouZero ONNX 子模块
    ├── douzero_encoder.dart    # 特征编码（cardsToArray / encodeXBatch / encodeZ）
    ├── douzero_moves.dart      # 合法动作枚举（复用 AiHandSearch + 14 牌型补全）
    └── douzero_inference.dart  # ONNX 推理封装（assets → OrtSession → runAsync）
```

## `lib/net/` —— 联网层（局域网模式）

```
lib/net/
├── protocol.dart               数据模型（RoomMeta/SeatInfo/ChatMessage/RoomSnapshot）+ 房间码
├── room_client_base.dart       抽象接口 RoomClientBase（局域网 / Supabase 共用）
├── room_client.dart            activeRoomClientProvider / roomClientProvider / currentUserProvider
├── lan/
│   ├── lan_room_server.dart    房主服务：房间数据 + WebSocket(45678) + UDP 广播(45679)；按座位校验请求、只下发本人手牌
│   ├── lan_room_client.dart    RoomClientBase 实现：房主本机直连 / 远端 WebSocket + 自动重连
│   ├── lan_discovery.dart      房间发现 + 本机局域网地址 + Android MulticastLock
│   └── local_profile.dart      本机持久化身份（uid + 昵称）
├── supabase_room_client.dart   Supabase 实现（保留，UI 未使用）
└── net_game_session.dart       联网会话（房主权威 + 乐观更新 + 座位重映射 + 人机补位 / 掉线立即托管）
```

## `lib/voice/` —— 语音群聊（Phase 3 🔧 待测试）

```
lib/voice/
├── voice_chat_controller.dart   Riverpod Notifier（连接 LiveKit Room + 推麦 + 说话者检测 + 单人 1 分钟自删 + 断连自动重连 + 加入/离开语音）
└── voice_token_service.dart     Supabase Edge Function 调用（Token 签发 + 管理员房间管理：list/delete/delete-all + 密码验证）

supabase/functions/get-voice-token/
└── index.ts                     LiveKit JWT 签发 + CreateRoom(empty_timeout=60s)

supabase/cleanup_stale_rooms.sql SQL 函数（pg_cron 每 5 分钟清理无在线玩家且 10 分钟未更新的房间）
```

## 命名规范

| 类型 | 规范 | 示例 |
|------|------|------|
| 文件 | `snake_case.dart` | `hand_detector.dart` |
| 类 / 枚举 | `PascalCase` | `HandPattern`、`GamePhase` |
| 函数 / 变量 | `camelCase` | `detectHand`、`mainRank` |
| 常量 | `lowerCamelCase`（Dart 惯例）或 `camelCase` | `defaultStartScore` |
| 私有 | 前缀 `_` | `_sortCards` |
| 测试文件 | `<name>_test.dart` | `hand_detector_test.dart` |

## 导入顺序（`analysis_options` 强制）

1. Dart SDK
2. 第三方包
3. `package:landlord/`（项目内）
4. 相对路径（仅 `core` 内部可用，避免循环）

## 模块边界（依赖方向）

```
ui ──▶ state ──▶ core ◀── ai
                   ▲
                   └── net（Phase 3）
```

- **`core` 不依赖任何人**（除 Dart SDK 与少量注解包）。
- `ai` 依赖 `core`，不依赖 UI。
- `state` 依赖 `core` + `ai`，不直接依赖 Flutter 渲染（Riverpod 的 Notifier 本身不依赖 Widget）。
- `ui` 依赖 `state` + `core`（只读模型）。

## 文件规模指引

- 单文件 ≤ **300 行**为佳，超过则考虑拆分。
- 单函数 ≤ **50 行**，圈复杂度控制在合理范围。
- `hand_detector` 因分支多可能较长，按牌型拆为内部私有函数 + 一个总入口。

## 文档与代码同步

- 规则变动 → 先改 [04-game-rules.md](./04-game-rules.md)，再改 `core/`。
- 新增依赖 → 更新 [02-tech-stack.md](./02-tech-stack.md) 依赖清单。
- 新增玩法/网络能力 → 更新对应文档与路线图。
