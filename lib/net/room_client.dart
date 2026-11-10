import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan/local_profile.dart';
import 'room_client_base.dart';

export 'room_client_base.dart';

/// 当前用户信息 Provider（局域网联机：本机持久化 uid + 可改昵称）。
final currentUserProvider = FutureProvider<({String uid, String nick})>(
  (ref) => LocalProfile.load(),
);

/// 网络后端模式。
///
/// 联机默认走局域网（房主设备即服务器）；Supabase 实现保留在
/// `supabase_room_client.dart`，当前 UI 不再使用。
enum NetBackend { lan, supabase }

/// 当前后端选择。
final netBackendProvider = StateProvider<NetBackend>((ref) => NetBackend.lan);

/// 当前所在房间的客户端（大厅开房 / 加入成功后设置，离开房间后清空）。
final activeRoomClientProvider = StateProvider<RoomClientBase?>((ref) => null);

/// RoomClient Provider：返回当前房间的客户端；未进入房间时为错误态。
final roomClientProvider = FutureProvider<RoomClientBase>((ref) {
  final client = ref.watch(activeRoomClientProvider);
  if (client == null) throw StateError('尚未进入局域网房间');
  return client;
});
