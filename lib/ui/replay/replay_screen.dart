import 'dart:async';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/card.dart';
import '../../core/game_phase.dart';
import '../../core/game_state.dart';
import '../../core/hand_detector.dart';
import '../../core/hand_type.dart'; // 引入 label 扩展
import '../game/widgets/card_widget.dart';

/// 复盘页面：将一局完整动作序列逐帧重演。
///
/// 每帧渲染：
/// - 三方剩余手牌（正面）
/// - 上家最近一手出牌（高亮当前步刚出的牌）
/// - 步骤信息条（第 N 步 / M · 类型 · 操作者）
/// 控件：⏮⏪▶⏸⏩⏭ + 拖动进度条 + 速度切换。
class ReplayScreen extends ConsumerStatefulWidget {
  const ReplayScreen({
    super.key,
    required this.replayLog,
    required this.finalState,
  });

  /// 全部动作步骤（按时间正序，含发牌）。
  final List<ReplayStep> replayLog;

  /// 最终结算状态（最后一步应用完后的状态）。
  final GameState finalState;

  @override
  ConsumerState<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends ConsumerState<ReplayScreen> {
  /// 当前指针：表示「即将应用第 [cursor] 步」。
  /// 渲染的状态 = 第 [cursor] 步的 snapshotBefore（即应用第 cursor 步之前的）。
  /// cursor == 0 → 显示发牌前；cursor == length → 显示最终。
  int _cursor = 0;
  Timer? _timer;
  double _speed = 1.0; // 1x / 2x / 4x

  static final _stepDurations = {
    1.0: const Duration(milliseconds: 1200),
    2.0: const Duration(milliseconds: 600),
    4.0: const Duration(milliseconds: 300),
  };

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 当前应渲染的状态。
  GameState get _currentSnapshot {
    if (_cursor >= widget.replayLog.length) return widget.finalState;
    return widget.replayLog[_cursor].snapshotBefore;
  }

  /// 上一步刚做出的动作（用于中央出牌区高亮）。
  ReplayStep? get _lastAction {
    if (_cursor == 0) return null;
    return widget.replayLog[_cursor - 1];
  }

  bool get _isPlaying => _timer?.isActive ?? false;

  void _play() {
    if (_cursor >= widget.replayLog.length) {
      _cursor = 0;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_stepDurations[_speed]!, (_) {
      if (_cursor >= widget.replayLog.length) {
        _timer?.cancel();
        setState(() {});
        return;
      }
      setState(() => _cursor++);
    });
    setState(() {});
  }

  void _pause() {
    _timer?.cancel();
    setState(() {});
  }

  void _stepBack() {
    _pause();
    if (_cursor > 0) setState(() => _cursor--);
  }

  void _stepForward() {
    _pause();
    if (_cursor < widget.replayLog.length) setState(() => _cursor++);
  }

  void _jumpToStart() {
    _pause();
    setState(() => _cursor = 0);
  }

  void _jumpToEnd() {
    _pause();
    setState(() => _cursor = widget.replayLog.length);
  }

  void _cycleSpeed() {
    const order = [1.0, 2.0, 4.0];
    final idx = order.indexOf(_speed);
    setState(() => _speed = order[(idx + 1) % order.length]);
    if (_isPlaying) {
      // 速度变了，重启 timer
      _timer?.cancel();
      _play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final maxH = constraints.maxHeight;

            // ---- 牌尺寸计算 ----
            // 布局：悬浮标题(30px) + 顶部两家(32%) + 中部动作&控制(36%) + 底部一家(32%)
            // 控制条移入中部右侧，不再占底部空间
            final availH = maxH - 30;
            final topSectionH = availH * 0.32;
            final bottomSectionH = availH * 0.36;
            final centerSectionH = availH * 0.26;

            final cardWByWidthTop = (maxW * 0.42 / 3.28).clamp(22.0, 60.0);
            final cardHByHeightTop = (topSectionH - 26).clamp(28.0, 64.0);
            final cardWByHeightTop = cardHByHeightTop * 48 / 68;

            double cardWTop = cardWByWidthTop < cardWByHeightTop
                ? cardWByWidthTop
                : cardWByHeightTop;
            double cardHTop = cardWTop * 68 / 48;

            final cardHBottom = (bottomSectionH - 26).clamp(28.0, 64.0);
            final cardWBottom = cardHBottom * 48 / 64;

            final cardHCenter = (centerSectionH - 40).clamp(22.0, 52.0);
            final cardWCenter = cardHCenter * 48 / 68;

            return Stack(
              children: [
                Column(
                  children: [
                    const SizedBox(height: 30),
                    Expanded(
                      flex: 32,
                      child: _buildOpponentsRow(
                        cardW: cardWTop,
                        cardH: cardHTop,
                      ),
                    ),
                    Expanded(
                      flex: 36,
                      child: _buildCenterRow(
                        cardW: cardWCenter,
                        cardH: cardHCenter,
                      ),
                    ),
                    Expanded(
                      flex: 32,
                      child: _buildBottomPlayerRow(
                        cardW: cardWBottom,
                        cardH: cardHBottom,
                      ),
                    ),
                  ],
                ),
                // 悬浮关闭按钮
                Positioned(top: 4, right: 6, child: _buildCloseButton()),
                // 悬浮标题
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      '对局复盘',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.of(context).pop(),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.close, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  // ---------- 顶部三方信息 ----------

  Widget _buildOpponentsRow({required double cardW, required double cardH}) {
    final snap = _currentSnapshot;
    if (snap.players.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final landlord = snap.landlordSeat ?? -1;
    final down = (landlord + 1) % 3; // 座位 1 = 下家
    final up = (landlord + 2) % 3; // 座位 2 = 上家
    final seatDown = landlord < 0 ? 1 : down;
    final seatUp = landlord < 0 ? 2 : up;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _buildPlayerColumn(
              snap,
              seatDown,
              cardW: cardW,
              cardH: cardH,
            ),
          ),
          const SizedBox(width: 6),
          _buildCenterInfo(snap, cardW: cardW * 0.8, cardH: cardH * 0.8),
          const SizedBox(width: 6),
          Expanded(
            child: _buildPlayerColumn(snap, seatUp, cardW: cardW, cardH: cardH),
          ),
        ],
      ),
    );
  }

  /// 底部第三家手牌（顶部未展示的那家，通常是地主）。
  /// 全宽展示，牌可以更大。
  Widget _buildBottomPlayerRow({required double cardW, required double cardH}) {
    final snap = _currentSnapshot;
    if (snap.players.isEmpty) return const SizedBox.shrink();
    final landlord = snap.landlordSeat ?? -1;
    // 顶部展示的是 (landlord+1)%3 和 (landlord+2)%3，底部补 landlord
    final seatBottom = landlord < 0 ? 0 : landlord;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Center(
        child: _buildPlayerColumn(snap, seatBottom, cardW: cardW, cardH: cardH),
      ),
    );
  }

  Widget _buildPlayerColumn(
    GameState snap,
    int seat, {
    required double cardW,
    required double cardH,
  }) {
    final player = snap.players[seat];
    final isLandlord = player.role == PlayerRole.landlord;
    final isCurrent =
        snap.currentPlayer == seat &&
        (snap.phase == GamePhase.bidding || snap.phase == GamePhase.playing);
    final lastAction = _lastAction;
    final isHighlight =
        lastAction != null &&
        lastAction.seat == seat &&
        lastAction.cards.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isHighlight
            ? Colors.amber.withValues(alpha: 0.2)
            : Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCurrent
              ? Colors.amber
              : (isHighlight
                    ? Colors.amber.withValues(alpha: 0.6)
                    : Colors.transparent),
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: ClipRect(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isLandlord ? Icons.star : Icons.person,
                  size: 12,
                  color: isLandlord ? Colors.amber : Colors.white70,
                ),
                const SizedBox(width: 3),
                Text(
                  '座位 $seat',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
                const SizedBox(width: 4),
                Text(
                  '${player.handCount}张',
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 1),
            LayoutBuilder(
              builder: (context, c) {
                final h = (c.maxHeight.isFinite && c.maxHeight < cardH)
                    ? c.maxHeight
                    : cardH;
                return _buildMiniHand(
                  player.hand,
                  cardW: cardW,
                  cardH: h.clamp(18.0, cardH),
                  maxWidth: c.maxWidth,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniHand(
    List<Card> hand, {
    required double cardW,
    required double cardH,
    required double maxWidth,
  }) {
    final sorted = List.of(hand)
      ..sort((a, b) => b.rank.value.compareTo(a.rank.value));
    if (sorted.isEmpty) {
      return const Center(
        child: Text(
          '（已出完）',
          style: TextStyle(color: Colors.white54, fontSize: 10),
        ),
      );
    }
    final total = sorted.length;
    final avail = maxWidth.isFinite ? maxWidth : 200.0;
    double step;
    if (total <= 1) {
      step = 0;
    } else {
      final fit = (avail - cardW) / (total - 1);
      step = fit.clamp(cardW * 0.18, cardW); // 露出至少 18% 宽度
    }
    final stackWidth = (total - 1) * step + cardW;
    return SizedBox(
      width: stackWidth,
      height: cardH,
      child: Stack(
        children: [
          for (var i = 0; i < total; i++)
            Positioned(
              left: i * step,
              child: CardWidget(card: sorted[i], width: cardW, height: cardH),
            ),
        ],
      ),
    );
  }

  Widget _buildCenterInfo(
    GameState snap, {
    required double cardW,
    required double cardH,
  }) {
    final lastAction = _lastAction;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            snap.phase == GamePhase.bidding
                ? '叫地主\n${snap.currentMaxBid} 分'
                : snap.phase == GamePhase.settled
                ? '已结算'
                : '倍数 ×${snap.multiplier}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 3),
          // 底牌（叫地主前显示牌背；成交后公开）
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in snap.bottomCards)
                CardWidget(
                  card: c,
                  width: cardW * 0.8,
                  height: cardH * 0.8,
                  faceDown:
                      snap.phase == GamePhase.bidding ||
                      snap.phase == GamePhase.dealing ||
                      lastAction == null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 中部：动作展示 + 控制条（左右布局）----------

  Widget _buildCenterRow({required double cardW, required double cardH}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Expanded(
            child: _buildActionArea(cardW: cardW, cardH: cardH),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 180, child: _buildControlsCompact()),
        ],
      ),
    );
  }

  // ---------- 中部动作展示 ----------

  Widget _buildActionArea({required double cardW, required double cardH}) {
    final last = _lastAction;
    if (last == null) {
      return const Center(
        child: Text(
          '开局发牌…',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStepInfo(last),
          const SizedBox(height: 6),
          if (last.cards.isNotEmpty)
            LayoutBuilder(
              builder: (context, c) => _buildPlayedCards(
                last.cards,
                cardW: cardW,
                cardH: cardH,
                maxWidth: c.maxWidth,
              ),
            ),
          if (last.cards.isEmpty && last.kind == ReplayStepKind.pass)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '不出',
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ),
          if (last.cards.isEmpty && last.kind == ReplayStepKind.bid)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _currentSnapshot.currentMaxBid > 0 ? '不叫' : '叫地主中…',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepInfo(ReplayStep step) {
    final phaseLabel = switch (step.phase) {
      GamePhase.dealing => '发牌',
      GamePhase.bidding => '叫地主',
      GamePhase.playing => '出牌',
      GamePhase.settled => '结算',
    };
    final kindLabel = switch (step.kind) {
      ReplayStepKind.deal => '发牌',
      ReplayStepKind.bid => '叫分',
      ReplayStepKind.bidSettle => '成交（拿底牌）',
      ReplayStepKind.play => _describePlay(step.cards),
      ReplayStepKind.pass => '不出',
    };
    final seatLabel = step.seat < 0 ? '系统' : '座位 ${step.seat}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$phaseLabel · $seatLabel',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            kindLabel,
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _describePlay(List<Card> cards) {
    final p = HandDetector.detect(cards);
    if (p == null) return '出牌';
    return '${p.type.label}（${cards.length}张）';
  }

  Widget _buildPlayedCards(
    List<Card> cards, {
    required double cardW,
    required double cardH,
    required double maxWidth,
  }) {
    final sorted = List.of(cards)
      ..sort((a, b) => b.rank.value.compareTo(a.rank.value));
    final total = sorted.length;
    final avail = maxWidth.isFinite ? maxWidth : 400.0;
    double step;
    if (total <= 1) {
      step = 0;
    } else {
      final fit = (avail - cardW) / (total - 1);
      step = fit.clamp(cardW * 0.35, cardW);
    }
    final stackWidth = (total - 1) * step + cardW;
    return SizedBox(
      width: stackWidth,
      height: cardH,
      child: Stack(
        children: [
          for (var i = 0; i < total; i++)
            Positioned(
              left: i * step,
              child: CardWidget(card: sorted[i], width: cardW, height: cardH),
            ),
        ],
      ),
    );
  }

  // ---------- 控制条（置于中部右侧，紧凑竖排）----------

  Widget _buildControlsCompact() {
    final total = widget.replayLog.length;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$_cursor/$total',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 20,
            child: Slider(
              value: _cursor.toDouble().clamp(0, total.toDouble()),
              max: total.toDouble(),
              divisions: total > 0 ? total : 1,
              onChanged: (v) {
                _pause();
                setState(() => _cursor = v.round());
              },
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ctrlBtn(
                Icons.skip_previous,
                _jumpToStart,
                size: 22,
                iconSize: 14,
              ),
              const SizedBox(width: 4),
              _ctrlBtn(Icons.fast_rewind, _stepBack, size: 22, iconSize: 14),
              const SizedBox(width: 6),
              _ctrlBtn(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                _isPlaying ? _pause : _play,
                size: 28,
                iconSize: 18,
                primary: true,
              ),
              const SizedBox(width: 6),
              _ctrlBtn(
                Icons.fast_forward,
                _stepForward,
                size: 22,
                iconSize: 14,
              ),
              const SizedBox(width: 4),
              _ctrlBtn(Icons.skip_next, _jumpToEnd, size: 22, iconSize: 14),
            ],
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _cycleSpeed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${_speed.toStringAsFixed(_speed == 1 ? 1 : 0)}x',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ctrlBtn(
    IconData icon,
    VoidCallback onTap, {
    double size = 26,
    double iconSize = 16,
    bool primary = false,
  }) {
    return Material(
      color: primary ? Colors.amber : Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: iconSize,
            color: primary ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}
