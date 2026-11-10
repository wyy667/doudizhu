import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 局域网联机常量与网络工具。
class LanNet {
  const LanNet._();

  /// 房主 WebSocket 服务默认端口（被占用时退化为随机端口，通过广播告知）。
  static const int serverPort = 45678;

  /// 房间发现 UDP 广播端口。
  static const int discoveryPort = 45679;

  /// 广播包标识。
  static const String magic = 'landlord-lan';
  static const int protocolVersion = 1;

  static const _channel = MethodChannel('landlord/lan');

  /// 本机局域网 IPv4 地址（优先 Wi-Fi / 热点网段）。
  static Future<List<String>> localIpv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addrs = <String>[];
      for (final i in ifaces) {
        final name = i.name.toLowerCase();
        // 排除蜂窝网络 / 虚拟网卡 / VPN 与代理 TUN
        if (name.startsWith('rmnet') ||
            name.startsWith('ccmni') ||
            name.startsWith('tun') ||
            name.contains('clash') ||
            name.contains('wintun') ||
            name.contains('vethernet') ||
            name.contains('docker') ||
            name.contains('vmware') ||
            name.contains('virtualbox')) {
          continue;
        }
        for (final a in i.addresses) {
          final ip = a.address;
          // 198.18.0.0/15 为基准测试保留段，常被代理软件的 TUN 网卡占用
          if (a.isLinkLocal ||
              ip.startsWith('198.18.') ||
              ip.startsWith('198.19.')) {
            continue;
          }
          addrs.add(ip);
        }
      }
      int score(String ip) {
        if (ip.startsWith('192.168.')) return 0;
        if (ip.startsWith('10.')) return 1;
        if (ip.startsWith('172.')) return 2;
        return 3;
      }

      addrs.sort((a, b) => score(a).compareTo(score(b)));
      return addrs;
    } catch (_) {
      return const [];
    }
  }

  /// 广播目标：全网广播 + 各网段定向广播（按 /24 估算，部分路由器会丢弃 255.255.255.255）。
  static Future<List<InternetAddress>> broadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    for (final ip in await localIpv4()) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
      }
    }
    return targets.map(InternetAddress.new).toList();
  }

  /// Android 默认会过滤非本机的广播/组播包，发现房间时需持有 MulticastLock。
  static Future<void> acquireMulticastLock() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquireMulticastLock');
    } catch (_) {}
  }

  static Future<void> releaseMulticastLock() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }
}

/// 局域网中发现的房间。
class LanRoomInfo {
  final String roomId;
  final String hostNick;
  final String address;
  final int port;
  final int humans;
  final int ais;
  final String status; // waiting | playing | settled
  final DateTime seenAt;

  /// 房主声明的本机局域网地址（用于在多网卡 / 开 VPN 时选出可达地址）。
  final List<String> hostIps;

  const LanRoomInfo({
    required this.roomId,
    required this.hostNick,
    required this.address,
    required this.port,
    required this.humans,
    required this.ais,
    required this.status,
    required this.seenAt,
    this.hostIps = const [],
  });

  bool get inGame => status != 'waiting';
  int get freeSeats => 3 - humans - ais;

  Map<String, dynamic> toAnnounce() => {
    'magic': LanNet.magic,
    'v': LanNet.protocolVersion,
    'room': roomId,
    'host': hostNick,
    'port': port,
    'humans': humans,
    'ais': ais,
    'status': status,
    'ips': hostIps,
  };

  /// 解析广播包。[myIps] 为本机地址：优先选择与本机同一 /24 网段的房主地址，
  /// 否则使用广播包的来源地址。
  static LanRoomInfo? fromDatagram(
    Datagram d, [
    List<String> myIps = const [],
  ]) {
    try {
      final m = jsonDecode(utf8.decode(d.data));
      if (m is! Map || m['magic'] != LanNet.magic) return null;
      final hostIps = [for (final ip in (m['ips'] as List? ?? const [])) '$ip'];
      return LanRoomInfo(
        roomId: m['room'] as String,
        hostNick: m['host'] as String? ?? '',
        address: pickAddress(d.address.address, hostIps, myIps),
        port: m['port'] as int? ?? LanNet.serverPort,
        humans: m['humans'] as int? ?? 1,
        ais: m['ais'] as int? ?? 0,
        status: m['status'] as String? ?? 'waiting',
        seenAt: DateTime.now(),
        hostIps: hostIps,
      );
    } catch (_) {
      return null;
    }
  }

  static String _prefix(String ip) {
    final i = ip.lastIndexOf('.');
    return i < 0 ? ip : ip.substring(0, i);
  }

  @visibleForTesting
  static String pickAddress(
    String source,
    List<String> hostIps,
    List<String> myIps,
  ) {
    if (hostIps.contains(source)) return source;
    final mine = myIps.map(_prefix).toSet();
    for (final ip in hostIps) {
      if (mine.contains(_prefix(ip))) return ip;
    }
    if (mine.contains(_prefix(source))) return source;
    return hostIps.isNotEmpty ? hostIps.first : source;
  }
}

/// 房间发现：监听房主的 UDP 广播，维护最近 4 秒内仍在广播的房间列表。
class LanDiscovery {
  RawDatagramSocket? _socket;
  Timer? _sweep;
  int _tick = 0;
  List<String> _myIps = const [];
  final _rooms = <String, LanRoomInfo>{};
  final _controller = StreamController<List<LanRoomInfo>>.broadcast();

  Stream<List<LanRoomInfo>> get rooms => _controller.stream;
  List<LanRoomInfo> get current => _sorted();

  Future<void> start() async {
    if (_socket != null) return;
    await LanNet.acquireMulticastLock();
    _myIps = await LanNet.localIpv4();
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanNet.discoveryPort,
        reuseAddress: true,
      );
    } catch (e) {
      debugPrint('[LanDiscovery] bind failed: $e');
      return;
    }
    _socket!.broadcastEnabled = true;
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _socket?.receive()) != null) {
        final info = LanRoomInfo.fromDatagram(d!, _myIps);
        if (info == null) continue;
        // 同一房主可能经多张网卡广播多次 → 按房间去重
        final key = '${info.roomId}:${info.port}:${info.hostIps.join(',')}';
        final isNew = !_rooms.containsKey(key);
        _rooms[key] = info;
        if (isNew) _emit();
      }
    });
    _sweep = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (++_tick % 5 == 0) _myIps = await LanNet.localIpv4();
      final now = DateTime.now();
      _rooms.removeWhere(
        (_, r) => now.difference(r.seenAt) > const Duration(seconds: 4),
      );
      _emit();
    });
  }

  List<LanRoomInfo> _sorted() =>
      _rooms.values.toList()..sort((a, b) => a.roomId.compareTo(b.roomId));

  void _emit() {
    if (!_controller.isClosed) _controller.add(_sorted());
  }

  Future<void> stop() async {
    _sweep?.cancel();
    _sweep = null;
    _socket?.close();
    _socket = null;
    await LanNet.releaseMulticastLock();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
