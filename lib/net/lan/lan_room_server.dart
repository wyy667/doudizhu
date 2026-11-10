import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol.dart';
import 'lan_discovery.dart';

/// 局域网房主服务（运行在房主设备上）。
///
/// - 持有房间「行数据」（字段与 Supabase 版 rooms 表一致：seats / ready / hands /
///   game_state / pending_action / status …），对局逻辑完全复用 NetGameSession。
/// - 通过 WebSocket 接收其他玩家的请求，变更后推送给所有连接；
///   每位玩家只收到**自己的手牌**，pending_action 只在房主本机流转。
/// - 每秒 UDP 广播一次房间信息供大厅发现。
/// - 人机（AI 座位 / 掉线托管）的 DouZero 推理只在房主设备运行。
class LanRoomServer {
  LanRoomServer._(this.roomId, this.hostUid, this.hostNick, bool chatEnabled)
    : _row = {
        'room_id': roomId,
        'host_uid': hostUid,
        'chat_enabled': chatEnabled,
        'status': 'waiting',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'seats': [
          {'uid': hostUid, 'nick': hostNick, 'online': true},
          null,
          null,
        ],
        'ready': [false, false, false],
        'hands': <String, dynamic>{},
        'game_state': null,
        'pending_action': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

  final String roomId;
  final String hostUid;
  final String hostNick;

  final Map<String, dynamic> _row;
  final List<Map<String, dynamic>> _chat = [];

  HttpServer? _http;
  final _guests = <WebSocket, _Guest>{};
  final _rowCtl = StreamController<Map<String, dynamic>>.broadcast();
  final _chatCtl = StreamController<Map<String, dynamic>>.broadcast();

  RawDatagramSocket? _udp;
  Timer? _announceTimer;
  List<InternetAddress> _targets = const [];
  List<String> _hostIps = const [];
  int _announceTick = 0;
  bool _closed = false;

  int get port => _http?.port ?? 0;
  bool get isClosed => _closed;

  /// 房主本机收到的完整行（含全部手牌与 pending_action）。
  Stream<Map<String, dynamic>> get rows => _rowCtl.stream;
  Stream<Map<String, dynamic>> get chats => _chatCtl.stream;
  Map<String, dynamic> get snapshot => _copy(_row);
  List<Map<String, dynamic>> get chatHistory => List.of(_chat);

  static Future<LanRoomServer> start({
    required String hostUid,
    required String hostNick,
    required bool chatEnabled,
    int? port,
  }) async {
    final s = LanRoomServer._(
      NetProtocol.generateRoomCode(),
      hostUid,
      hostNick,
      chatEnabled,
    );
    await s._bind(port ?? LanNet.serverPort);
    await s._startAnnounce();
    return s;
  }

  // ── 网络 ──

  Future<void> _bind(int port) async {
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } catch (_) {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _http!.listen(_onRequest, onError: (_) {});
    debugPrint('[LanServer] room=$roomId listening on :${_http!.port}');
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.pingInterval = const Duration(seconds: 3);
      final g = _Guest();
      _guests[ws] = g;
      ws.listen(
        (data) => _onGuestMessage(ws, g, data),
        onDone: () => _onGuestGone(ws, g),
        onError: (_) {},
        cancelOnError: false,
      );
      return;
    }
    req.response
      ..statusCode = req.uri.path == '/info'
          ? HttpStatus.ok
          : HttpStatus.notFound
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(req.uri.path == '/info' ? _announceInfo() : {}));
    await req.response.close();
  }

  void _onGuestMessage(WebSocket ws, _Guest g, dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(data) as Map);
    } catch (_) {
      return;
    }
    switch (msg['t']) {
      case 'hello':
        g.uid = msg['uid'] as String?;
        g.nick = (msg['nick'] as String?) ?? '';
        if (g.uid == null) return;
        // 远端不能冒用房主身份（否则可接管房主座位）
        if (g.uid == hostUid) {
          g.uid = null;
          _send(ws, {'t': 'closed', 'reason': '身份与房主冲突，无法加入'});
          ws.close();
          return;
        }
        // 已有座位 → 视为重连，恢复在线
        final seat = _seatOf(g.uid!);
        if (seat != null) {
          final seats = _seats();
          final sd = Map<String, dynamic>.from(seats[seat] as Map);
          if (sd['online'] != true) {
            sd['online'] = true;
            seats[seat] = sd;
            _row['seats'] = seats;
            _publish();
          }
        }
        _send(ws, {
          't': 'welcome',
          'roomId': roomId,
          'row': _filtered(g.uid!),
          'chat': _chat,
        });
      case 'resync':
        if (g.uid != null) _send(ws, {'t': 'row', 'row': _filtered(g.uid!)});
      case 'rpc':
        final id = msg['id'];
        if (g.uid == null) {
          _send(ws, {'t': 'res', 'id': id, 'ok': false, 'err': '未握手'});
          return;
        }
        try {
          final r = handle(
            g.uid!,
            g.nick,
            msg['m'] as String,
            Map<String, dynamic>.from((msg['a'] as Map?) ?? const {}),
          );
          _send(ws, {'t': 'res', 'id': id, 'ok': true, 'r': r});
        } catch (e) {
          _send(ws, {'t': 'res', 'id': id, 'ok': false, 'err': _errText(e)});
        }
    }
  }

  void _onGuestGone(WebSocket ws, _Guest g) {
    _guests.remove(ws);
    if (_closed || g.uid == null) return;
    // 同一 uid 仍有其他连接（快速重连）→ 不算离线
    if (_guests.values.any((o) => o.uid == g.uid)) return;
    final seat = _seatOf(g.uid!);
    if (seat == null) return;
    final seats = _seats();
    final sd = Map<String, dynamic>.from(seats[seat] as Map);
    if (sd['online'] == false) return;
    sd['online'] = false;
    seats[seat] = sd;
    _row['seats'] = seats;
    debugPrint('[LanServer] seat $seat (${g.uid}) disconnected');
    _publish();
  }

  void _send(WebSocket ws, Map<String, dynamic> msg) {
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  // ── 请求处理（房主本机直接调用，远端经 WebSocket rpc 调用）──

  /// 执行一次房间操作，返回结果（join 返回座位号，其余返回 null）。
  Object? handle(
    String uid,
    String nick,
    String method,
    Map<String, dynamic> a,
  ) {
    if (_closed) throw StateError('房间已关闭');
    final isHost = uid == hostUid;
    void requireHost() {
      if (!isHost) throw StateError('仅房主可执行');
    }

    int seatArg() => a['seat'] as int;
    void requireSeatOwner(int seat) {
      if (!isHost && _seatOf(uid) != seat) throw StateError('无权操作该座位');
    }

    switch (method) {
      case 'join':
        return _join(uid, nick);
      case 'leave':
        final seat = seatArg();
        requireSeatOwner(seat);
        if (isHost) {
          close();
          return null;
        }
        final seats = _seats()..[seat] = null;
        _row['seats'] = seats;
        _row['ready'] = _readyList()..[seat] = false;
        _publish();
      case 'exit':
        final seat = seatArg();
        requireSeatOwner(seat);
        if (isHost) {
          close();
          return null;
        }
        _setSeatField(seat, 'online', false);
        _row['ready'] = _readyList()..[seat] = false;
        _publish();
      case 'setOnline':
        final seat = seatArg();
        requireSeatOwner(seat);
        _setSeatField(seat, 'online', a['online'] == true);
        _publish();
      case 'addAi':
        requireHost();
        final seat = seatArg();
        final seats = _seats();
        if (seats[seat] != null) throw StateError('座位已被占用');
        seats[seat] = {
          'uid': 'ai_${roomId}_$seat',
          'nick': a['nick'] as String? ?? '人机',
          'online': true,
          'isAI': true,
        };
        _row['seats'] = seats;
        _publish();
      case 'removeAi':
        requireHost();
        final seat = seatArg();
        final seats = _seats();
        final sd = seats[seat];
        if (sd is Map && sd['isAI'] == true) {
          seats[seat] = null;
          _row['seats'] = seats;
          _publish();
        }
      case 'submitAction':
        final action = Map<String, dynamic>.from(a['action'] as Map);
        if (!isHost && action['bySeat'] != _seatOf(uid)) {
          throw StateError('无权代替其他座位出牌');
        }
        _row['pending_action'] = action;
        _publish(hostOnly: true);
      case 'clearPending':
        requireHost();
        _row['pending_action'] = null;
        _publish(hostOnly: true);
      case 'updateGameState':
        requireHost();
        _row['game_state'] = a['state'];
        _publish();
      case 'writeHand':
        requireHost();
        final hands = Map<String, dynamic>.from(_row['hands'] as Map? ?? {});
        hands['${seatArg()}'] = a['cards'];
        _row['hands'] = hands;
        _publish();
      case 'clearHands':
        requireHost();
        _row['hands'] = <String, dynamic>{};
        _publish();
      case 'updateStatus':
        requireHost();
        _row['status'] = a['status'];
        _publish();
      case 'setReady':
        final seat = seatArg();
        requireSeatOwner(seat);
        _row['ready'] = _readyList()..[seat] = a['ready'] == true;
        _publish();
      case 'clearReady':
        requireHost();
        _row['ready'] = [false, false, false];
        _publish();
      case 'chat':
        if (_row['chat_enabled'] != true) return null;
        final seat = seatArg();
        requireSeatOwner(seat);
        final text = (a['text'] as String? ?? '').trim();
        if (text.isEmpty) return null;
        final sd = _seats()[seat];
        final msg = ChatMessage(
          bySeat: seat,
          nick: sd is Map ? sd['nick'] as String? ?? nick : nick,
          text: text.substring(0, text.length.clamp(0, 200)),
          ts: DateTime.now().millisecondsSinceEpoch,
        ).toMap();
        _chat.add(msg);
        if (_chat.length > 50) _chat.removeAt(0);
        if (!_chatCtl.isClosed) _chatCtl.add(msg);
        for (final ws in _guests.keys) {
          _send(ws, {'t': 'chat', 'msg': msg});
        }
      case 'batch':
        requireHost();
        if (a.containsKey('gameState')) _row['game_state'] = a['gameState'];
        if (a['hands'] != null) {
          _row['hands'] = Map<String, dynamic>.from(a['hands'] as Map);
        }
        if (a['status'] != null) _row['status'] = a['status'];
        if (a['clearPending'] == true) _row['pending_action'] = null;
        if (a['clearReady'] == true) _row['ready'] = [false, false, false];
        _publish();
      case 'updateHostUid':
        // 局域网房间的服务端就在房主设备上，房主不可迁移。
        return null;
      default:
        throw StateError('未知操作 $method');
    }
    return null;
  }

  int _join(String uid, String nick) {
    final seats = _seats();
    for (var s = 0; s < 3; s++) {
      final sd = seats[s];
      if (sd is Map && sd['uid'] == uid) {
        seats[s] = {
          ...Map<String, dynamic>.from(sd),
          'nick': nick,
          'online': true,
        };
        _row['seats'] = seats;
        _publish();
        return s;
      }
    }
    if (_row['status'] != 'waiting') throw StateError('对局进行中，暂时无法加入');
    for (var s = 0; s < 3; s++) {
      if (seats[s] == null) {
        seats[s] = {'uid': uid, 'nick': nick, 'online': true};
        _row['seats'] = seats;
        _publish();
        return s;
      }
    }
    throw StateError('房间已满');
  }

  // ── 数据辅助 ──

  List<dynamic> _seats() {
    final raw = _row['seats'];
    final list = <dynamic>[null, null, null];
    if (raw is List) {
      for (var i = 0; i < raw.length && i < 3; i++) {
        list[i] = raw[i];
      }
    }
    return list;
  }

  List<bool> _readyList() {
    final raw = _row['ready'];
    return [
      for (var i = 0; i < 3; i++)
        raw is List && raw.length > i && raw[i] == true,
    ];
  }

  int? _seatOf(String uid) {
    final seats = _seats();
    for (var s = 0; s < 3; s++) {
      final sd = seats[s];
      if (sd is Map && sd['uid'] == uid) return s;
    }
    return null;
  }

  void _setSeatField(int seat, String key, Object value) {
    final seats = _seats();
    final sd = seats[seat];
    if (sd is! Map) return;
    seats[seat] = {...Map<String, dynamic>.from(sd), key: value};
    _row['seats'] = seats;
  }

  /// 给某位玩家的视图：只含自己的手牌，不含 pending_action。
  Map<String, dynamic> _filtered(String uid) {
    final row = _copy(_row);
    final seat = _seatOf(uid);
    final hands = row['hands'];
    row['hands'] = {
      if (seat != null && hands is Map && hands['$seat'] != null)
        '$seat': hands['$seat'],
    };
    row.remove('pending_action');
    return row;
  }

  void _publish({bool hostOnly = false}) {
    if (_closed) return;
    _row['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    if (!_rowCtl.isClosed) _rowCtl.add(_copy(_row));
    if (hostOnly) return;
    for (final entry in _guests.entries) {
      final uid = entry.value.uid;
      if (uid == null) continue;
      _send(entry.key, {'t': 'row', 'row': _filtered(uid)});
    }
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> m) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map);

  static String _errText(Object e) {
    final s = e.toString();
    return s.startsWith('Bad state: ') ? s.substring(11) : s;
  }

  // ── 房间广播 ──

  Map<String, dynamic> _announceInfo() {
    final seats = _seats();
    var humans = 0;
    var ais = 0;
    for (final sd in seats) {
      if (sd is Map) {
        if (sd['isAI'] == true) {
          ais++;
        } else {
          humans++;
        }
      }
    }
    return LanRoomInfo(
      roomId: roomId,
      hostNick: hostNick,
      address: '',
      port: port,
      humans: humans,
      ais: ais,
      status: _row['status'] as String? ?? 'waiting',
      seenAt: DateTime.now(),
      hostIps: _hostIps,
    ).toAnnounce();
  }

  Future<void> _startAnnounce() async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udp!.broadcastEnabled = true;
    } catch (e) {
      debugPrint('[LanServer] UDP bind failed: $e');
      return;
    }
    _targets = await LanNet.broadcastTargets();
    _hostIps = await LanNet.localIpv4();
    _announceTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_closed) return;
      // 网络切换（如开热点）后刷新广播目标与本机地址
      if (++_announceTick % 10 == 0) {
        _targets = await LanNet.broadcastTargets();
        _hostIps = await LanNet.localIpv4();
      }
      final bytes = utf8.encode(jsonEncode(_announceInfo()));
      for (final t in _targets) {
        try {
          _udp?.send(bytes, t, LanNet.discoveryPort);
        } catch (_) {}
      }
    });
  }

  /// 解散房间：通知所有玩家并关闭服务。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _announceTimer?.cancel();
    _udp?.close();
    for (final ws in _guests.keys.toList()) {
      _send(ws, {'t': 'closed', 'reason': '房主已解散房间'});
      try {
        await ws.close();
      } catch (_) {}
    }
    _guests.clear();
    await _http?.close(force: true);
    await _rowCtl.close();
    await _chatCtl.close();
    debugPrint('[LanServer] room=$roomId closed');
  }
}

class _Guest {
  String? uid;
  String nick = '';
}
