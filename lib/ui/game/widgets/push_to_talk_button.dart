import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../voice/voice_chat_controller.dart';

class PushToTalkButton extends ConsumerWidget {
  const PushToTalkButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(voiceChatControllerProvider);
    final notifier = ref.read(voiceChatControllerProvider.notifier);

    final bool isActive = state.micEnabled;

    final Color bgColor;
    final IconData icon;
    if (!state.connected) {
      bgColor = Colors.grey.shade700;
      icon = Icons.mic_off;
    } else if (isActive) {
      bgColor = Colors.green;
      icon = Icons.mic;
    } else {
      bgColor = Colors.white.withValues(alpha: 0.12);
      icon = Icons.mic_none;
    }

    return GestureDetector(
      onTap: state.connected ? () => notifier.setMic(!isActive) : null,
      child: Container(
        width: 48,
        height: 48,
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
