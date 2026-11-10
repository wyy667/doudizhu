import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_controller.dart';
import '../../net/lan/lan_room_client.dart';
import '../../net/net_game_session.dart';
import '../../net/room_client.dart';
import '../../state/game_session.dart';
import '../chat/chat_overlay.dart';
import '../game/game_screen.dart';
import '../game/widgets/table_widgets.dart';

/// 联网对局画面：通过 ProviderScope override 将 GameScreen 切换为网络模式。
class NetGameScreen extends ConsumerStatefulWidget {
  final String roomId;
  final int mySeat;
  final bool isHost;
  final bool chatEnabled;
  final RoomClientBase? client;
  final Set<int> aiSeats;

  const NetGameScreen({
    super.key,
    required this.roomId,
    required this.mySeat,
    required this.isHost,
    required this.chatEnabled,
    this.client,
    this.aiSeats = const {},
  });

  @override
  ConsumerState<NetGameScreen> createState() => _NetGameScreenState();
}

class _NetGameScreenState extends ConsumerState<NetGameScreen>
    with WidgetsBindingObserver {
  bool _exiting = false;
  bool _connected = true;
  RoomClientBase? _cachedClient;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final client = _effectiveClient;
    if (client != null) {
      _subs.add(
        client.watchConnected().listen((c) {
          if (mounted) setState(() => _connected = c);
        }),
      );
      if (client is LanRoomClient) {
        _subs.add(client.onRoomClosed.listen(_onRoomClosed));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 被系统杀死或用户划掉时，尽力通知房主
    if (state == AppLifecycleState.detached && !_exiting) {
      _exiting = true;
      _effectiveClient?.exitRoom(widget.roomId, widget.mySeat);
    }
  }

  RoomClientBase? get _effectiveClient {
    if (_cachedClient != null) return _cachedClient;
    if (widget.client != null) {
      _cachedClient = widget.client;
      return _cachedClient;
    }
    final asyncVal = ref.read(roomClientProvider);
    if (asyncVal case AsyncData(:final value)) {
      _cachedClient = value;
      return value;
    }
    return null;
  }

  Future<void> _onRoomClosed(String reason) async {
    if (!mounted || _exiting) return;
    _exiting = true;
    final client = _effectiveClient;
    if (client is LanRoomClient) await client.dispose();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('房间已解散'),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _showExitDialog(
    BuildContext context,
    RoomClientBase client,
  ) async {
    if (_exiting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isHost ? '解散房间' : '离开房间'),
        content: Text(
          widget.isHost
              ? '你是房主（人机也运行在你的设备上），离开后房间解散，所有玩家都会退出。'
              : '确定要离开吗？\n离开后你的位置由人机托管，可在大厅重新加入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(widget.isHost ? '解散' : '离开'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _exiting = true);
      try {
        await client.exitRoom(widget.roomId, widget.mySeat);
      } catch (_) {}
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _effectiveClient;

    if (client == null) {
      return const Scaffold(
        backgroundColor: TableColors.feltEdge,
        body: Center(child: CircularProgressIndicator(color: Colors.amber)),
      );
    }

    final c = client;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showExitDialog(context, c);
      },
      child: ProviderScope(
        overrides: [
          gameSessionProvider.overrideWith(() => NetGameSession()),
          netRoomContextProvider.overrideWithValue(
            NetRoomContext(
              roomId: widget.roomId,
              mySeat: widget.mySeat,
              myUid: c.uid,
              isHost: widget.isHost,
              chatEnabled: widget.chatEnabled,
              aiSeats: widget.aiSeats,
            ),
          ),
          if (widget.chatEnabled) chatRoomIdOverride(widget.roomId),
        ],
        child: Stack(
          children: [
            Scaffold(
              resizeToAvoidBottomInset: false,
              backgroundColor: TableColors.feltEdge,
              body: SafeArea(
                child: Stack(
                  children: [
                    const GameScreen(),
                    // 右上角返回按钮
                    Positioned(
                      top: 6,
                      right: 8,
                      child: RoundIconButton(
                        icon: Icons.logout,
                        color: TableColors.gold,
                        tooltip: widget.isHost ? '解散房间' : '离开房间',
                        onTap: () => _showExitDialog(context, c),
                      ),
                    ),
                    if (widget.chatEnabled)
                      ChatOverlay(roomId: widget.roomId, mySeat: widget.mySeat),
                    if (!_connected && !_exiting)
                      Positioned(
                        top: 52,
                        left: 0,
                        right: 0,
                        child: Center(child: _buildReconnectBanner(c)),
                      ),
                  ],
                ),
              ),
            ),
            // 退出 loading 遮罩
            if (_exiting)
              Container(
                color: Colors.black54,
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.amber),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildReconnectBanner(RoomClientBase c) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '与房主连接中断，正在重连（你的位置暂由人机托管）',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: () => _showExitDialog(context, c),
              child: const Text('离开', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
