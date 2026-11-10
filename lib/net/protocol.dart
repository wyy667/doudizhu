/// 网络对局协议常量与工具。
///
/// RTDB 数据结构：
/// ```
/// rooms/$roomId/
///   meta/          {hostUid, chatEnabled, status, createdAt}
///   seats/         {0: {uid,nick,online}, 1: {...}, 2: null}
///   game/          {phase, currentPlayer, landlordSeat, lastAction, handCounts, multiplier, ...}
///   hands/0/       [cardIndex, ...]   ← 按座位存手牌
///   hands/1/
///   hands/2/
///   pendingAction/ {bySeat, type, ...}
///   chat/$pushId/  {bySeat, nick, text, ts}
/// ```
class NetProtocol {
  static const roomsPath = 'rooms';

  static String roomPath(String roomId) => '$roomsPath/$roomId';
  static String metaPath(String roomId) => '$roomsPath/$roomId/meta';
  static String seatsPath(String roomId) => '$roomsPath/$roomId/seats';
  static String gamePath(String roomId) => '$roomsPath/$roomId/game';
  static String handsPath(String roomId) => '$roomsPath/$roomId/hands';
  static String handPath(String roomId, int seat) =>
      '$roomsPath/$roomId/hands/$seat';
  static String pendingPath(String roomId) =>
      '$roomsPath/$roomId/pendingAction';
  static String chatPath(String roomId) => '$roomsPath/$roomId/chat';
  static String readyPath(String roomId) => '$roomsPath/$roomId/ready';

  /// 生成 4 位房间码（大写字母+数字，排除易混淆字符）。
  static String generateRoomCode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final now = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var seed = now;
    for (var i = 0; i < 4; i++) {
      seed = (1103515245 * seed + 12345) & 0x7fffffff;
      buf.write(chars[seed % chars.length]);
    }
    return buf.toString();
  }
}

/// 房间元信息。
class RoomMeta {
  final String hostUid;
  final bool chatEnabled;
  final String status; // waiting | playing | settled
  final int createdAt;

  const RoomMeta({
    required this.hostUid,
    required this.chatEnabled,
    required this.status,
    required this.createdAt,
  });

  factory RoomMeta.fromMap(Map<dynamic, dynamic> m) => RoomMeta(
    hostUid: m['hostUid'] as String,
    chatEnabled: m['chatEnabled'] as bool? ?? false,
    status: m['status'] as String? ?? 'waiting',
    createdAt: m['createdAt'] as int? ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'hostUid': hostUid,
    'chatEnabled': chatEnabled,
    'status': status,
    'createdAt': createdAt,
  };
}

/// 座位信息。
class SeatInfo {
  final String uid;
  final String nick;
  final bool online;
  final bool isAI;

  const SeatInfo({
    required this.uid,
    required this.nick,
    required this.online,
    this.isAI = false,
  });

  factory SeatInfo.fromMap(Map<dynamic, dynamic> m) => SeatInfo(
    uid: m['uid'] as String,
    nick: m['nick'] as String,
    online: m['online'] as bool? ?? false,
    isAI: m['isAI'] as bool? ?? false,
  );

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'nick': nick,
    'online': online,
    if (isAI) 'isAI': true,
  };
}

/// 聊天消息。
class ChatMessage {
  final int bySeat;
  final String nick;
  final String text;
  final int ts;

  const ChatMessage({
    required this.bySeat,
    required this.nick,
    required this.text,
    required this.ts,
  });

  factory ChatMessage.fromMap(Map<dynamic, dynamic> m) => ChatMessage(
    bySeat: m['bySeat'] as int,
    nick: m['nick'] as String,
    text: m['text'] as String,
    ts: m['ts'] as int,
  );

  Map<String, dynamic> toMap() => {
    'bySeat': bySeat,
    'nick': nick,
    'text': text,
    'ts': ts,
  };
}

/// 房间状态快照（等待室 UI 用）。
class RoomSnapshot {
  final String roomId;
  final RoomMeta meta;
  final List<SeatInfo?> seats;
  final String? myUid;
  final int? mySeat;
  final bool isHost;

  const RoomSnapshot({
    required this.roomId,
    required this.meta,
    required this.seats,
    required this.myUid,
    required this.mySeat,
    required this.isHost,
  });

  int get playerCount => seats.where((s) => s != null).length;
  bool get isFull => playerCount >= 3;

  /// AI 座位号集合。
  Set<int> get aiSeats => {
    for (var s = 0; s < seats.length; s++)
      if (seats[s]?.isAI ?? false) s,
  };

  /// 真实（人类）在线玩家数。
  int get humanPlayerCount => seats.where((s) => s != null && !s.isAI).length;
}
