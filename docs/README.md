# Landlord（斗地主）设计文档集

> 本项目是一个基于 Flutter 3 的斗地主游戏，采用横屏模式，从「单机人机对战」起步，逐步演进到「多玩法 + 联网对战」。
>
> 本文档集遵循 spec-driven（规范驱动）开发流程，文档之间相互引用、层层递进。任何代码改动都应先更新对应文档。

## 文档总览

| 文档 | 内容 | 面向 |
|------|------|------|
| [01-product.md](./01-product.md) | 产品愿景、用户画像、功能矩阵、商业目标 | 所有人（先读） |
| [02-tech-stack.md](./02-tech-stack.md) | 技术选型与决策依据（Flutter/状态管理/AI/联网） | 开发 |
| [03-project-structure.md](./03-project-structure.md) | 目录结构、命名规范、分层约定 | 开发 |
| [04-game-rules.md](./04-game-rules.md) | 斗地主完整规则与 14 种牌型（核心领域知识） | 开发（必读） |
| [05-architecture.md](./05-architecture.md) | 系统架构、状态机、数据模型、游戏循环 | 开发 |
| [06-ai-strategy.md](./06-ai-strategy.md) | AI 算法演进路线（启发式 → MCTS → DouZero） | 开发 |
| [07-multiplayer-design.md](./07-multiplayer-design.md) | 联网对战架构（房间制/协议/防作弊） | 开发 |
| [08-roadmap.md](./08-roadmap.md) | 分阶段开发路线图与里程碑 | 所有人 |
| [09-design-mvp.md](./09-design-mvp.md) | Phase 1 MVP 的详细设计（可执行） | 开发 |
| [10-mahjong-feasibility.md](./10-mahjong-feasibility.md) | 日本麻将功能可行性分析（暂不实施） | 开发 |
| [11-ai-battle-results.md](./11-ai-battle-results.md) | DouZero ADP/WP/SL 模型对战实测与理论分析 | 开发 |
| [12-backend-setup.md](./12-backend-setup.md) | 后端部署与配置手册（Supabase + LiveKit + Firebase） | 运维/开发 |

## 阅读建议

- **快速了解全貌**：按 `01 → 08` 的顺序读。
- **准备动手开发 Phase 1**：`01 → 04 → 05 → 09`，再参考 `02/03`。
- **只想看技术决策**：直接看 `02` 和各文档的「决策与依据」小节。
- **研究 AI**：`06` 是独立的、相对深入的一篇。

## 项目阶段全景

```
Phase 1   ─ 单机 MVP（人 vs 2 AI，经典斗地主）          ✅ 已完成
    │
Phase 2   ─ 玩法与体验丰富（叫分制/战绩/春天）           ✅ 已完成
    │
Phase 2.5 ─ DouZero ONNX 端侧集成（SOTA）                ✅ 已完成
    │
Phase 2.6 ─ AI 精简：仅保留 DouZero WP                   ✅ 已完成
    │
Phase 3   ─ 联网对战（Supabase + Firebase + LiveKit 语音）  ✅ 已完成
    │
Phase 4   ─ 社交与生态（账号、好友、排行、赛事、观战）
```

## 决策原则

1. **领域逻辑与表现层完全隔离** —— 规则引擎 (`core/`) 不依赖 Flutter，可独立单测，也为未来「服务端权威」铺路。
2. **渐进式复杂度** —— 每个阶段都可独立交付、可玩；不提前实现后续阶段。
3. **可替换的 AI 与网络层** —— AI 引擎和联网后端都通过接口抽象，便于升级（如接入 DouZero 模型）。
4. **横屏优先** —— 所有界面按横屏设计，竖屏不作为目标形态。
