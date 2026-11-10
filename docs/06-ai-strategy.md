# 06 · AI 策略设计

> **当前状态**：仅使用 DouZero WP（ICML 2021 SOTA），端侧 ONNX 推理。
>
> 历史上曾实现启发式 AI 和 PIMC 作为渐进难度，已于 2026-07 精简移除，以降低复杂度和包体积。

## 1. 架构总览

```
┌─────────────────────────────────────┐
│           Flutter App               │
│                                     │
│  ┌──────────┐   ┌────────────────┐  │
│  │ BidAi    │   │  DouZeroAi     │  │
│  │ (叫地主) │   │  (出牌 ONNX)   │  │
│  │ 手牌强度 │   │  枚举→编码→推理│  │
│  └──────────┘   └────────────────┘  │
│                                     │
│  ┌─────────────────────────────┐   │
│  │       GameEngine            │   │
│  │  (规则/状态机/结算)         │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

| 组件 | 文件 | 职责 |
|------|------|------|
| **BidAi** | `lib/ai/bid_ai.dart` | 叫地主阶段：手牌强度评估 → 叫分 0/1/2/3 |
| **DouZeroAi** | `lib/ai/douzero_ai.dart` | 出牌阶段：候选枚举 → 特征编码 → ONNX 推理 → argmax Q |
| **DouZeroModels** | `lib/ai/douzero/douzero_inference.dart` | ONNX session 管理 + 推理（含原生内存释放） |
| **DouZeroEncoder** | `lib/ai/douzero/douzero_encoder.dart` | 特征编码（z: 5×162 LSTM, x: 373/484） |
| **DouZeroMoves** | `lib/ai/douzero/douzero_moves.dart` | 合法动作枚举（14 种牌型） |
| **AiHandSearch** | `lib/ai/ai_player.dart` | 牌型搜索引擎（AiHandSearch.findBeats） |
| **GameSession** | `lib/state/game_session.dart` | 编排器：人类动作 + AI 调度 |

## 2. DouZero WP 模型

### 2.1 为什么选 WP

DouZero（ICML 2021）用 DMC 自博弈训练，提供三种奖励函数变体：

| 模型 | 全称 | 训练目标 |
|------|------|---------|
| **WP** | **W**inning **P**ercentage | 最大化胜率（赢=1/输=0） |
| ADP | Average Difference Points | 最大化分差 |
| SL | Supervised Learning | 模仿人类数据 |

WP 在纯胜率对战中最强（90000 局测试验证），且低方差稳健——对人类玩家是最难对付的对手。详见 [docs/11-ai-battle-results.md](./11-ai-battle-results.md)。

### 2.2 模型资源

- 路径：`assets/models/douzero_wp/`
- 文件：`landlord.onnx` / `landlord_up.onnx` / `landlord_down.onnx`
- 大小：每个 ~6MB，共 ~18MB
- 来源：[palemoky/douzero-baselines](https://huggingface.co/palemoky/douzero-baselines)（Apache-2.0）

### 2.3 网络输入输出

| 角色 | 输入 z | 输入 x | 输出 |
|------|--------|--------|------|
| landlord | [N, 5, 162] | [N, 373] | [N, 1] Q 值 |
| landlord_up | [N, 5, 162] | [N, 484] | [N, 1] |
| landlord_down | [N, 5, 162] | [N, 484] | [N, 1] |

### 2.4 推理流程

1. `DouZeroMoves.enumerate(state, seat)` — 枚举所有合法候选动作
2. `DouZeroEncoder.encodeZ(state)` — 编码 LSTM 历史（最后 15 步 → 5×162）
3. `DouZeroEncoder.encodeXBatch(state, seat, candidates, role)` — 编码 (state, action) 特征
4. `DouZeroModels.run(role, z, x, n)` — ONNX 批量推理，返回 N 个 Q 值
5. argmax Q → 选择最佳动作

推理后**必须释放** `OrtValue` 和 `OrtRunOptions`（在 `finally` 块中），否则原生内存泄漏。

## 3. 叫地主（BidAi）

DouZero 不负责 bidding，使用独立的 `BidAi`：

```
手牌强度 = 大王(4) + 小王(3) + 火箭(4) + 炸弹×8 + 2×3 + A×1
→ strength ≥ 18: 叫 3 分
→ strength ≥ 12: 叫 2 分
→ strength ≥ 7:  叫 1 分
→ 否则: 不叫
```

## 4. Fallback 策略

| 场景 | 处理 |
|------|------|
| ONNX 推理成功 | argmax Q → 选择最佳候选 |
| ONNX 推理失败 | 选择候选列表首个（保守降级） |
| 单一候选 | 直接返回（跳过 ONNX） |
| 无候选 | PassAction |

## 5. AI 对战测试

- 页面：`lib/ui/battle/battle_screen.dart`（WP 地主 vs WP 农民）
- 引擎：`lib/ai/battle_engine.dart`（支持 `keepReplays: false` 的 headless 模式）
- 自动化测试：`test/ai/battle_tournament_test.dart`

## 6. 已移除的组件

以下组件在 2026-07 精简中移除，此处记录供历史参考：

| 组件 | 说明 | 移除原因 |
|------|------|---------|
| HeuristicAi | 启发式 AI（手牌分解 + 贪心策略） | 被 DouZero 完全取代 |
| PimcAi | 完美信息蒙特卡洛（PIMC） | 被 DouZero 完全取代 |
| RolloutPolicy + HandDecomposer | 手牌分解与 rollout 策略 | 仅被 HeuristicAi/PimcAi 使用 |
| AiDifficulty 枚举 | easy/normal/hard 三档难度 | 仅一个 AI 实现，无需分档 |
| ADP / SL 模型 | 分差优化 / 监督学习变体 | WP 在胜率维度最强 |

## 7. 参考资料

- [DouZero: Mastering DouDizhu with Self-Play Deep RL (ICML 2021)](https://arxiv.org/abs/2106.06135) · [GitHub](https://github.com/kwai/DouZero)
- [palemoky/douzero-baselines · ONNX 镜像](https://huggingface.co/palemoky/douzero-baselines) · Apache-2.0
- [onnxruntime_v2 Flutter 插件](https://pub.dev/packages/onnxruntime_v2)
- 对战实测数据：[11-ai-battle-results.md](./11-ai-battle-results.md)
