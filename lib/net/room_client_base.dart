import 'dart:async';

import '../net/protocol.dart';

/// 房间客户端抽象接口。
///
/// 当前由 Supabase 实现，保留抽象接口以便未来扩展或测试 mock。
abstract class RoomClientBase {
  String get uid;
  String get nickname;

  // ── 房间生命周期 ──
  Future<String> createRoom({required bool chatEnabled});
  Future<int> joinRoom(String roomId);
  Future<void> leaveRoom(String roomId, int seat);
  Future<void> exitRoom(String roomId, int seat);

  /// 设置座位 online 状态（断线重连恢复用）。
  Future<void> setOnline(String roomId, int seat, bool online);

  /// 监听网络连接状态（true=已连接/重连成功）。
  Stream<bool> watchConnected();

  /// 强制重新拉取房间数据（断线重连后同步最新状态）。
  Future<void> resync(String roomId);

  /// 更新房主 UID（房主迁移用）。
  Future<void> updateHostUid(String roomId, String newHostUid);

  /// 房主添加 AI 玩家到指定空座位。
  Future<void> addAiSeat(String roomId, int seat, String nick);

  /// 房主移除 AI 玩家。
  Future<void> removeAiSeat(String roomId, int seat);

  // ── 监听 ──
  Stream<RoomSnapshot> watchRoom(String roomId);
  Stream<Map<dynamic, dynamic>?> watchGameState(String roomId);
  Stream<List<int>> watchMyHand(String roomId, int mySeat);
  Stream<Map<dynamic, dynamic>?> watchPendingAction(String roomId);
  Stream<ChatMessage> watchChat(String roomId);
  Stream<List<bool>> watchReady(String roomId);

  // ── 写入 ──
  Future<void> submitAction(String roomId, Map<String, dynamic> action);
  Future<void> clearPendingAction(String roomId);
  Future<void> updateGameState(String roomId, Map<String, dynamic> state);
  Future<void> writeHand(String roomId, int seat, List<int> cards);
  Future<void> clearHands(String roomId);
  Future<void> updateStatus(String roomId, String status);
  Future<void> setReady(String roomId, int seat, bool ready);
  Future<void> clearReady(String roomId);
  Future<void> sendChat(String roomId, int seat, String text);

  /// 批量更新房间数据（一次网络往返完成所有写入）。
  Future<void> batchUpdate(
    String roomId, {
    Map<String, dynamic>? gameState,
    Map<int, List<int>>? hands,
    String? status,
    bool clearPendingAction = false,
    bool clearReady = false,
  });
}
