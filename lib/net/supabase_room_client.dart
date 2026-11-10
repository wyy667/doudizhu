import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'protocol.dart';
import 'room_client_base.dart';
import '../voice/voice_token_service.dart';

/// Supabase 房间客户端（国内节点方案）。
///
/// 采用 **Hybrid 实时架构**：
/// - **Broadcast channel**（<50ms）：写入后立即广播 partial changes，低延迟同步
/// - **PostgresChanges**（50-200ms）：作为兜底/重连恢复，保证最终一致性
///
/// 两个数据源都更新 [_cachedRows] 并通过 [_rowControllers] 发射完整行，
/// 各 watch 方法通过 [_transformRowStream] 统一转换，无需关心数据来源。
class SupabaseRoomClient implements RoomClientBase {
  final SupabaseClient _db;
  @override
  final String uid;
  @override
  final String nickname;

  /// 每个房间缓存的最新完整行数据。
  final _cachedRows = <String, Map<String, dynamic>>{};

  /// 每个房间的广播 controller（原始行数据，所有 watch 方法共用）。
  final _rowControllers = <String, StreamController<Map<String, dynamic>>>{};

  /// PostgresChanges channel（兜底同步）。
  final _pgChannels = <String, RealtimeChannel>{};

  /// Broadcast channel（低延迟同步）。
  final _bcChannels = <String, RealtimeChannel>{};

  final _chatControllers = <String, StreamController<ChatMessage>>{};
  final _chatChannels = <String, RealtimeChannel>{};

  /// 心跳定时器（key = roomId-seat）。
  final _heartbeats = <String, Timer>{};

  /// 连接状态 controller。
  final _connectedController = StreamController<bool>.broadcast();

  SupabaseRoomClient({required this.uid, required this.nickname})
    : _db = Supabase.instance.client;

  // ── 房间生命周期 ──

  @override
  Future<String> createRoom({required bool chatEnabled}) async {
    String code;
    bool exists = true;
    do {
      code = NetProtocol.generateRoomCode();
      final res = await _db
          .from('rooms')
          .select('room_id')
          .eq('room_id', code)
          .maybeSingle();
      exists = res != null;
    } while (exists);

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.from('rooms').insert({
      'room_id': code,
      'host_uid': uid,
      'chat_enabled': chatEnabled,
      'status': 'waiting',
      'created_at': now,
      'seats': [
        {'uid': uid, 'nick': nickname, 'online': true, 'last_seen': now},
        null,
        null,
      ],
      'ready': [false, false, false],
      'hands': {},
      'updated_at': now,
    });
    _startHeartbeat(code, 0);
    return code;
  }

  @override
  Future<int> joinRoom(String roomId) async {
    final res = await _db
        .from('rooms')
        .select('seats')
        .eq('room_id', roomId)
        .maybeSingle();
    if (res == null) throw Exception('房间不存在');

    final seatsRaw = res['seats'];
    final seats = <dynamic>[null, null, null];
    if (seatsRaw is List) {
      for (var i = 0; i < seatsRaw.length && i < 3; i++) {
        seats[i] = seatsRaw[i];
      }
    }

    // 重连：如果已有该玩家的座位，直接恢复
    for (var s = 0; s < 3; s++) {
      final sd = seats[s];
      if (sd is Map && sd['uid'] == uid) {
        seats[s] = {
          'uid': uid,
          'nick': nickname,
          'online': true,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        };
        final data = {
          'seats': seats,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        await _db.from('rooms').update(data).eq('room_id', roomId);
        _broadcastChanges(roomId, data);
        _startHeartbeat(roomId, s);
        return s;
      }
    }

    // 找空座位
    for (var s = 0; s < 3; s++) {
      if (seats[s] == null) {
        seats[s] = {
          'uid': uid,
          'nick': nickname,
          'online': true,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        };
        final data = {
          'seats': seats,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        await _db.from('rooms').update(data).eq('room_id', roomId);
        _broadcastChanges(roomId, data);
        _startHeartbeat(roomId, s);
        return s;
      }
    }
    throw Exception('房间已满');
  }

  @override
  Future<void> leaveRoom(String roomId, int seat) async {
    _stopHeartbeat(roomId, seat);
    await _updateJsonField(roomId, 'seats', (seats) {
      final list = _ensureList3(seats);
      list[seat] = null;
      return list;
    });
    // 检查是否还有真人玩家在线，没有则删除房间（AI 不计入）
    final res = await _db
        .from('rooms')
        .select('seats')
        .eq('room_id', roomId)
        .maybeSingle();
    if (res != null) {
      final seats = res['seats'];
      bool hasOnlinePlayers = false;
      if (seats is List) {
        for (final v in seats) {
          if (v is Map && v['online'] == true && v['isAI'] != true) {
            hasOnlinePlayers = true;
            break;
          }
        }
      }
      if (!hasOnlinePlayers) {
        await _db.from('rooms').delete().eq('room_id', roomId);
        VoiceTokenService.deleteLiveKitRoom(roomId);
      }
    }
    _cleanupRoom(roomId);
  }

  @override
  Future<void> exitRoom(String roomId, int seat) async {
    _stopHeartbeat(roomId, seat);
    await _updateJsonFields(roomId, {
      'seats': (v) {
        final list = _ensureList3(v);
        final seatData = list[seat];
        if (seatData is Map) {
          list[seat] = Map<String, dynamic>.from(seatData)..['online'] = false;
        }
        return list;
      },
      'ready': (v) {
        final list = _ensureList3(v);
        if (seat < 3) list[seat] = false;
        return list;
      },
    });

    final res = await _db
        .from('rooms')
        .select('seats')
        .eq('room_id', roomId)
        .maybeSingle();
    if (res != null) {
      final seats = res['seats'];
      bool hasOnlinePlayers = false;
      if (seats is List) {
        for (final v in seats) {
          if (v is Map && v['online'] == true && v['isAI'] != true) {
            hasOnlinePlayers = true;
            break;
          }
        }
      }
      if (!hasOnlinePlayers) {
        await _db.from('rooms').delete().eq('room_id', roomId);
        VoiceTokenService.deleteLiveKitRoom(roomId);
      }
    }
    _cleanupRoom(roomId);
  }

  @override
  Future<void> addAiSeat(String roomId, int seat, String nick) async {
    await _updateJsonField(roomId, 'seats', (seats) {
      final list = _ensureList3(seats);
      list[seat] = {
        'uid': 'ai_${roomId}_$seat',
        'nick': nick,
        'online': true,
        'isAI': true,
      };
      return list;
    });
  }

  @override
  Future<void> removeAiSeat(String roomId, int seat) async {
    await _updateJsonField(roomId, 'seats', (seats) {
      final list = _ensureList3(seats);
      list[seat] = null;
      return list;
    });
  }

  /// 设置座位 online 状态。
  @override
  Future<void> setOnline(String roomId, int seat, bool online) async {
    debugPrint(
      '[SupabaseRoom] setOnline room=$roomId seat=$seat online=$online',
    );
    try {
      await _updateJsonField(roomId, 'seats', (v) {
        final list = _ensureList3(v);
        final sd = list[seat];
        if (sd is Map) {
          list[seat] = Map<String, dynamic>.from(sd)..['online'] = online;
        }
        return list;
      });
    } catch (e) {
      debugPrint('[SupabaseRoom] setOnline failed (expected offline): $e');
    }
    if (online) {
      _startHeartbeat(roomId, seat);
    } else {
      _stopHeartbeat(roomId, seat);
    }
  }

  /// 监听 Supabase Realtime 连接状态。
  @override
  Stream<bool> watchConnected() {
    return _connectedController.stream;
  }

  /// 更新房主 UID。
  @override
  Future<void> updateHostUid(String roomId, String newHostUid) async {
    debugPrint('[SupabaseRoom] updateHostUid room=$roomId → $newHostUid');
    try {
      await _db
          .from('rooms')
          .update({'host_uid': newHostUid})
          .eq('room_id', roomId);
    } catch (e) {
      debugPrint('[SupabaseRoom] updateHostUid failed: $e');
    }
  }

  /// 强制重新拉取房间数据（断线重连后同步）。
  @override
  Future<void> resync(String roomId) async {
    try {
      final res = await _db
          .from('rooms')
          .select()
          .eq('room_id', roomId)
          .maybeSingle();
      if (res != null) {
        final row = _applyStaleCheck(Map<String, dynamic>.from(res));
        final cachedTs = _cachedRows[roomId]?['updated_at'] as int? ?? 0;
        final rowTs = row['updated_at'] as int? ?? 0;
        if (rowTs >= cachedTs) {
          _cachedRows[roomId] = row;
          _rowControllers[roomId]?.add(row);
        }
        debugPrint(
          '[SupabaseRoom] resync ✅ room=$roomId phase=${row['game_state']?['phase']}',
        );
      }
    } catch (e) {
      debugPrint('[SupabaseRoom] resync ❌ $e');
    }
  }

  /// 检查 seats 中 last_seen 过期的座位（>30s），将其 online 标记为 false。
  Map<String, dynamic> _applyStaleCheck(Map<String, dynamic> row) {
    final seatsRaw = row['seats'];
    if (seatsRaw is! List) return row;
    final now = DateTime.now().millisecondsSinceEpoch;
    var modified = false;
    final newSeats = List<dynamic>.from(seatsRaw);
    for (var s = 0; s < newSeats.length; s++) {
      final sd = newSeats[s];
      if (sd is Map) {
        final online = sd['online'] == true;
        final lastSeen = sd['last_seen'] as int?;
        if (online && lastSeen != null) {
          if (now - lastSeen > 30000) {
            newSeats[s] = Map<String, dynamic>.from(sd)..['online'] = false;
            modified = true;
            debugPrint(
              '[SupabaseRoom] stale seat $s '
              'lastSeen=${now - lastSeen}ms ago → offline',
            );
          }
        }
      }
    }
    if (modified) {
      row['seats'] = newSeats;
    }
    return row;
  }

  /// 启动心跳：每 10 秒更新 seats[seat].last_seen。
  void _startHeartbeat(String roomId, int seat) {
    final key = '$roomId-$seat';
    _heartbeats[key]?.cancel();
    _updateLastSeen(roomId, seat);
    _heartbeats[key] = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _updateLastSeen(roomId, seat),
    );
  }

  void _stopHeartbeat(String roomId, int seat) {
    final key = '$roomId-$seat';
    _heartbeats[key]?.cancel();
    _heartbeats.remove(key);
  }

  Future<void> _updateLastSeen(String roomId, int seat) async {
    try {
      await _updateJsonField(roomId, 'seats', (v) {
        final list = _ensureList3(v);
        final sd = list[seat];
        if (sd is Map) {
          list[seat] = Map<String, dynamic>.from(sd)
            ..['last_seen'] = DateTime.now().millisecondsSinceEpoch;
        }
        return list;
      });
    } catch (_) {}
  }

  // ── 监听 ──

  @override
  Stream<RoomSnapshot> watchRoom(String roomId) {
    _ensureRoomChannel(roomId);
    return _transformRowStream<RoomSnapshot>(roomId, (row) {
      final meta = RoomMeta(
        hostUid: row['host_uid'] as String? ?? '',
        chatEnabled: row['chat_enabled'] as bool? ?? false,
        status: row['status'] as String? ?? 'waiting',
        createdAt: row['created_at'] as int? ?? 0,
      );
      final seatsRaw = row['seats'];
      final seats = List<SeatInfo?>.filled(3, null);
      int? mySeat;
      if (seatsRaw is List) {
        for (var s = 0; s < seatsRaw.length && s < 3; s++) {
          final sd = seatsRaw[s];
          if (sd is Map) {
            final info = SeatInfo.fromMap(Map<dynamic, dynamic>.from(sd));
            seats[s] = info;
            if (info.uid == uid) mySeat = s;
          }
        }
      }
      return RoomSnapshot(
        roomId: roomId,
        meta: meta,
        seats: seats,
        myUid: uid,
        mySeat: mySeat,
        isHost: meta.hostUid == uid,
      );
    });
  }

  @override
  Stream<Map<dynamic, dynamic>?> watchGameState(String roomId) {
    _ensureRoomChannel(roomId);
    return _transformRowStream<Map<dynamic, dynamic>?>(roomId, (row) {
      final gs = row['game_state'];
      return gs is Map ? Map<dynamic, dynamic>.from(gs) : null;
    });
  }

  @override
  Stream<List<int>> watchMyHand(String roomId, int mySeat) {
    _ensureRoomChannel(roomId);
    return _transformRowStream<List<int>>(roomId, (row) {
      final hands = row['hands'];
      if (hands is Map) {
        return _parseHandList(hands['$mySeat']);
      }
      return <int>[];
    });
  }

  @override
  Stream<Map<dynamic, dynamic>?> watchPendingAction(String roomId) {
    _ensureRoomChannel(roomId);
    return _transformRowStream<Map<dynamic, dynamic>?>(roomId, (row) {
      final pa = row['pending_action'];
      return pa is Map ? Map<dynamic, dynamic>.from(pa) : null;
    });
  }

  @override
  Stream<List<bool>> watchReady(String roomId) {
    _ensureRoomChannel(roomId);
    return _transformRowStream<List<bool>>(roomId, (row) {
      return _parseReadyList(row['ready']);
    });
  }

  @override
  Stream<ChatMessage> watchChat(String roomId) {
    final existing = _chatControllers[roomId];
    if (existing != null && !existing.isClosed) return existing.stream;

    final controller = StreamController<ChatMessage>.broadcast();
    _chatControllers[roomId] = controller;

    _db
        .from('room_chat')
        .select()
        .eq('room_id', roomId)
        .order('ts')
        .limit(50)
        .then((rows) {
          if (!controller.isClosed) {
            for (final row in rows as List) {
              controller.add(
                ChatMessage(
                  bySeat: row['by_seat'] as int,
                  nick: row['nick'] as String,
                  text: row['text'] as String,
                  ts: row['ts'] as int,
                ),
              );
            }
          }
        });

    final channel = _db
        .channel('chat:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'room_chat',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (!controller.isClosed) {
              controller.add(
                ChatMessage(
                  bySeat: row['by_seat'] as int,
                  nick: row['nick'] as String,
                  text: row['text'] as String,
                  ts: row['ts'] as int,
                ),
              );
            }
          },
        )
        .subscribe();
    _chatChannels[roomId] = channel;

    return controller.stream;
  }

  // ── 写入 ──

  @override
  Future<void> submitAction(String roomId, Map<String, dynamic> action) async {
    final data = {
      'pending_action': action,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> clearPendingAction(String roomId) async {
    final data = {
      'pending_action': null,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> updateGameState(
    String roomId,
    Map<String, dynamic> state,
  ) async {
    final data = {
      'game_state': state,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> writeHand(String roomId, int seat, List<int> cards) async {
    await _updateJsonField(roomId, 'hands', (v) {
      final map = _ensureMap3(v);
      map['$seat'] = cards;
      return map;
    });
  }

  @override
  Future<void> clearHands(String roomId) async {
    final data = {
      'hands': {},
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> updateStatus(String roomId, String status) async {
    final data = {
      'status': status,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> setReady(String roomId, int seat, bool ready) async {
    await _updateJsonField(roomId, 'ready', (v) {
      final list = _ensureList3(v);
      if (seat < 3) list[seat] = ready;
      return list;
    });
  }

  @override
  Future<void> clearReady(String roomId) async {
    final data = {
      'ready': [false, false, false],
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  @override
  Future<void> sendChat(String roomId, int seat, String text) async {
    await _db.from('room_chat').insert({
      'room_id': roomId,
      'by_seat': seat,
      'nick': nickname,
      'text': text.substring(0, text.length.clamp(0, 200)),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> batchUpdate(
    String roomId, {
    Map<String, dynamic>? gameState,
    Map<int, List<int>>? hands,
    String? status,
    bool clearPendingAction = false,
    bool clearReady = false,
  }) async {
    final data = <String, dynamic>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (gameState != null) data['game_state'] = gameState;
    if (hands != null) {
      final handsMap = <String, dynamic>{};
      for (final entry in hands.entries) {
        handsMap['${entry.key}'] = entry.value;
      }
      data['hands'] = handsMap;
    }
    if (status != null) data['status'] = status;
    if (clearPendingAction) data['pending_action'] = null;
    if (clearReady) data['ready'] = [false, false, false];
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  // ── 核心：Hybrid 实时同步（Broadcast + PostgresChanges）──

  /// 确保房间有完整的实时同步设施：
  /// - rowController（统一数据出口）
  /// - 初始 SELECT 加载
  /// - PostgresChanges channel（兜底/重连恢复）
  /// - Broadcast channel（低延迟同步）
  void _ensureRoomChannel(String roomId) {
    if (_rowControllers.containsKey(roomId)) return;

    final controller = StreamController<Map<String, dynamic>>.broadcast();
    _rowControllers[roomId] = controller;

    // 初始加载
    _db.from('rooms').select().eq('room_id', roomId).maybeSingle().then((res) {
      if (res != null && !controller.isClosed) {
        final row = Map<String, dynamic>.from(res);
        // 不用陈旧 SELECT 覆盖已通过 Broadcast 到达的更新数据
        final cached = _cachedRows[roomId];
        final cachedTs = cached?['updated_at'] as int? ?? 0;
        final rowTs = row['updated_at'] as int? ?? 0;
        if (cached == null || rowTs >= cachedTs) {
          _cachedRows[roomId] = row;
          controller.add(row);
        }
      }
    });

    // PostgresChanges（兜底，50-200ms）
    final pgChannel = _db
        .channel('room_pg:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rooms',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) {
            final row = _applyStaleCheck(
              Map<String, dynamic>.from(payload.newRecord),
            );
            _cachedRows[roomId] = row;
            if (!controller.isClosed) controller.add(row);
          },
        )
        .subscribe();
    _pgChannels[roomId] = pgChannel;

    // Broadcast（低延迟，<50ms）+ 连接状态检测
    final bcChannel = _db
        .channel(
          'room_bc:$roomId',
          opts: const RealtimeChannelConfig(self: false),
        )
        .onBroadcast(
          event: 'changes',
          callback: (payload) {
            final changes = Map<String, dynamic>.from(payload);
            final cached = Map<String, dynamic>.from(_cachedRows[roomId] ?? {});
            cached.addAll(changes);
            final row = _applyStaleCheck(cached);
            _cachedRows[roomId] = row;
            if (!controller.isClosed) controller.add(row);
          },
        )
        .subscribe((status, error) {
          // channel 状态变化 → 通知连接状态
          final connected = status == RealtimeSubscribeStatus.subscribed;
          debugPrint(
            '[SupabaseRoom] channel status=$status'
            '${error != null ? ' error=$error' : ''}'
            ' → connected=$connected',
          );
          if (!_connectedController.isClosed) {
            _connectedController.add(connected);
          }
        });
    _bcChannels[roomId] = bcChannel;
  }

  /// 通过 Broadcast channel 广播 partial changes（低延迟同步）。
  ///
  /// 写入 DB 后立即调用，其他客户端通过 Broadcast 收到变更（<50ms），
  /// PostgresChanges 随后到达作为兜底（50-200ms），两者幂等合并。
  void _broadcastChanges(String roomId, Map<String, dynamic> changes) {
    _ensureRoomChannel(roomId);
    final channel = _bcChannels[roomId];
    if (channel != null) {
      // 拷贝为 Map<String, dynamic>，避免 Dart 类型推断导致 send() 写入
      // payload['type']='broadcast' 时出现运行时类型不匹配（如 Map<String,int?>）
      final payload = Map<String, dynamic>.from(changes);
      unawaited(
        channel.sendBroadcastMessage(event: 'changes', payload: payload),
      );
    }
  }

  /// 将原始行 stream 转换为目标类型的 stream。
  ///
  /// 如果已有缓存数据，在 microtask 中先 replay 给新 listener，
  /// 确保 listener 注册后才收到。
  Stream<T> _transformRowStream<T>(
    String roomId,
    T Function(Map<String, dynamic> row) transform,
  ) {
    final controller = StreamController<T>.broadcast();
    final rowController = _rowControllers[roomId];

    final cached = _cachedRows[roomId];
    if (cached != null) {
      scheduleMicrotask(() {
        if (!controller.isClosed) controller.add(transform(cached));
      });
    }

    rowController?.stream.listen((row) {
      if (!controller.isClosed) controller.add(transform(row));
    });

    return controller.stream;
  }

  // ── 辅助方法 ──

  List<int> _parseHandList(dynamic raw) {
    if (raw is List) return raw.cast<int>();
    return <int>[];
  }

  List<bool> _parseReadyList(dynamic raw) {
    final result = List<bool>.filled(3, false);
    if (raw is List) {
      for (var s = 0; s < raw.length && s < 3; s++) {
        result[s] = raw[s] == true;
      }
    }
    return result;
  }

  void _cleanupRoom(String roomId) {
    // 停止该房间的所有心跳
    final hbKeys = _heartbeats.keys.where((k) => k.startsWith('$roomId-'));
    for (final k in hbKeys.toList()) {
      _heartbeats[k]?.cancel();
      _heartbeats.remove(k);
    }
    _rowControllers[roomId]?.close();
    _chatControllers[roomId]?.close();
    _rowControllers.remove(roomId);
    _chatControllers.remove(roomId);
    _cachedRows.remove(roomId);
    final pgChannel = _pgChannels.remove(roomId);
    if (pgChannel != null) _db.removeChannel(pgChannel);
    final bcChannel = _bcChannels.remove(roomId);
    if (bcChannel != null) _db.removeChannel(bcChannel);
    final chatChannel = _chatChannels.remove(roomId);
    if (chatChannel != null) _db.removeChannel(chatChannel);
  }

  List<dynamic> _ensureList3(dynamic v) {
    final list = <dynamic>[null, null, null];
    if (v is List) {
      for (var i = 0; i < v.length && i < 3; i++) {
        list[i] = v[i];
      }
    }
    return list;
  }

  Map<String, dynamic> _ensureMap3(dynamic v) {
    final map = <String, dynamic>{'0': [], '1': [], '2': []};
    if (v is Map) {
      for (final k in ['0', '1', '2']) {
        if (v[k] != null) map[k] = v[k];
      }
    }
    return map;
  }

  Future<void> _updateJsonField(
    String roomId,
    String column,
    dynamic Function(dynamic current) modifier,
  ) async {
    final res = await _db
        .from('rooms')
        .select(column)
        .eq('room_id', roomId)
        .maybeSingle();
    if (res == null) return;
    final newValue = modifier(res[column]);
    final data = {
      column: newValue,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }

  Future<void> _updateJsonFields(
    String roomId,
    Map<String, dynamic Function(dynamic current)> modifiers,
  ) async {
    final columns = modifiers.keys.toList();
    final res = await _db
        .from('rooms')
        .select(columns.join(','))
        .eq('room_id', roomId)
        .maybeSingle();
    if (res == null) return;
    final data = <String, dynamic>{};
    for (final entry in modifiers.entries) {
      data[entry.key] = entry.value(res[entry.key]);
    }
    data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await _db.from('rooms').update(data).eq('room_id', roomId);
    _broadcastChanges(roomId, data);
  }
}
