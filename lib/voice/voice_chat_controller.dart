import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';

import 'voice_token_service.dart';

final _voiceChatRoomIdProvider = Provider<String>((ref) {
  throw UnimplementedError('Must be overridden');
});

final voiceChatRoomIdProvider = Provider<String>((ref) {
  return ref.watch(_voiceChatRoomIdProvider);
});

Override voiceChatRoomIdOverride(String roomId) {
  return _voiceChatRoomIdProvider.overrideWithValue(roomId);
}

class VoiceChatController extends Notifier<VoiceChatState> {
  static VoiceChatController? _activeInstance;

  /// 紧急断开当前语音连接（退出房间/App 被杀时调用）。
  static Future<void> disconnectActive() async {
    _activeInstance?._wasConnected = false;
    await _activeInstance?._disconnect();
    _activeInstance?.state = VoiceChatState.initial();
    _activeInstance = null;
  }

  @override
  VoiceChatState build() {
    final roomId = ref.watch(_voiceChatRoomIdProvider);

    _activeInstance = this;
    _roomId = roomId;

    ref.onDispose(() {
      _activeInstance = null;
      _disconnect();
    });

    return const VoiceChatState.initial();
  }

  Room? _room;
  String? _roomId;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  bool _wasConnected = false;

  // 单人 1 分钟自删
  Timer? _aloneTimer;
  static const _aloneTimeout = Duration(seconds: 60);
  bool _leaving = false; // 正在执行离开操作（防止 _onRoomUpdate 触发重连）

  Future<void> _connect(String roomId) async {
    final wasConnected = _wasConnected;
    if (_room != null) {
      await _disconnect();
    }

    _roomId = roomId;

    try {
      debugPrint('[Voice] 请求 Token, roomId=$roomId');
      final result = await VoiceTokenService.fetchToken(roomId);
      final room = Room();

      room.addListener(_onRoomUpdate);

      debugPrint('[Voice] 正在连接 LiveKit...');
      await room.connect(result['url'] as String, result['token'] as String);

      _room = room;
      _wasConnected = true;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      debugPrint('[Voice] 连接成功, 远程参与者: ${room.remoteParticipants.length}');
      _updateState();
    } catch (e) {
      debugPrint('[Voice] 连接失败: $e');
      state = state.copyWith(connected: false, error: true, inVoiceRoom: true);
      if (wasConnected) {
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    if (_roomId == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[Voice] 已达最大重连次数($_maxReconnectAttempts)，停止重连');
      return;
    }
    _reconnectAttempts++;
    final rid = _roomId!;
    debugPrint('[Voice] 第 $_reconnectAttempts 次重连，5秒后...');
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      _reconnectTimer = null;
      debugPrint('[Voice] 尝试重连...');
      _connect(rid);
    });
  }

  void _onRoomUpdate() {
    _updateState();
    final room = _room;
    if (room == null) return;

    // 房间被删除或断连时自动重连（跳过主动离开）
    if (!_leaving &&
        room.connectionState == ConnectionState.disconnected &&
        _roomId != null) {
      debugPrint('[Voice] 连接断开，准备重连...');
      _scheduleReconnect();
    }

    // 单人自删检测
    _checkAlone(room);
  }

  void _checkAlone(Room room) {
    if (room.connectionState != ConnectionState.connected) return;
    final remoteCount = room.remoteParticipants.length;

    if (remoteCount == 0) {
      // 只剩自己一人 → 启动 1 分钟倒计时
      if (_aloneTimer == null) {
        debugPrint('[Voice] 只剩自己一人，1 分钟后自动删除房间');
        final rid = _roomId!;
        _aloneTimer = Timer(_aloneTimeout, () async {
          debugPrint('[Voice] 单人超时，删除语音房间 $rid');
          await VoiceTokenService.deleteLiveKitRoom(rid);
          await disconnect();
        });
      }
    } else {
      // 有人加入 → 取消倒计时
      if (_aloneTimer != null) {
        debugPrint('[Voice] 有人加入，取消单人自删');
        _aloneTimer!.cancel();
        _aloneTimer = null;
      }
    }
  }

  void _updateState() {
    if (_room == null) return;

    final remote = _room!.remoteParticipants;
    final speakingUids = <String>[];
    for (final p in remote.values) {
      if (p.isSpeaking) {
        speakingUids.add(p.identity);
      }
    }

    final connected = _room!.connectionState == ConnectionState.connected;

    state = state.copyWith(
      connected: connected,
      micEnabled: _room!.localParticipant?.isMicrophoneEnabled() ?? false,
      speakingUids: speakingUids,
      error: false,
    );
  }

  void setMic(bool enabled) {
    debugPrint('[Voice] 麦克风: ${enabled ? "开" : "闭"}');
    _room?.localParticipant?.setMicrophoneEnabled(enabled);
    _updateState();
  }

  /// 离开语音房间（主动退出，不触发重连）。
  Future<void> disconnect() async {
    _leaving = true;
    _aloneTimer?.cancel();
    _aloneTimer = null;
    _wasConnected = false;
    await _disconnect();
    state = state.copyWith(
      inVoiceRoom: false,
      connected: false,
      micEnabled: false,
    );
    _leaving = false;
  }

  /// 重新加入语音房间。
  Future<void> reconnect() async {
    final String rid = _roomId ?? ref.read(_voiceChatRoomIdProvider);
    _roomId = rid;
    state = state.copyWith(inVoiceRoom: true);
    await _connect(rid);
  }

  Future<void> _disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _aloneTimer?.cancel();
    _aloneTimer = null;
    final room = _room;
    if (room == null) return;
    // 先移除监听 + 置空 _room，再调 disconnect()，
    // 否则 disconnect() 触发的事件会被 _onRoomUpdate 捕获并错误地调度重连。
    _room = null;
    room.removeListener(_onRoomUpdate);
    debugPrint('[Voice] 断开连接...');
    try {
      await room.localParticipant?.setMicrophoneEnabled(false);
    } catch (_) {}
    try {
      await room.disconnect();
    } catch (_) {}
    debugPrint('[Voice] 已断开 ✓');
  }
}

class VoiceChatState {
  final bool connected;
  final bool inVoiceRoom;
  final bool micEnabled;
  final List<String> speakingUids;
  final bool error;

  const VoiceChatState({
    required this.connected,
    required this.inVoiceRoom,
    required this.micEnabled,
    required this.speakingUids,
    required this.error,
  });

  const VoiceChatState.initial()
    : connected = false,
      inVoiceRoom = false,
      micEnabled = false,
      speakingUids = const [],
      error = false;

  VoiceChatState copyWith({
    bool? connected,
    bool? inVoiceRoom,
    bool? micEnabled,
    List<String>? speakingUids,
    bool? error,
  }) {
    return VoiceChatState(
      connected: connected ?? this.connected,
      inVoiceRoom: inVoiceRoom ?? this.inVoiceRoom,
      micEnabled: micEnabled ?? this.micEnabled,
      speakingUids: speakingUids ?? this.speakingUids,
      error: error ?? this.error,
    );
  }
}

final voiceChatControllerProvider =
    NotifierProvider<VoiceChatController, VoiceChatState>(
      VoiceChatController.new,
      dependencies: [_voiceChatRoomIdProvider],
    );
