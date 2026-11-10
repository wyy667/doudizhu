import 'dart:async';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../net/lan/lan_discovery.dart';
import '../../net/lan/lan_room_client.dart';
import '../../net/lan/local_profile.dart';
import '../../net/room_client.dart';
import '../game/widgets/table_widgets.dart';
import 'room_screen.dart';

/// 局域网联机大厅：开房（本机当房主）/ 自动发现附近房间 / 手动输入房主 IP。
class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({super.key});

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  final _nickController = TextEditingController();
  final _ipController = TextEditingController();
  final _discovery = LanDiscovery();
  StreamSubscription<List<LanRoomInfo>>? _discoverySub;
  List<LanRoomInfo> _rooms = const [];
  List<String> _myIps = const [];
  bool _chatEnabled = true;
  bool _busy = false;
  String? _uid;

  @override
  void initState() {
    super.initState();
    // 回到大厅时释放上一个房间的连接 / 服务
    final old = ref.read(activeRoomClientProvider);
    if (old is LanRoomClient) old.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(activeRoomClientProvider.notifier).state = null;
    });
    _loadProfile();
    _discoverySub = _discovery.rooms.listen((r) {
      if (mounted) setState(() => _rooms = r);
    });
    _discovery.start();
    LanNet.localIpv4().then((ips) {
      if (mounted) setState(() => _myIps = ips);
    });
  }

  Future<void> _loadProfile() async {
    final p = await LocalProfile.load();
    if (!mounted) return;
    setState(() {
      _uid = p.uid;
      _nickController.text = p.nick;
    });
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _discovery.dispose();
    _nickController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  Future<({String uid, String nick})> _saveProfile() async {
    await LocalProfile.setNick(_nickController.text);
    ref.invalidate(currentUserProvider);
    final p = await LocalProfile.load();
    _uid = p.uid;
    return p;
  }

  Future<void> _createRoom() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final me = await _saveProfile();
      final client = await LanRoomClient.host(
        uid: me.uid,
        nick: me.nick,
        chatEnabled: _chatEnabled,
      );
      ref.read(activeRoomClientProvider.notifier).state = client;
      await ref.read(roomClientProvider.future);
      if (!mounted) return;
      await _discovery.stop();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => RoomScreen(
            roomId: client.roomId,
            isHost: true,
            chatEnabled: _chatEnabled,
          ),
        ),
      );
    } catch (e) {
      _showError('创建房间失败：${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join(String address, int port) async {
    if (_busy) return;
    setState(() => _busy = true);
    LanRoomClient? client;
    try {
      final me = await _saveProfile();
      client = await LanRoomClient.connect(
        uid: me.uid,
        nick: me.nick,
        address: address,
        port: port,
      );
      final seat = await client.joinRoom(client.roomId);
      ref.read(activeRoomClientProvider.notifier).state = client;
      await ref.read(roomClientProvider.future);
      if (!mounted) return;
      await _discovery.stop();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => RoomScreen(
            roomId: client!.roomId,
            isHost: false,
            chatEnabled: true,
            mySeat: seat,
          ),
        ),
      );
    } catch (e) {
      await client?.dispose();
      _showError('加入失败：${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _joinManual() {
    final raw = _ipController.text.trim();
    if (raw.isEmpty) return;
    final parts = raw.split(':');
    final port = parts.length > 1
        ? int.tryParse(parts[1]) ?? LanNet.serverPort
        : LanNet.serverPort;
    _join(parts[0], port);
  }

  String _errText(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException') || s.contains('SocketException')) {
      return '连接不到房主，请确认在同一 Wi-Fi / 热点下';
    }
    return s.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TableColors.feltEdge,
      body: TableFelt(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 300, child: _buildCreatePanel()),
                      const SizedBox(width: 14),
                      Expanded(child: _buildRoomsPanel()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Text(
            '局域网联机',
            style: TextStyle(
              color: TableColors.gold,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '同一 Wi-Fi 或连接房主手机热点即可，无需外网；空位与掉线玩家由房主设备上的人机代打',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
          ),
          if (_busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: TableColors.gold,
              ),
            ),
        ],
      ),
    );
  }

  BoxDecoration get _panelDeco => BoxDecoration(
    color: TableColors.panel,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: TableColors.panelBorder),
  );

  Widget _buildCreatePanel() {
    return Container(
      decoration: _panelDeco,
      padding: const EdgeInsets.all(14),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PanelTitle(icon: Icons.person, text: '我的昵称'),
            const SizedBox(height: 8),
            _textField(_nickController, hint: '输入昵称', maxLength: 12),
            const SizedBox(height: 14),
            const _PanelTitle(icon: Icons.add_home_work, text: '我来当房主'),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text(
                  '允许聊天',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                Switch(
                  value: _chatEnabled,
                  onChanged: (v) => setState(() => _chatEnabled = v),
                  activeThumbColor: TableColors.gold,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Center(
              child: TableButton(
                label: '创建房间',
                icon: Icons.play_arrow_rounded,
                style: TableButtonStyle.primary,
                height: 42,
                minWidth: 180,
                enabled: !_busy && _uid != null,
                onTap: _createRoom,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _myIps.isEmpty
                  ? '未检测到局域网地址，请先连接 Wi-Fi 或打开热点'
                  : '本机地址：${_myIps.first}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _myIps.isEmpty ? Colors.orangeAccent : Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoomsPanel() {
    return Container(
      decoration: _panelDeco,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _PanelTitle(icon: Icons.wifi_tethering, text: '附近的房间'),
              const SizedBox(width: 8),
              const ThinkingDots(size: 4, color: TableColors.gold),
              const Spacer(),
              Text(
                '${_rooms.length} 个',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _rooms.isEmpty
                ? Center(
                    child: Text(
                      '正在搜索局域网内的房间…\n请确认与房主连接同一 Wi-Fi，或在下方输入房主地址',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _rooms.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _roomTile(_rooms[i]),
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _textField(
                  _ipController,
                  hint: '房主地址，如 192.168.1.5',
                  keyboardType: TextInputType.url,
                ),
              ),
              const SizedBox(width: 10),
              TableButton(
                label: '连接',
                height: 38,
                minWidth: 76,
                style: TableButtonStyle.accent,
                enabled: !_busy && _uid != null,
                onTap: _joinManual,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _roomTile(LanRoomInfo r) {
    final statusText = switch (r.status) {
      'waiting' => r.freeSeats > 0 ? '等待中' : '已满',
      _ => '对局中',
    };
    final statusColor = r.status == 'waiting' && r.freeSeats > 0
        ? Colors.lightGreenAccent
        : Colors.orangeAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            r.roomId,
            style: const TextStyle(
              color: TableColors.gold,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '房主：${r.hostNick}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                Text(
                  '${r.humans} 名玩家'
                  '${r.ais > 0 ? ' + ${r.ais} 人机' : ''} · ${r.address}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: statusColor.withValues(alpha: 0.6)),
            ),
            child: Text(
              statusText,
              style: TextStyle(color: statusColor, fontSize: 11),
            ),
          ),
          const SizedBox(width: 10),
          TableButton(
            label: r.inGame ? '重连' : '加入',
            height: 34,
            minWidth: 66,
            style: TableButtonStyle.primary,
            enabled: !_busy && _uid != null,
            onTap: () => _join(r.address, r.port),
          ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController c, {
    required String hint,
    int? maxLength,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: c,
      maxLength: maxLength,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
        counterText: '',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        filled: true,
        fillColor: Colors.black.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: TableColors.gold.withValues(alpha: 0.4),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: TableColors.gold.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TableColors.gold),
        ),
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: TableColors.gold),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}
