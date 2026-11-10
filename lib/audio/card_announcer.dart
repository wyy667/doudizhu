import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/card.dart';
import '../core/hand_detector.dart';
import '../core/hand_type.dart';
import '../state/settings.dart';

/// 出牌报牌：调用系统 TTS 播报牌型（「对三」「顺子」「王炸」「不要」…）。
///
/// 三个座位用不同音调区分；新播报会打断上一条，保证与牌面同步。
class CardAnnouncer {
  CardAnnouncer() {
    _init = _setup();
  }

  final FlutterTts _tts = FlutterTts();
  late final Future<void> _init;
  final Random _rand = Random();
  bool _enabled = true;
  bool _ready = false;

  void setEnabled(bool v) {
    _enabled = v;
    if (!v) _safe(_tts.stop);
  }

  Future<void> _setup() async {
    try {
      await _tts.awaitSpeakCompletion(false);
      final langs = await _tts.getLanguages;
      final list = langs is List ? langs.map((e) => '$e').toList() : <String>[];
      const preferred = ['zh-CN', 'zh_CN', 'cmn-Hans-CN', 'zh-Hans-CN', 'zh'];
      final lang = preferred.firstWhere(
        (p) => list.any((l) => l.toLowerCase() == p.toLowerCase()),
        orElse: () => list.firstWhere(
          (l) => l.toLowerCase().startsWith('zh'),
          orElse: () => 'zh-CN',
        ),
      );
      await _tts.setLanguage(lang);
      await _tts.setSpeechRate(
        defaultTargetPlatform == TargetPlatform.android ? 0.55 : 0.6,
      );
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// 某座位出牌；[remaining] 为出牌后剩余张数，1/2 张时追加报警。
  Future<void> announcePlay(int seat, List<Card> cards, {int? remaining}) {
    var text = playText(cards);
    if (remaining == 1 || remaining == 2) {
      text = '$text，我只剩${remaining == 1 ? '一' : '两'}张牌了';
    }
    return _speak(seat, text);
  }

  /// 某座位不出。
  Future<void> announcePass(int seat) {
    const options = ['不要', '要不起', '过'];
    return _speak(seat, options[_rand.nextInt(options.length)]);
  }

  /// 某座位叫分（0 = 不叫）。
  Future<void> announceBid(int seat, int score) =>
      _speak(seat, score <= 0 ? '不叫' : '$score分');

  Future<void> _speak(int seat, String text) async {
    if (!_enabled || text.isEmpty) return;
    await _init;
    if (!_ready) return;
    try {
      await _tts.stop();
      await _tts.setPitch(const [1.0, 1.25, 0.82][seat % 3]);
      await _tts.speak(text);
    } catch (_) {}
  }

  void _safe(Future<dynamic> Function() f) {
    f().catchError((_) => null);
  }

  void dispose() => _safe(_tts.stop);

  /// 牌型 → 播报文本。
  @visibleForTesting
  static String playText(List<Card> cards) {
    final pattern = HandDetector.detect(cards);
    if (pattern == null) return '';
    final rank = _mainRankOf(cards);
    final name = rank == null ? '' : rankSpeech(rank);
    return switch (pattern.type) {
      HandType.single => name,
      HandType.pair => '对$name',
      HandType.triple => '三个$name',
      HandType.tripleSingle => '三带一',
      HandType.triplePair => '三带一对',
      HandType.straight => '顺子',
      HandType.pairStraight => '连对',
      HandType.plane || HandType.planeSingle || HandType.planePair => '飞机',
      HandType.bombTwoSingle => '四带二',
      HandType.bombTwoPair => '四带两对',
      HandType.bomb => '炸弹',
      HandType.rocket => '王炸',
    };
  }

  /// 点数口语读法。
  static String rankSpeech(Rank r) => switch (r) {
    Rank.c3 => '三',
    Rank.c4 => '四',
    Rank.c5 => '五',
    Rank.c6 => '六',
    Rank.c7 => '七',
    Rank.c8 => '八',
    Rank.c9 => '九',
    Rank.c10 => '十',
    Rank.cJ => 'J',
    Rank.cQ => 'Q',
    Rank.cK => 'K',
    Rank.cA => 'A',
    Rank.c2 => '二',
    Rank.bj => '小王',
    Rank.rj => '大王',
  };

  /// 出现次数最多的点数（单/对/三张的主体）。
  static Rank? _mainRankOf(List<Card> cards) {
    if (cards.isEmpty) return null;
    final counts = <Rank, int>{};
    for (final c in cards) {
      counts[c.rank] = (counts[c.rank] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}

/// 报牌 Provider（单例，绑定音效开关）。
final cardAnnouncerProvider = Provider<CardAnnouncer>((ref) {
  final a = CardAnnouncer();
  a.setEnabled(ref.read(soundEnabledProvider));
  ref.listen(soundEnabledProvider, (_, v) => a.setEnabled(v));
  ref.onDispose(a.dispose);
  return a;
});
