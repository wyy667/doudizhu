import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/ai/ai_player.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';
import 'package:landlord/net/lan/lan_discovery.dart';
import 'package:landlord/net/lan/lan_room_client.dart';
import 'package:landlord/net/net_game_session.dart';
import 'package:landlord/net/room_client.dart';
import 'package:landlord/state/game_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _container(
  LanRoomClient client,
  int seat,
  bool host,
  Set<int> ai,
) {
  return ProviderContainer(
    overrides: [
      activeRoomClientProvider.overrideWith((ref) => client),
      netRoomContextProvider.overrideWithValue(
        NetRoomContext(
          roomId: client.roomId,
          mySeat: seat,
          myUid: client.uid,
          isHost: host,
          chatEnabled: true,
          aiSeats: ai,
        ),
      ),
      gameSessionProvider.overrideWith(() => NetGameSession()),
    ],
  );
}

/// 轮到自己时：叫分阶段（房主叫 3 分，其他人不叫）/ 出牌阶段出最小可出或不出。
void _drive(ProviderContainer c, {required bool host}) {
  final GameState s = c.read(gameSessionProvider);
  final n = c.read(gameSessionProvider.notifier);
  if (s.currentPlayer != 0 || s.players.length < 3) return;
  if (s.phase == GamePhase.bidding) {
    n.bid(host ? 3 : 0);
  } else if (s.phase == GamePhase.playing) {
    final me = s.players[0];
    final last = s.lastValidPlay;
    final lead = last == null || last.seat == 0;
    final beats = AiHandSearch.findBeats(me.hand, lead ? null : last.pattern);
    if (beats.isEmpty) {
      n.pass();
    } else {
      n.play(beats.first.cards);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // flutter_test 默认拦截 HttpClient（WebSocket 依赖它），本测试需要真实回环网络
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test(
    '房主 + 玩家 + 人机局域网对局；玩家掉线后由房主人机托管至终局',
    () async {
      final host = await LanRoomClient.host(
        uid: 'host-uid',
        nick: '房主',
        chatEnabled: true,
      );
      final guest = await LanRoomClient.connect(
        uid: 'guest-uid',
        nick: '玩家',
        address: '127.0.0.1',
        port: host.port,
      );
      expect(guest.roomId, host.roomId);
      final guestSeat = await guest.joinRoom(guest.roomId);
      expect(guestSeat, 1);

      // 非房主无权添加人机 / 改状态
      await expectLater(
        guest.addAiSeat(host.roomId, 2, 'x'),
        throwsA(anything),
      );
      await expectLater(
        guest.updateStatus(host.roomId, 'playing'),
        throwsA(anything),
      );

      await host.addAiSeat(host.roomId, 2, '人机1');
      await host.updateStatus(host.roomId, 'playing');

      final hc = _container(host, 0, true, {2});
      final gc = _container(guest, 1, false, {2});
      final hSub = hc.listen(
        gameSessionProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final gSub = gc.listen(
        gameSessionProvider,
        (_, _) {},
        fireImmediately: true,
      );

      // 玩家视角：只能拿到自己的手牌，看不到别人的
      final guestHand = await guest
          .watchMyHand(guest.roomId, 1)
          .firstWhere((h) => h.isNotEmpty)
          .timeout(const Duration(seconds: 10));
      expect(guestHand.length, 17);
      final otherHand = await guest
          .watchMyHand(guest.roomId, 0)
          .first
          .timeout(const Duration(seconds: 5));
      expect(otherHand, isEmpty, reason: '不应收到房主手牌');

      var guestPlays = 0;
      var guestDropped = false;
      var sawTakeover = false;
      final deadline = DateTime.now().add(const Duration(seconds: 150));
      while (DateTime.now().isBefore(deadline)) {
        final hs = hc.read(gameSessionProvider);
        if (hs.phase == GamePhase.settled) break;
        _drive(hc, host: true);
        if (!guestDropped) {
          final g0 = gc.read(gameSessionProvider);
          final before = g0.players.isEmpty ? 0 : g0.players[0].handCount;
          _drive(gc, host: false);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          final gs = gc.read(gameSessionProvider);
          if (gs.phase == GamePhase.playing &&
              gs.players.isNotEmpty &&
              before > 0 &&
              gs.players[0].handCount < before) {
            guestPlays++;
          }
          // 玩家出过牌后模拟掉线
          if (gs.phase == GamePhase.playing && guestPlays >= 1) {
            guestDropped = true;
            gSub.close();
            gc.dispose();
            await guest.dispose();
          }
        } else if (hs.autoPlaySeats.contains(1)) {
          // 房主显示座位 1 = 下家 = 实际座位 1（玩家）
          sawTakeover = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      final end = hc.read(gameSessionProvider);
      expect(guestDropped, isTrue);
      expect(sawTakeover, isTrue, reason: '玩家掉线后应立即由人机托管');
      expect(end.phase, GamePhase.settled, reason: '对局应由人机托管打完');
      expect(end.seatOnline[1], isFalse);

      hSub.close();
      hc.dispose();
      await host.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('聊天、掉线重连找回座位、房主解散时玩家收到通知', () async {
    final host = await LanRoomClient.host(
      uid: 'h2',
      nick: '房主',
      chatEnabled: true,
    );
    var guest = await LanRoomClient.connect(
      uid: 'g2',
      nick: '玩家',
      address: '127.0.0.1',
      port: host.port,
    );
    expect(await guest.joinRoom(guest.roomId), 1);

    final chatFuture = host
        .watchChat(host.roomId)
        .firstWhere((m) => m.text == '你好')
        .timeout(const Duration(seconds: 5));
    await guest.sendChat(guest.roomId, 1, '你好');
    expect((await chatFuture).nick, '玩家');

    // 掉线 → 房主看到离线
    await guest.dispose();
    final offline = await host
        .watchRoom(host.roomId)
        .firstWhere((s) => s.seats[1]?.online == false)
        .timeout(const Duration(seconds: 5));
    expect(offline.seats[1]?.uid, 'g2');

    // 同一 uid 重连 → 回到原座位
    guest = await LanRoomClient.connect(
      uid: 'g2',
      nick: '玩家',
      address: '127.0.0.1',
      port: host.port,
    );
    expect(await guest.joinRoom(guest.roomId), 1);
    final back = await host
        .watchRoom(host.roomId)
        .firstWhere((s) => s.seats[1]?.online == true)
        .timeout(const Duration(seconds: 5));
    expect(back.humanPlayerCount, 2);

    final closed = guest.onRoomClosed.first.timeout(const Duration(seconds: 5));
    await host.dispose();
    expect(await closed, contains('解散'));
    await guest.dispose();
  });

  test('多网卡时选择与本机同网段的房主地址', () {
    // 来源是代理 TUN 地址 → 改用房主声明的同网段地址
    expect(
      LanRoomInfo.pickAddress('198.18.0.1', ['192.168.1.3'], ['192.168.1.20']),
      '192.168.1.3',
    );
    // 来源本身就是房主声明的地址
    expect(
      LanRoomInfo.pickAddress('192.168.43.1', ['192.168.43.1'], []),
      '192.168.43.1',
    );
    // 旧版本未声明地址 → 使用来源地址
    expect(LanRoomInfo.pickAddress('10.0.0.5', [], ['10.0.0.9']), '10.0.0.5');
  });

  test('远端冒用房主 uid 会被拒绝', () async {
    final host = await LanRoomClient.host(
      uid: 'same',
      nick: '房主',
      chatEnabled: false,
    );
    await expectLater(
      LanRoomClient.connect(
        uid: 'same',
        nick: '冒充者',
        address: '127.0.0.1',
        port: host.port,
      ),
      throwsA(predicate((e) => '$e'.contains('冲突'))),
    );
    await host.dispose();
  });
}
