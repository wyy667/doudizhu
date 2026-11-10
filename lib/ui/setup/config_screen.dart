import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../supabase_init.dart';

/// 后端服务配置页。
///
/// 用户填写自己的 Supabase 项目 URL + publishable key。
/// 首次保存后自动初始化 Supabase；修改配置后需重启 App。
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  bool _saving = false;
  bool _showInstructions = false;
  bool _isAuthorConfig = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await AppConfig.load();
    if (mounted) {
      _urlController.text = config.supabaseUrl;
      _keyController.text = config.supabaseAnonKey;
      setState(() => _isAuthorConfig = config.isAuthorConfig);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      _showError('URL 和 Key 不能为空');
      return;
    }
    if (!url.startsWith('https://')) {
      _showError('URL 必须以 https:// 开头');
      return;
    }

    setState(() => _saving = true);

    final alreadyInitialized = SupabaseService.isInitialized;

    await AppConfig(
      supabaseUrl: url,
      supabaseAnonKey: key,
      isAuthorConfig: false,
    ).save();

    if (mounted) setState(() => _isAuthorConfig = false);

    if (!alreadyInitialized) {
      try {
        await SupabaseService.ensureInitialized();
      } catch (e) {
        _showError('初始化失败：$e');
        if (mounted) setState(() => _saving = false);
        return;
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(alreadyInitialized ? '配置已保存，重启 App 后生效' : '配置已保存 ✓'),
        backgroundColor: alreadyInitialized ? Colors.orange : Colors.green,
      ),
    );

    if (alreadyInitialized) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20),
      appBar: AppBar(
        // title: const Text('后端配置', style: TextStyle(color: Colors.white)),
        title: RichText(
          text: TextSpan(
            text: '后端配置 ',
            style: TextStyle(color: Colors.white, fontSize: 22),
            children: const <TextSpan>[
              TextSpan(
                text: '(要用到电脑和 https://github.com/wyy667/doudizhu 仓库中文件)',
                style: TextStyle(color: Colors.orange, fontSize: 15),
              ),
            ],
          ),
        ),
        backgroundColor: const Color(0xFF0D3F12),
        iconTheme: const IconThemeData(color: Colors.white),
        // actions: [
        //   const Text(
        //     '联机对战需要配置你自己的 Supabase 项目',
        //     style: TextStyle(color: Colors.white, fontSize: 15),
        //   ),
        // ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isAuthorConfig) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '当前使用作者提供的配置，可能随时不可用。强烈建议配置你自己的 Supabase 项目。',
                        style: TextStyle(color: Colors.orange, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: const Padding(
                    padding: EdgeInsets.only(top: 15),
                    child: Text(
                      'Supabase URL',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecoration('https://xxxx.supabase.co'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: const Padding(
                    padding: EdgeInsets.only(top: 15),
                    child: Text(
                      'Publishable key',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _keyController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: _inputDecoration("sb_publishable_... 或 eyJ..."),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.save),
                label: const Text(
                  '保存',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // ── 配置指引 ──
            GestureDetector(
              onTap: () =>
                  setState(() => _showInstructions = !_showInstructions),
              child: Row(
                children: [
                  Icon(
                    _showInstructions ? Icons.expand_less : Icons.expand_more,
                    color: Colors.amber,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '如何获取 Supabase 配置？',
                    style: TextStyle(
                      color: Colors.amber,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            if (_showInstructions) ...[
              const SizedBox(height: 12),
              _buildInstructions(),
            ],
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.white24, fontSize: 13),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      filled: true,
      fillColor: Colors.black.withValues(alpha: 0.3),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.amber),
      ),
    );
  }

  Widget _buildInstructions() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 一键脚本提示 ──
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.bolt, color: Colors.green, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '快速方式：在项目根目录运行\nnode supabase/scripts/setup.mjs\n可自动完成步骤 2~8 并输出 Key',
                    style: TextStyle(color: Colors.green, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _step(
            '1',
            '创建 Supabase 项目',
            'supabase.com → New Project\n区域推荐 Southeast Asia (Singapore)',
          ),
          _step(
            '2',
            '在 Supabase 中执行建表 SQL',
            'Dashboard → SQL Editor\n粘贴执行 supabase/schema.sql\n（创建 rooms / room_chat 表 + RLS + Realtime）',
          ),
          _step(
            '3',
            '在 Supabase 中执行清理 SQL',
            '同一 SQL Editor 中执行 supabase/cleanup_stale_rooms.sql\n（cleanup 函数 + 每 30 分钟 cron 自动清理过期房间）\n前置：Database → Extensions → 启用 pg_cron',
          ),
          _step(
            '4',
            '在 Supabase 中启用匿名登录',
            'Dashboard → Authentication → Sign In / Providers → Supabase Auth → User Signups → Allow anonymous sign-ins → 开启 → Save changes',
          ),
          _step(
            '5',
            '在 Supabase 中创建 Edge Function',
            'Dashboard → Edge Functions → Deploy a new function → Via Editor\n下方Function name填 get-voice-token\n将仓库 supabase/functions/get-voice-token/index.ts 的代码粘贴进去 → Deploy function',
          ),
          _step(
            '6',
            '创建 LiveKit Cloud 项目',
            'cloud.livekit.io → Create Project\n记录 API Key、API Secret、WebSocket URL',
          ),
          _step(
            '7',
            '在 Supabase 中设置 LiveKit Secrets',
            'Dashboard → Project Settings → Edge Functions → Secrets\n添加 4 个 Secret：\n'
                '  LIVEKIT_API_KEY = LiveKit API Key\n'
                '  LIVEKIT_API_SECRET = LiveKit API Secret\n'
                '  LIVEKIT_WS_URL = wss://xxx.livekit.cloud\n'
                '  ADMIN_PASSWORD = 自定义管理密码',
          ),
          _step(
            '8',
            '复制 Supabase 创建的该项目的 URL 和 Key 填入上方',
            'Dashboard → Project Settings → API\n复制 Project URL 和 publishable key',
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.amber, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '完整步骤见 docs/12-backend-setup.md',
                    style: TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String num, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              num,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
