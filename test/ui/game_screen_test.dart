import 'package:flutter/material.dart' hide Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landlord/core/card.dart';
import 'package:landlord/core/deck.dart';
import 'package:landlord/core/game_action.dart';
import 'package:landlord/core/game_engine.dart';
import 'package:landlord/core/game_phase.dart';
import 'package:landlord/core/game_state.dart';
import 'package:landlord/state/game_session.dart';
import 'package:landlord/ui/game/game_screen.dart';
import 'package:landlord/ui/game/widgets/card_widget.dart';

class _RecordingSession extends SessionNotifier {
  _RecordingSession(this.initial);
  final GameState initial;
  final bids = <int>[];
  final plays = <List<Card>>[];
  var passes = 0;

  @override
  GameState build() => initial;
  @override
  void bid(int score) => bids.add(score);
  @override
  void play(List<Card> cards) => plays.add(cards);
  @override
  void pass() => passes++;
  @override
  void newGame() {}
  @override
  void bright() {}
}

GameState _dealt(int seed) {
  const e = GameEngine();
  final d = Deck.deal(seed);
  return e.apply(GameState.initial(), DealAction(d.hands, d.bottom, seed));
}

Future<_RecordingSession> _pump(WidgetTester tester, GameState s) async {
  tester.view.physicalSize = const Size(844, 390);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _RecordingSession(s);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [gameSessionProvider.overrideWith(() => session)],
      child: const MaterialApp(home: GameScreen()),
    ),
  );
  await tester.pump(const Duration(seconds: 2));
  return session;
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  testWidgets('轮到本家叫分时显示叫分按钮并回调', (tester) async {
    // seed 0 → 首叫座位 0（人类）
    final s = _dealt(0);
    expect(s.phase, GamePhase.bidding);
    expect(s.currentPlayer, 0);
    final session = await _pump(tester, s);

    expect(find.text('不叫'), findsOneWidget);
    await tester.tap(find.text('3分'));
    await tester.pump();
    expect(session.bids, [3]);
    await _dispose(tester);
  });

  testWidgets('地主首出：提示选牌后可出牌，对手只显示叠放牌背', (tester) async {
    const e = GameEngine();
    final s = e.apply(_dealt(0), const BidAction(0, 3));
    expect(s.phase, GamePhase.playing);
    final session = await _pump(tester, s);

    // 手牌 20 张正面 + 底牌 3 张正面；对手每家最多 3 张牌背
    final faceUp = tester
        .widgetList<CardWidget>(find.byType(CardWidget))
        .where((w) => !w.faceDown)
        .length;
    expect(faceUp, 23);
    expect(find.text('17'), findsNWidgets(2));
    // 首出不能「不出」
    expect(find.text('不出'), findsNothing);

    await tester.tap(find.text('提示'));
    await tester.pump();
    await tester.tap(find.text('出牌'));
    await tester.pump();
    expect(session.plays, hasLength(1));
    expect(session.plays.single, isNotEmpty);
    await _dispose(tester);
  });

  testWidgets('点击手牌切换选中', (tester) async {
    const e = GameEngine();
    final s = e.apply(_dealt(0), const BidAction(0, 3));
    await _pump(tester, s);

    bool anySelected() => tester
        .widgetList<CardWidget>(find.byType(CardWidget))
        .any((w) => w.selected);
    expect(anySelected(), isFalse);
    // 点击手牌区域最右侧那张牌
    final handRight = tester.getBottomRight(find.byType(GameScreen));
    await tester.tapAt(Offset(handRight.dx / 2, handRight.dy - 30));
    await tester.pump(const Duration(milliseconds: 300));
    expect(anySelected(), isTrue);
    await _dispose(tester);
  });
}
