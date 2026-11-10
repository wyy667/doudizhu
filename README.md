# landlord · 经典斗地主

> 本仓库是基于 [Sanotsu/landlord](https://github.com/Sanotsu/landlord) 的二次修改版本，原项目作者为 Sanotsu。AI 模型与相关算法来自 [kwai/DouZero](https://github.com/kwai/DouZero)。感谢原作者的工作。

本次二改主要加入和调整了局域网联机、人机补位、系统 TTS 报牌、长期积分与牌桌界面，并为公开发布移除了共享后端配置。原始代码、文档及 AI 来源详见文末来源说明。

Flutter 开发的经典模式斗地主：单机 AI 对战 + 局域网联机（无需服务器 / 外网）。AI 采用 DouZero WP（ICML 2021 SOTA）端侧 ONNX 推理。

> 完整设计文档见 [`docs/`](./docs)（13 篇，覆盖产品愿景 → 技术选型 → 架构 → 路线图 → 部署手册）。

## 当前状态

单机完整可玩 + 局域网联机（同一 Wi-Fi / 热点，缺人由房主设备上的人机补位）+ 动画特效 + TTS 报牌 + 联机中地主可明牌等。

目前只构建测试了 Android 设备：

- Android 14 & Android 12 (努比亚 Z60 Ultra 和 小米 6)
- 其他系统请自行构建测试

## 安装下载

本仓库发布源码，暂未上传 APK。请按下文自行构建；本机已有 APK 不纳入发布。

联机为局域网模式，无需任何配置，具体见下方[局域网联机](#section1)。

### 核心功能

**游戏引擎**（`lib/core/`，纯 Dart，零 Flutter 依赖）

- 14 种牌型识别 + 比较规则
- 状态机：发牌 → 叫分（1/2/3 分）→ 出牌 → 结算
- 春天 / 反春天判定（×2 倍数，`playCount` 追踪出牌轮数）
- 三人都不叫时强制首家叫 1 分
- **规则变体**（`RuleVariant`）：参数化叫分上限 / 炸弹倍率 / 春天开关 / 是否洗牌；内置经典 / 不洗牌预设

**AI**（`lib/ai/`）

- **DouZero WP** 端侧 ONNX 推理，3 个预训练模型（landlord / landlord_up / landlord_down，各 ~6 MB）
- 特征编码精确移植 `kwai/DouZero`
- ONNX Runtime 在 `android/app/build.gradle.kts` 中强制为 1.25.1：插件自带的 1.23.2 会在骁龙 SM8845/SM8850 等（支持 SME 但不支持 SME2）的设备上推理时 SIGILL 闪退（[onnxruntime#27884](https://github.com/microsoft/onnxruntime/issues/27884)）
- 叫分策略（手牌强度评估）
- 单机 1 人 vs 2 AI；局域网房间空位 / 掉线玩家由人机代打（推理只在房主设备运行）
- AI 对战测试（WP 地主 vs WP 农民自动对战）

**单机体验**

- 战绩统计（胜率 / 连胜 / 倍数 / 春天次数，SharedPreferences 持久化，按规则变体筛选）
- **长期积分**：初始 1000，每局按 倍数 × 身份（地主 2 / 农民 1）× 10 增减（单机与局域网均计入），首页 / 牌桌 / 结算面板显示，可在设置中重置回 1000
- 对局复盘（逐帧重演三方手牌 + 播放控制）
- 出牌 **系统 TTS 报牌**（「对三」「顺子」「王炸」「要不起」「我只剩两张牌了」，三座位不同音调）+ 震动反馈；选牌/胜负保留程序音效
- 调试模式
- **专业牌桌布局**：绒布牌桌 + 顶栏（记牌器 / 底牌 / 底分倍数）；对手为头像 + 身份角标 + 叠放牌背与剩余张数（≤2 张报警），不再逐张平铺；三方独立出牌区与「不出 / 叫分」气泡
- **动画体系**：发牌飞牌动画、出牌弹出（scale + fade）、手牌收拢（AnimatedPositioned）、被压渐暗、当前回合光环
- **结算面板**：胜负 + 倍数 + 春天 + 三方得分，可「看牌」查看剩余手牌
- **炸弹 / 火箭全屏特效**：径向渐变闪光 + 大字提示

**局域网联机**（`lib/net/`，房主权威模式）

- **房主设备即服务器**：`LanRoomServer` 在房主手机上启动 WebSocket 服务（默认端口 45678），每秒 UDP 广播房间（端口 45679），其他人在大厅自动发现或手动输入房主 IP
- 同一 Wi-Fi，或连接房主手机热点即可，**不需要外网 / 云服务 / 注册**
- 房主权威：房主执行引擎计算并下发状态；每位玩家只收到**自己的手牌**，非房主无法篡改对局（服务端按座位校验请求）
- **人机补位**：开始游戏时空位自动由人机补齐；对局中玩家掉线**立即**由人机托管（DouZero 推理固定在房主设备），重连后点击手牌区即可收回
- 断线自动重连（同一身份找回原座位）；房主离开 = 解散房间，其他玩家收到提示
- 出牌超时 30s 自动托管 + 明牌（仅地主、首出前，倍数 ×2）
**文字聊天**（`lib/chat/`）

- 局域网房间内文字聊天（经房主转发）

**UI 一致性**

- 全局暗色弹窗主题（`DialogThemeData`），所有 AlertDialog 与牌桌绿一致

### 验证

```bash
flutter test
flutter analyze
```

## 运行

### 单机模式（零配置）

```bash
git clone https://github.com/wyy667/doudizhu.git landlord
cd landlord
flutter pub get
flutter run       # 建议真机横屏
```

<span id="section1"></span>

### 局域网联机（零配置）

1. 所有人连接**同一 Wi-Fi**，或房主打开手机热点、其他人连接该热点（无需流量 / 外网）
2. 房主：首页「局域网联机」→「创建房间」→ 可点空位添加人机 →「开始游戏」（剩余空位自动由人机补齐）
3. 其他人：首页「局域网联机」→ 在「附近的房间」中点「加入」；若路由器屏蔽广播，可在底部输入房主地址（房间页有显示）手动连接
4. 人机与掉线托管的 AI 推理都在房主设备上运行，其他设备只负责显示和操作

> 桌面端同机多开调试：启动前设置环境变量 `LANDLORD_PROFILE=a` / `b` 即可使用不同身份。
>
> 旧的 Supabase 云端联机实现（`lib/net/supabase_room_client.dart`、`supabase/`）仍保留在仓库中，但 UI 已不再使用。
## 技术栈

| 领域     | 技术                                                 |
| -------- | ---------------------------------------------------- |
| 框架     | Flutter 3.x / Dart ^3.11                             |
| 状态管理 | Riverpod 2.x                                         |
| AI 推理  | ONNX Runtime（端侧，DouZero WP 模型）                |
| 联网     | 局域网：dart:io WebSocket + UDP 广播发现（房主权威）  |
| 音效     | audioplayers（选牌/胜负）+ flutter_tts（系统 TTS 报牌） |
| 持久化   | SharedPreferences（战绩 / 设置 / 后端配置）          |

## 项目结构

```
lib/
├── core/              # 领域核心（纯 Dart，零 Flutter 依赖）
│   ├── card.dart            #   扑克牌
│   ├── deck.dart            #   牌堆
│   ├── game_engine.dart     #   游戏引擎（参数化 RuleVariant）
│   ├── game_state.dart      #   游戏状态（含 ruleVariant / brightSeats）
│   ├── rule_variant.dart    #   ★ 规则变体数据类 + 预设
│   ├── app_config.dart      #   ★ 运行时后端配置（SharedPreferences）
│   ├── hand_detector.dart   #   牌型识别（14 种）
│   ├── hand_compare.dart    #   牌型比较
│   └── ...
├── ai/                # AI 策略
│   ├── douzero_ai.dart      #   ★ DouZero WP 统一入口
│   ├── bid_ai.dart          #   叫地主策略
│   ├── battle_engine.dart   #   AI 对战引擎
│   └── douzero/             #   ONNX 集成子模块
│       ├── douzero_encoder.dart    #   特征编码
│       ├── douzero_inference.dart  #   ONNX 推理
│       └── douzero_moves.dart      #   合法动作枚举
├── stats/             # 战绩持久化
├── state/             # Riverpod 编排
├── net/               # 联网层（局域网）
│   ├── net_game_session.dart    #   联机会话（序列化/反序列化/座位重映射）
│   ├── protocol.dart            #   通信协议 + 数据模型
│   ├── room_client_base.dart    #   抽象基类（保留枚举以便扩展）
│   ├── room_client.dart         #   Provider 定义（NetBackend 枚举 + roomClientProvider）
│   ├── lan/                     #   ★ 局域网实现
│   │   ├── lan_room_server.dart  #     房主服务（房间数据 + WebSocket + 广播）
│   │   ├── lan_room_client.dart  #     RoomClientBase 实现（房主本机 / 远端 + 自动重连）
│   │   ├── lan_discovery.dart    #     UDP 房间发现 + 本机地址
│   │   └── local_profile.dart    #     本机身份（uid + 昵称）
│   └── supabase_room_client.dart#   Supabase 实现（保留，UI 未使用）
├── voice/             # 语音（LiveKit，局域网模式未使用）
│   ├── voice_chat_controller.dart   #   连接/断连重连/单人自删/推麦
│   └── voice_token_service.dart     #   Edge Function 调用（Token + 管理）
├── chat/              # 文字聊天
├── audio/             # 音效 + TTS 报牌
├── supabase_init.dart #   Supabase 懒初始化（从 AppConfig 读取）
└── ui/                # 表现层
    ├── game/                # 单机游戏界面 + 卡牌/语音组件
    ├── lobby/               # 局域网大厅（发现/开房/手动连接）/ 等待室 / 联机牌桌
    ├── replay/              # 对局复盘
    ├── battle/              # AI 对战
    ├── stats/               # 战绩统计
    ├── settings/            # 设置
    ├── setup/               # Supabase 后端配置页（保留，UI 未使用）
    └── chat/                # 聊天浮层
```

## 云端后端（已停用）

局域网联机不需要以下组件，仅作历史保留：

| 组件                                        | 说明                                                                         |
| ------------------------------------------- | ---------------------------------------------------------------------------- |
| `supabase/schema.sql`                       | 建表 SQL（rooms + room_chat + RLS + Realtime + 索引）                        |
| `supabase/cleanup_stale_rooms.sql`          | 过期房间自动清理（SECURITY DEFINER + CASCADE + cron 30 min）                 |
| `supabase/functions/get-voice-token/`       | Edge Function：LiveKit Token 签发 + 管理员操作（list / delete / delete-all） |
| `supabase/scripts/setup.mjs`                | ★ 一键配置脚本（自动建表 + 部署 Function + 设 Secrets + 验证）               |
| `supabase/scripts/delete_livekit_rooms.cjs` | Node.js 零依赖 LiveKit 管理脚本（内置 JWT 签发）                             |

> 部署与配置详见 [`docs/12-backend-setup.md`](./docs/12-backend-setup.md)。

## 补充说明

当前开发环境 Flutter 版本:

```sh
> flutter --version
Flutter 3.44.6 • channel stable • https://github.com/flutter/flutter.git
Framework • revision ee80f08bbf (4 weeks ago) • 2026-07-08 15:02:06 -0700
Engine • hash d3a3293399556a85388faf8c6f0723a7a5597aa8 (revision 83675ed276) (1 months ago) • 2026-06-30 16:59:03.000Z
Tools • Dart 3.12.2 • DevTools 2.57.0
```

## 来源与授权说明

本项目基于 [Sanotsu/landlord](https://github.com/Sanotsu/landlord) 修改，保留其代码及文档来源。上游在本次发布时未声明开源许可证，因此本仓库公开源码不代表已取得对上游代码的任意使用、修改或再分发授权；相关权利需与原作者确认。本仓库未为第三方代码擅自添加统一许可证。

AI 模型及特征编码来自 [kwai/DouZero](https://github.com/kwai/DouZero)，其 Apache-2.0 许可副本见 [THIRD_PARTY_LICENSES/DouZero-LICENSE](THIRD_PARTY_LICENSES/DouZero-LICENSE)。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 发布与本地配置

公开版本不包含共享 Supabase 默认地址/Key，旧共享配置会在加载时清除；单机和局域网模式无需云端配置。保留的云端实现需自行配置服务。

Android 签名证书、`android/key.properties`、SDK 路径配置、环境文件、日志、截图、APK 和构建缓存均不纳入发布。缺少发布证书时，Android release 构建使用调试签名以便本地体验；正式分发应使用自己的发布证书。

```bash
flutter pub get
flutter test
flutter analyze
flutter build apk --release
```

本次发布使用独立的干净 Git 历史，不携带上游旧提交中的配置值。隐私检查范围与结果见 [PUBLICATION_AUDIT.md](PUBLICATION_AUDIT.md)。
