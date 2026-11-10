import 'dart:math' as math;

import 'package:flutter/material.dart' hide Card;

import '../../../core/card.dart';
import 'card_widget.dart';

/// 牌桌配色。
class TableColors {
  const TableColors._();
  static const feltCenter = Color(0xFF2E8B57);
  static const feltMid = Color(0xFF1C6B43);
  static const feltEdge = Color(0xFF0C3B25);
  static const gold = Color(0xFFFFC94A);
  static const goldDeep = Color(0xFFE09B1A);
  static const panel = Color(0xB3081F14);
  static const panelBorder = Color(0x33FFFFFF);
  static const landlord = Color(0xFFFFB300);
  static const farmer = Color(0xFF4FC3F7);
  static const danger = Color(0xFFFF5252);
}

/// 牌桌背景：绒布径向渐变 + 桌沿暗角 + 中央椭圆桌线。
class TableFelt extends StatelessWidget {
  const TableFelt({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.1),
          radius: 1.05,
          colors: [
            TableColors.feltCenter,
            TableColors.feltMid,
            TableColors.feltEdge,
          ],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: CustomPaint(painter: _FeltPainter(), child: child),
    );
  }
}

class _FeltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.46),
      width: size.width * 0.70,
      height: size.height * 0.62,
    );
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.07),
    );
    canvas.drawOval(
      oval.deflate(6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = Colors.white.withValues(alpha: 0.04),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 牌桌按钮风格。
enum TableButtonStyle { primary, secondary, danger, accent }

/// 牌桌立体按钮：渐变填充 + 底部投影 + 按压回弹。
class TableButton extends StatefulWidget {
  const TableButton({
    super.key,
    required this.label,
    this.onTap,
    this.style = TableButtonStyle.secondary,
    this.enabled = true,
    this.icon,
    this.minWidth = 76,
    this.height = 36,
  });

  final String label;
  final VoidCallback? onTap;
  final TableButtonStyle style;
  final bool enabled;
  final IconData? icon;
  final double minWidth;
  final double height;

  @override
  State<TableButton> createState() => _TableButtonState();
}

class _TableButtonState extends State<TableButton> {
  bool _pressed = false;

  (List<Color>, Color, Color) get _palette => switch (widget.style) {
    TableButtonStyle.primary => (
      const [Color(0xFFFFD86B), Color(0xFFF2A516)],
      const Color(0xFFB36B00),
      const Color(0xFF5A2E00),
    ),
    TableButtonStyle.accent => (
      const [Color(0xFF7FD4FF), Color(0xFF2E8FE0)],
      const Color(0xFF1A5C9A),
      Colors.white,
    ),
    TableButtonStyle.danger => (
      const [Color(0xFFFF8A80), Color(0xFFE53935)],
      const Color(0xFF8E1C1C),
      Colors.white,
    ),
    TableButtonStyle.secondary => (
      const [Color(0xFFF7F7F2), Color(0xFFD5D9D2)],
      const Color(0xFF8A928A),
      const Color(0xFF26352B),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (grad, shadow, fg) = _palette;
    final enabled = widget.enabled && widget.onTap != null;
    final depth = _pressed ? 1.0 : 3.0;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTapUp: enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap?.call();
              }
            : null,
        // IntrinsicWidth：按内容收缩，避免在有界宽度的父级中被拉伸成整行
        child: IntrinsicWidth(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            constraints: BoxConstraints(minWidth: widget.minWidth),
            height: widget.height,
            margin: EdgeInsets.only(top: 3 - depth),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.height / 2),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: grad,
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(color: shadow, offset: Offset(0, depth)),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: Offset(0, depth + 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: widget.height * 0.45, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: widget.height * 0.40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 长期积分徽章（金币图标 + 数值，负分显示红色）。
class BankrollChip extends StatelessWidget {
  const BankrollChip({super.key, required this.value, this.large = false});
  final int value;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fs = large ? 16.0 : 12.0;
    final color = value < 0 ? TableColors.danger : TableColors.gold;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 10 : 8,
        vertical: large ? 4 : 3,
      ),
      decoration: BoxDecoration(
        color: TableColors.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monetization_on, size: fs + 2, color: color),
          const SizedBox(width: 4),
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: fs,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆形图标按钮（顶栏用）。
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.color = Colors.white70,
    this.size = 30,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(
        side: BorderSide(color: TableColors.panelBorder),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.55, color: color),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 出牌展示排序：按「同点数张数多 → 点数大」排列，飞机/三带等主体在前，带牌在后。
List<Card> sortForDisplay(List<Card> cards) {
  final counts = <Rank, int>{};
  for (final c in cards) {
    counts[c.rank] = (counts[c.rank] ?? 0) + 1;
  }
  return List<Card>.from(cards)..sort((a, b) {
    final byCount = counts[b.rank]!.compareTo(counts[a.rank]!);
    if (byCount != 0) return byCount;
    final byRank = b.rank.value.compareTo(a.rank.value);
    if (byRank != 0) return byRank;
    return a.suit.index.compareTo(b.suit.index);
  });
}

/// 重叠排布的一组牌（出牌区 / 底牌 / 透视手牌）。
///
/// 在 [maxWidth] 内自适应：间距最大为牌宽 × [maxStepRatio]，放不下时自动收紧。
class CardFan extends StatelessWidget {
  const CardFan({
    super.key,
    required this.cards,
    required this.cardHeight,
    required this.maxWidth,
    this.maxStepRatio = 0.42,
    this.dimmed = false,
    this.faceDown = false,
  });

  final List<Card> cards;
  final double cardHeight;
  final double maxWidth;
  final double maxStepRatio;
  final bool dimmed;
  final bool faceDown;

  static double widthFor(
    int n,
    double cardHeight,
    double maxWidth, {
    double maxStepRatio = 0.42,
  }) {
    if (n <= 0) return 0;
    final w = cardHeight * kCardAspect;
    if (n == 1) return w;
    final step = math.min(w * maxStepRatio, (maxWidth - w) / (n - 1));
    return w + step * (n - 1);
  }

  @override
  Widget build(BuildContext context) {
    final n = cards.length;
    if (n == 0) return const SizedBox.shrink();
    final w = cardHeight * kCardAspect;
    final step = n == 1
        ? 0.0
        : math.max(2.0, math.min(w * maxStepRatio, (maxWidth - w) / (n - 1)));
    return SizedBox(
      width: w + step * (n - 1),
      height: cardHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < n; i++)
            Positioned(
              left: i * step,
              top: 0,
              child: CardWidget(
                card: cards[i],
                width: w,
                height: cardHeight,
                dimmed: dimmed,
                faceDown: faceDown,
              ),
            ),
        ],
      ),
    );
  }
}

/// 对手手牌：叠放的牌背 + 剩余张数（不再逐张平铺）。
/// 剩余 ≤2 张时红色报警脉冲。
class CardBackStack extends StatelessWidget {
  const CardBackStack({
    super.key,
    required this.count,
    required this.cardHeight,
    this.alarm = false,
  });

  final int count;
  final double cardHeight;
  final bool alarm;

  @override
  Widget build(BuildContext context) {
    final w = cardHeight * kCardAspect;
    final layers = count == 0 ? 0 : math.min(3, count);
    final offset = w * 0.09;
    final totalW = w + offset * math.max(0, layers - 1);
    return SizedBox(
      width: totalW,
      height: cardHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (count == 0)
            Container(
              width: w,
              height: cardHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(w * 0.09),
                border: Border.all(color: Colors.white24, width: 1),
              ),
            ),
          for (var i = 0; i < layers; i++)
            Positioned(
              left: i * offset,
              top: 0,
              child: CardBack(width: w, height: cardHeight),
            ),
          Positioned.fill(
            child: Center(
              child: _CountBadge(
                count: count,
                alarm: alarm,
                size: math.max(20.0, w * 0.62),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.alarm,
    required this.size,
  });

  final int count;
  final bool alarm;
  final double size;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: alarm
            ? TableColors.danger
            : Colors.black.withValues(alpha: 0.72),
        border: Border.all(
          color: alarm ? Colors.white : TableColors.gold,
          width: 1.4,
        ),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: alarm ? Colors.white : TableColors.gold,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
    );
    if (!alarm) return badge;
    return _Pulse(child: badge);
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(
        begin: 0.9,
        end: 1.12,
      ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

/// 玩家头像：圆形渐变 + 身份角标 + 当前回合光环。
class SeatAvatar extends StatefulWidget {
  const SeatAvatar({
    super.key,
    required this.label,
    required this.size,
    this.isLandlord = false,
    this.isFarmer = false,
    this.active = false,
    this.offline = false,
    this.autoPlay = false,
  });

  final String label;
  final double size;
  final bool isLandlord;
  final bool isFarmer;
  final bool active;
  final bool offline;
  final bool autoPlay;

  @override
  State<SeatAvatar> createState() => _SeatAvatarState();
}

class _SeatAvatarState extends State<SeatAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _ring.repeat();
  }

  @override
  void didUpdateWidget(covariant SeatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_ring.isAnimating) {
      _ring.repeat();
    } else if (!widget.active && _ring.isAnimating) {
      _ring.stop();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final colors = widget.isLandlord
        ? const [Color(0xFFFFE082), Color(0xFFE65100)]
        : widget.isFarmer
        ? const [Color(0xFFB3E5FC), Color(0xFF0277BD)]
        : const [Color(0xFFCFD8DC), Color(0xFF455A64)];

    final avatar = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: widget.isLandlord
          ? Icon(Icons.workspace_premium, color: Colors.white, size: s * 0.58)
          : Text(
              widget.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: s * 0.40,
                fontWeight: FontWeight.w900,
                shadows: const [Shadow(color: Colors.black38, blurRadius: 3)],
              ),
            ),
    );

    return SizedBox(
      width: s + 8,
      height: s + 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _ring,
              builder: (context, _) => CustomPaint(
                size: Size(s + 8, s + 8),
                painter: _RingPainter(_ring.value),
              ),
            ),
          Opacity(opacity: widget.offline ? 0.45 : 1, child: avatar),
          if (widget.isLandlord || widget.isFarmer)
            Positioned(
              bottom: -4,
              child: _RoleTag(landlord: widget.isLandlord, height: s * 0.32),
            ),
          if (widget.autoPlay || widget.offline)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Colors.black87,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.offline ? Icons.cloud_off : Icons.smart_toy,
                  size: s * 0.28,
                  color: widget.offline ? Colors.orange : Colors.cyanAccent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..shader = SweepGradient(
        transform: GradientRotation(t * 2 * math.pi),
        colors: const [
          Color(0x00FFC94A),
          TableColors.gold,
          Color(0xFFFFF3C4),
          Color(0x00FFC94A),
        ],
        stops: const [0.0, 0.55, 0.75, 1.0],
      ).createShader(rect);
    canvas.drawCircle(rect.center, size.width / 2 - 1.5, paint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => oldDelegate.t != t;
}

class _RoleTag extends StatelessWidget {
  const _RoleTag({required this.landlord, required this.height});
  final bool landlord;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: math.max(14, height),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: landlord
              ? const [Color(0xFFFFD54F), Color(0xFFFF8F00)]
              : const [Color(0xFF81D4FA), Color(0xFF0288D1)],
        ),
        border: Border.all(color: Colors.white, width: 1),
      ),
      child: Text(
        landlord ? '地主' : '农民',
        style: TextStyle(
          color: Colors.white,
          fontSize: math.max(9, height * 0.62),
          fontWeight: FontWeight.w900,
          height: 1.0,
          shadows: const [Shadow(color: Colors.black38, blurRadius: 2)],
        ),
      ),
    );
  }
}

/// 状态气泡：「不出」「叫2分」「不叫」等。
class SpeechBubble extends StatelessWidget {
  const SpeechBubble({
    super.key,
    required this.text,
    this.color = Colors.white,
    this.fontSize = 16,
  });

  final String text;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: fontSize * 0.9,
        vertical: fontSize * 0.35,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(fontSize),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.2),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

/// 「思考中」三点动画。
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.color = Colors.white70, this.size = 6});
  final Color color;
  final double size;

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: widget.size,
              height: widget.size,
              margin: EdgeInsets.symmetric(horizontal: widget.size * 0.3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(
                  alpha:
                      0.25 +
                      0.75 *
                          (0.5 +
                                  0.5 *
                                      math.sin(
                                        (_c.value - i * 0.18) * 2 * math.pi,
                                      ))
                              .clamp(0.0, 1.0),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
