> 历史记录：下文提及的作者共享后端配置和彩蛋已在公开版本中移除，当前需使用自己的后端配置。

# 08 · 开发路线图

> 总原则：**每个 Phase 都可独立交付、可玩**。不提前实现后续阶段，但 Phase 1 的架构决策需为后续留好接口。
> 详细设计文档 [09-design-mvp.md](./09-design-mvp.md) 对应 Phase 1。

## Phase 总览

```
Phase 1  单机 MVP（人 vs 2 AI）         ✅ 已完成
Phase 2  玩法与体验增强                  ✅ 已完成（核心 6/8 项）
Phase 2.5 DouZero ONNX 端侧集成         ✅ 已完成（AI 强度跃升至 SOTA）
Phase 2.6 难度重构 + AI 对战 + 牌面美化  ✅ 已完成
Phase 3  联网对战（Supabase）               ✅ 已完成
Phase 3.1 Firebase 移除 + 运行时配置       ✅ 已完成
Phase 4  社交与生态
```

---

## 🟢 Phase 1 · 单机 MVP（目标：可玩的完整斗地主）✅ 已完成

**范围**：1 人 + 2 AI，经典规则，本地一局完整流程。

### 1.1 交付物

- [x] 横屏锁定 + 主菜单（开始游戏 / 设置）
- [x] 完整规则引擎：`detectHand`（14 牌型）+ `canBeat`
- [x] 状态机：发牌 → 叫地主 → 出牌 → 结算
- [x] 玩家交互：选牌、出牌、不出、提示
- [x] 启发式 AI（简单难度）
- [x] 倍数与基础结算（炸弹/火箭 ×2）
- [x] 重开一局

### 1.2 验收标准（已达成）

| 项 | 标准 | 实际 |
|----|------|------|
| 规则正确性 | 14 牌型识别 + 比较全通过单测 | ✅ 51 个核心测试全过 |
| 可玩性 | 完整一局能从发牌走到胜负 | ✅ AI vs AI 烟雾测试通过 |
| 性能 | AI 出牌 < 1s；60fps | ✅ 启发式 <10ms |
| 离线 | 飞行模式下完整可玩 | ✅ 零网络依赖 |

### 1.3 实际偏差（与原计划）

- **未用 freezed/build_runner**：改用 Dart 3 原生 `sealed class` + 手写不可变模型。零构建步骤、完全可控。如未来需要可平滑切换。
- **持久化未用 sqflite**：战绩需求简单，用 `shared_preferences` 存 JSON 足够（见 Phase 2）。

---

## 🟡 Phase 2 · 玩法与体验增强 ✅ 已完成（核心 5/8 项）

**范围**：在单机基础上丰富玩法、视觉、可玩深度。无联网。

### 2.1 交付物状态

| # | 项目 | 状态 | 说明 |
|---|------|:----:|------|
| 1 | 战绩与统计 | ✅ | `StatsRecord`/`StatsSummary`/`StatsRepository`（SharedPreferences），主菜单战绩面板，12 个测试 |
| 2 | 叫地主完整流程 | ✅ | `BidAction(score 0/1/2/3)` 叫分制 + 抢地主 + 流局处理，8 个测试 |
| 3 | 春天/反春天 | ✅ | 引擎 ×2 倍数 + `GameState.isSpring`/`isAntiSpring` 字段 + `PlayerState.playCount` 追踪出牌轮数 + 结算面板显示「🌸 春天/反春天 ×2」 |
| 4 | AI 升级（PIMC） | ✅ | `PimcAi` 普通难度（采样确定化+rollout），`HeuristicAi.chooseActionSync` 复用，4 个测试 |
| 5 | 规则变体 | ⏸ | 未做。需 `RuleVariant` 配置抽象，留待后续 |
| 6 | 视觉与音效 | 🔧 | 牌面已美化；出牌音效已实现（`SfxPlayer` 程序生成 WAV：选牌/出牌/不出/炸弹/火箭/胜利/失败 + HapticFeedback）；出牌动画待加 |
| 7 | 回放与复盘 | ✅ | `ReplayScreen` 逐帧回放（三方手牌+倍速+进度条），调试透视开关，`ReplayStep` 数据层 |
| 8 | 设置 | ✅ | 难度切换 + 音效/震动开关 + 调试工具总开关（`SettingsScreen`，默认隐藏调试图标） |

### 2.2 已完成的关键架构工作

- AI 接入 PIMC，保持 `AiPlayer` 接口不变（运行时按难度切换）。
- 叫分制完整重构 `CallLandlordAction` → `BidAction`，引擎 + AI + UI + 测试同步更新。
- 战绩自动记录接入 GameSession 的 `_applyAction` 收口，结算时异步写入。

### 2.3 已知限制（Phase 2 遗留）

- **战绩得分模型**：`score = multiplier × (地主?2:1)`，已区分地主/农民倍率差异。春天/反春天倍数已包含在 multiplier 中。
- **规则变体**：未做（留待后续）。
- **出牌动画**：音效已实现，过渡动画待加。

### 2.4 AI 增强迭代（2026-07 补充）

针对用户反馈「AI 太弱」，对 PIMC 做了深度增强（对齐 DouZero DMC 思路）：

| 改进点 | 内容 |
|--------|------|
| **采样信息修复** | `GameState.playedCards` 累积所有公开牌（出过的+底牌），PIMC 据此精确推断未知牌。原版只看 `lastValidPlay` 是致命缺陷。 |
| **强 rollout** | 新增 `RolloutPolicy`（`lib/ai/rollout_policy.dart`）：基于 `HandDecomposer` 最少手数估值 + 精确炸弹时机（手牌≤6/对手≤2 才用）+ 农民协作（队友出大牌则让）。明显强于原启发式 rollout。 |
| **采样数提升** | samples 30→200，标准差 ±3.5%，能区分 7% 胜率差的动作。 |
| **Isolate 执行** | `GameSession` 用 `Isolate.run` 调度 PIMC，samples×candidates 次 rollout 全在后台线程，UI 不卡顿。 |

> DouZero ONNX 端侧集成已在 Phase 2.5 完成，详见下文 §2.5。

### 2.5 测试与质量

- `flutter analyze` 0 issues
- `flutter build apk --debug` 成功（含 ONNX native lib + 3 个 ONNX asset）

---

## 🟠 Phase 2.5 · DouZero ONNX 端侧集成 ✅ 已完成（2026-07）

**触发**：用户在 [palemoky/douzero-baselines · models_onnx](https://huggingface.co/palemoky/douzero-baselines/tree/main/models_onnx) 找到现成 ADP ONNX 文件（三模型各 ~6MB），绕开「无 ONNX 发布」障碍，重新评估为可行。

### 2.5.1 交付物

| 项 | 状态 | 说明 |
|---|:----:|---|
| ONNX 推理封装 | ✅ | `DouZeroModels` 单例：assets → 临时文件 → `OrtSession.fromFile` → `runAsync` |
| 特征编码器（Dart 移植） | ✅ | `DouZeroEncoder`：cardsToArray 54-dim、encodeXBatch 373/484、encodeZ 5×162，对齐 `kwai/DouZero/douzero/env/env.py` |
| 合法动作枚举 | ✅ | `DouZeroMoves.enumerate`（复用 `AiHandSearch.findBeats` + lead 候选补全 14 牌型） |
| `DouZeroAi implements AiPlayer` | ✅ | bidding 降级 HeuristicAi，推理失败 fallback PimcAi |
| GameState 字段扩展 | ✅ | 新增 `playedBySeat` / `lastMoveBySeat` / `actionSeq` 供编码使用，4 个 `_apply*` 同步维护 |
| 难度接入 | ✅ | `AiDifficulty.hard`（DouZero）对应主菜单「困难」按钮；难度体系重构为三档：简单=启发式 / 普通=PIMC / 困难=DouZero |
| 测试 | ✅ | 34 个新测试（编码器 22 + AI 7 + 引擎新字段 5），全量 124 测试通过 |

### 2.5.2 关键技术决策

- **模型 schema 已验证**：`z: [batch,5,162]` + `x: [batch,373|484]` → `values: [batch,1]`，batch 为 dynamic axis。
- **推理在主 isolate 跑**：模型 <6MB、N≤30，单次 ~30-80ms，`OrtSession.runAsync` 内部用持久 isolate 不卡 UI。`GameSession._runAiTurn` 的 `else` 分支直接 `await`，零改动接入。
- **座位→角色映射**：基于 `state.landlordSeat`，`(seat-landlord)%3==1 → landlord_down`，`==2 → landlord_up`。
- **other_hand 当前 perfect-info**：DouZero 训练即 perfect-info；如要切换 non-cheating 仅改 `_otherHandUnion` 即可。

### 2.5.3 包体影响

- debug APK：237MB（含 arm64/armv7/x86_64 三套 `libonnxruntime.so`，每套 14-23MB）。
- release APK 单 ABI 估算：~30MB。
- 可选优化：`android/app/build.gradle.kts` 加 `ndk { abiFilters += listOf("arm64-v8a") }` 限制 ABI。

### 2.5.4 详细文档

- AI 设计与编码规范：[06-ai-strategy.md](./06-ai-strategy.md) §6
- 实现文件清单：见 §6.3

### 2.5.5 复盘与对局分析（2026-07 补充）

为分析 DouZero AI 决策合理性，新增 **三层对局分析能力**：

| 层次 | 实现 | 适用场景 |
|------|------|--------|
| **结算弹层 · 三方剩余手牌** | `_buildSettledOverlay` 展示按出牌顺序排列的三方剩余手牌（胜者标 ✦） | 一局结束快速查看 |
| **完整复盘 · ReplayScreen** | 逐帧重演整局：三方手牌状态 + 上家最近出牌 + ⏮⏪▶⏸⏩⏭ + 进度条 + 1x/2x/4x 倍速 | 深度复盘 AI 出牌逻辑 |
| **调试透视开关** | `debugToolsEnabledProvider`（总开关，设置页控制）+ `debugShowHandsProvider`（对家手牌正面显示，对局内眼睛按钮切换）。默认全关，开启后单机对局显示 AI 决策日志徽标 + 透视按钮 | 实时分析 AI 决策 |

**数据层**：
- `GameState.replayLog: List<ReplayStep>` 记录每步动作 + 应用前完整快照。
- `ReplayStep { phase, seat, kind, cards, snapshotBefore }`，`kind ∈ { deal, bid, bidSettle, play, pass }`。
- 4 个 `_apply*` 方法同步追加，零额外开销（不可变快照复用）。
- ReplayScreen 直接读 `snapshotBefore`，无需重放历史——O(1) 跳转任意帧。

**测试**：`test/core/replay_log_test.dart` 6 个用例，含「逐步重放：每步 snapshotBefore + 应用该步 = 下一步 snapshotBefore」的端到端一致性校验。

**已知设计权衡**：
- **snapshotBefore 体积**：每步存一份完整 GameState（含三方手牌），单局约 30-80 步 × ~10KB ≈ <1MB 内存。结算进入新一局时由 GC 自动回收，无累积问题。
- **调试工具默认关**：`debugToolsEnabledProvider` 控制调试图标（AI 徽标 + 透视按钮）是否出现；透视开关 `debugShowHandsProvider` 控制对家手牌是否正面显示。两者均默认关闭，需在设置页手动开启。

---

## 🟤 Phase 2.6 · 难度重构 + AI 对战 + 牌面美化 ✅ 已完成（2026-07）

### 2.6.1 难度体系三档重构

原四档（简单/普通/困难/极限）合并为三档，删除低意义的「弱化」难度：

| 难度 | 算法 | 实现类 | 变化 |
|------|------|--------|------|
| 简单 | 完整启发式 | `HeuristicAi` | 原 easy/normal 合并，策略升级（委托 RolloutPolicy） |
| 普通 | PIMC 蒙特卡洛 | `PimcAi`（samples=200） | 原 hard，采样数 30→200 |
| 困难 | DouZero ONNX | `DouZeroAi` | 原 douzero（极限） |

关键改动：
- `AiDifficulty` 枚举删除 `douzero`，重新映射 easy/normal/hard
- `HeuristicAi` 出牌阶段委托 `RolloutPolicy`（HandDecomposer 分解 + 剩余手数评估 + 农民协作），删除旧 `_leadPlay`/`_followPlay` 冗余代码
- 主菜单删除「极限」按钮

### 2.6.2 AI 对战引擎

`BattleEngine` + `BattleScreen`：自动运行 N 局 AI vs AI，统计胜率，保留每局回放。

- 5 个模型自由组合地主/农民：DouZero ADP/WP/SL + PIMC + 启发式
- `BattleConfig`（landlordModel / farmerModel / totalGames / seed）
- `BattleStats`（胜率 / 平均倍数 / 平均步数 / 每局回放详情）
- UI：模型选择 ChoiceChip + 局数滑块 + 进度条 + 胜率面板 + 复盘列表

### 2.6.3 牌面与 UI 改进

- 牌面重新设计为欢乐斗地主风格（左上数字+小花色、右下大花色、大小王竖向 JOKER）
- 复盘页面重构：控制条移入中部右侧（固定宽度），底部释放更多空间给牌面
- 对战按钮文字可见性修复

### 2.6.4 单机对局体验优化（2026-07 补充）

| 改进 | 说明 |
|------|------|
| **春天/反春天 UI** | `GameState` 新增 `isSpring`/`isAntiSpring` 字段，引擎命中时写入；结算面板显示粉色「🌸 春天 ×2」/「🌸 反春天 ×2」。`PlayerState.playCount` 追踪每座出牌轮数：春天=两农民 `playCount==0`；反春天=地主 `playCount==1`（仅出第一手）+ 另一农民 `playCount==0` |
| **出牌音效** | `SfxPlayer`（`lib/audio/sfx_player.dart`）：程序生成 WAV 音色（选牌 1200Hz / 出牌 800Hz / 炸弹低频扫频 / 火箭 / 胜利 C-E-G / 失败降调），`GameSession._applyAction` 统一触发 + HapticFeedback 触觉反馈 |
| **战绩得分** | `score = multiplier × (地主?2:1)`，地主胜负翻倍 |
| **设置页** | 新建 `SettingsScreen`：音效/震动/调试工具开关，主菜单新增设置入口 |
| **调试工具分级** | `debugToolsEnabledProvider`（总开关，控制 AI 徽标 + 透视按钮可见性）+ `debugShowHandsProvider`（透视开关，眼睛按钮切换），均默认关 |
| **手牌区优化** | 手牌尺寸 48×68 → 52×74；左右间距 8→16px，底部间距 8→2px；操作按钮缩小（padding 20→14 / fontSize 15→13 / 间距 12→8px） |
| **座位标签** | 出牌区 "座位 X 出" → "上家/下家/我"；对手信息栏显示 "上家 · 农民 X张" |
| **单机重开修复** | 主菜单点「开始游戏」时 `ref.invalidate(gameSessionProvider)` 强制重建，避免残留上一局结算画面 |
| **联机大厅优化** | 大陆/海外切换移至 AppBar；卡片紧凑布局，无滚动（键盘弹出时 SingleChildScrollView 兜底防溢出） |
| **对手上一手动作** | 对手手牌下方显示小牌面（重叠展示不限数量）或「过」，三方都能看到队友出了什么/是否 pass |
| **联机房间号显示** | NetGameScreen 左侧垂直居中显示房间号（RotatedBox，半透明），退出后仍可见 |
| **键盘防溢出** | 两层 Scaffold 均 `resizeToAvoidBottomInset: false`，聊天输入时游戏画面不缩放 |
| **聊天面板修复** | 移除面板内返回按钮（统一由游戏画面退出按钮处理）+ `OverflowBox(maxWidth:250)` + `ClipRect` 解决展开动画溢出 |

---

## 🔵 Phase 3 · 联网对战 ✅ 已完成

**方案**：Supabase Postgres + Realtime（房主权威模式，零服务端代码）。详见 [07-multiplayer-design.md](./07-multiplayer-design.md)。

### 3.1 交付物

| # | 项目 | 状态 | 说明 |
|---|------|:----:|------|
| 1 | Firebase RTDB 房间制 | ✅ | `RoomClient` 封装 createRoom/joinRoom/exitRoom，4 位房间码 |
| 2 | 房主权威状态机 | ✅ | `NetGameSession` 运行 GameEngine，广播公共状态 + 手牌同步 |
| 3 | 座位重映射 | ✅ | 本地玩家恒为显示座位 0，GameScreen 完全复用 |
| 4 | 文本聊天 | ✅ | `ChatOverlay` 悬浮面板（高度限 60%），显示发送者昵称 |
| 5 | 结算 + 三方手牌 | ✅ | 广播 `allHands`，所有设备显示真实手牌 |
| 6 | 复盘重建 | ✅ | 广播 `deckSeed` + `actionLog`，非房主本地重建完整 replayLog |
| 7 | 再来一局准备系统 | ✅ | 非房主点「准备」，房主全员准备后点「再来一局」 |
| 8 | 退出确认 + RTDB 清理 | ✅ | PopScope 确认对话框 + exitRoom 清座位/手牌/准备 |
| 9 | 玩家名显示 | ✅ | `PlayerState.name`，广播 `seatNicks`，对手卡片显示昵称 |
| 10 | 联网模式隐藏调试图标 | ✅ | `debugToolsEnabledProvider` 总开关（默认关），联网模式强制隐藏 AI 徽标/透视按钮 |
| 11 | Supabase 国内方案 | ✅ | `RoomClientBase` 抽象接口 + `SupabaseRoomClient` 实现 |
| 12 | 大陆/海外后端切换 | ✅ | 大厅 UI 切换按钮 + `netBackendProvider`，默认 Supabase（大陆） |
| 13 | Hybrid 实时架构 | ✅ | Broadcast (<50ms) + PostgresChanges (兜底)，出牌延迟从 250-400ms 降到 <50ms |
| 14 | 非房主乐观更新 | ✅ | 出牌后本地立即移除手牌（0ms 感知延迟），3 秒超时回滚 |
| 15 | 房间生命周期管理 | ✅ | 退出 loading / 结算页离开按钮 / App 被杀清理 / 房间自动删除 / 重连座位恢复 |
| 16 | 房主回声隔离 | ✅ | 房主 `_onGameState`/`_onMyHand` 跳过 PostgresChanges 回声，防止显示倒退 |
| 17 | 初始 SELECT 防过期 | ✅ | `updated_at` 时间戳比较，防止异步 SELECT 覆盖更新的 Broadcast 数据 |
| 18 | 语音群聊（LiveKit Cloud） | ✅ | 加入/离开语音 + 推麦 + 说话者检测 + 单人 1 分钟自删 + 断连自动重连（最多 3 次）+ 管理员密码管理房间 + **默认不自动建房间（手动加入）** |
| 19 | 重连体验完善 | ✅ | exitRoom 保留座位 UID + 手牌；RoomScreen 从 watchRoom 获取 isHost；exitRoom 不清手牌 |
| 20 | 玩家进出通知 | ✅ | ChatController 监听 seats online 变化 → 聊天框灰色系统消息 |
| 21 | Supabase stale room 清理 | ✅ | SQL 函数 `cleanup_stale_rooms()` SECURITY DEFINER 绕过 RLS + `ON DELETE CASCADE` 外键自动清理聊天记录 + cron 30 分钟 |
| 22 | AI 凑人（二缺一补位） | ✅ | 房主可添加 1 个 DouZero AI 玩家凑齐 3 人；AI 由房主设备驱动，不参与语音 |
| 23 | 乐观更新重构 | ✅ | `pendingCardIndices` 标记 pending 牌（不改 `_myHand`）；手牌灰显 35% + 禁用按钮；超时 3s→10s |
| 24 | 房主续局 | ✅ | 房主重进时从 RTDB 读取 `deckSeed` + `actionLog` → `_resumeFromRtdb()` 重放重建权威状态 |
| 25 | 出牌超时 30s + 托管 | ✅ | 仅房主运行 `_turnTimer`(30s)；广播 `turnDeadline`；超时进入托管（AI 接管直到玩家触摸退出）；对手显示 🤖 |
| 26 | 断线重连 | ✅ | Firebase `.info/connected` + onDisconnect 重注册；Supabase 10s 心跳（`last_seen`）+ channel subscribe 回调 |
| 27 | 联网战绩记录 | ✅ | 房主/非房主各自记录胜负（`StatsRecord.isOnline`）；战绩面板 🌐 图标 |
| 28 | 房主迁移 | ✅ | 房主离线 15s → 最小在线真人接管 → 重建引擎 + AI 托管旧房主 + pendingAction 回捞 |
| 29 | ready 系统修复 | ✅ | autoPlay/离线/AI 座位自动准备；房主座位用实际座位号（迁移后正确） |

### 3.2 未完成项（后续迭代）

#### ✅ P0 · 联网四项真机验证（已完成）

**乐观更新（pendingCardIndices）**

| # | 验证场景 | 预期结果 | 状态 |
|---|---------|---------|:----:|
| 1a | 非房主出合法牌 → 手牌灰显 → 房主确认 → 手牌更新 | 灰显 35% + 按钮禁用 → 确认后 pendingCardIndices 清空 | ✅ |
| 1b | 非房主出牌 → 房主拒绝/10s 超时 | 手牌恢复可选，pendingCardIndices 移除 | ✅ |
| 1c | 乐观更新期间（灰显中）禁点所有按钮 | 出牌/不出/提示 均不可点击 | ✅ |
| 1d | pendingCardIndices 序列化 → 广播 → 非房主反序列化 + 座位重映射 | 重映射后索引正确对应本地手牌 | ✅ |

**房主续局（_resumeFromRtdb）**

| # | 验证场景 | 预期结果 | 状态 |
|---|---------|---------|:----:|
| 2a | 房主退出 → 重进同一房间 → _hostInitOrResume 读 RTDB | deckSeed + actionLog 重放 → _authState 重建 | ✅ |
| 2b | 续局后房主继续出牌 → 广播 → 非房主同步 | 非房主无感知中断，游戏正常继续 | ✅ |
| 2c | 续局后 _scheduleTurnTimeout 恢复 | 超时定时器恢复运行 | ✅ |
| 2d | 无进行中对局时 _hostInitOrResume | 正常初始化新对局，不误触发续局 | ✅ |

**出牌超时 30s + 托管**

| # | 验证场景 | 预期结果 | 状态 |
|---|---------|---------|:----:|
| 3a | 房主轮到某人出牌 → 30s 无操作 → _onTurnTimeout | 进入托管，AI 接管出牌 | ✅ |
| 3b | 托管中 AI 连续多轮出牌 | AI 持续运行直到玩家退出托管 | ✅ |
| 3c | 玩家触摸屏幕/"托管中"文字 → disableAutoPlay → 操作栏恢复 | AI Timer 取消，按钮恢复可点 | ✅ |
| 3d | 非房主超时 → pendingAction(disableAutoPlay) → 房主处理 | 非房主也能退出托管 | ✅ |
| 3e | turnDeadline 广播 → 非房主 _TurnCountdownBadge 倒计时 | ≤10s 变红，跨设备同步 | ✅ |
| 3f | autoPlaySeats 序列化 → 广播 → 所有人看到 🤖 图标 | 座位重映射后正确显示 | ✅ |
| 3g | _startNewGame 清空 _autoPlaySeats | 新局不残留托管状态 | ✅ |
| 3h | dispose 时取消 _turnTimer | 无 Timer 泄漏 | ✅ |

**断线重连 + 在线状态**

| # | 验证场景 | 预期结果 | 状态 |
|---|---------|---------|:----:|
| 4a | Firebase 断网 → .info/connected=false → 恢复 → onDisconnect 重注册 | online 状态正确更新，回调重新生效 | ✅ |
| 4b | Supabase 断网 → channel error → 恢复 → 心跳恢复 | last_seen 更新恢复，channel 自动重连 | ✅ |
| 4c | 断线期间对手出牌 → 重连后 resync 同步最新状态 | 无丢失动作，phase=settled 正确获取 | ✅ |
| 4d | 设备 A 断网 → 设备 B 看到 A 离线（灰显 + cloud_off + 顶部通知） | 对手区域 Opacity 45% + 橙色图标 + 顶部 banner | ✅ |
| 4e | 设备 A 重连 → 设备 B 看到 A 恢复（绿色顶部通知） | 顶部 banner "XXX 重新连接了" | ✅ |
| 4f | Supabase stale seat 检测（last_seen > 30s → offline） | 杀进程后其他设备 30s 内检测到离线 | ✅ |

#### P1 · 功能完善

| # | 项目 | 说明 | 状态 |
|---|------|------|:----:|
| 5 | 联网战绩记录 | 房主/非房主各自记录自己的胜负结果（`StatsRecord.isOnline`）；战绩面板显示 🌐 图标 | ✅ |
| 6 | 房主迁移 | 房主离线 15s → 最小在线真人座位接管（写 `meta.hostUid`）→ 重建引擎 + AI 托管旧房主 + 回捞 pendingAction；旧房主重连降级为非房主 | ✅ |
| 7 | ready 系统修复 | autoPlay/离线/AI 座位自动准备；房主座位用实际座位号（迁移后正确） | ✅ |

#### P2 · 体验 / 后续

| # | 项目 | 说明 | 状态 |
|---|------|------|:----:|
| 8 | 规则变体 | `RuleVariant` 数据类参数化引擎（shuffle/bidMax/bombMultiplier/springEnabled）；经典/不洗牌预设；`GameState.ruleVariant` 随状态序列化；`StatsRecord.variantId` 向下兼容 | ✅ |
| 9 | 出牌动画 | `AnimatedSwitcher`(scale 0.5→1.0 `easeOutBack` + fade 500ms) 弹出；`AnimatedPositioned`(400ms `easeOutCubic`) 手牌收拢；`AnimatedOpacity`(300ms) 被压渐暗 | ✅ |
| 10 | 账号/社交 | Phase 4 范围 | ⬜ |
| 11 | 炸弹/火箭特效 | `TweenAnimationBuilder` 1.5s 径向渐变闪光（炸弹=橙 `bolt` / 火箭=紫 `local_fire_department`）+ 大字提示；`_checkBombEffect` 检测 `lastValidPlay` 变化 | ✅ |
| 12 | 发牌动画 | `_DealAnimation`(AnimationController 2000ms)：15 张牌轮发至三座位（每张 100ms `easeOut`），中央牌堆缩小，末尾淡出 | ✅ |
| 13 | 明牌（联网） | 仅联网 + 仅地主 + 成交后首出前；`BrightAction` + `brightSeats`；倍数 ×2；地主手牌通过 `brightHands` 广播给非房主 | ✅ |

---

## 🔵 Phase 3.1 · Firebase 移除 + 运行时配置 ✅ 已完成

**目标**：开源化准备——移除 Firebase（Supabase 单后端覆盖全球），消除硬编码凭证，支持用户自建后端配置。

### 3.1.1 交付物

| # | 项目 | 状态 | 说明 |
|---|------|:----:|------|
| 1 | Firebase 完全移除 | ✅ | 删除 5 个文件（firebase_options/firebase_init/google-services.json/firebase.json/database.rules.json）；pubspec 删 3 依赖；Gradle 删 gms 插件 + firebase-bom；room_client.dart 删 420 行 Firebase 实现 |
| 2 | NetBackend 枚举保留 | ✅ | `enum NetBackend { supabase }`（删 firebase 值，保留枚举以便未来扩展） |
| 3 | RTDB 序列化分支清理 | ✅ | `net_game_session.dart` 删 `lastMoveBySeat` 的 `List` 反序列化分支（仅保留 `Map`） |
| 4 | 大厅区域切换删除 | ✅ | `lobby_screen.dart` 删 `_buildRegionToggle` + `_regionChip`；`home_screen.dart` 删 backend 重置 |
| 5 | 运行时后端配置 | ✅ | `lib/core/app_config.dart`：Supabase URL/Key 存 SharedPreferences；`SupabaseService.ensureInitialized()` 从 AppConfig 读取（不再硬编码） |
| 6 | 后端配置页 | ✅ | `lib/ui/setup/config_screen.dart`：横排输入框（Label 130px + Expanded）+ 8 步完整指引（建表→部署 Edge Function→设 LiveKit Secrets）+ 作者配置警告横幅 |
| 7 | 联机入口检查 | ✅ | `home_screen.dart`：点联机 → `AppConfig.isConfigured` 检查 → 未配置弹引导 → 配置页 |
| 8 | 作者配置彩蛋 | ✅ | 主页连点标题 5 次 → 弹窗（已启用→清除 / 未启用→使用作者配置）；`AppConfig.useAuthorConfig()` / `AppConfig.clear()` |
| 9 | 设置页后端入口 | ✅ | `settings_screen.dart`：新增「后端服务」分区 + Supabase 配置入口（`Material` + `ListTile.shape` 避免 ink splash 遮挡） |
| 10 | 后端配置文档 | ✅ | `docs/12-backend-setup.md` 完全重写：去掉 Firebase，面向开源用户的 8 步配置指南 + 故障排查 + 检查清单 |

### 3.1.2 技术决策

- **移除 Firebase 的判断依据**：Supabase Postgres + Realtime 已覆盖全球（Singapore 节点大陆/海外均可），Firebase RTDB 的延迟优势不足以支撑双后端的维护复杂度。移除后消除 `google-services.json` 构建时依赖，为运行时配置扫清障碍
- **NetBackend 枚举保留**：`enum NetBackend { supabase }` 仅保留单值，但保留枚举模式 + `netBackendProvider`，以便未来新增后端（如自建服务器）时代码改动最小化
- **RoomClientBase 抽象保留**：虽然只剩一个实现（`SupabaseRoomClient`），保留抽象接口方便测试 mock + 未来扩展
- **AppConfig 设计**：`supabaseUrl` / `supabaseAnonKey` / `isAuthorConfig` 三字段存 SharedPreferences；`isConfigured` getter 供 UI 层快速判断；`useAuthorConfig()` 静态方法写入作者默认值 + 标记 `isAuthorConfig: true`；用户手动保存时 `isAuthorConfig` 自动清 `false`
- **Supabase.initialize 一次性约束**：App 启动时不初始化（单机零网络）；联机入口检查配置 → 已配置 → `SupabaseService.ensureInitialized()` → 进大厅；首次保存配置后立即初始化；修改配置需重启 App（极低频操作，可接受）
- **作者配置彩蛋**：连点标题 5 次检查 `isAuthorConfig` → 已启用弹「清除」对话框（红色）/ 未启用弹「使用作者配置」对话框（琥珀色）；配置页 `isAuthorConfig == true` 时顶部显示橙色警告横幅；用户手动修改保存后标记自动清除
- **配置页横排布局**：横屏 640×360 紧凑屏，Label + 输入框纵向排列会遮挡折叠指引；改为 `Row`（Label `SizedBox(width:130)` + `Expanded(TextField)`），两个 Label 宽度一致

### 3.1.3 变更清单

**删除文件（5 个）**：
- `lib/firebase_options.dart`、`lib/firebase_init.dart`、`android/app/google-services.json`、`firebase.json`、`database.rules.json`

**新建文件（2 个）**：
- `lib/core/app_config.dart`（运行时配置数据类）
- `lib/ui/setup/config_screen.dart`（后端配置页）

**修改文件**：
- `lib/net/room_client.dart`（重写：删 Firebase 实现，保留枚举 + 简化 provider）
- `lib/supabase_init.dart`（从 AppConfig 读取，不硬编码）
- `lib/ui/home/home_screen.dart`（联机检查 + 彩蛋）
- `lib/ui/settings/settings_screen.dart`（后端配置入口）
- `lib/ui/lobby/lobby_screen.dart`（删区域切换）
- `lib/ui/lobby/net_game_screen.dart`（删 isSupabase 判断，语音恒注入）
- `lib/net/net_game_session.dart`（删 RTDB List 分支）
- `pubspec.yaml`（删 firebase_*）
- `android/app/build.gradle.kts`（删 gms 插件 + firebase-bom）
- `android/settings.gradle.kts`（删 FlutterFire 块）
- `docs/12-backend-setup.md`（完全重写）

### 3.3 技术决策

- **Supabase Postgres + Realtime**：单后端（Phase 3.1 移除 Firebase），`RoomClientBase` 抽象接口统一，`NetBackend` 枚举保留以便扩展
- **房主权威模式**（非服务端权威）：信任模型，适合好友休闲
- **手牌按座位存**（非按 UID）：避免房主写其他玩家手牌时的权限问题
- **沉浸式全屏**：`SystemUiMode.immersiveSticky`，横屏最大化显示范围
- **Supabase Hybrid 实时架构**：Broadcast (<50ms) 为主通道 + PostgresChanges (50-200ms) 兜底，出牌延迟从 250-400ms 降到 <50ms
- **非房主乐观更新**：出牌后本地立即移除手牌（0ms 感知），3 秒超时回滚兜底非法出牌
- **房主 PostgresChanges 回声隔离**：房主 `_authState != null` 时跳过 DB 回声重建，始终用本地权威引擎输出
- **房间生命周期全链路**：退出 loading 防重复 + 结算页离开按钮 + `detached` best-effort 清理 + 在线玩家检查删房 + UID 重连座位恢复
- **语音群聊（LiveKit Cloud）**：开源 WebRTC 平台，Toggle 推麦模式，Edge Function 签发 Token + CreateRoom(empty_timeout=60s)。备选 Agora 声网（大陆延迟更低但闭源）
- **重连数据保留**：`exitRoom` 仅标记 `online: false`（保留 UID + 手牌），`joinRoom` 通过 UID 匹配恢复原座位 + `watchMyHand` 拿回手牌
- **isHost 动态判定**：`RoomScreen` 从 `watchRoom` snapshot 实时获取 `isHost`（`meta.hostUid == uid`），不依赖构造函数传入值
- **AI 凑人**：房主设备运行 DouZero AI（`_maybeScheduleAi` + `_runAiTurn`），AI 动作走 `_hostProcessAction` 管道与人类动作统一处理；AI 不参与语音/聊天；仅允许 1 AI（二缺一场景）
- **单机重开**：主菜单 `ref.invalidate(gameSessionProvider)` 强制重建 provider，确保每次进入都是新对局（非残留结算画面）
- **调试工具分级控制**：`debugToolsEnabledProvider`（总开关，默认关）控制调试图标可见性 → `debugShowHandsProvider`（子开关）控制对手手牌透视；关闭总开关自动联动关闭透视
- **音效无文件方案**：`SfxPlayer` 用 Dart 程序生成 WAV PCM 字节（正弦波 + 包络 + 频率扫描），`audioplayers.BytesSource` 播放，零外部音频文件依赖
- **AI 玩家不保活房间**：`leaveRoom`/`exitRoom` 检查在线真人时跳过 `isAI` 座位，避免仅剩 AI 的房间永不清理
- **过期房间无条件清理**：`cleanup_stale_rooms()` 以 `updated_at` 超 30 分钟为唯一判据，不检查 seats 在线状态（强杀/关机残留的 online 标记不可信）；`SECURITY DEFINER` 绕过 RLS；`room_chat.room_id` 加 `ON DELETE CASCADE` 外键，删房间自动级联删聊天
- **LiveKit 房间三层清理**：① 单人 1 分钟自删（客户端监听 `remoteParticipants == 0` → 60s 定时器 → 调 Edge Function DeleteRoom）；② 管理员密码手动删（设置页 → LiveKit 管理 → 密码验证 → 列表/删除）；③ cron 清理 Supabase 房间时同步删 LiveKit（`exitRoom` 自动调用 `deleteLiveKitRoom`）
- **LiveKit 断连自动重连**：`_onRoomUpdate` 检测 `ConnectionState.disconnected` → 5s 延迟 → `fetchToken` → `ensureRoom`（409 复用 / 新建）→ 重连同一房间名的新 Session；最多 3 次，首次连接失败不重试
- **语音加入/离开 UI**：`VoiceControls` 组件 = [加入/离开耳机按钮] + [推麦按钮（仅语音中显示）]；离开/加入弹窗确认防误触
- **对手上一手动作展示**：`GameState.actedSeats: Set<int>` 跟踪本轮已行动座位；`_buildOpponentLastAction` 在对手手牌下方显示小牌面（重叠 8px）或「过」；联网模式序列化 `actedSeats` + `lastMoveBySeat` 广播（key 为 string 适配 JSON）
- **Edge Function 统一入口**：`get-voice-token` 支持正常 Token 签发 + 管理员操作（`verify-password` / `list` / `delete` / `delete-all`）；管理员操作需 `ADMIN_PASSWORD` Secret，自动清理免密码
- **LiveKit 数据解析**：LiveKit protobuf JSON 使用 snake_case（`creation_time` / `num_participants`）+ int64 可能以 string 返回；`_parseInt` 统一处理 int/string 两种格式
- ~~**语音仅限 Supabase 后端**~~（Phase 3.1 后 Firebase 已移除，语音恒可用）
- ~~**Firebase RTDB 序列化兼容**~~（Phase 3.1 后已移除，仅保留 Map 格式）
- **键盘防溢出**：两层 Scaffold（GameScreen + NetGameScreen）均设 `resizeToAvoidBottomInset: false`，聊天输入时游戏画面不缩放
- **游戏画面自适应布局**：`_buildHumanArea` 包裹在 `Expanded` 中获得有界高度，内部按钮栏与手牌之间的间距改用 `Flexible(loose, max=12)` — 空间充足时间距 12px，空间紧张（如联网多出"等待"文本）间距自动缩小，任何屏幕尺寸不溢出
- **反春天判定修复**：`PlayerState.hasPlayed`(bool) → `playCount`(int) 追踪出牌轮数。旧逻辑检查 `!landlord.hasPlayed`，但地主必须先出第一手牌，导致反春天永不触发。新逻辑：反春天 = 农民胜 + 地主 `playCount==1`（仅出第一手）+ 另一农民 `playCount==0`
- ~~**默认区域改为大陆**~~（Phase 3.1 后仅 Supabase 单后端，无需区域切换。`RegionDetector` 简化为仅检测网络连通性）
- **乐观更新重构（pendingCardIndices）**：非房主出牌后不再修改 `_myHand`，改用 `GameState.pendingCardIndices: Set<int>` 标记 pending 牌。UI 层手牌灰显 35% + 禁用所有按钮（出牌/不出/提示）。超时 3s→10s 给房主更宽裕的处理窗口。确认后 `pendingCardIndices` 清空；回滚时恢复手牌
- **房主续局（_resumeFromState）**：房主中途退出后重新进入时，`_hostInitOrResume()` 从数据库读取 `deckSeed` + `actionLog`，重放所有动作重建 `_authState`，恢复房主权威模式继续对局
- **出牌超时 30s + 托管模式**：仅房主运行 `_turnTimer`（30s）；`_turnDeadline`(UTC ms) 广播给所有客户端，`_TurnCountdownBadge` 显示倒计时（≤10s 变红）。超时后 `_autoPlaySeats.add(seat)` → AI 持续接管（复用 `_runAiTurn`），不再是单次自动出牌。玩家触摸屏幕退出托管（`disableAutoPlay()` → 移除座位 + 广播）
- **断线重连**：Supabase 10s 心跳（`last_seen` 字段）+ channel `subscribe` 回调检测连接状态变化。重连后 `resync()` 强制 re-SELECT 最新数据
- **超时调度顺序关键**：`_scheduleTurnTimeout()` 必须在 `_buildDisplayFromAuth()` + `_syncThenBroadcast()` **之前**调用，否则 `state` 赋值后 Timer 在错误的 state 上操作
- **座位在线状态（seatOnline）**：`GameState.seatOnline: List<bool>` 追踪各座位在线状态；`NetGameSession` 订阅 `watchRoom` 获取 seat online 变化 → 座位重映射后注入 display state；UI 层对手离线时 `Opacity(0.45)` 灰显 + `cloud_off` 图标 + 顶部 banner 通知（`addPostFrameCallback` 避免 build 冲突）
- **Supabase stale seat 检测**：无 `onDisconnect` 原语，改用 `_applyStaleCheck()` 在每次 PostgresChanges/Broadcast/resync 回调中检查 `last_seen > 30s` → 强制 `online: false`，解决杀进程后无人标记离线的问题
- **wasConnected 防刷屏**：Supabase channel `channelError` 会持续重试（~10s 间隔），`wasConnected` 标志确保断线后 `setOnline(false)` 只调用一次，避免无限报错
- **手牌区溢出修复**：`_buildHumanArea` 内层 `SingleChildScrollView(neverScrollable, reverse: true)` + `ClipRect` 替代 `Column(mainAxisSize.max)`，内容超出时裁剪顶部而非触发 RenderFlex 断言
- **联网战绩记录**：`StatsRecord.isOnline` 区分单机/联网；房主在 `_hostProcessAction` 结算时记录（含 `_turns` 计数器）；非房主在 `_onGameState` 检测 `phase=settled` 时从 `actionLog` 估算 turns 并记录；`_settleRecordedForSeed` 幂等保护防重复；战绩面板显示 🌐 图标标识联网对局
- **最小化房主迁移**：房主离线 > 15s → `_checkHostMigration()` 启动迁移 → `_performMigration()` 选最小在线真人座位写 `meta.hostUid`（确定性候选，唯一写入者，无竞争）→ `_activateHost()` 重建引擎 + 标记离线座位为 autoPlay + 回捞 pendingAction → `_deactivateHost()` 旧房主恢复时降级（取消定时器/引擎）。`_isHost` 替代 `_ctx.isHost`（可变），所有引用统一
- **ready 系统修复**：`readySeats` getter 中 autoPlay/AI/离线座位自动准备，不阻塞再来一局；房主座位用 `_ctx.mySeat` 而非硬编码 seat 0（迁移后正确）
- **语音手动加入**：`VoiceChatController.build()` 不再自动 `_connect(roomId)`，初始 `inVoiceRoom: false`；用户点击琥珀色耳机按钮 → 确认 → `reconnect()` 才建 LiveKit 房间。节约 WebRTC 分钟（进游戏画面不点语音 = 零消耗）；战绩筛选器改为 经典/不洗牌/联机/全部（默认经典）
- **RuleVariant 参数化引擎**：`GameEngine` 消除魔法数字（叫分上限 `bidMax`、炸弹倍率 `bombMultiplier`、春天开关 `springEnabled`），全部从 `state.ruleVariant` 读取；预设 `classic`/`noShuffle`；`GameMode` enum 废弃，改用 `ruleVariantProvider`（`StateProvider<RuleVariant>`）；`StatsRecord.noShuffle: bool` → `variantId: String?`（向下兼容旧记录）
- **出牌动画方案 B（原位缩放淡入）**：640×360 紧凑屏飞行距离极短，Overlay 飞行 ROI 低。改用 `AnimatedSwitcher`(scale 0.5→1.0 + fade) 出牌弹出 + `AnimatedPositioned`(`ValueKey(card.index)` 确保正确 diff) 手牌收拢 + `AnimatedOpacity` 被压渐暗。`_buildOpponentLastAction` + `_buildHumanLastAction` 合并为统一 `_buildLastActionArea(state, seat, {fallbackAvail})`
- **炸弹/火箭全屏特效**：`_checkBombEffect()` 追踪 `lastValidPlay` 变化 → 检测 `pattern.type.isBombLike` → `_buildBombOverlay` 全屏 `TweenAnimationBuilder`(1.5s)：0~25% 闪入 + 25~75% 保持 + 75~100% 闪出；径向渐变（炸弹=橙/火箭=紫）+ 图标 + 大字
- **发牌动画**：`_DealAnimation`(StatefulWidget + `SingleTickerProviderStateMixin`)，15 张牌轮发（card i → seat `i%3`），每张间隔 100ms，总 2000ms（发牌 1500ms + 淡出 300ms）；中央牌堆随进度缩小；牌背用 `CardSizes` medium（42×60）
- **明牌仅联网+仅地主**：单机模式纯斗地主（DouZero WP 模型未训练明牌/赖子等变体规则，单机明牌仅影响计分无策略价值）；联网模式仅地主在成交后首出前（`phase=playing && lastValidPlay==null`）可点"明牌×2"按钮 → `BrightAction` → `multiplier *= 2` + `brightSeats.add(seat)`；地主手牌通过广播 `brightHands` 字段传输给非房主客户端（房主 `_buildDisplayFromAuth` 直接从 `_authState` 取真实手牌）

---

## 🟣 Phase 4 · 社交与生态

**范围**：账号体系、社交、长期可玩性。

### 4.1 候选特性

- 账号（手机/邮箱/第三方登录）
- 好友列表、邀请好友
- 排行榜（赛季制）
- 段位/积分赛
- 赛事与观战
- 商店（皮肤/牌背，纯装饰、不影响公平）

### 4.2 商业化（若转向）

- 仅做**装饰性付费**（牌背、特效、表情）。
- 永不做「影响胜负」的付费（保护公平）。

---

## 跨阶段约定

- **每个 Phase 结束**：更新本文档勾选状态 + 对应详细设计文档。
- **架构债**：若 Phase 中发现某抽象不合适，先记入「已知限制」，下个 Phase 集中重构，不在 MVP 中途大改。
- **测试覆盖率**：`core/` 始终保持高位（>85%），AI 关键路径必须有断言用例。
