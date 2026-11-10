import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase_init.dart';

class VoiceTokenService {
  static const _functionName = 'get-voice-token';

  static Future<Map<String, dynamic>> fetchToken(String roomId) async {
    await SupabaseService.ensureInitialized();
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id ?? '';

    debugPrint('[Voice] Token请求: uid=$uid, roomId=$roomId');
    final res = await client.functions.invoke(
      _functionName,
      body: {'roomId': roomId, 'uid': uid},
    );

    final data = res.data as Map<String, dynamic>;
    if (data['error'] != null) {
      debugPrint('[Voice] Token失败: ${data['error']}');
      throw Exception(data['error']);
    }
    debugPrint('[Voice] Token获取成功 ✓');
    return data;
  }

  /// 自动清理：最后一人离开时删除 LiveKit 房间（无需密码）。
  static Future<void> deleteLiveKitRoom(String roomId) async {
    await SupabaseService.ensureInitialized();
    final client = Supabase.instance.client;
    debugPrint('[Voice] 删除 LiveKit 房间: $roomId');
    try {
      final res = await client.functions.invoke(
        _functionName,
        body: {'action': 'delete', 'roomId': roomId},
      );
      final data = res.data as Map<String, dynamic>;
      if (data['ok'] == true) {
        debugPrint('[Voice] LiveKit 房间已删除 ✓');
      } else {
        debugPrint('[Voice] LiveKit 删除异常: $data');
      }
    } catch (e) {
      debugPrint('[Voice] LiveKit 删除失败: $e');
    }
  }

  /// 管理员操作：验证密码
  static Future<bool> verifyAdminPassword(String password) async {
    try {
      await SupabaseService.ensureInitialized();
      final res = await Supabase.instance.client.functions.invoke(
        _functionName,
        body: {'action': 'verify-password', 'adminPassword': password},
      );
      final data = res.data as Map<String, dynamic>;
      return data['ok'] == true;
    } catch (e) {
      debugPrint('[Voice] 密码验证失败: $e');
      return false;
    }
  }

  /// 管理员操作：列出所有 LiveKit 房间
  static Future<List<LiveKitRoomInfo>> listRooms(String adminPassword) async {
    await SupabaseService.ensureInitialized();
    final res = await Supabase.instance.client.functions.invoke(
      _functionName,
      body: {'action': 'list', 'adminPassword': adminPassword},
    );
    final data = res.data;
    if (data is Map) {
      final rooms = (data['rooms'] as List?) ?? [];
      return rooms
          .map((r) => LiveKitRoomInfo.fromMap(r as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Edge Function 返回格式异常: $data');
  }

  /// 管理员操作：删除指定房间
  static Future<void> adminDeleteRoom(
    String roomId,
    String adminPassword,
  ) async {
    await SupabaseService.ensureInitialized();
    final res = await Supabase.instance.client.functions.invoke(
      _functionName,
      body: {
        'action': 'delete',
        'roomId': roomId,
        'adminPassword': adminPassword,
      },
    );
    final data = res.data;
    if (data is Map && data['ok'] == true) return;
    final err = (data is Map ? data['error'] : null) ?? '删除失败';
    throw Exception(err);
  }

  /// 管理员操作：删除所有房间
  static Future<({int deleted, int total})> adminDeleteAllRooms(
    String adminPassword,
  ) async {
    await SupabaseService.ensureInitialized();
    final res = await Supabase.instance.client.functions.invoke(
      _functionName,
      body: {'action': 'delete-all', 'adminPassword': adminPassword},
    );
    final data = res.data;
    if (data is Map && data['ok'] == true) {
      return (
        deleted: data['deleted'] as int? ?? 0,
        total: data['total'] as int? ?? 0,
      );
    }
    throw Exception('Edge Function 返回格式异常: $data');
  }
}

class LiveKitRoomInfo {
  final String name;
  final String sid;
  final int numParticipants;
  final int creationTime;

  const LiveKitRoomInfo({
    required this.name,
    required this.sid,
    required this.numParticipants,
    required this.creationTime,
  });

  factory LiveKitRoomInfo.fromMap(Map<String, dynamic> m) => LiveKitRoomInfo(
    name: '${m['name'] ?? ''}',
    sid: '${m['sid'] ?? ''}',
    numParticipants: _parseInt(m['num_participants']),
    creationTime: _parseInt(m['creation_time']),
  );

  static int _parseInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(creationTime * 1000);

  String get sidShort => sid.length > 8 ? sid.substring(0, 8) : sid;
}
