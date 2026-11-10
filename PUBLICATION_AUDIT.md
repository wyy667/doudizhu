# 公开发布检查记录

检查日期：2026-11-10（Asia/Shanghai）。

## 范围

检查本地 Flutter 应用的已跟踪文件、未跟踪源码与本机敏感文件名，并扫描应用原 Git 历史；另扫描本地 DouZero Git 历史。发布范围为 Flutter 应用当前源码、文档、模型与测试，不上传独立的 DouZero 源码副本和本地 APK。

使用 Gitleaks 8.30.1 进行密钥扫描，并补充检查环境配置、私钥/签名文件、本机用户路径、邮箱、服务地址及二进制文件中的私钥/Token/用户路径。文档中的服务占位地址、测试中的局域网示例地址及源码相对导入路径经人工复核后保留。

## 发现与处理

- 本地存在 Android 发布签名证书及 `android/key.properties`：仅保留在原本地开发目录，不复制、不提交、不上传。
- `android/local.properties`、IDE/SDK 配置、构建缓存、运行日志、截图和预编译 APK：排除发布。
- 原应用内置上游共享 Supabase URL 和 publishable Key：移除硬编码和启用方法；加载到旧共享配置时清除，保留用户自填后端配置的能力。Publishable Key 属于客户端公开访问 Key，此处移除是为了避免二改版本默认连接他人的服务。
- 原 Git 历史扫描命中 3 条 Firebase/Supabase Key 记录：本次使用独立的新 Git 仓库，仅提交清理后的当前源码，不携带这些历史记录。没有修改原本地仓库历史，也没有删除本地签名文件。
- DouZero 本地 Git 历史扫描未命中。
- 扩充 `.gitignore`，防止环境文件、签名材料和本机产物误入后续提交；提交作者使用 GitHub noreply 邮箱。

清理后的发布目录 Gitleaks 扫描：0 条命中。二进制补充检查未命中上述模式。提交后、推送前再次扫描实际待发布历史；详细脱敏扫描报告仅存本地临时审计目录。

## 验证

- `flutter pub get`：通过；保留应用依赖锁文件。
- `flutter test --reporter compact`：135 项测试通过，包含新增的旧共享配置清理与用户配置保留测试。
- `flutter analyze --no-pub`：通过，无问题（通过 ASCII 目录别名绕过首次分析服务异常）。
- `dart analyze`：通过，无问题。
- 未重新构建或发布 APK；现有 ONNX smoke 测试允许本机缺少 native binding 时输出诊断，因此测试通过不等同于 Android 真机 AI 验证。

为便于未配置私有发布证书的开发者运行，Android 构建在缺少 `key.properties` 时使用调试签名；正式分发应自行配置发布证书。删除了已不存在的音效目录声明（音效由程序生成）。

## 来源与许可证

本仓库为 https://github.com/Sanotsu/landlord 的二次修改版本（本地上游基线 `f3a06a6`），AI 来源 https://github.com/kwai/DouZero 。README 和 THIRD_PARTY_NOTICES.md 已标注来源与主要修改。DouZero 的 Apache-2.0 许可文本随附；Flutter 原项目未声明许可证，本仓库没有擅自为第三方代码授予统一开源许可。公开源码与完整的开源再分发授权应予区分。
