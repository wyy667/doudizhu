# 09 · Phase 1 MVP 详细设计

> 这是 [08-roadmap.md](./08-roadmap.md) Phase 1 的**可执行设计**。读前置：[04-game-rules.md](./04-game-rules.md)、[05-architecture.md](./05-architecture.md)、[03-project-structure.md](./03-project-structure.md)。
>
> **状态：✅ Phase 1 已完成（2026-07）**。本文档保留作为 Phase 1 的设计记录与 Phase 3 的参考基线。实际实现与本文档的小偏差见 [08-roadmap.md](./08-roadmap.md) §1.3。

## 1. MVP 范围回顾

人 vs 2 AI，经典斗地主，完整一局，离线，横屏。明确**不做**：联网、战绩存储、规则变体、动画音效、春天计分（仅数据结构预留倍数字段）。

## 2. 横屏锁定实现

### 2.1 代码（`lib/main.dart`）

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // 可选：全屏沉浸式
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: LandlordApp()));
}
```

### 2.2 平台配置

- **Android**（`AndroidManifest.xml` 的 `<activity>`）：
  ```xml
  android:screenOrientation="sensorLandscape"
  android:configChanges="orientation|screenSize|keyboardHidden"
  ```
- **iOS**（`Info.plist`）：`UISupportedInterfaceOrientations` 仅留两项横屏；iPad 用 `UISupportedInterfaceOrientations~ipad`。

> 配 `configChanges` 避免转屏时 Activity 重建（Flutter 默认会自己处理，但显式声明更稳）。

## 3. 规则引擎（`lib/core/`，最核心）

### 3.1 `Card` / `Rank`

```dart
enum Rank {
  c3(3, '3'), c4(4,'4'), c5(5,'5'), c6(6,'6'), c7(7,'7'), c8(8,'8'),
  c9(9,'9'), c10(10,'10'), cJ(11,'J'), cQ(12,'Q'), cK(13,'K'),
  cA(14,'A'), c2(15,'2'), bj(16,'小王'), rj(17,'大王');
  final int value; final String label;
  const Rank(this.value, this.label);
}

enum Suit { spade, heart, diamond, club, jokerSmall, jokerBig }

class Card {
  final Rank rank; final Suit suit;
  const Card(this.rank, this.suit);
  // == / hashCode 基于 rank+suit；排序按 rank
}
```

54 张全量：13 点 × 4 花色 + 小王 + 大王 = 54。

### 3.2 牌型识别 `detectHand` —— 算法骨架

```text
detectHand(List<Card> cards) -> HandPattern?:
  n = cards.length
  counts = 按点数分组计数  // Map<Rank,int>
  ranks  = counts.keys 按 value 排序

  // 1. 火箭
  if n==2 && 含小王 && 含大王: return rocket
  // 2. 炸弹
  if n==4 && counts 全为同一 rank: return bomb
  // 3. 单/对/三
  if n==1: single
  if n==2 && counts[唯一rank]==2: pair
  if n==3 && counts[唯一rank]==3: triple
  // 4. 三带一/二
  if n==4 && 有 rank 计数==3 && 另一张任意: tripleSingle
  if n==5 && 有 rank 计数==3 && 另一 rank 计数==2: triplePair
  // 5. 顺子（≥5，不含 2/王，连续）
  if n>=5 && 全计数==1 && max-min==n-1 && 无 2/王: straight
  // 6. 连对（≥3 对，连续，无 2/王）
  if n>=6 && n%2==0 && 全计数==2 && 连续 && 无 2/王: pairStraight
  // 7. 飞机不带（≥2 个连续三张，无 2/王）
  if 全计数==3 && 连续 && 无 2/王 && n>=6: plane
  // 8. 飞机带单/对
  if 是飞机 + 等长单牌（含或不含对）：planeSingle（需校验翅膀约束）
  if 是飞机 + 等长对子：planePair
  // 9. 四带二
  if n==6 && 有 rank 计数==4: bombTwoSingle
  if n==8 && 有 rank 计数==4 && 其余两对: bombTwoPair
  else: null  // 非法组合
```

`mainRank` 取规则：单/对/三/三带/炸弹取主体 rank；顺子/连对/飞机取**最小**主体 rank；火箭固定最大。

### 3.3 比较 `canBeat`

```dart
bool canBeat(HandPattern played, HandPattern? last) {
  if (last == null) return true;               // 自由出牌
  if (played.type == rocket) return true;
  if (played.type == bomb) {
    if (last.type == rocket) return false;
    if (last.type == bomb) return played.mainRank > last.mainRank;
    return true;                                // 炸压非炸非火箭
  }
  // 普通牌型
  return played.type == last.type
      && played.length == last.length
      && played.mainRank > last.mainRank;
}
```

### 3.4 单元测试（必须）

为每种牌型准备正例/反例 + 跨牌型比较矩阵，例如：
- `detectHand([3,3,3,4,4])` → triplePair
- `detectHand([3,4,5,6,8])` → null（顺子不连续）
- `canBeat(bomb K, single A)` → true
- `canBeat(bomb K, bomb A)` → false

## 4. 状态机与引擎（`lib/core/game_engine.dart`）

按 [05-architecture.md](./05-architecture.md) §2 的 `GameState`/`GameAction`/`apply` 实现。

### 4.1 关键校验点

- `Deal`：phase==dealing；每人 17 张、底牌 3 张、无重复。
- `CallLandlord`：phase==bidding；轮到该 seat；首位 accept 即地主（MVP 简化）。
- `Play`：phase==playing；轮到该 seat；`detectHand != null` 且 `canBeat(..., lastValid)`；牌确在本人手牌中。
- `Pass`：phase==playing；轮到该 seat；`lastValidPlay != null`；自己不是 lastValidPlayer。

### 4.2 倍数

- 初始 1。
- 每出一次炸弹（含 `bomb`/`bombTwoSingle`/`bombTwoPair` 中带出的四张部分按规则）→ 逻辑上「出现四张」触发 ×2（具体以规则为准，MVP 简化为 `bomb` 与 `rocket` 各 ×2）。
- `rocket` → ×2。

## 5. AI（`lib/ai/heuristic_ai.dart`）

按 [06-ai-strategy.md](./06-ai-strategy.md) §4 实现 `HandDecomposer` + `leadPlay`/`followPlay`。

### 5.1 信息遮蔽（设计意图）

> ⚠️ 实际实现偏离：AI 接收完整 `GameState`（含三方手牌），由 AI 实现自行约束信息使用范围（启发式/PIMC 仅读自身手牌+公开信息；DouZero 用 perfect-info）。详见 [06-ai-strategy.md](./06-ai-strategy.md) §3。

引擎给 AI 的 `state` 中，**非自身玩家的 `hand` 字段为空 list**，仅保留 `handCounts`。从类型层面避免 AI 误用：
```dart
GameState maskForAi(GameState s, int seat);
```

### 5.2 调度

- `GameSessionNotifier` 在轮到 AI 时：
  ```dart
  Future.delayed(thinkDelay, () async {
    final action = await compute(_aiChoose, (s.state, s.state.currentPlayer));
    s.applyAction(action);
  });
  ```
- `_aiChoose` 在 Isolate 中跑 `HeuristicAi().chooseAction(masked)`。

## 6. UI（`lib/ui/game/`）

### 6.1 `game_screen.dart` 布局结构

```
Scaffold
 └─ SafeArea
     └─ Column / Row（用 LayoutBuilder 按宽高比决定）
         ├─ 顶栏：上家区（左）、倍数/底牌（中）、下家区（右）
         ├─ 中区：出牌展示（三人的最近一手）
         ├─ 底区：玩家手牌 + 操作按钮（不出/提示/出牌）
```

### 6.2 选牌交互

- `HandWidget`：水平排列，点击切换「选中态」（上移 ~12px + 高亮）。
- 「出牌」按钮：根据 `validate(state, PlayAction(me, selectedCards))` 启用/禁用，禁用则灰。
- 「提示」：调用 `findValidCombos(state)`，循环切换候选组合（多按一次切下一组）。
- 「不出」：仅当非自由出牌时启用。

### 6.3 叫地主

`BiddingOverlay`：弹层，按钮「叫地主 / 不叫」。

### 6.4 结算

`SettleOverlay`：显示胜负、倍数、得分；按钮「再来一局 / 返回主菜单」。

## 7. 主菜单（`lib/ui/home/`）

极简：
- 「开始游戏」→ 进入 `game_screen`（自动发牌开局）。
- 「难度」下拉（简单/普通/困难）。
- 「设置」（音量预留，MVP 可仅有占位）。

## 8. 数据流（一次完整对局，端到端）

```
main → LandlordApp → HomeScreen
  ├─ 点击「开始游戏」→ ref.read(sessionProvider).notifier.newGame()
  │     → engine: DealAction（随机/种子发牌）→ phase=bidding
  │     → 轮流叫地主（AI 自动、人类点按钮）→ CallLandlordAction
  │     → 确定地主 → 底牌并入 → phase=playing
  │     → 循环：currentPlayer 是人 → 等输入；是 AI → 异步出牌
  │     → 任一 hand 空 → phase=settled
  └─ 结算面板 → 「再来一局」→ newGame()
```

## 9. 错误处理与边界

| 情况 | 处理 |
|------|------|
| 玩家点了不能压的牌组合 | 「出牌」按钮禁用 + 短 toast「管不上」 |
| AI 异常（理论上不该） | Notifier try/catch，回退 Pass，记日志 |
| App 切后台 | Riverpod 状态在内存；冷启动丢失可接受（MVP 不持久化），重开新局 |
| 牌过多屏宽 | 手牌叠加显示（每张只露牌头），或允许横向滚动 |

## 10. 测试清单（Phase 1 验收）

### 单元（`test/core/`）
- [ ] `detectHand`：14 牌型各至少 3 用例 + 反例
- [ ] `canBeat`：跨牌型矩阵
- [ ] `deck`：54 张不重不漏、洗牌可种子化
- [ ] `game_engine`：每个 action 的合法/非法转移
- [ ] `HandDecomposer`：典型手牌的分解结果

### Widget（`test/ui/`）
- [ ] 选牌 → 出牌按钮启用/禁用正确
- [ ] 提示能切到下一组合
- [ ] 结算面板显示正确胜负

### 集成（`integration_test/`）
- [ ] 完整一局：开局 → 玩家先出完 → 显示玩家胜
- [ ] 完整一局：地主 AI 先出完 → 显示 AI 胜

## 11. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 牌型识别算法分支多易漏 | 严格单测 + 表驱动测试；参考 [04](./04-game-rules.md) 的 14 类穷举 |
| 飞机带翅膀边界复杂 | 单独写 `plane_test.dart`，覆盖「翅膀不能含三张组/炸弹」 |
| 启发式 AI 太弱/像作弊 | 信息遮蔽类型隔离；MVP 难度调到「合理」即可，强度交给 Phase 2 PIMC |
| Riverpod 学习成本 | 文档内给出 Notifier 范式；先简单用 `Notifier`，不引入复杂异步模式 |
| `compute` 序列化开销 | GameState 用 freezed + json_serializable，已天然可序列化 |

## 12. 开发顺序建议（自底向上）

1. **core**：`Card`/`Rank`/`Suit` → `detectHand` + 单测 → `canBeat` + 单测 → `deck` → `game_engine` + 单测。
2. **AI**：`HandDecomposer` + 单测 → `HeuristicAi` → 在 `test` 里跑 AI vs AI 若干局观察合理性。
3. **state**：`GameSessionNotifier` 串起 core + AI。
4. **UI**：先静态画 `game_screen`（用假数据）→ 接 Provider → 接交互。
5. **联调**：完整一局 → 打磨延迟/反馈 → 验收测试。
6. **横屏/平台配置**：早做，避免后期返工。
