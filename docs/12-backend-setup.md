# 12 · 后端部署与配置手册

> 联机对战需要你自己的 Supabase 项目 + LiveKit Cloud 项目。
> 单机模式无需任何后端配置。

---

## 快速开始：一键脚本（推荐）

### 前置条件

1. 已下载本项目源码（`git clone` 或 ZIP 解压），在项目根目录操作
2. 已注册 Supabase 账号 (supabase.com) 并创建项目
3. 已注册 LiveKit Cloud (cloud.livekit.io) 并创建项目，手上有以下信息：
   - API Key、API Secret、WebSocket URL
4. 已在 Supabase Dashboard 手动开启匿名登录（脚本无法自动完成此步）：
   - Dashboard → Authentication → Sign In / Providers → Allow anonymous sign-ins → 开启 → Save changes
5. 手上有 Supabase 数据库密码（创建项目时设置的）
6. Node.js >= 18

### 运行脚本

在**项目根目录**执行：

```bash
node supabase/scripts/setup.mjs
```

脚本自动完成：

| 步骤 | 操作 | 方式 |
|------|------|------|
| 1 | 安装 Supabase CLI | `npm install -g supabase` |
| 2 | 浏览器登录 | `supabase login` |
| 3 | 输入 project-ref | 交互 |
| 4 | 关联项目 | `supabase link` |
| 5 | 输入数据库密码 | 交互 |
| 6 | 建表 SQL | `supabase db query --linked` |
| 7 | 清理 SQL + pg_cron | 同上 |
| 8 | 部署 Edge Function | `supabase functions deploy` |
| 9 | 设置 LiveKit Secrets | `supabase secrets set`（交互输入凭据） |
| 10 | 验证 + 输出 Key | HTTP 测试 + CLI 获取 publishable key |

脚本结束后，终端会输出 Supabase URL 和 Publishable Key，填入 App 即可。

> 如脚本某步失败，会提示你手动在 Dashboard 完成。也可完全跳过脚本，按下方手动步骤操作。

---

## 手动配置流程

> 如果脚本不可用或你更倾向于逐步操作，按以下步骤进行。

```
1. 创建 Supabase 项目
2. 执行建表 SQL（rooms + room_chat + RLS + Realtime）
3. 执行清理 SQL（cleanup 函数 + cron 定时任务）
4. 启用匿名登录
5. 部署 Edge Function
6. 创建 LiveKit Cloud 项目
7. 设置 Supabase Secrets（关联 LiveKit）
8. 在 App 中填入 Supabase URL + Key
```

---

## 1. 创建 Supabase 项目

1. 访问 https://supabase.com → 注册 → **New Project**
2. 填写：
   - **Name**: 自定义（如 `landlord`）
   - **Database Password**: 自行设置并记录
   - **Region**: 推荐 `Southeast Asia (Singapore)`（大陆延迟最低）
3. 等待 provisioning 完成（约 2 分钟）

---

## 2. 执行建表 SQL

进入 **Dashboard → SQL Editor → New query**，粘贴执行仓库中的 `supabase/schema.sql` 全部内容：

```sql
-- 文件位置：supabase/schema.sql
-- 创建：
--   rooms 表（房间主表，所有状态以 JSONB 存储）
--   room_chat 表（聊天记录，ON DELETE CASCADE 关联 rooms）
--   RLS 策略（认证用户可读写）
--   Realtime 发布（Postgres Changes）
--   索引
```

直接复制 `supabase/schema.sql` 全部内容粘贴到 SQL Editor 中运行即可。

---

## 3. 执行清理 SQL（定时任务）

同样在 SQL Editor 中，粘贴执行 `supabase/cleanup_stale_rooms.sql`。

### 3.1 前置：启用 pg_cron 扩展

如果尚未启用，先执行：

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

> Dashboard → Database → Extensions 也可启用。

### 3.2 执行清理脚本

```sql
-- 文件位置：supabase/cleanup_stale_rooms.sql
-- 功能：
--   1. 为 room_chat 添加 ON DELETE CASCADE 外键（首次执行）
--   2. 创建 cleanup_stale_rooms() 函数（SECURITY DEFINER 绕过 RLS）
--   3. 注册 cron 每 30 分钟清理超过 30 分钟未更新的房间
```

### 3.3 验证 cron

```sql
SELECT jobid, schedule, active, jobname FROM cron.job;
-- 应看到 cleanup-stale-rooms，active = true

SELECT cleanup_stale_rooms();
-- 手动执行一次，返回: Cleaned N rooms (cutoff=...)
```

---

## 4. 启用匿名登录

**Dashboard → Authentication → Sign In / Providers → Supabase Auth → User Signups → Allow anonymous sign-ins → 开启 → Save changes**

App 使用匿名登录（无需用户注册），自动获取 UID。

---

## 5. 部署 Edge Function

### 方式一：Dashboard 网页部署（推荐，无需安装任何工具）

1. **Dashboard → Edge Functions → Deploy a new function → Via Editor**
2. **Function name**: `get-voice-token`
3. 将仓库 `supabase/functions/get-voice-token/index.ts` 的代码粘贴进编辑器
4. 点击 **Deploy function**

### 方式二：CLI 部署

```bash
npm install -g supabase
supabase login
# project-ref 为 Project URL 中 .supabase.co 前面的长字符串
# 也就是 Dashboard → Project Settings → General settings → Project ID
supabase link --project-ref <你的project-ref>
supabase functions deploy get-voice-token
```

> 部署后验证：Dashboard → **Edge Functions** → 应看到 `get-voice-token`。

---

## 6. 创建 LiveKit Cloud 项目

1. 访问 https://cloud.livekit.io → 注册 → **Create Project**
2. 填写：
   - **Name**: 自定义（如 `landlord`）
   - **Region**: 选最近的（如 Singapore / Tokyo）
3. 进入项目 → **Settings**，记录以下三个值：

| 值                | 示例                                 |
| ----------------- | ------------------------------------ |
| **API Key**       | `APIxxxxxxxxx`                       |
| **API Secret**    | `xxxxxxxxxxxxxxxxxxxxxxxxx`          |
| **WebSocket URL** | `wss://landlord-xxxxx.livekit.cloud` |

---

## 7. 设置 Supabase Secrets

Edge Function 需要通过环境变量读取 LiveKit 凭据。

在 **Dashboard → Project Settings → Edge Functions → Secrets** 中添加：

| Secret 名            | 值                                                   |
| -------------------- | ---------------------------------------------------- |
| `LIVEKIT_API_KEY`    | LiveKit API Key                                      |
| `LIVEKIT_API_SECRET` | LiveKit API Secret                                   |
| `LIVEKIT_WS_URL`     | `wss://landlord-xxxxx.livekit.cloud`                 |
| `ADMIN_PASSWORD`     | 自定义管理员密码（用于 App 设置页管理 LiveKit 房间） |

或用 CLI 设置：

```bash
supabase secrets set LIVEKIT_API_KEY=APIxxxxxxxxx
supabase secrets set LIVEKIT_API_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxx
supabase secrets set LIVEKIT_WS_URL=wss://landlord-xxxxx.livekit.cloud
supabase secrets set ADMIN_PASSWORD=你的管理员密码
```

---

## 8. 在 App 中填入配置

1. 打开 App → 点击「联机对战」→ 弹出引导 → 「去配置」
2. 或：App → 设置 → Supabase 配置
3. 填入：
   - **Supabase URL**: Dashboard → Project Settings → API → Project URL
   - **Publishable / Anon Key**: 同页面 → Project API Keys → publishable key
4. 点击保存

> 首次保存后自动初始化并进入大厅。修改配置后需重启 App。

---

## Edge Function 功能说明

`get-voice-token` 是统一入口，处理所有 LiveKit 相关请求：

| 请求                                         | 用途                                  | 需要密码 |
| -------------------------------------------- | ------------------------------------- | :------: |
| `{roomId, uid}`                              | 签发 LiveKit JWT Token + 确保房间存在 |    否    |
| `{action: 'delete', roomId}`                 | 删除指定 LiveKit 房间（自动清理）     |    否    |
| `{action: 'delete', roomId, adminPassword}`  | 删除指定房间（管理员手动）            |    是    |
| `{action: 'list', adminPassword}`            | 列出所有活跃房间                      |    是    |
| `{action: 'delete-all', adminPassword}`      | 删除全部房间                          |    是    |
| `{action: 'verify-password', adminPassword}` | 验证管理员密码                        |    是    |

---

## 故障排查

### Supabase

| 症状                 | 原因                            | 解决                                                                   |
| -------------------- | ------------------------------- | ---------------------------------------------------------------------- |
| `Failed host lookup` | DNS 解析失败                    | 检查网络连接                                                           |
| RLS 拦截 DELETE      | cleanup 函数无 SECURITY DEFINER | 重新执行 cleanup_stale_rooms.sql                                       |
| cron 不执行          | pg_cron 扩展未安装              | Dashboard → Database → Extensions → 启用 pg_cron                       |
| Edge Function 500    | Secret 未设置                   | 检查 4 个 Secret 是否都已配置                                          |
| 匿名登录失败         | Anonymous 未启用                | Authentication → Sign In / Providers → Allow anonymous sign-ins → 开启 |

### LiveKit

| 症状           | 原因                             | 解决                                            |
| -------------- | -------------------------------- | ----------------------------------------------- |
| 语音连接失败   | WS URL / API Key / Secret 不匹配 | 检查 Supabase Secrets 与 LiveKit Dashboard 一致 |
| 房间删了又出现 | 内有真人断连后自动重连           | 正常行为，用「离开语音」按钮退出                |
| DeleteRoom 401 | Edge Function token 缺权限       | 确认 Edge Function 代码是最新版本               |

---

## 配置检查清单

```
□ Supabase 项目已创建（Singapore 推荐）
□ supabase/schema.sql 已执行（rooms + room_chat + RLS + Realtime）
□ pg_cron 扩展已启用
□ cleanup_stale_rooms.sql 已执行（函数 + cron）
□ Anonymous 认证已启用（Allow anonymous sign-ins）
□ Edge Function get-voice-token 已部署
□ LiveKit Cloud 项目已创建
□ 4 个 Secret 已设置（LIVEKIT_API_KEY / SECRET / WS_URL / ADMIN_PASSWORD）
□ App 中已填入 Supabase URL + publishable key
□ 联机对战测试通过
□ 语音群聊测试通过
```
