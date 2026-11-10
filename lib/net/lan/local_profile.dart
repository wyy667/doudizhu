import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本机玩家身份（局域网联机用）：持久化 uid + 可修改昵称。
///
/// uid 用于断线重连时找回自己的座位，因此必须跨启动保持不变。
class LocalProfile {
  const LocalProfile._();

  static const _uidKey = 'lan_uid';
  static const _nickKey = 'lan_nick';

  /// 桌面端同机多开调试：设置环境变量 LANDLORD_PROFILE 使用独立身份。
  static String get _suffix {
    if (kIsWeb) return '';
    final p = Platform.environment['LANDLORD_PROFILE'];
    return p == null || p.isEmpty ? '' : '_$p';
  }

  static Future<({String uid, String nick})> load() async {
    final prefs = await SharedPreferences.getInstance();
    var uid = prefs.getString('$_uidKey$_suffix');
    if (uid == null || uid.isEmpty) {
      uid = _randomId();
      await prefs.setString('$_uidKey$_suffix', uid);
    }
    var nick = prefs.getString('$_nickKey$_suffix');
    if (nick == null || nick.trim().isEmpty) {
      nick = '玩家${uid.substring(0, 4).toUpperCase()}';
    }
    return (uid: uid, nick: nick);
  }

  static Future<void> setNick(String nick) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = nick.trim();
    if (trimmed.isEmpty) {
      await prefs.remove('$_nickKey$_suffix');
    } else {
      await prefs.setString(
        '$_nickKey$_suffix',
        trimmed.substring(0, trimmed.length.clamp(0, 12)),
      );
    }
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
