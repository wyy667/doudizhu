# 10 · 日本麻将功能可行性分析

> **状态**：暂不实施。本文档记录 2026-07 的调研结论，避免后续重复工作。
> **结论**：在当前条件下，集成强力麻将 AI 的成本过高、风险过大。如果未来重启此功能，建议从 **混合架构**（本地规则引擎 + MJAI Server API）入手。

---

## 1. 背景

考虑在现有斗地主 Flutter App 中扩展日本麻将（立直麻将）功能，核心诉求是接入强力 AI 对手。调研了以下技术路径：

- Mortal（最强开源日麻 AI）+ flutter_rust_bridge + MJAI 协议
- Akochan（经典统计 AI）集成
- 联网 API 方案
- 自研启发式 AI

---

## 2. Mortal 集成分析

### 2.1 项目概况

| 属性 | 详情 |
|------|------|
| 仓库 | [Equim-chan/Mortal](https://github.com/Equim-chan/Mortal) |
| 语言 | Rust 85.8% + Python 13.4% |
| Stars | 1.5K |
| AI 类型 | 深度强化学习（ResNet + Dueling DQN） |
| 许可证 | **AGPL-3.0-or-later** |
| AI 强度 | 目前最强开源日麻 AI |

### 2.2 网络结构（源码 `mortal/model.py`）

```
Brain (特征提取器):
  Conv1d(in_ch, conv_ch, 3) → BatchNorm1d → Mish
  × [ResBlock with ChannelAttention] × num_blocks
  Conv1d(conv_ch, 32, 3) → Mish → Flatten → Linear(32×34, 1024)
  → phi (1024维特征向量)

DQN (动作评估器, Dueling DQN):
  v_head: Linear(1024, 512) → Mish → Linear(512, 1)
  a_head: Linear(1024, 512) → Mish → Linear(512, 47)  ← ACTION_SPACE
  Q = V + A - A_mean
```

- 有 4 个版本（v1-v4），v1 额外有 VAE 式 latent space（mu/logsig）
- 使用 BatchNorm1d（momentum=0.01, eps=1e-3）、Mish 激活、Channel Attention
- 依赖 `libriichi.consts: obs_shape, oracle_obs_shape, ACTION_SPACE, GRP_SIZE`

### 2.3 libriichi 架构（致命问题）

libriichi **不是独立 Rust 库**，而是 PyO3 Python 扩展模块：

```toml
# libriichi/Cargo.toml
crate-type = ["cdylib"]                    # 编译为 Python 扩展
pyo3 = { features = ["extension-module"] } # 绑定 Python 解释器
default = ["pymod"]
```

推理流程（从源码 `agent/mortal.rs` 确认）：

```
Python (mortal.py)
  └─ Bot.react(mjai_json)           ← #[pyclass]，被 Python 调用
       ├─ PlayerState.update()      ← 纯 Rust，游戏状态管理 ✅
       ├─ agent.set_scene()         ← rayon 并行特征编码 ✅
       │    └─ state.encode_obs()   ← 纯 Rust，千行复杂编码 ✅
       ├─ agent.get_reaction()
       │    └─ self.evaluate()
       │         └─ Python::with_gil()   ← 回调 Python！ ❌
       │              └─ engine.react_batch(obs, masks)  ← PyTorch 推理
       └─ 返回 MJAI JSON
```

**核心问题**：`MortalBatchAgent` 每次推理都通过 `Python::with_gil()` 回调 Python 执行 PyTorch 模型。没有 Python 运行时，推理管道完全断裂。

### 2.4 模型权重不公开（最大阻碍）

作者 Equim 在 [gist](https://gist.github.com/Equim-chan/cf3f01735d5d98f1e7be02e94b288c56) 中明确表态（2022-08-19）：

> 鉴于在线版本 mjai.ekyu.moe 已经基本实现了所期望的功能，**目前没有公开模型参数的计划**。

原因：防止用于在线平台作弊。

自行训练需要：
- 数月高规格 GPU 时间（RTX 4090 级别）
- 天凤牌谱数据集（作者未公开数据集和获取方式）
- 完整训练配置（未完全公开）

### 2.5 可行性评估

| 维度 | 结论 |
|------|------|
| 模型获取 | ❌ 权重不公开，自行训练需数月 GPU + 数据集 |
| 移动端集成 | ❌ libriichi 是 PyO3 扩展，需剥离 Python 依赖（等于重写半个 Mortal） |
| 桌面端子进程 | ⚠️ 架构可行，但仍需权重 |
| ONNX 路径 | ❌ 需权重 + 剥离 PyO3 + 重写 agent 层 |
| 许可证 | ⚠️ AGPL-3.0，代码集成要求 App 开源；协议通信不受约束 |
| **整体** | **不可行** |

### 2.6 PerfectDou 教训（已验证）

此前曾尝试集成 PerfectDou（另一个斗地主 AI 变体），发现其仓库中的 ONNX 模型实际是 DouZero ADP 基线的副本（Q 值完全一致）。真正的 PerfectDou 使用不同的编码系统（Cython 编译，无法移植）。**已从项目中移除 PerfectDou 相关代码。**

---

## 3. Akochan 集成分析

### 3.1 项目概况

| 属性 | 详情 |
|------|------|
| 仓库 | [critter-mj/akochan](https://github.com/critter-mj/akochan) |
| 语言 | C++ (99.6%) |
| Stars | 296 |
| AI 类型 | **经典统计 AI**（非神经网络） |
| 预训练参数 | **包含在仓库内**（`params/` 目录，数百个 .txt 文件） |
| 许可证 | **自定义日本语专有许可**（非 MIT/GPL/OSI 认证） |
| 维护状态 | 2020 年后基本停滞（87 commits 总计） |
| AI 强度 | 天凤凤凰位稳定水平（弱于 Mortal） |

### 3.2 AI 架构

无神经网络。使用预计算统计概率表 + 蒙特卡洛模拟计算期望顺位得分：

```
ai_src/                       ← 编译为 ai.dll / libai.so
├── selector.cpp              ← 动作选择器（核心决策）
├── exp_values.cpp            ← 期望值计算
├── tactics.cpp               ← 战术配置
├── tenpai_est.cpp            ← 听牌概率估计
├── betaori.cpp               ← 弃和策略
├── agari.cpp                 ← 和牌分析
└── ...

params/                       ← 预训练统计参数（随仓库发布）
├── tenpai_prob/ako/          ← 听牌概率表（~100个文件）
├── agari_prob/ako/           ← 和牌概率表
├── houjuu_prob/ako/          ← 放铳概率表
├── betaori/ako/              ← 弃和参数
├── rank_prob/ako/            ← 顺位概率
└── ... (共14类概率表)
```

### 3.3 MJAI 通信接口

`main.cpp` 提供 `pipe` 模式：

```bash
system.exe pipe <tactics.json> <player_id>
# stdin 读取 MJAI 事件 JSON
# stdout 输出最佳动作 JSON
```

### 3.4 许可证分析（关键风险）

LICENSE 是自定义日本语专有许可，关键条款：

1. **使用**：研究/学习免费；商业使用需作者书面授权
2. **再分发**：需注明出处；**修改 AI 参数后再分发明确禁止**
3. **著作权**：归作者所有
4. **管辖**：日本国法律，东京地方法院专属管辖
5. **变更**：作者可不经通知变更条款

**商业 App（内购/广告）必须联系作者 critter 获得书面授权。**

### 3.5 可行性评估

| 维度 | 结论 |
|------|------|
| 模型获取 | ✅ 预训练参数直接包含在仓库 |
| 桌面端集成 | ✅ pipe 模式 + 子进程，无 Python 依赖 |
| 移动端集成 | ⚠️ 需 NDK 交叉编译 + extern "C" 封装 + Boost 适配 |
| 许可证 | ❌ 自定义专有许可，商业使用需授权 |
| 维护状态 | ❌ 项目停滞，无上游支持 |
| AI 强度 | ⚠️ 中等（凤凰位水平），弱于 Mortal |
| **整体** | **桌面可行/移动困难，许可证和维护是两大隐患** |

---

## 4. 联网 AI 方案

### 4.1 MJAI Server API（最推荐）

**[MJAI Server](https://mjai-blog.7xcnnw11phu.eu.org/)** 是第三方托管的 REST API 服务，提供多个强力日麻 AI 模型的在线访问。

#### API 流程

```
// 1. 注册/登录
POST /user/register  {"name":"xxx","secret":"xxx"}
POST /user/trial     （临时 IP 账号，试用码：FREE_TRIAL_SPONSORED_BY_MJAPI_DiscordID_9ns4esyx）

// 2. 开局
POST /mjai/start  {"model":"canary-v1","player_id":0}

// 3. 每步查询
POST /mjai/act  {"seq":1,"event":{"type":"tsumo","actor":0,"pai":"1s"}}
→ {"type":"dahai","actor":0,"pai":"3p","tsumogiri":false}

// 4. 批量模式
POST /mjai/batch  {"events":[...]}
```

- API 根：`https://mjai.7xcnnw11phu.eu.org`
- 文档：`https://mjai-doc.7xcnnw11phu.eu.org`
- Playground：`https://mjai-ui.7xcnnw11phu.eu.org`
- 速率限制：1 req/s 软限，2 req/s 硬限
- 最大请求体：4KB
- Session：1 小时超时

#### 可用模型

| 模型 | 用户等级 | 架构 | 训练数据 | 推理成本 |
|------|---------|------|---------|---------|
| `mini` | 0 (试用) | SuperLite I v1 | 185M 行 | 0.01 |
| `medium` | 1 (注册) | Lite I v1 | 160M 行 | 0.03 |
| `canary-v1` | 1 (注册) | RR v0 | 250M 行 | 0.05 |
| `experimental-v2` | 1 (注册) | OG A | 700M 行 | 0.05 |
| `finetuned-s2` | 2 (研究) | RF v4 | 1.35B 行 | 0.05 |

#### 性能参考

`canary-v1` 在 10 万局半庄中对 `akagi-v4`（强模型）的平均顺位 2.471，平均 pt +2.651。

#### 优势

- **零集成成本**：纯 HTTP API，Dart `http` 包即可调用
- **跨平台**：移动/桌面/Web 全平台一致
- **强力 AI**：多个深度学习模型可选
- **无许可证风险**：不分发模型代码/权重，仅调用 API
- **持续更新**：2025年3月仍有新模型发布

#### 风险

| 风险 | 严重度 | 说明 |
|------|--------|------|
| 服务依赖 | 高 | 第三方个人运营，无 SLA |
| 商业授权 | 高 | 面向"研究学习"，商业使用需联系作者（Discord: `9ns4esyx`） |
| 配额 | 中 | 24h 有限查询次数，免费用户较少 |
| 网络延迟 | 低 | 50-300ms，回合制可接受 |

### 4.2 自建服务器

| 后端 | 服务器要求 | 月成本 | AI 强度 |
|------|-----------|--------|---------|
| akochan | 2核 CPU VPS | ~$5-10 | ★★★☆ |
| Mortal (自训) | GPU 服务器 | ~$50-200 | ★★★★★ |
| MJAI Server API | 无 | $0 | ★★★★ |

### 4.3 混合架构（如果重启此功能的首选方案）

```
┌─────────────────────────────────────┐
│           Flutter App               │
│                                     │
│  ┌──────────┐   ┌────────────────┐  │
│  │ 本地引擎  │   │  AI 决策层     │  │
│  │ (Dart)   │   │                │  │
│  │ ·牌局逻辑│   │  有网络?       │  │
│  │ ·和牌判定│   │  ├─是→ MJAI API│  │
│  │ ·符翻计算│   │  └─否→ 启发式  │  │
│  │ ·合法动作│   │                │  │
│  └──────────┘   └────────────────┘  │
│                                     │
│  ┌─────────────────────────────┐   │
│  │       UI (Flutter)          │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

本地必须实现的部分（任何方案都需要）：
- 麻将规则引擎（发牌、合法动作验证、和牌判定、符翻计算、流局处理）
- 这部分用 Dart 实现，不依赖 AI

AI 决策可插拔：
- 在线模式 → MJAI Server API（强力）
- 离线模式 → 启发式（中等）

---

## 5. 自研启发式 AI 评估

### 5.1 难度分析

| 维度 | 斗地主 | 日本麻将 |
|------|--------|----------|
| 牌种类 | 54 张（15 点数 × 4） | 136 张（34 种 × 4） |
| 手牌规模 | 17-20 张 | 13 张 + 摸/弃循环 |
| 信息可见性 | 明牌为主 | **高度隐藏** |
| 和牌判断 | 无（出完即胜） | **极其复杂**（符/翻/役种/役满） |
| 听牌判断 | 无 | 需复杂 shanten 算法 |
| 攻防判断 | 较简单 | **核心难题**（需概率模型） |
| 役种约束 | 无 | 几十种（立直/一发/断幺/平和/染手/...） |
| 顺位意识 | 无 | **日麻核心**（非对称效用函数） |

### 5.2 纯启发式预期水平

- 打牌选择（shanten + 效率表）：能做到"看起来会打"
- 攻防判断：**致命弱点**——没有概率模型，无法估算放铳损失
- 预期强度：天凤 3-4 段（中级），缺乏挑战性

### 5.3 结论

编写难度大（日麻规则引擎 + shanten + 役种判定 + 攻防 EV），且效果不佳（用户不会觉得 AI 有挑战性）。**暂不考虑。**

---

## 6. 其他相关项目（参考）

| 项目 | 类型 | 说明 |
|------|------|------|
| [Cryolite/kanachan](https://github.com/Cryolite/kanachan) | 日麻 AI | 另一个日麻 AI 框架，未深入调研 |
| [gimite/mjai](https://github.com/gimite/mjai) | MJAI 服务器 | 日麻 AI 对战游戏服务器（Ruby） |
| [RiichiLab](https://riichi.dev) | AI 竞技平台 | 开放日麻 AI 对战平台，WebSocket + MJAI |
| [Akagi](https://github.com/shinkuan/Akagi) | 辅助工具 | 支持雀魂/天凤/雀魂一番街的 AI 辅助工具 |
| [akochan-docker](https://github.com/Apricot-S/akochan-docker) | Docker | akochan 的 Docker 化部署 |
| [mjai-reviewer](https://github.com/Equim-chan/mjai-reviewer) | 牌谱检讨 | Mortal 作者的另一项目，支持 Mortal 和 akochan 后端 |

---

## 7. 总结与建议

### 综合对比

| 方案 | 可行性 | AI 强度 | 离线 | 许可证 | 推荐 |
|------|--------|---------|------|--------|------|
| Mortal 集成 | ❌ | ★★★★★ | ✅ | AGPL-3.0 | 不推荐 |
| Akochan 桌面 | ⚠️ | ★★★ | ✅ | 专有(需授权) | 可考虑 |
| Akochan 移动 | ⚠️困难 | ★★★ | ✅ | 专有(需授权) | 不推荐 |
| MJAI Server API | ✅ | ★★★★ | ❌ | 需协商 | **首选** |
| 混合(本地+API) | ✅ | ★★★★~★★★ | ⚠️ | 需协商 | **首选** |
| 纯本地启发式 | ✅ | ★★ | ✅ | 无限制 | 不推荐 |

### 如果未来重启

推荐分步骤：

1. **规则引擎**（Dart）：合法动作、和牌判定、符翻计算——任何方案的基础
2. **接入 MJAI Server API**：作为主力 AI
3. **启发式回退**：离线时使用
4. **联系 MJAI Server 作者**确认商业使用条款
