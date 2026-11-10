import 'dart:io';

import 'package:flutter/foundation.dart';

/// 检查网络连通性。
class RegionDetector {
  /// 检查是否有基础网络连接（DNS lookup），最多等待 3 秒。
  static Future<bool> hasNetwork() async {
    try {
      final result = await InternetAddress.lookup(
        'cloudflare.com',
      ).timeout(const Duration(seconds: 3));
      debugPrint('[Region] DNS lookup 成功: ${result.length} 条记录');
      return true;
    } catch (e) {
      debugPrint('[Region] DNS lookup 失败: $e');
      return false;
    }
  }
}
