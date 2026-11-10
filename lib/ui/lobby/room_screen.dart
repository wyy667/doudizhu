import 'dart:async';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../net/lan/lan_discovery.dart';
import '../../net/lan/lan_room_client.dart';
import '../../net/protocol.dart';
import '../../net/room_client.dart';
import '../game/widgets/table_widgets.dart';
import 'net_game_screen.dart';

/// 等待室：显示房间号与房主地址、座位、开始按钮。
///
/// 房主可点击空位添加人机；开始游戏时剩余空位自动由人机补齐。
class RoomScreen extends ConsumerStatefulWidget {
  final String roomId;
  final bool isHost;
  final bool chatEnabled;
  final int? mySeat;

  const RoomScreen({
    super.key,
    required this.roomId,
    required this.isHost,
    required this.chatEnabled,
    this.mySeat,
  });

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  List<SeatInfo?> _seats = [null, null, null];
  RoomMeta? _meta;
  int? _mySeat;
  bool _leaving = false;
  bool _navigated = false;
  bool _isHost = false;
  bool _connected = true;
  bool _starting = false;
  List<String> _hostIps = const [];
  final _subs = <StreamSubscription<dynamic>>[];

  RoomClientBase? get _client => ref
      .read(roomClientProvider)
      .maybeWhen(data: (c) => c, orElse: () => null);

  @override
  void initState() {
    super.initState();
    _mySeat = widget.mySeat ?? (widget.isHost ? 0 : null);
    _isHost = widget.isHost;
    _setupListeners();
    if (widget.isHost) {
      LanNet.localIpv4().then((ips) {
        if (mounted) setState(() => _hostIps = ips);
      });
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _setupListeners() {
    final client = _client;
    if (client == null) return;

    _subs.add(
      client.watchRoom(widget.roomId).listen((snap) {
        if (!mounted) return;
        // 房间已开局（含重连回到进行中的对局）→ 进入牌桌
        if ((snap.meta.status == 'playing' || snap.meta.status == 'settled') &&
            !_leaving &&
            !_navigated) {
          _navigated = true;
          _seats = snap.seats;
          _meta = snap.meta;
          _mySeat = snap.mySeat ?? _mySeat;
          _isHost = snap.isHost;
          _navigateToGame();
          return;
        }
        setState(() {
          _seats = snap.seats;
          _meta = snap.meta;
          _mySeat = snap.mySeat ?? _mySeat;
          _isHost = snap.isHost;
        });
      }),
    );
    _subs.add(
      client.watchConnected().listen((c) {
        if (mounted) setState(() => _connected = c);
      }),
    );
    if (client is LanRoomClient) {
      _subs.add(client.onRoomClosed.listen(_onRoomClosed));
    }
  }

  void _onRoomClosed(String reason) {
    if (!mounted || _leaving || _navigated) return;
    _leaving = true;
    final client = _client;
    if (client is LanRoomClient) client.dispose();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(reason), backgroundColor: Colors.orange),
    );
    Navigator.of(context).pop();
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (_isHost) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('解散房间'),
          content: const Text('你是房主，离开后房间将解散，其他玩家会被移出。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('解散'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _leaving = true);
    final client = _client;
    if (client != null && _mySeat != null) {
      await client.leaveRoom(widget.roomId, _mySeat!);
    }
    if (mounted) Navigator.of(context).pop();
  }

  int _aiCounter() => _seats.where((s) => s?.isAI ?? false).length + 1;

  Future<void> _addAi(int seat) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.addAiSeat(widget.roomId, seat, '人机${_aiCounter()}');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _removeAi(int seat) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.removeAiSeat(widget.roomId, seat);
    } catch (_) {}
  }

  Future<void> _startGame() async {
    if (_starting) return;
    final client = _client;
    if (client == null) return;
    setState(() => _starting = true);
    try {
      // 空位自动由人机补齐（推理在房主本机运行）
      var n = _aiCounter();
      final filled = List<SeatInfo?>.from(_seats);
      for (var s = 0; s < 3; s++) {
        if (filled[s] == null) {
          final nick = '人机${n++}';
          await client.addAiSeat(widget.roomId, s, nick);
          filled[s] = SeatInfo(
            uid: 'ai_${widget.roomId}_$s',
            nick: nick,
            online: true,
            isAI: true,
          );
        }
      }
      _seats = filled;
      await client.updateStatus(widget.roomId, 'playing');
      if (!mounted || _navigated) return;
      _navigated = true;
      _navigateToGame();
    } catch (e) {
      _toast('开始失败：$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _navigateToGame() {
    final client = _client;
    final aiSeats = <int>{
      for (var s = 0; s < _seats.length; s++)
        if (_seats[s]?.isAI ?? false) s,
    };
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => NetGameScreen(
          roomId: widget.roomId,
          mySeat: _mySeat ?? 0,
          isHost: _isHost,
          chatEnabled: _meta?.chatEnabled ?? widget.chatEnabled,
          client: client,
          aiSeats: aiSeats,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg.replaceFirst('Bad state: ', ''))),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final humans = _seats.where((s) => s != null && !s.isAI).length;
    final empties = _seats.where((s) => s == null).length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_leaving) _leave();
      },
      child: Scaffold(
        backgroundColor: TableColors.feltEdge,
        body: TableFelt(
          child: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildRoomCard(),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var s = 0; s < 3; s++) ...[
                              if (s > 0) const SizedBox(width: 40),
                              _seatWidget(s),
                            ],
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (_isHost) ...[
                          TableButton(
                            label: _starting ? '准备中…' : '开始游戏',
                            icon: Icons.play_arrow_rounded,
                            style: TableButtonStyle.primary,
                            height: 46,
                            minWidth: 200,
                            enabled: !_starting,
                            onTap: _startGame,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            empties > 0
                                ? '当前 $humans 名玩家，开始后 $empties 个空位由人机补齐'
                                : '点击人机头像可移除，空出位置等朋友加入',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ] else
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '等待房主开始游戏',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const ThinkingDots(
                                size: 5,
                                color: TableColors.gold,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: TextButton.icon(
                    onPressed: _leaving ? null : _leave,
                    icon: Icon(
                      _isHost ? Icons.close : Icons.exit_to_app,
                      color: Colors.redAccent,
                    ),
                    label: Text(
                      _isHost ? '解散房间' : '离开房间',
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
                if (!_connected)
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text(
                          '与房主的连接中断，正在重连…',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoomCard() {
    final client = _client;
    final addr = _isHost
        ? (_hostIps.isEmpty ? '未检测到局域网地址' : _hostIps.first)
        : (client is LanRoomClient ? client.address ?? '' : '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      decoration: BoxDecoration(
        color: TableColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TableColors.gold.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          const Text(
            '房间号',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          Text(
            widget.roomId,
            style: const TextStyle(
              color: TableColors.gold,
              fontSize: 38,
              fontWeight: FontWeight.w900,
              letterSpacing: 12,
              height: 1.2,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi, size: 14, color: Colors.white54),
              const SizedBox(width: 4),
              Text(
                _isHost ? '房主地址 $addr' : '已连接房主 $addr',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              if (_meta?.chatEnabled == true) ...[
                const SizedBox(width: 12),
                const Icon(Icons.chat, size: 13, color: Colors.white54),
                const SizedBox(width: 3),
                const Text(
                  '聊天开启',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
          if (_isHost)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '同一 Wi-Fi / 热点下的朋友在「局域网联机」中即可看到本房间',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _seatWidget(int seat) {
    final info = _seats.length > seat ? _seats[seat] : null;
    final isMe = _mySeat == seat;
    final isAI = info?.isAI ?? false;
    final isHostSeat = info != null && info.uid == _meta?.hostUid;
    final canAdd = _isHost && info == null;
    final canRemove = _isHost && isAI;

    Widget avatar;
    if (info == null) {
      avatar = Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.25),
          border: Border.all(color: Colors.white24, width: 1.5),
        ),
        child: Icon(
          canAdd ? Icons.smart_toy_outlined : Icons.person_add_alt,
          color: Colors.white38,
          size: 28,
        ),
      );
    } else if (isAI) {
      avatar = Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF90A4AE), Color(0xFF37474F)],
          ),
          border: Border.fromBorderSide(
            BorderSide(color: Colors.white, width: 2),
          ),
        ),
        child: const Icon(Icons.smart_toy, color: Colors.white, size: 30),
      );
    } else {
      avatar = SeatAvatar(
        label: info.nick.isNotEmpty ? info.nick.substring(0, 1) : '?',
        size: 64,
        active: isMe,
        offline: !info.online,
      );
    }

    return GestureDetector(
      onTap: canAdd
          ? () => _addAi(seat)
          : canRemove
          ? () => _removeAi(seat)
          : null,
      child: SizedBox(
        width: 110,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                if (isHostSeat)
                  const Positioned(
                    top: -4,
                    right: -4,
                    child: Icon(
                      Icons.workspace_premium,
                      color: TableColors.gold,
                      size: 20,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              info == null
                  ? (canAdd ? '点击添加人机' : '等待加入')
                  : (isMe ? '${info.nick}（我）' : info.nick),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: info == null ? Colors.white38 : Colors.white,
                fontSize: 13,
                fontWeight: isMe ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
            Text(
              isHostSeat
                  ? '房主'
                  : isAI
                  ? (canRemove ? '人机 · 点击移除' : '人机')
                  : info != null && !info.online
                  ? '已断线'
                  : '座位 ${seat + 1}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
