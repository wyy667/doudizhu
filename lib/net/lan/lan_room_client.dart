import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol.dart';
import '../room_client_base.dart';
import 'lan_room_server.dart';

/// 局域网房间客户端。
///
/// - 房主：内嵌 [LanRoomServer]，操作在本机直接执行。
/// - 其他玩家：WebSocket 连接房主，断线后每 2 秒自动重连（同一 uid 找回座位）。
///
/// 对外语义与 Supabase 版一致，NetGameSession / 等待室 / 聊天无需感知差异。
class LanRoomClient implements RoomClientBase {
  LanRoomClient._({
    required this.uid,
    required this.nickname,
    LanRoomServer? server,
    this.address,
    required this.port,
  }) : _server = server;

  @override
  final String uid;
  @override
  final String nickname;

  final LanRoomServer? _server;

  /// 房主地址（仅非房主）。
  final String? address;
  final int port;

  String _roomId = '';
  String get roomId => _roomId;
  bool get isHostDevice => _server != null;

  Map<String, dynamic>? _row;
  final _chat = <ChatMessage>[];
  final _rowCtl = StreamController<Map<String, dynamic>>.broadcast();
  final _chatCtl = StreamController<ChatMessage>.broadcast();
  final _connCtl = StreamController<bool>.broadcast();
  final _closedCtl = StreamController<String>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];

  WebSocket? _ws;
  bool _connected = false;
  bool _disposed = false;
  String? _closedReason;
  Timer? _reconnectTimer;
  int _rpcId = 0;
  final _pending = <int, Completer<dynamic>>{};

  /// 是否与房主保持连接（房主本机恒为 true）。
  bool get connected => isHostDevice || _connected;

  /// 房间被房主解散时发出原因。
  Stream<String> get onRoomClosed => _closedCtl.stream;
  String? get closedReason => _closedReason;

  /// 作为房主开房：启动本机服务。
  static Future<LanRoomClient> host({
    required String uid,
    required String nick,
    required bool chatEnabled,
  }) async {
    final server = await LanRoomServer.start(
      hostUid: uid,
      hostNick: nick,
      chatEnabled: chatEnabled,
    );
    final c = LanRoomClient._(
      uid: uid,
      nickname: nick,
      server: server,
      port: server.port,
    );
    c._roomId = server.roomId;
    c._row = server.snapshot;
    c._subs
      ..add(server.rows.listen(c._onRow))
      ..add(server.chats.listen((m) => c._onChat(m)));
    return c;
  }

  /// 作为玩家连接房主。连接或握手失败会抛出异常。
  static Future<LanRoomClient> connect({
    required String uid,
    required String nick,
    required String address,
    required int port,
  }) async {
    final c = LanRoomClient._(
      uid: uid,
      nickname: nick,
      address: address,
      port: port,
    );
    try {
      await c._connect();
    } catch (_) {
      await c.dispose();
      rethrow;
    }
    return c;
  }

  // ── 连接管理（非房主）──

  Future<void> _connect() async {
    final ws = await WebSocket.connect(
      'ws://$address:$port/ws',
    ).timeout(const Duration(seconds: 4));
    ws.pingInterval = const Duration(seconds: 3);
    final welcome = Completer<void>();
    _ws = ws;
    ws.listen(
      (data) => _onMessage(data, welcome),
      onDone: () => _onSocketDone(ws, welcome),
      onError: (_) {},
      cancelOnError: false,
    );
    ws.add(jsonEncode({'t': 'hello', 'uid': uid, 'nick': nickname}));
    await welcome.future.timeout(const Duration(seconds: 4));
    _setConnected(true);
  }

  void _onMessage(dynamic data, Completer<void> welcome) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(data) as Map);
    } catch (_) {
      return;
    }
    switch (msg['t']) {
      case 'welcome':
        _roomId = msg['roomId'] as String;
        final isReconnect = _chat.isNotEmpty;
        if (!isReconnect) {
          for (final m in (msg['chat'] as List? ?? const [])) {
            _onChat(Map<String, dynamic>.from(m as Map));
          }
        }
        _onRow(Map<String, dynamic>.from(msg['row'] as Map));
        if (!welcome.isCompleted) welcome.complete();
      case 'row':
        _onRow(Map<String, dynamic>.from(msg['row'] as Map));
      case 'chat':
        _onChat(Map<String, dynamic>.from(msg['msg'] as Map));
      case 'res':
        final c = _pending.remove(msg['id']);
        if (c == null) return;
        if (msg['ok'] == true) {
          c.complete(msg['r']);
        } else {
          c.completeError(StateError(msg['err'] as String? ?? '操作失败'));
        }
      case 'closed':
        _closedReason = msg['reason'] as String? ?? '房主已解散房间';
        if (!welcome.isCompleted) {
          welcome.completeError(StateError(_closedReason!));
          return;
        }
        if (!_closedCtl.isClosed) _closedCtl.add(_closedReason!);
    }
  }

  void _onSocketDone(WebSocket ws, Completer<void> welcome) {
    if (!welcome.isCompleted) {
      welcome.completeError(StateError('房主拒绝了连接'));
    }
    if (!identical(ws, _ws)) return;
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('与房主的连接已断开'));
    }
    _pending.clear();
    if (_disposed) return;
    _setConnected(false);
    if (_closedReason != null) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () async {
      if (_disposed || _closedReason != null || _ws != null) return;
      try {
        await _connect();
        debugPrint('[LanClient] reconnected to $address:$port');
      } catch (_) {
        _ws = null;
        _scheduleReconnect();
      }
    });
  }

  void _setConnected(bool v) {
    if (_connected == v) return;
    _connected = v;
    if (!_connCtl.isClosed) _connCtl.add(v);
  }

  Future<dynamic> _rpc(String method, [Map<String, dynamic>? args]) async {
    final a = args ?? const <String, dynamic>{};
    final server = _server;
    if (server != null) {
      return server.handle(uid, nickname, method, a);
    }
    final ws = _ws;
    if (ws == null || !_connected) throw StateError('未连接到房主');
    final id = ++_rpcId;
    final c = Completer<dynamic>();
    _pending[id] = c;
    ws.add(jsonEncode({'t': 'rpc', 'id': id, 'm': method, 'a': a}));
    return c.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('房主无响应');
      },
    );
  }

  void _onRow(Map<String, dynamic> row) {
    _row = row;
    if (!_rowCtl.isClosed) _rowCtl.add(row);
  }

  void _onChat(Map<String, dynamic> m) {
    final msg = ChatMessage.fromMap(m);
    _chat.add(msg);
    if (!_chatCtl.isClosed) _chatCtl.add(msg);
  }

  /// 订阅时先回放最新数据，再跟随后续变化。
  Stream<T> _rowStream<T>(T Function(Map<String, dynamic> row) f) {
    StreamSubscription<Map<String, dynamic>>? sub;
    late final StreamController<T> c;
    c = StreamController<T>(
      onListen: () {
        final cur = _row;
        if (cur != null) c.add(f(cur));
        sub = _rowCtl.stream.listen(
          (r) => c.add(f(r)),
          onDone: () => c.close(),
        );
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  // ── RoomClientBase ──

  @override
  Future<String> createRoom({required bool chatEnabled}) async {
    if (!isHostDevice) throw StateError('仅房主可创建房间');
    return _roomId;
  }

  @override
  Future<int> joinRoom(String roomId) async => (await _rpc('join')) as int;

  @override
  Future<void> leaveRoom(String roomId, int seat) async {
    try {
      await _rpc('leave', {'seat': seat});
    } catch (_) {}
    await dispose();
  }

  @override
  Future<void> exitRoom(String roomId, int seat) async {
    try {
      await _rpc('exit', {'seat': seat});
    } catch (_) {}
    await dispose();
  }

  @override
  Future<void> setOnline(String roomId, int seat, bool online) =>
      _rpc('setOnline', {'seat': seat, 'online': online});

  @override
  Stream<bool> watchConnected() => _connCtl.stream;

  @override
  Future<void> resync(String roomId) async {
    final server = _server;
    if (server != null) {
      if (!server.isClosed) _onRow(server.snapshot);
      return;
    }
    try {
      _ws?.add(jsonEncode({'t': 'resync'}));
    } catch (_) {}
  }

  @override
  Future<void> updateHostUid(String roomId, String newHostUid) async {}

  @override
  Future<void> addAiSeat(String roomId, int seat, String nick) =>
      _rpc('addAi', {'seat': seat, 'nick': nick});

  @override
  Future<void> removeAiSeat(String roomId, int seat) =>
      _rpc('removeAi', {'seat': seat});

  @override
  Stream<RoomSnapshot> watchRoom(String roomId) => _rowStream((row) {
    final meta = RoomMeta(
      hostUid: row['host_uid'] as String? ?? '',
      chatEnabled: row['chat_enabled'] as bool? ?? false,
      status: row['status'] as String? ?? 'waiting',
      createdAt: row['created_at'] as int? ?? 0,
    );
    final seats = List<SeatInfo?>.filled(3, null);
    int? mySeat;
    final raw = row['seats'];
    if (raw is List) {
      for (var s = 0; s < raw.length && s < 3; s++) {
        final sd = raw[s];
        if (sd is Map) {
          final info = SeatInfo.fromMap(sd);
          seats[s] = info;
          if (info.uid == uid) mySeat = s;
        }
      }
    }
    return RoomSnapshot(
      roomId: _roomId,
      meta: meta,
      seats: seats,
      myUid: uid,
      mySeat: mySeat,
      isHost: meta.hostUid == uid,
    );
  });

  @override
  Stream<Map<dynamic, dynamic>?> watchGameState(String roomId) =>
      _rowStream((row) {
        final gs = row['game_state'];
        return gs is Map ? Map<dynamic, dynamic>.from(gs) : null;
      });

  @override
  Stream<List<int>> watchMyHand(String roomId, int mySeat) => _rowStream((row) {
    final hands = row['hands'];
    final h = hands is Map ? hands['$mySeat'] : null;
    return h is List ? h.cast<int>() : <int>[];
  });

  @override
  Stream<Map<dynamic, dynamic>?> watchPendingAction(String roomId) =>
      _rowStream((row) {
        final pa = row['pending_action'];
        return pa is Map ? Map<dynamic, dynamic>.from(pa) : null;
      });

  @override
  Stream<List<bool>> watchReady(String roomId) => _rowStream((row) {
    final raw = row['ready'];
    return [
      for (var i = 0; i < 3; i++)
        raw is List && raw.length > i && raw[i] == true,
    ];
  });

  @override
  Stream<ChatMessage> watchChat(String roomId) {
    StreamSubscription<ChatMessage>? sub;
    late final StreamController<ChatMessage> c;
    c = StreamController<ChatMessage>(
      onListen: () {
        for (final m in _chat) {
          c.add(m);
        }
        sub = _chatCtl.stream.listen(c.add, onDone: () => c.close());
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  @override
  Future<void> submitAction(String roomId, Map<String, dynamic> action) =>
      _rpc('submitAction', {'action': action});

  @override
  Future<void> clearPendingAction(String roomId) => _rpc('clearPending');

  @override
  Future<void> updateGameState(String roomId, Map<String, dynamic> state) =>
      _rpc('updateGameState', {'state': state});

  @override
  Future<void> writeHand(String roomId, int seat, List<int> cards) =>
      _rpc('writeHand', {'seat': seat, 'cards': cards});

  @override
  Future<void> clearHands(String roomId) => _rpc('clearHands');

  @override
  Future<void> updateStatus(String roomId, String status) =>
      _rpc('updateStatus', {'status': status});

  @override
  Future<void> setReady(String roomId, int seat, bool ready) =>
      _rpc('setReady', {'seat': seat, 'ready': ready});

  @override
  Future<void> clearReady(String roomId) => _rpc('clearReady');

  @override
  Future<void> sendChat(String roomId, int seat, String text) =>
      _rpc('chat', {'seat': seat, 'text': text});

  @override
  Future<void> batchUpdate(
    String roomId, {
    Map<String, dynamic>? gameState,
    Map<int, List<int>>? hands,
    String? status,
    bool clearPendingAction = false,
    bool clearReady = false,
  }) => _rpc('batch', {
    'gameState': ?gameState,
    if (hands != null)
      'hands': {for (final e in hands.entries) '${e.key}': e.value},
    'status': ?status,
    'clearPending': clearPendingAction,
    'clearReady': clearReady,
  });

  /// 断开连接；房主则解散房间。可重复调用。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
    await _server?.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('已离开房间'));
    }
    _pending.clear();
    await _rowCtl.close();
    await _chatCtl.close();
    await _connCtl.close();
    await _closedCtl.close();
  }
}
