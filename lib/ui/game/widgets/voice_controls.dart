import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../voice/voice_chat_controller.dart';

/// 语音控制组件组：[加入/离开语音] + [推麦]（仅在语音房间内显示推麦）。
class VoiceControls extends ConsumerWidget {
  const VoiceControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(voiceChatControllerProvider);
    final notifier = ref.read(voiceChatControllerProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 加入/离开语音按钮（始终显示）
        _VoiceToggleButton(state: state, notifier: notifier),
        // 推麦按钮（仅在语音房间内且已连接时显示）
        if (state.inVoiceRoom && state.connected) ...[
          const SizedBox(width: 8),
          _PushToTalkButton(state: state, notifier: notifier),
        ],
      ],
    );
  }

  static Future<bool?> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }
}

/// 加入/离开语音房间按钮。
class _VoiceToggleButton extends StatelessWidget {
  final VoiceChatState state;
  final VoiceChatController notifier;

  const _VoiceToggleButton({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final inRoom = state.inVoiceRoom;

    final Color bgColor;
    final IconData icon;
    if (!inRoom) {
      // 不在语音房间 → 显示加入
      bgColor = Colors.amber.withValues(alpha: 0.8);
      icon = Icons.headset;
    } else if (!state.connected) {
      // 正在连接
      bgColor = Colors.grey.shade700;
      icon = Icons.headphones;
    } else {
      // 在语音房间 → 显示离开
      bgColor = Colors.black.withValues(alpha: 0.4);
      icon = Icons.headset_off;
    }

    return GestureDetector(
      onTap: () => _onTap(context),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: inRoom
                ? Colors.redAccent.withValues(alpha: 0.5)
                : Colors.amber,
            width: 1.5,
          ),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  void _onTap(BuildContext context) async {
    if (state.inVoiceRoom) {
      // 离开语音确认
      final confirmed = await VoiceControls.showConfirmDialog(
        context,
        title: '离开语音',
        content: '离开后将无法与其他玩家语音通话。\n确定要离开语音房间吗？',
        confirmText: '离开',
      );
      if (confirmed == true) {
        await notifier.disconnect();
      }
    } else {
      // 加入语音确认
      final confirmed = await VoiceControls.showConfirmDialog(
        context,
        title: '加入语音',
        content: '加入后将与其他开启语音的玩家通话。\n确定要加入语音房间吗？',
        confirmText: '加入',
      );
      if (confirmed == true) {
        await notifier.reconnect();
      }
    }
  }
}

/// 推麦按钮（仅在语音房间内显示）。
class _PushToTalkButton extends StatelessWidget {
  final VoiceChatState state;
  final VoiceChatController notifier;

  const _PushToTalkButton({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final bool isActive = state.micEnabled;

    final Color bgColor;
    final IconData icon;
    if (isActive) {
      bgColor = Colors.green;
      icon = Icons.mic;
    } else {
      bgColor = Colors.white.withValues(alpha: 0.12);
      icon = Icons.mic_none;
    }

    return GestureDetector(
      onTap: () => notifier.setMic(!isActive),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: isActive
                ? Colors.greenAccent
                : Colors.white.withValues(alpha: 0.25),
            width: 2,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.green.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}
