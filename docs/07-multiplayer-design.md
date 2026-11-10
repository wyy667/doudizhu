# 07 · 联网对战设计（Phase 3 · Firebase + Supabase 双后端）

> **⚠ 现状（2026-11）**：联机已改为**局域网模式**——房主设备运行 `LanRoomServer`（WebSocket + UDP 广播发现），
> 对局逻辑仍复用本文的房主权威 `NetGameSession`；空位与掉线玩家由房主设备上的 DouZero 人机代打。
> 详见 [`03-project-structure.md`](./03-project-structure.md) 的 `lib/net/lan/` 与 README「局域网联机」。下文为云端方案的历史设计。
>
> **方案**：双后端共存——Firebase RTDB（海外）+ Supabase Postgres + Realtime（国内），房主权威模式，零服务端代码。
> **状态**：✅ 已完成并真机验证。Supabase 方案采用 Hybrid 实时架构（Broadcast + PostgresChanges）+ 乐观更新，出牌同步延迟 <50ms。

## 1. 架构

```
┌─ Flutter App ──────────────────────────────────────────────┐
│                                                             │
│  GameScreen  ← gameSessionProvider（单机/联网无感知）       │
│       │                                                     │
│       ├─ GameSession（单机）                                │
│       └─ NetGameSession（联网，ProviderScope override）     │
│             │                                               │
│             ├─ 房主：GameEngine 权威 + RTDB 广播            │
│             └─ 非房主：RTDB 监听 + 动作提交                 │
│                                                             │
│  RoomClient ──── Firebase RTDB ──── 其他客户端              │
│  ChatController ─ Firebase RTDB ──── 聊天消息同步           │
└─────────────────────────────────────────────────────────────┘
```

### 房主权威模式

| 角色 | 职责 |
|------|------|
| **房主**（座位 0） | 运行 `GameEngine`（validate + apply），处理所有玩家动作，广播公共状态到 RTDB，分发每人手牌，记录复盘数据 |
| **非房主**（座位 1/2） | 从 RTDB 读取自己的手牌和公共状态，提交动作到 RTDB `pendingAction` 节点 |

防作弊：RTDB 安全规则限制 `auth != null` 才可读写。房主校验所有动作合法性。房主理论上有能力作弊（信任模型），适合好友休闲场景。

## 2. RTDB 数据结构

```
rooms/$roomId/
  meta/            {hostUid, chatEnabled, status, createdAt}
  seats/           {0:{uid,nick,online}, 1:{...}, 2:null}
  game/            {phase, currentPlayer, landlordSeat, handCounts, multiplier,
                    lastPlaySeat, lastPlayCards, lastPlayType, lastPlayMainRank,
                    passCount, winnerSeat, bidParticipants, currentMaxBid,
                    bottomCards, seatNicks,
                    [settled 时附加] deckSeed, actionLog, allHands}
  hands/0/         [cardIndex, ...]      ← 按座位存手牌（房主写入）
  hands/1/
  hands/2/
  pendingAction/   {bySeat, type, ...}   ← 非房主写入，房主读取后清除
  ready/           {0:true, 1:true, 2:false}  ← 再来一局准备状态
  chat/$pushId/    {bySeat, nick, text, ts}
```

### 关键设计决策

| 决策 | 原因 |
|------|------|
| 手牌按座位存（`hands/$seat`）而非按 UID | 房主需要写入所有玩家的手牌，按 UID 隔离会导致权限不足 |
| 手牌在 `rooms/` 下而非顶级 `hands/` | 简化安全规则：`rooms/$roomId` 统一 `auth != null` 可读写 |
| 结算时广播 `allHands` + `deckSeed` + `actionLog` | 让所有设备显示三方真实手牌 + 完整复盘重建 |
| RTDB 数字键自动转数组 | 代码兼容 `Map` 和 `List` 两种返回格式 |

## 3. 客户端文件结构

```
lib/
├── net/
│   ├── protocol.dart            RTDB 路径常量 + 数据模型（RoomMeta/SeatInfo/ChatMessage）
│   ├── room_client.dart         RTDB 操作封装（createRoom/joinRoom/exitRoom/watch*/submit*）
│   └── net_game_session.dart    联网会话（extends SessionNotifier）
├── chat/
│   └── chat_controller.dart     聊天 Riverpod 状态
├── state/
│   └── game_session.dart        SessionNotifier 基类 + GameSession（单机）
├── ui/
│   ├── lobby/
│   │   ├── lobby_screen.dart    创建/加入房间（左右并排布局）
│   │   ├── room_screen.dart     等待室（座位展示 + 玩家名 + 开始按钮 + 自动跳转）
│   │   └── net_game_screen.dart 联网对局（ProviderScope override + PopScope 退出确认）
│   └── chat/
│       └── chat_overlay.dart    悬浮聊天面板（高度限 60%，不遮挡手牌）
├── firebase_init.dart           Firebase 初始化
├── firebase_options.dart        flutterfire CLI 生成
└── main.dart                    入口（初始化 Firebase + 沉浸式全屏）
```

### SessionNotifier 基类

```dart
abstract class SessionNotifier extends Notifier<GameState> {
  void bid(int score);
  void play(List<Card> cards);
  void pass();
  void newGame();

  // 联网模式属性（默认单机行为）
  bool get isOnlineMode => false;
  bool get isHost => true;
  List<bool> get readySeats => [true, true, true];
  bool get amReady => true;
  void toggleReady() {}
}
```

### 座位重映射

`NetGameSession._buildDisplayState` / `_buildDisplayFromAuth` 将本地玩家重映射到显示座位 0：

```
实际座位 → 显示座位: (actualSeat - mySeat + 3) % 3
```

### 手牌同步流程

```
玩家出牌 → _submitAction
  ├─ 房主: _hostProcessAction
  │    ├─ _authState = engine.apply(state, action)
  │    ├─ _myHand 从 _authState 同步
  │    ├─ state = _buildDisplayFromAuth()    ← 立即更新显示
  │    └─ _syncThenBroadcast()               ← 先写手牌，再写状态
  │         ├─ _syncAllHands()               ← 3 个座位的最新手牌写 RTDB
  │         └─ _broadcastState()             ← 公共状态写 RTDB
  └─ 非房主: client.submitAction → RTDB pendingAction
       └─ 房主 watchPendingAction → _hostProcessAction
```

### 结算与复盘

- 房主 `_authState.replayLog` 包含完整对局记录
- 结算广播附加 `deckSeed` + `actionLog`（JSON 序列化的动作序列）
- 非房主收到后用 `Deck.deal(seed)` + 重放动作重建 `replayLog`
- 结算时广播 `allHands`，所有设备显示三方真实手牌

### 再来一局准备系统

```
结算画面:
  ├─ 非房主: 显示「准备」按钮 → toggleReady() → RTDB ready/$seat = true
  ├─ 房主: 显示「再来一局」按钮（全员准备后可点）
  │    ├─ 检查 readySeats.every((r) => r)（座位 0 恒 true）
  │    └─ _startNewGame() → 清除 ready → 发牌 → 广播
  └─ 房主看到准备进度「2/3」
```

### 退出与清理

- `NetGameScreen` 加 `PopScope`：弹出「离开房间」确认对话框
- 确认后调用 `RoomClient.exitRoom(roomId, seat)`：
  - 清除座位 `seats/$seat`
  - 清除手牌 `hands/$seat`
  - 清除准备状态 `ready/$seat`
  - 房间空了自动删除
- 单机模式 `GameScreen` 加 `PopScope`：弹出「退出游戏」确认

## 4. Firebase 配置步骤

### 4.1 创建 Firebase 项目

1. 访问 [Firebase Console](https://console.firebase.google.com/)
2. 创建新项目（如 `landlord`）
3. 添加 Android 应用（包名 `com.swm.landlord`）

### 4.2 启用服务

1. **Authentication** → 启用「匿名」登录
2. **Realtime Database** → 创建数据库（区域选 `us-central1` 或 `asia-southeast1`）
3. 规则 → 粘贴 `database.rules.json` 的内容：

```json
{
  "rules": {
    "rooms": {
      "$roomId": {
        ".read": "auth != null",
        ".write": "auth != null"
      }
    }
  }
}
```

### 4.3 安装 CLI 并配置

```bash
# 安装 Firebase CLI
npm install -g firebase-tools
firebase login

# 安装 FlutterFire CLI
dart pub global activate flutterfire_cli

# 在项目目录运行
flutterfire configure
# → 选择你的 Firebase 项目
# → 自动生成 lib/firebase_options.dart
```

### 4.4 依赖

`pubspec.yaml` 已包含：

```yaml
dependencies:
  firebase_core: ^3.x
  firebase_database: ^11.x
  firebase_auth: ^5.x
```

## 5. 免费额度（Spark Plan）

| 资源 | 免费额度 | 说明 |
|------|---------|------|
| 同时连接 | 200 | 3 人 × ~60 房间 |
| 存储 | 1 GB | 每局 <10 KB |
| 月下载 | 10 GB | 日活 <500 无压力 |

> **注意**：中国大陆地区 Firebase 访问可能不稳定，需要科学上网或考虑替代方案（详见 §7）。

## 6. 断线处理

- RTDB `onDisconnect` 原语：玩家断线时自动标记 `online: false`
- 客户端自动重连（Firebase SDK 内建）
- 重连后自动接收最新的 `game/` 和 `hands/$seat/` 状态

## 7. 已知限制与后续方向

| 局限 | 后续方案 |
|------|---------|
| Firebase 在中国大陆完全不可用 | ✅ 已新增 Supabase 方案（见 §8） |
| 房主权威（信任模型） | 迁移到 Cloud Functions 或 Dart 服务端 |
| 无 AI 代打 | 断线超时后房主可指定 AI 补位 |
| 无观战 | 新增 `spectators/` 节点（只读） |
| 无语音通话 | 方案设计完成（WebRTC P2M / Agora SDK / 腾讯 TRTC），待实施 |
| 房间无密码 | meta 加 `password` 字段 |
| 房主退出后游戏中断 | 房主迁移机制（选出新房主） |

## 8. Supabase 国内方案

> **背景**：Firebase 在中国大陆完全被墙。Supabase 作为开源替代方案，服务器可选 Singapore 节点，WebSocket 连接不被封锁。

### 8.1 架构

```
客户端自动检测后端
├─ 海外 → Firebase RTDB（房主权威）
└─ 国内 → Supabase Postgres + Realtime（房主权威）
```

两套实现共用 `RoomClientBase` 抽象接口，`NetGameSession` / `ChatController` / UI 层完全无感知。

### 8.2 数据结构（Postgres 表）

```sql
-- rooms 表：每个房间一行
rooms (
  room_id TEXT PRIMARY KEY,
  host_uid TEXT, chat_enabled BOOL, status TEXT, created_at BIGINT,
  seats JSONB,           -- [{uid,nick,online}, null, null]
  game_state JSONB,      -- 房主广播的公共游戏状态
  pending_action JSONB,  -- 非房主提交的动作
  ready JSONB,           -- [false, false, false]
  hands JSONB,           -- {"0":[cards], "1":[...], "2":[...]}
  updated_at BIGINT
)

-- room_chat 表：聊天消息
room_chat (
  id BIGSERIAL PRIMARY KEY,
  room_id TEXT, by_seat INT, nick TEXT, text TEXT, ts BIGINT
)
```

SQL schema 完整文件：`supabase/schema.sql`

### 8.3 实时同步（Hybrid 架构）

Supabase 提供三种 Realtime 模式，本方案采用 **Broadcast + PostgresChanges** 双通道 Hybrid 架构：

| 模式 | 延迟 | 经过 DB | 本方案用途 |
|------|------|---------|-----------|
| **Broadcast** | **<50ms** | ❌ 纯 WebSocket | ✅ 实时状态同步（出牌/手牌/game_state） |
| PostgresChanges | 50–200ms | ✅ WAL 逻辑复制 | ✅ 兜底/重连恢复（保证最终一致性） |
| Presence | <100ms | ❌ CRDT | 未使用（座位通过 seats JSONB 管理） |

> 来源：[Supabase Realtime in Production (2026)](https://www.agilesoftlabs.com/blog/2026/05/supabase-realtime-in-production-what) — Broadcast 典型 <50ms，PostgresChanges 50–200ms。

#### 数据流对比

```
旧方案（纯 PostgresChanges）:
  写 DB (RTT ~200ms) → WAL 解析 (50-200ms) → PostgresChanges 推送 → 客户端收到
  总延迟: 250-400ms

新方案（Hybrid）:
  写 DB (RTT ~200ms) ──────────────────────────────→ PostgresChanges 兜底
   └→ Broadcast 推送 (<50ms) → 客户端立即收到         (50-200ms 后到达，幂等合并)
  实时延迟: <50ms
```

#### Broadcast 工作原理

每个房间创建一个 Broadcast channel（`room_bc:$roomId`，`self: false`）：

1. **写入方**（房主/非房主）写完 DB 后，调用 `_broadcastChanges(roomId, partialChanges)` 发送变更字段
2. **接收方**收到 broadcast payload → `cached.addAll(changes)` 合并到缓存行 → 通过 `rowController` 发射完整行
3. 所有 watch 方法（`watchGameState` / `watchMyHand` / `watchPendingAction` / `watchReady`）从同一个 `rowController` 转换数据，无需关心数据来源

**关键设计**：
- `self: false` — 发送方不收到自己的广播（本地已更新，避免冗余）
- Partial changes — 只广播变更字段（如 `{game_state: {...}, hands: {...}}`），客户端 merge 到缓存
- 幂等合并 — PostgresChanges 随后到达时用完整行覆盖缓存，数据一致不闪烁
- **重连恢复** — Broadcast 消息不持久化；断线重连后 `_ensureRoomChannel` 的初始 SELECT 恢复完整状态，PostgresChanges 接续后续更新

#### Firebase 方案对比

| 操作 | Firebase RTDB | Supabase (Hybrid) |
|------|---------------|-------------------|
| 数据变更通知 | `onValue`（纯 WebSocket，~30ms） | Broadcast（<50ms）+ PostgresChanges（兜底） |
| 数据写入 | `ref.set()` / `ref.update()` | `.from('rooms').update()` + `sendBroadcastMessage` |
| 延迟 | ~30ms（RTDB 天然低延迟） | <50ms（Broadcast） / 50-200ms（PostgresChanges 兜底） |
| 匿名登录 | `FirebaseAuth.signInAnonymously()` | `supabase.auth.signInAnonymously()` |
| 安全规则 | `database.rules.json` | RLS Policy（authenticated 可读写） |

> Firebase RTDB 本身就是纯 WebSocket 推送（不经 WAL），天然低延迟，无需额外优化。Supabase 的 Broadcast 模式使其达到接近 RTDB 的延迟水平。

### 8.4 客户端代码结构

```
lib/
├── net/
│   ├── room_client_base.dart         抽象接口（RoomClientBase）
│   ├── room_client.dart              Provider 定义 + NetBackend 枚举
│   └── supabase_room_client.dart     Supabase 实现
├── supabase_init.dart                Supabase 初始化（从 AppConfig 读取）
├── supabase/
│   ├── schema.sql                   建表 + RLS + Realtime（在 Dashboard 执行）
```

### 8.5 Supabase 配置步骤

1. 访问 [supabase.com](https://supabase.com) 创建项目（区域选 **Singapore**）
2. SQL Editor → 执行 `supabase/schema.sql`
3. Authentication → Providers → 启用 **Anonymous**
4. Project Settings → API → 复制 URL 和 publishable_key
5. 填入 `lib/supabase_init.dart` 的 `supabaseUrl` 和 `supabaseKey`
6. 在 `lib/net/room_client.dart` 中设置 `backendMode = NetBackend.supabase;`

### 8.6 免费额度

| 资源 | 免费额度 | 说明 |
|------|---------|------|
| 数据库 | 500 MB | 每局 <10 KB |
| Realtime 连接 | 200 并发 | 3 人 × ~60 房间 |
| 认证用户 | 50,000 MAU | 匿名登录 |
| 带宽 | 5 GB/月 | 小型应用足够 |

### 8.7 非房主乐观更新（Optimistic UI v2）

**问题**：非房主出牌后，需经过 `submitAction → 房主处理 → batchUpdate → Broadcast` 链路才能看到 UI 变化，感知延迟 200ms+。

**方案（pendingCardIndices 标记法）**：非房主 `play()` 时本地**不修改** `_myHand`，而是将出的牌索引写入 `GameState.pendingCardIndices: Set<int>`，UI 据此灰显：

```
玩家点击出牌
  ├─ 标记 pending（0ms）：pendingCardIndices = {索引...}
  │    ├─ 手牌灰显 35% + 缩小
  │    └─ 所有按钮禁用（出牌/不出/提示）
  ├─ 异步提交：submitAction → Broadcast → 房主处理 → batchUpdate → Broadcast 回传
  └─ 确认/回滚：
       ├─ _onMyHand 收到权威手牌 → pendingCardIndices 清空（合法出牌，手牌自然更新）
       └─ 10 秒超时未确认 → 回滚（移除 pendingCardIndices，手牌恢复可选）
```

**与 v1 的差异**：
- v1 直接修改 `_myHand`（快照 + 移除）→ 复杂的快照管理 + 回滚逻辑
- v2 使用 `pendingCardIndices` 标记 → `_myHand` 始终是权威值，灰显仅影响外观
- 超时从 3s → 10s（给房主更宽裕的处理窗口，尤其跨区域网络延迟）

### 8.8 客户端文件结构（Supabase 补充）

```
lib/
├── net/
│   ├── room_client_base.dart         抽象接口（RoomClientBase，含 batchUpdate）
│   ├── room_client.dart              Provider 定义 + NetBackend 枚举
│   ├── supabase_room_client.dart     Supabase 实现（Hybrid: Broadcast + PostgresChanges）
│   └── net_game_session.dart         联网会话（房主权威 + 非房主乐观更新 + 座位重映射）
├── supabase_init.dart                Supabase 初始化（从 AppConfig 读取）
├── supabase/
│   ├── schema.sql                   建表 + RLS + Realtime（在 Dashboard 执行）
```

### 8.9 房主 PostgresChanges 回声隔离

**问题**：房主写 DB 后，PostgresChanges 会在 50-200ms 后回声通知房主自身。如果房主在此期间已处理新动作（`_authState` 已更新），回声会用旧数据覆盖显示，造成画面「倒退」。

**修复**：`_onGameState` 和 `_onMyHand` 在 `_authState != null` 时跳过状态重建：

```dart
void _onGameState(Map<dynamic, dynamic>? data) {
  if (data == null) return;
  _lastStateData = data;
  if (_authState != null) return;  // 房主用 _buildDisplayFromAuth 权威显示
  state = _buildDisplayState(data);
}
```

房主的显示始终来自 `_buildDisplayFromAuth()`（本地 GameEngine 权威输出），PostgresChanges 回声只用于 `_lastStateData` 参考值，不触发重建。

### 8.10 初始 SELECT 防过期覆盖

**问题**：`_ensureRoomChannel` 的异步 SELECT 可能在某次 Broadcast 之后才返回，用过期数据覆盖缓存中的更新数据。

**修复**：SELECT 回调用 `updated_at` 时间戳比较，只在不比缓存旧时才更新：

```dart
final cachedTs = cached?['updated_at'] as int? ?? 0;
final rowTs = row['updated_at'] as int? ?? 0;
if (cached == null || rowTs >= cachedTs) {
  _cachedRows[roomId] = row;
  controller.add(row);
}
```

### 8.11 房间生命周期管理

#### 退出流程（含 loading 状态防重复点击）

| 场景 | 触发 | 行为 |
|------|------|------|
| 等待室退出 | 右上角按钮 / 返回键 | `_leaving` 标志 → 按钮替换为 loading → `leaveRoom` → pop |
| 游戏中退出 | 返回键 PopScope | 确认对话框 → loading 遮罩 → `exitRoom` → popUntil 首页 |
| 结算页离开 | 「离开」按钮 | 确认对话框 → loading 遮罩 → `exitRoom` → popUntil 首页 |
| App 被杀 | `AppLifecycleState.detached` | best-effort `exitRoom`（不保证完成） |

#### 房间自动删除策略

`leaveRoom`（等待室退出）/ `exitRoom`（游戏中退出）退出时检查 **在线玩家数**：

| 方法 | 座位处理 | 手牌处理 | 房间删除 |
|------|---------|---------|---------|
| `leaveRoom` | `seats[seat] = null`（彻底清除） | 不处理 | 检查在线玩家，全离线则删除 |
| `exitRoom` | `seats[seat].online = false`（保留 UID） | **保留**（重连恢复） | 检查在线玩家，全离线则删除 |

> `exitRoom` **不再删除座位和手牌**，仅标记 `online: false`。这样玩家重连时 `joinRoom` 通过 UID 匹配恢复原座位 + `watchMyHand` 初始 SELECT 拿回完整手牌。

Firebase 额外利用 `onDisconnect` 在 WebSocket 断开时自动标记 `online: false`，确保杀进程后在线状态正确更新。

#### 重连座位恢复

`joinRoom` 检测玩家 UID 是否已在座位中：

```
joinRoom → SELECT seats
  ├─ 找到 uid 匹配的座位 → 恢复该座位（online: true）→ 返回原座位号
  └─ 无匹配 → 找空座位 → 占座 → 返回座位号
```

确保玩家断线重连/退出重新加入后回到原座位，房主身份不丢失。

#### 结算后重新加入

`RoomScreen` 自动跳转条件包含 `status == 'settled'`：

```dart
if (status == 'playing' || status == 'settled') → 自动跳转到游戏画面
```

玩家离开后重新加入结算中的房间，直接进入对局画面看到结算弹窗，可正常点「准备」参与下一局。

### 8.12 已知限制

| 限制 | 影响 | 后续方案 |
|------|------|---------|
| `setReady` 竞态条件 | 两个玩家同时点「准备」可能互相覆盖（窗口 ~200ms） | RPC + `jsonb_set` 原子操作 |
| Supabase 无 `onDisconnect` | 杀进程后 `online` 标记不自动更新（依赖 `detached` 回调 best-effort） | ✅ SQL 函数 `cleanup_stale_rooms()` + pg_cron 每 5 分钟清理 |
| pg_cron 需 Pro 计划 | 免费计划不支持 pg_cron 扩展 | 升级 Pro 或使用外部 cron 服务调用 Edge Function |
| 房主权威信任模型 | 房主可作弊 | 迁移到服务端权威 |

---

## 9. 语音群聊（LiveKit Cloud · Phase 4）

> **方案**：LiveKit Cloud（开源 WebRTC 平台）提供实时语音群聊，Supabase Edge Function 签发 Token，推麦（Push-to-Talk）交互模式。
> **备选**：Agora（声网）——若 LiveKit 在大陆用户场景下延迟过高，可切换。

### 9.1 方案选型

| 维度 | LiveKit Cloud ✅ | Agora（备选） | 淘汰原因 |
|------|-----------------|-------------|---------|
| 免费额度 | 5,000 WebRTC 分钟/月 | 10,000 分钟/月 | — |
| 3人局约12分钟 | ~130 局/月 | ~260 局/月 | — |
| 开源可控 | ✅ MIT 开源，可自建 | ❌ 闭源 | Daily.co 免费仅 5 个房间 |
| ICP 备案 | ✅ 无需 | ⚠️ 大陆节点需备案 | Daily.co 一票否决 |
| Flutter SDK | `livekit_client` pub.dev 成熟 | `agora_rtc_engine` | — |
| 升级费用 | $50/月 Ship 含 15 万分钟 | $0.99/千分钟 | — |

**选择 LiveKit 的原因**：
- 开源 MIT，若 Cloud 不够用可直接**自建 LiveKit 服务端**（Go 单二进制），代码零迁移
- Room 原生概念——一个游戏房间 = 一个 LiveKit Room，映射天然
- 推麦 API 一行代码：`LocalParticipant.setMicrophoneEnabled(bool)`

### 9.2 架构

```
┌───────────── Flutter App ─────────────┐
│                                        │
│  VoiceChatController (Riverpod)        │
│    ├─ LiveKit Room                     │
│    ├─ 推麦状态：muted / unmuted         │
│    ├─ 说话者检测：audioLevel 订阅       │
│    └─ UI：推麦按钮 + 座位高亮           │
│                                        │
│  集成点：NetGameScreen (仅联网模式)      │
│    ├─ Stack 层追加推麦按钮              │
│    └─ VoiceIndicator 座位边框高亮       │
│                                        │
├───────────────────────────────────────┤
│                                        │
│  Token 签发                             │
│    Supabase Edge Function               │
│    POST /get-voice-token                │
│    { roomId } → JWT (10min TTL)         │
│                                        │
└────────────────────────────────────────┘
```

### 9.3 Token 签发流程

```
Client                  Supabase Edge Function        LiveKit Cloud
  │                            │                         │
  │ POST /get-voice-token      │                         │
  │ { roomId }                 │                         │
  │───────────────────────────>│                         │
  │                            │ 1. 用 LK_API_SECRET     │
  │                            │    签发 JWT              │
  │                            │    (sub=uid, roomId)     │
  │                            │                         │
  │ { token, url }             │                         │
  │<───────────────────────────│                         │
  │                            │                         │
  │ Room.connect(url, token)                              │
  │──────────────────────────────────────────────────────>│
  │<───────────────── WebRTC Audio ──────────────────────>│
```

### 9.4 推麦交互设计

```
游戏画面右侧栏（横屏）:
┌──────────────┬──────┐
│              │ [←]  │  返回按钮（右上角）
│  Game Area   ├──────┤
│              │ 聊天  │  聊天面板（从 top:36 开始，高度 60%）
│              │      │
│  Hand Cards  ├──────┤
│              │ [🎧] │  语音按钮（默认显示"加入"，琥珀色耳机图标）
└──────────────┴──────┘

手动加入/离开语音（默认不建房间，节约 WebRTC 分钟）:
  进入游戏画面 → inVoiceRoom: false → 显示琥珀色"加入"按钮
  点击"加入" → 确认弹窗 → reconnect() → fetchToken + room.connect
  → 连接成功后显示"离开"按钮 + 推麦按钮

点击推麦按钮（Toggle 切换模式）:
  → LocalParticipant.setMicrophoneEnabled(true)
  → 按钮变绿色 + 呼吸灯光效
  → 再次点击 → setMicrophoneEnabled(false) → 按钮变灰

退出房间:
  → VoiceChatController.disconnectActive() → 自动静音 + 断开 LiveKit
```

### 9.5 说话者检测（体验增强）

LiveKit 提供 `audioLevel` 事件（0.0–1.0，每 100ms 更新）：

```dart
participant.addListener(() {
  if (participant.audioLevel > 0.3) {
    // 对应座位边框亮绿色
  }
});
```

用 `audioLevel` 检测谁在说话，对应游戏座位上显示绿色光圈，类似 QQ 群通话效果。

### 9.6 客户端文件结构

```
lib/voice/
  voice_chat_controller.dart      Riverpod Notifier（连接/断连重连/单人自删/加入离开语音/推麦/说话者检测）
  voice_token_service.dart        Edge Function 调用（Token + 管理员 list/delete/delete-all/verify-password）

lib/ui/game/widgets/
  voice_controls.dart             语音控制组件组：[加入/离开耳机] + [推麦（仅语音中显示）]

supabase/functions/get-voice-token/
  index.ts                        LiveKit JWT 签发 + CreateRoom + DeleteRoom + ListRooms + 管理员密码校验

supabase/scripts/
  delete_livekit_rooms.cjs        Node.js 零依赖脚本：直接调 LiveKit API list/delete/delete-all
```

### 9.7 配置步骤

1. 访问 [cloud.livekit.io](https://cloud.livekit.io) 创建项目（免费 Build 计划，无需信用卡）
2. Project Settings → API Keys → 复制 API Key 和 API Secret
3. 在 Supabase Dashboard → Edge Functions 添加环境变量：
   - `LIVEKIT_API_KEY` = 项目 API Key
   - `LIVEKIT_API_SECRET` = 项目 API Secret
4. 部署 `supabase/functions/get-voice-token`：
   ```bash
   supabase functions deploy get-voice-token
   ```
5. 在 Flutter 端填入 LiveKit Cloud URL（Dashboard 可见，形如 `wss://xxx.livekit.cloud`）

### 9.8 免费额度估算

| 场景 | 消耗 | 免费额度使用率 |
|------|------|--------------|
| 3 人 × 12 分钟/局 | 36 分钟/局 | 免费额度可持续 130 局 |
| 每天玩 5 局 | 180 分钟/天 | 免费额度可持续 27 天 |
| 2 个房间并发 | 6 人同时在线 | 并发限制 100，完全够用 |

超出免费额度后，Build 计划会**硬拒绝**新连接（不扣费）。升级 Ship 计划 $50/月 含 150,000 分钟（~4,100局）。

### 9.9 备选方案：Agora（声网）

若 LiveKit 在大陆用户场景下延迟过高，Agora 作为备选：

- 免费 10,000 分钟/月（约 260 局）
- 选择**亚洲（中国大陆除外）**节点，避免 ICP 备案
- Flutter SDK：`agora_rtc_engine`
- 国内用户延迟更低（SD-RTN 专线覆盖全国）
- 迁移成本：替换 `voice_chat_controller.dart` 中的连接逻辑，UI 层不变

### 9.10 退出清理 & 分钟数防护

**问题**：如果玩家杀进程退出，LiveKit 房间可能残留并持续计费 WebRTC 分钟。

**三层防护**：

| 层级 | 机制 | 说明 |
|------|------|------|
| 客户端 | `VoiceChatController.disconnectActive()` | 正常退出 + `detached` 回调均调用，静态方法绕过 Riverpod scope 限制 |
| 服务端 | LiveKit `empty_timeout: 60` | Edge Function 中通过 Server API `CreateRoom` 显式设置 |
| 服务端 | Supabase stale room 清理 | SQL 函数 `cleanup_stale_rooms()` + pg_cron 每 5 分钟清理无在线玩家且 10 分钟未更新的房间 |

> `empty_timeout` **不是** LiveKit Dashboard 设置，而是 Server API `CreateRoom` 参数。Edge Function 在签发 Token 前先调用 `CreateRoom`（若房间已存在返回 409，忽略即可）。

正常退出流程：
```
点「离开」 → disconnectActive() → exitRoom() → Navigator.popUntil()
```
杀进程流程：
```
detached 回调 → disconnectActive() + exitRoom() （best-effort）
```

### 9.11 玩家进出通知

`ChatController` 额外监听 `watchRoom` 座位 `online` 状态变化，自动在聊天框中插入灰色系统消息：

| 变化 | 消息 |
|------|------|
| `online: true → false` | `XXX 离开了`（居中灰色文字） |
| `online: false → true` | `XXX 重新连接了`（居中灰色文字） |

首次加载时跳过通知（避免进房间时全员显示"重新连接了"）。系统消息 `bySeat = -1`，不写入数据库，仅本地显示。

### 9.12 游戏画面 UI 布局（联网模式）

```
┌──────────────────────────────┬──────┐
│                              │ [←]  │ ← Positioned(top:0, right:0)
│       游戏区域                ├──────┤
│  (对手信息 / 出牌展示)         │ 聊天  │ ← Positioned(top:36, height:60%-36)
│                              │ 面板  │
│                              │      │
├──────────────────────────────┤      │
│  手牌区 + 操作按钮             ├──────┤
│  [不出] [提示] [出牌]          │ [🎤] │ ← Positioned(top:36+60%H+12)
└──────────────────────────────┴──────┘
```

- 返回按钮：半透明黑色背景，点击触发退出对话框
- 聊天面板：顶部 36px 让位给返回按钮，内部标题栏也有返回按钮
- 麦克风按钮：`LayoutBuilder` 动态计算位置，始终紧贴聊天框底部，不遮挡手牌

---

## 10. AI 凑人（二缺一自动补位 · Phase 3）

> **场景**：房间内只有 2 个真实玩家时，房主可添加 1 个 AI 玩家凑齐 3 人开打。
> **限制**：仅允许添加 1 个 AI（禁止 2 AI 局——那不如玩单机）。

### 10.1 设计原则

| 原则 | 说明 |
|------|------|
| 仅房主可添加 | 非房主看不到「添加 AI」按钮 |
| 仅二缺一时出现 | 2 真人 + 0 AI + 1 空位 → 显示按钮；其他情况隐藏 |
| AI 由房主设备驱动 | 房主的 `NetGameSession` 负责运行 DouZero 推理并广播 |
| AI 不参与语音 | AI 没有 LiveKit 连接，不消耗 WebRTC 分钟 |
| AI 自动准备 | `readySeats` 中 AI 座位始终为 true |

### 10.2 数据模型

`SeatInfo` 新增 `isAI` 字段：

```dart
class SeatInfo {
  final String uid;    // AI 座位: 'ai_{roomId}_{seat}'
  final String nick;   // 'AI 玩家'
  final bool online;   // true
  final bool isAI;     // true（新增）
}
```

Firebase 和 Supabase 的 `addAiSeat` / `removeAiSeat` 直接写/删座位数据。

### 10.3 房主 AI 调度流程

```
玩家动作（人或 AI）
  → _hostProcessAction(action)
    → GameEngine.apply → 更新 _authState
    → _syncThenBroadcast()（广播给非房主）
    → _maybeScheduleAi()  ← 检查下一手是否 AI 回合
        ├─ 当前玩家不是 AI → 等待人类操作
        └─ 当前玩家是 AI → Timer(800ms) → _runAiTurn()
              ├─ DouZeroAi.chooseAction(_authState, aiSeat)
              │   ├─ 叫分阶段: BidAi（启发式）
              │   └─ 出牌阶段: DouZeroMoves.enumerate → ONNX 推理 → argmax
              ├─ 校验动作合法性，非法则兜底（叫0 / Pass）
              └─ _hostProcessAction(actionJson) → 链式触发下一手
```

### 10.4 非房主视角

非房主无需感知 AI 存在：
- 收到房主广播的游戏状态，AI 的出牌/叫分与人类操作格式完全一致
- AI 座位手牌始终背面朝上（`isHuman = false`），结算时翻开
- AI 座位昵称显示为 "AI 玩家"

### 10.5 房间 UI

```
等待室（2 真人 + 1 空位）:
┌──────┐  ┌──────┐  ┌──────┐
│ 玩家1 │  │ 玩家2 │  │ 空位  │
│  👤   │  │  👤   │  │  ➕   │
└──────┘  └──────┘  └──────┘

         [🤖 添加 AI 玩家]  ← 仅房主可见

添加 AI 后:
┌──────┐  ┌──────┐  ┌──────┐
│ 玩家1 │  │ 玩家2 │  │ AI   │
│  👤   │  │  👤   │  │  🤖   │  ← 点击可移除（仅房主）
└──────┘  └──────┘  └──────┘

         [开始游戏]
```

### 10.6 文件变更

| 文件 | 变更 |
|------|------|
| `protocol.dart` | `SeatInfo` 新增 `isAI`；`RoomSnapshot` 新增 `aiSeats` / `humanPlayerCount` |
| `room_client_base.dart` | 新增 `addAiSeat` / `removeAiSeat` 抽象方法 |
| `room_client.dart` | Firebase 实现：直接 `.set()` / `.remove()` 座位；`leaveRoom`/`exitRoom` 检查在线真人时跳过 `isAI` |
| `supabase_room_client.dart` | Supabase 实现：`_updateJsonField` 修改 seats JSON；`leaveRoom`/`exitRoom` 检查在线真人时跳过 `isAI`；删房时同步调 `VoiceTokenService.deleteLiveKitRoom` |
| `net_game_session.dart` | 新增 `_aiSeats` / `_ai` / `_aiTimer`；`_maybeScheduleAi()` + `_runAiTurn()`；`_buildGameStateMap` 序列化 `actedSeats`/`lastMoveBySeat`；`_buildDisplayState`/`_buildDisplayFromAuth` 反序列化+座位重映射（兼容 Firebase RTDB List 格式） |
| `room_screen.dart` | 「添加 AI 玩家」按钮 + AI 座位 🤖 图标 + 点击移除 |
| `net_game_screen.dart` | `NetGameScreen` 接收 `aiSeats` 参数传给 `NetRoomContext`；左侧房间号显示；`resizeToAvoidBottomInset: false`；语音仅 Supabase 后端启用（`netBackendProvider` 判断） |

---

## 11. LiveKit 房间管理（Phase 3 补充）

### 11.1 三层清理机制

| 层级 | 触发 | 实现 | 场景 |
|------|------|------|------|
| **单人 1 分钟自删** | 语音房间只剩 1 人 → 60s 无人加入 | 客户端 `_checkAlone` + `VoiceTokenService.deleteLiveKitRoom` | 正常退出：大家陆续离开，最后一人等 1 分钟自动清理 |
| **管理员手动删** | 设置页输入密码 → 查看/删除 | Edge Function `action: list/delete/delete-all` + `ADMIN_PASSWORD` | 清理残留死房间（所有客户端断开但 LiveKit 未释放） |
| **exitRoom 自动删** | 最后一个真人退出游戏房间 | `supabase_room_client.dart` 检测无人 → 删 Supabase 房 + 删 LiveKit 房 | 正常退出游戏 |

### 11.2 断连自动重连

管理员删除有人的语音房间后，所有已连接玩家的 WebRTC 被踢：

```
LiveKit 房间被删
  → 客户端 _onRoomUpdate 检测 ConnectionState.disconnected
  → _scheduleReconnect()（5s 延迟，防多次回调重置）
  → _connect(roomId) → fetchToken → ensureRoom
    → LiveKit 409（他人已重建）→ Token 照发 → 连入新 Session
  → 最多 3 次；首次连接失败不重试（避免无网络时无限循环）
```

### 11.3 Edge Function 统一入口

`get-voice-token` 支持两种模式：

| 请求 | 响应 | 密码 |
|------|------|:----:|
| `{roomId, uid}` | `{token, url}` | ✗ |
| `{action: 'delete', roomId}` | `{ok: true}` | ✗（exitRoom 自动清理） |
| `{action: 'delete', roomId, adminPassword}` | `{ok: true}` | ✓ |
| `{action: 'list', adminPassword}` | `{rooms: [...]}` | ✓ |
| `{action: 'delete-all', adminPassword}` | `{ok, deleted, total}` | ✓ |
| `{action: 'verify-password', adminPassword}` | `{ok: true}` | ✓ |

### 11.4 LiveKit 数据注意事项

- protobuf JSON 使用 **snake_case**：`creation_time` / `num_participants`（非 camelCase）
- `int64` 字段可能以 **string** 返回：`_parseInt` 统一处理 `int` / `string`
- `num_participants` 是当前活跃 WebRTC 连接数，Dashboard Subscribers 更详细

### 11.5 语音功能后端限制

语音群聊**仅支持 Supabase 后端**，原因：

| 环节 | 依赖 | Firebase 用户 |
|------|------|--------------|
| Edge Function 调用 | Supabase Auth UID | 无 UID（走 Firebase Auth） |
| Token 签发 | Supabase Edge Function | 无法调用 |
| WebRTC 连接 | LiveKit JWT | 无 Token |

`NetGameScreen` 通过 `netBackendProvider` 判断后端类型：
- **Supabase** → 注入 `voiceChatRoomIdOverride` + 显示 `VoiceControls`
- **Firebase** → 跳过语音初始化 + 不显示语音按钮

### 11.6 Firebase RTDB 序列化兼容

Firebase RTDB 的一个已知行为：**数字 string key 自动转为数组索引**。

`lastMoveBySeat` 序列化为 `{"0": [...], "1": [...], "2": [...]}`：
- Supabase（JSONB）→ 保持 `Map` 格式
- Firebase（RTDB）→ 自动转为 `List`（`[[...], [...], [...]]`）

`_buildDisplayState` 反序列化时同时处理两种格式：

```dart
if (lmbsRaw is Map) {
  // Supabase: {"0":[...], "1":[...], "2":[...]}
} else if (lmbsRaw is List) {
  // Firebase: [[...], [...], [...]]
}
```

### 11.7 默认区域与网络检测

联机模式默认选中 **Supabase（大陆）** 后端，不再根据 IP 自动检测区域。原因：同一区域的玩家才能开房游戏，IP 检测可能导致房主在大陆、玩家在海外时选中不同后端，无法加入房间。

进入联机时仅做基础网络连通性检查：

```dart
// RegionDetector.hasNetwork() — DNS lookup cloudflare.com，3 秒超时
final hasNetwork = await RegionDetector.hasNetwork();
if (!hasNetwork) {
  // 弹窗提示无网络
  return;
}
// 默认 Supabase，用户可在大厅手动切换
ref.read(netBackendProvider.notifier).state = NetBackend.supabase;
```

### 11.8 游戏画面自适应布局

游戏画面底部 `_buildHumanArea` 使用 `Expanded` 获得有界高度，内部按钮栏与手牌之间的间距改用 `Flexible(loose, max=12)`：

- **空间充足**：间距 12px，多余空间浮在顶部（`mainAxisAlignment.end`）
- **空间紧张**（如联网结算栏多出"等待"文本）：间距自动缩小
- **任何屏幕尺寸**不溢出，无需 per-device 适配

### 11.9 出牌超时 + 托管模式

#### 超时定时器

仅房主运行倒计时（非房主从广播的 `turnDeadline` 渲染 UI）：

```
房主 _scheduleTurnTimeout():
  ├─ _turnTimer = Timer(30s) → _onTurnTimeout()
  └─ _turnDeadline = DateTime.now().toUtc().millisecondsSinceEpoch + 30000
       ↓ 广播到 game_state.turnDeadline

非房主收到 turnDeadline:
  └─ _TurnCountdownBadge 渲染倒计时
       ├─ >10s: 白色
       └─ ≤10s: 红色（紧迫感）
```

**关键：调度顺序**——`_scheduleTurnTimeout()` 必须在 `_buildDisplayFromAuth()` + `_syncThenBroadcast()` **之前**调用。否则 `state =` 赋值后 Riverpod 通知监听器，Timer 可能在已过时的 state 上操作。

#### 超时 → 托管（非单次自动出牌）

```
_onTurnTimeout(seat):
  ├─ _autoPlaySeats.add(seat)
  ├─ 广播 autoPlaySeats 到所有客户端
  └─ _maybeScheduleAi() → _runAiTurn()
       └─ AI 持续接管该座位，直到玩家主动退出托管
```

#### 退出托管

玩家触摸屏幕任意位置 → `disableAutoPlay()`：
- **房主**：本地移除 `_autoPlaySeats` + 广播 + 取消 AI Timer
- **非房主**：提交 `pendingAction(type: disableAutoPlay)` → 房主处理

#### UI 体现

| 元素 | 正常 | 托管中 |
|------|------|--------|
| 操作栏 | [不出] [提示] [出牌] | 🤖 托管中（点击退出） |
| 手牌区 | 可选/可操作 | 灰显 + 不可交互 |
| 对手信息栏 | 正常 | 🤖 图标（所有人可见） |

### 11.10 房主续局（Host Resume）

房主中途退出（杀进程/网络断开）后重新进入房间时，需要恢复权威状态继续对局：

```
_hostInitOrResume():
  ├─ 读取 RTDB game_state
  ├─ 已有进行中的对局？
  │    ├─ 否 → 正常初始化新对局
  │    └─ 是 → _resumeFromRtdb(deckSeed, actionLog)
  │         ├─ Deck.deal(seed) → 原始牌序
  │         ├─ GameEngine 逐条 apply actionLog
  │         └─ _authState 重建完成 → 房主权威恢复
  └─ _scheduleTurnTimeout()（恢复超时定时器）
```

非房主无需特殊处理——房主广播恢复后的权威状态，非房主自动同步。

### 11.11 断线重连

#### Firebase

```
.info/connected 监听:
  ├─ true（连接恢复）
  │    ├─ 重新设置 onDisconnect 回调（Firebase 每次重连需重新注册）
  │    │    ├─ seats/$seat/online = false
  │    │    └─ 房间清理（检查在线人数 → 空则删房）
  │    └─ setOnline(true)
  └─ false（连接断开）
       └─ UI 显示"连接中..."（不阻塞游戏）
```

#### Supabase

Supabase 无 `onDisconnect` 原语，改用 **心跳 + channel subscribe 回调**：

```
心跳机制:
  ├─ 每 10s 更新 seats JSONB 中 $seat.last_seen = now()
  ├─ cleanup_stale_rooms() 检查 last_seen 超时 → 清理
  └─ channel.subscribe(status callback):
       ├─ 'SUBSCRIBED' → 连接正常
       ├─ 'CHANNEL_ERROR' / 'TIMED_OUT' → 标记断线
       └─ 重连后 channel 自动恢复
```

### 11.12 提示 Toast UI

点击「提示」无可压牌时，底部居中显示浮动文字提示（替代 SnackBar）：

```
_showToast(message):
  ├─ OverlayEntry + Positioned(bottom, full width, Center)
  ├─ Material(transparent) ← 必须！否则 Text 渲染黄色双下划线
  └─ 3 秒后自动移除
```

> **Flutter 坑**：`OverlayEntry` 内的 `Text` 缺少 `Material` 祖先时，会渲染两行黄色下划线（Flutter 默认 Material widget 警告样式）。必须包裹 `Material(color: Colors.transparent)`。

### 11.13 房主迁移（Host Migration）

> **场景**：房主杀 App / 永久离开 → 房主设备死亡 → 引擎/AI/定时器全部停止 → 其他玩家游戏冻结。

#### 迁移流程

```
T+0s   房主杀 App
T+~5s  其他设备通过 watchRoom 检测到房主 seat offline
T+15s  _checkHostMigration 触发（15s 延迟，避免网络抖断误触发）
       ├─ 选取最小在线真人座位号为候选人（确定性，所有客户端独立计算同一结果）
       ├─ 候选人写 meta.hostUid = 自己的 uid（唯一写入者，无竞争）
       └─ RTDB onValue → 所有客户端 isHost 更新

候选人检测到 isHost: false→true
  → _activateHost()
       ├─ _isHost = true
       ├─ 订阅 watchPendingAction
       ├─ 离线人类座位加入 _autoPlaySeats（AI 托管）
       ├─ _hostInitOrResume() 从 deckSeed + actionLog 重建 _authState
       └─ _recoverPendingAction() 回捞旧房主未处理的动作

旧房主设备恢复网络？
  → 检测到 isHost: true→false → _deactivateHost()
       ├─ _isHost = false
       ├─ 取消 _pendingSub / _turnTimer / _aiTimer
       └─ _authState = null → 切回被动接收模式

旧房主重新加入房间？
  → meta.hostUid 已改 → 以非房主身份进入 → 坐回原座位 → 可触摸退出托管
```

#### 关键设计决策

| 决策 | 方案 | 原因 |
|------|------|------|
| **延迟触发** | 15s | 房主临时断网 < 15s 由设备存活 + 托管覆盖；> 15s 判定设备死亡 |
| **候选人规则** | 最小在线真人座位号 | 确定性，所有客户端独立计算同一结果，零竞争 |
| **持久化方式** | 写 `meta.hostUid` | 旧房主重进时自动识别为新角色；watchRoom.isHost 全局一致 |
| **旧房主座位** | 加入 `_autoPlaySeats` | 新房主设备 AI 托管，对局继续 |
| **_isHost 可变** | 替代 `_ctx.isHost` | 迁移后角色变化，所有引用统一用 `_isHost` |

#### 边界场景

- **迁移过程中第二个玩家也离开**：`_checkHostMigration` 持续运行，重新计算候选人；全离线 → `exitRoom` 删除房间
- **房主设备抖断恢复**：`_deactivateHost()` 降级为非房主，切回被动模式
- **pendingAction 遗漏**：`_recoverPendingAction()` 读取并处理，非法动作被引擎 validate 安全拒绝

### 11.14 联网战绩记录

每局结束时，**每个玩家各自记录自己的结果**（房主和非房主独立记录）：

| 角色 | 记录时机 | 数据来源 |
|------|---------|---------|
| 房主 | `_hostProcessAction` 检测 `phase=settled` | `_authState` 完整字段 + `_turns` 计数器 |
| 非房主 | `_onGameState` 检测 `phase=settled` | 广播数据 `deckSeed` + `actionLog` 估算 turns |

- `_settleRecordedForSeed` 幂等保护（同 seed 只记一次）
- `StatsRecord.isOnline = true` 标识联网对局
- 战绩面板显示 🌐 `public` 图标

### 11.15 ready 系统修复（再来一局）

**问题**：玩家离开后 seat 永远无法准备 → 卡住无法再来一局。

**修复**：`readySeats` getter 中以下座位自动准备，不阻塞再来一局：

| 座位类型 | 自动准备 | 原因 |
|---------|:-------:|------|
| 房主座位 | ✅ | `_ctx.mySeat`（迁移后正确，不再硬编码 seat 0） |
| AI 座位 | ✅ | 无人类操作 |
| autoPlay 座位 | ✅ | AI 在控制 |
| 离线座位 | ✅ | 无人操作，不应阻塞；重连后自然参与下一局 |

→ 剩余在线真人全部准备即可开始新一局，AI/托管/离线座位由房主设备 AI 接管。

### 11.16 规则变体（RuleVariant）

引擎魔法数字参数化为 `RuleVariant` 数据类，随 `GameState` 序列化：

| 字段 | 默认 | 说明 |
|------|------|------|
| `id` | `'classic'` | 序列化标识 |
| `label` | `'经典'` | UI 显示名 |
| `shuffle` | `true` | 洗牌/不洗牌（`Deck.deal` / `Deck.dealNoShuffle`）|
| `bidMax` | `3` | 叫分上限（引擎 validate/apply 读取）|
| `bombMultiplier` | `2` | 炸弹倍率（`multiplier *= bombMultiplier`）|
| `springEnabled` | `true` | 春天/反春天开关 |

**预设**：`classic`（经典）/ `noShuffle`（不洗牌）。

**向下兼容**：`StatsRecord.noShuffle: bool` → `variantId: String?`（旧记录 `variantId=null` 时按 `noShuffle` 推断）；`reconstructReplay()` 按 `variant.shuffle` 选择发牌方法。

**联网序列化**：`_buildGameStateMap` 广播 `'ruleVariant': _variant.id`；房主重连 `_resumeFromRtdb` 从 `gs['ruleVariant']` 恢复；非房主 `_buildDisplayState` 从 `data['ruleVariant']` 解析。

### 11.17 明牌（仅联网 + 仅地主）

**设计依据**：欢乐斗地主官方规则——明牌最常用形式为"收完底牌后可选择明牌，游戏倍数×2"。仅地主可操作，不影响农民间公平性。单机模式不启用（DouZero 模型未训练此规则，单机明牌仅影响计分无策略价值）。

| 维度 | 实现 |
|------|------|
| **时机** | `phase == playing && lastValidPlay == null`（成交后、首出前）|
| **操作者** | 仅 `landlordSeat`（引擎 validate 强制）|
| **效果** | `BrightAction` → `multiplier *= 2` + `brightSeats.add(seat)` |
| **可见性** | 地主手牌对两个农民公开（`brightSeats.contains(player.seat)` → `_buildOpponentHandFaceUp`）|
| **UI** | 操作栏"明牌×2"按钮：仅 `isOnlineMode && humanSeat == landlordSeat && lastValidPlay == null && !brightSeats.contains(humanSeat)` |
| **单机** | `GameSession.bright()` 空操作 |

**联网手牌传输**：

| 路径 | 实现 |
|------|------|
| 广播 | `_buildGameStateMap` → `'brightHands': { '$seat': [cardIndex, ...] }`（仅 phase≠settled 时）|
| 房主显示 | `_buildDisplayFromAuth` → `showRealHand = isMe \|\| isSettled \|\| brightSeats.contains(actualSeat)` |
| 非房主显示 | `_buildDisplayState` → 解析 `brightHands` map → 明牌座位用真实手牌替代 `Card.fromIndex(0)` 填充 |
