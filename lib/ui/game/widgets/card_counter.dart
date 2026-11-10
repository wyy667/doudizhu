import 'package:flutter/material.dart' hide Card;

import '../../../core/card.dart';
import '../../../core/game_state.dart';
import 'table_widgets.dart';

/// 记牌器：单行横条显示「对手手中」各点数剩余张数（总数 − 已出 − 自己手牌）。
/// 点击可折叠为按钮。
class CardCounter extends StatefulWidget {
  final GameState state;
  final int mySeat;
  final double cellWidth;
  const CardCounter({
    super.key,
    required this.state,
    this.mySeat = 0,
    this.cellWidth = 20,
  });

  /// 展开时的总宽度（用于顶栏排版）。
  static double expandedWidth(double cellWidth) => cellWidth * 15 + 12;

  @override
  State<CardCounter> createState() => _CardCounterState();
}

class _CardCounterState extends State<CardCounter> {
  bool _expanded = true;

  static const _ranks = [
    Rank.rj,
    Rank.bj,
    Rank.c2,
    Rank.cA,
    Rank.cK,
    Rank.cQ,
    Rank.cJ,
    Rank.c10,
    Rank.c9,
    Rank.c8,
    Rank.c7,
    Rank.c6,
    Rank.c5,
    Rank.c4,
    Rank.c3,
  ];

  String _label(Rank r) => switch (r) {
    Rank.bj => '小',
    Rank.rj => '大',
    _ => r.label,
  };

  Map<Rank, int> _remaining() {
    final m = <Rank, int>{for (final r in _ranks) r: r.isJoker ? 1 : 4};
    void sub(Iterable<Card> cards) {
      for (final c in cards) {
        m[c.rank] = (m[c.rank] ?? 0) - 1;
      }
    }

    sub(widget.state.playedCards);
    if (widget.mySeat < widget.state.players.length) {
      sub(widget.state.players[widget.mySeat].hand);
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.centerLeft,
      child: _expanded ? _buildExpanded() : _buildCollapsed(),
    );
  }

  Widget _buildCollapsed() {
    return GestureDetector(
      onTap: () => setState(() => _expanded = true),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: TableColors.panel,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: TableColors.panelBorder),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_rounded, size: 14, color: TableColors.gold),
            SizedBox(width: 4),
            Text(
              '记牌器',
              style: TextStyle(
                color: TableColors.gold,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded() {
    final remain = _remaining();
    final cw = widget.cellWidth;
    return GestureDetector(
      onTap: () => setState(() => _expanded = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: TableColors.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TableColors.panelBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (final r in _ranks) _cell(r, remain[r] ?? 0, cw)],
        ),
      ),
    );
  }

  Widget _cell(Rank rank, int n, double cw) {
    final out = n <= 0;
    final full = !rank.isJoker && n == 4;
    final countColor = out
        ? Colors.white24
        : full
        ? const Color(0xFFFF7043)
        : TableColors.gold;
    return SizedBox(
      width: cw,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _label(rank),
            style: TextStyle(
              color: out ? Colors.white30 : Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            height: 1,
            color: Colors.white12,
          ),
          Text(
            out ? '-' : '$n',
            style: TextStyle(
              color: countColor,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
