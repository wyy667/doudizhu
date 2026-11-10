import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/protocol.dart';
import '../net/room_client.dart';

/// 聊天消息列表状态。
class ChatController extends Notifier<List<ChatMessage>> {
  StreamSubscription<ChatMessage>? _sub;
  StreamSubscription<RoomSnapshot>? _roomSub;
  List<SeatInfo?> _lastSeats = [null, null, null];
  bool _initialSeats = true;

  @override
  List<ChatMessage> build() {
    final clientAsync = ref.watch(roomClientProvider);
    final roomId = ref.watch(_chatRoomIdProvider);

    clientAsync.maybeWhen(
      data: (client) {
        _sub?.cancel();
        _sub = client.watchChat(roomId).listen((msg) {
          state = [...state, msg];
        });

        _roomSub?.cancel();
        _roomSub = client.watchRoom(roomId).listen((snapshot) {
          _checkOnlineChanges(snapshot);
        });
      },
      orElse: () {},
    );

    ref.onDispose(() {
      _sub?.cancel();
      _roomSub?.cancel();
    });
    return [];
  }

  void _checkOnlineChanges(RoomSnapshot snapshot) {
    final seats = snapshot.seats;
    if (_initialSeats) {
      _initialSeats = false;
      _lastSeats = List<SeatInfo?>.from(seats);
      return;
    }

    for (var i = 0; i < 3; i++) {
      final prev = _lastSeats.length > i ? _lastSeats[i] : null;
      final curr = seats.length > i ? seats[i] : null;
      final wasOnline = prev?.online == true;
      final isOnline = curr?.online == true;

      if (wasOnline && !isOnline && prev != null) {
        state = [
          ...state,
          ChatMessage(
            bySeat: -1,
            nick: '',
            text: '${prev.nick} 离开了',
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      } else if (!wasOnline && isOnline && curr != null) {
        state = [
          ...state,
          ChatMessage(
            bySeat: -1,
            nick: '',
            text: '${curr.nick} 重新连接了',
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        ];
      }
    }
    _lastSeats = List<SeatInfo?>.from(seats);
  }

  Future<void> send(String text, int seat) async {
    if (text.trim().isEmpty) return;
    final client = ref
        .read(roomClientProvider)
        .maybeWhen(data: (c) => c, orElse: () => null);
    if (client == null) return;
    final roomId = ref.read(_chatRoomIdProvider);
    await client.sendChat(roomId, seat, text.trim());
  }

  void clear() => state = [];
}

/// 当前聊天房间 ID（由 UI override）。
final _chatRoomIdProvider = Provider<String>((ref) {
  throw UnimplementedError('Must be overridden');
});

/// 公开的 roomId Provider（供 UI 和 ChatController 共用）。
final chatRoomIdProvider = Provider<String>((ref) {
  return ref.watch(_chatRoomIdProvider);
});

/// 聊天 Controller Provider。
final chatControllerProvider =
    NotifierProvider<ChatController, List<ChatMessage>>(
      ChatController.new,
      dependencies: [_chatRoomIdProvider],
    );

/// Override 帮手：注入 roomId 到聊天 Provider 链。
Override chatRoomIdOverride(String roomId) {
  return _chatRoomIdProvider.overrideWithValue(roomId);
}
