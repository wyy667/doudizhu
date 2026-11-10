import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';

void main() {
  const engine = GameEngine();

  /// 用 seed=0 推到 playing 状态（座位 0 当地主）。
  GameState dealtState() => engine.apply(
    GameState.initial(),
    DealAction(Deck.deal(0).hands, Deck.deal(0).bottom, 0),
  );

  group('GameState.replayLog · 完整对局回放', () {
    test('DealAction 后日志第一步是 deal', () {
      final s = dealtState();
      expect(s.replayLog.length, 1);
      final step = s.replayLog.single;
      expect(step.kind, ReplayStepKind.deal);
      expect(step.seat, -1);
      expect(step.snapshotBefore.phase, GamePhase.dealing);
    });

    test('bid pass 也记入日志，kind=bid, cards=空', () {
      var s = dealtState();
      // currentPlayer 叫 0 分
      final startSeat = s.currentPlayer;
      s = engine.apply(s, BidAction(startSeat, 0));
      expect(s.replayLog.length, 2);
      final step = s.replayLog.last;
      expect(step.kind, ReplayStepKind.bid);
      expect(step.seat, startSeat);
      expect(step.cards, isEmpty);
      // snapshotBefore 是叫分前的状态
      expect(step.snapshotBefore.currentMaxBid, 0);
    });

    test('bid 3 立即成交 → kind=bidSettle, cards=底牌', () {
      var s = dealtState();
      final startSeat = s.currentPlayer;
      s = engine.apply(s, BidAction(startSeat, 3));
      expect(s.replayLog.length, 2);
      final step = s.replayLog.last;
      expect(step.kind, ReplayStepKind.bidSettle);
      expect(step.seat, startSeat);
      expect(step.cards.length, 3, reason: '底牌 3 张');
      // snapshotBefore 是成交前（bidding）的状态
      expect(step.snapshotBefore.phase, GamePhase.bidding);
    });

    test('PlayAction 记入日志，kind=play, cards=出的牌', () {
      var s = dealtState();
      s = engine.apply(s, BidAction(s.currentPlayer, 3));
      final card = s.players[s.landlordSeat!].hand.last;
      s = engine.apply(s, PlayAction(s.landlordSeat!, [card]));
      final last = s.replayLog.last;
      expect(last.kind, ReplayStepKind.play);
      expect(last.cards.length, 1);
      expect(last.cards.first, card);
      // snapshotBefore 应该是地主出牌前（手牌还包含这张）
      expect(last.snapshotBefore.players[s.landlordSeat!].hand, contains(card));
    });

    test('PassAction 记入日志，kind=pass, cards=空', () {
      var s = dealtState();
      s = engine.apply(s, BidAction(s.currentPlayer, 3));
      final card = s.players[s.landlordSeat!].hand.last;
      s = engine.apply(s, PlayAction(s.landlordSeat!, [card]));
      // 下家 pass
      final nextSeat = (s.landlordSeat! + 1) % 3;
      s = engine.apply(s, PassAction(nextSeat));
      final last = s.replayLog.last;
      expect(last.kind, ReplayStepKind.pass);
      expect(last.seat, nextSeat);
      expect(last.cards, isEmpty);
    });

    test('逐步重放：每步 snapshotBefore + 应用该步 = 下一步 snapshotBefore', () {
      // 完整跑一局（用 seed=0，让座位 0 当地主；之后 AI/手动出牌到结束）
      var s = dealtState();
      s = engine.apply(s, BidAction(s.currentPlayer, 3));
      // 简单循环：轮流出最小单牌（地主 → 下家 → 上家 → ...），不 pass
      // 直至有人赢
      var safety = 200;
      while (s.phase != GamePhase.settled && safety-- > 0) {
        final seat = s.currentPlayer;
        final player = s.players[seat];
        if (player.hand.isEmpty) {
          // 跳到下一家
          s = s.copyWith(currentPlayer: (seat + 1) % 3);
          continue;
        }
        final card = player.hand.last;
        try {
          s = engine.apply(s, PlayAction(seat, [card]));
        } catch (_) {
          // 管不上则 pass
          try {
            s = engine.apply(s, PassAction(seat));
          } catch (_) {
            // 自由出牌又 pass 失败：跳过
            s = s.copyWith(currentPlayer: (seat + 1) % 3);
          }
        }
      }
      expect(s.phase, GamePhase.settled);

      // 重放验证：每一步应用后 = 下一步的 snapshotBefore（或最终态）
      for (var i = 0; i < s.replayLog.length; i++) {
        final step = s.replayLog[i];
        final before = step.snapshotBefore;
        // 重新应用这一步
        final action = _reconstructAction(step, s);
        final after = engine.apply(before, action);
        final expectedAfter = i + 1 < s.replayLog.length
            ? s.replayLog[i + 1].snapshotBefore
            : s;
        // 关键字段对照
        expect(after.phase, expectedAfter.phase);
        expect(after.currentPlayer, expectedAfter.currentPlayer);
        expect(after.landlordSeat, expectedAfter.landlordSeat);
        expect(
          after.players.map((p) => p.hand.length).toList(),
          expectedAfter.players.map((p) => p.hand.length).toList(),
          reason: '第 $i 步重放后手牌数不符',
        );
      }
    });
  });
}

/// 根据 ReplayStep 重构对应的 GameAction。
GameAction _reconstructAction(ReplayStep step, GameState finalState) {
  switch (step.kind) {
    case ReplayStepKind.deal:
      // 发牌动作：用 snapshotBefore 之后的状态反推
      // snapshotBefore 是 dealing（空手），after 是 bidding（已发牌）
      // 重新构造一个 DealAction 需要原始 hands 和 seed——用 finalState.deckSeed
      // 因为 replayLog 首步总是 deal，其 snapshotBefore 是 initial()，
      // 应用任意有效 DealAction 都可以推到 after 的 phase。
      // 我们用 step.snapshotBefore 之后的真实状态（即 step 之后第一步 snapshotBefore）
      // 来反推 hands——这其实不可行；改成直接用 finalState 重建。
      final deal = Deck.deal(finalState.deckSeed);
      return DealAction(deal.hands, deal.bottom, finalState.deckSeed);
    case ReplayStepKind.bid:
      return BidAction(step.seat, 0); // pass（叫分值不影响 snapshotBefore 对照）
    case ReplayStepKind.bidSettle:
      // 成交的 BidAction 需要 score=3 或 currentMaxBid+1；这里用 3 兜底
      // 因为 before.currentMaxBid 可能 < 3，3 一定合法
      return BidAction(step.seat, 3);
    case ReplayStepKind.play:
      return PlayAction(step.seat, List<Card>.from(step.cards));
    case ReplayStepKind.pass:
      return PassAction(step.seat);
  }
}
