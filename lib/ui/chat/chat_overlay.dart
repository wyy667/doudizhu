import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_controller.dart';
import '../../net/protocol.dart';

/// 悬浮聊天面板（半透明，覆盖在游戏画面右侧）。
class ChatOverlay extends ConsumerStatefulWidget {
  final String roomId;
  final int mySeat;

  const ChatOverlay({super.key, required this.roomId, required this.mySeat});

  @override
  ConsumerState<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends ConsumerState<ChatOverlay> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref.read(chatControllerProvider.notifier).send(text, widget.mySeat);
    _controller.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatControllerProvider);
    if (messages.isNotEmpty) _scrollToBottom();

    // 限制聊天框高度：不遮挡底部手牌区域
    final screenHeight = MediaQuery.of(context).size.height;
    final chatHeight = screenHeight * 0.6;

    // 收起时只在右侧中部留一个小标签，避免遮挡右侧玩家头像与出牌区
    if (!_expanded) {
      return Positioned(
        right: 0,
        top: screenHeight * 0.42,
        child: Container(
          width: 34,
          height: 84,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(10),
            ),
            border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
          ),
          child: _buildCollapsed(),
        ),
      );
    }

    return Positioned(
      right: 0,
      top: 36,
      height: chatHeight - 36,
      child: ClipRect(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: _expanded ? 251 : 44,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            border: Border(
              left: BorderSide(color: Colors.amber.withValues(alpha: 0.3)),
            ),
          ),
          child: _expanded
              ? OverflowBox(
                  alignment: Alignment.centerRight,
                  maxWidth: 250,
                  child: _buildExpanded(messages),
                )
              : _buildCollapsed(),
        ),
      ),
    );
  }

  Widget _buildCollapsed() {
    return GestureDetector(
      onTap: () => setState(() => _expanded = true),
      child: const Center(
        child: RotatedBox(
          quarterTurns: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat, color: Colors.amber, size: 18),
              SizedBox(width: 4),
              Text('聊天', style: TextStyle(color: Colors.amber, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(List<ChatMessage> messages) {
    return Column(
      children: [
        // 标题栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              const SizedBox(width: 4),
              const Icon(Icons.chat, color: Colors.amber, size: 16),
              const SizedBox(width: 6),
              const Text(
                '聊天',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _expanded = false),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.chevron_right,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        // 消息列表
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: messages.length,
            itemBuilder: (_, i) => _buildMessage(messages[i]),
          ),
        ),
        // 输入框
        Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    hintText: '发消息...',
                    hintStyle: const TextStyle(
                      color: Colors.white30,
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.send, color: Colors.amber, size: 18),
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                onPressed: _send,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessage(ChatMessage msg) {
    if (msg.bySeat == -1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Center(
          child: Text(
            msg.text,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
      );
    }

    final isMe = msg.bySeat == widget.mySeat;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isMe
                ? Colors.amber.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isMe)
                Text(
                  msg.nick,
                  style: TextStyle(
                    color: Colors.amber.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
              Text(
                msg.text,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
