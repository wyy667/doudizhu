import 'dart:math' as math;

import 'package:flutter/material.dart' hide Card;

import '../../../core/card.dart';

/// 扑克牌标准宽高比（宽 / 高）。
const double kCardAspect = 0.7;

/// 手牌渲染尺寸常量（旧接口保留；新牌桌按屏幕高度自适应计算尺寸）。
class CardSizes {
  const CardSizes._();
  static const double bigWidth = 52;
  static const double bigHeight = 74;
  static const double mediumWidth = 42;
  static const double mediumHeight = 60;
  static const double smallWidth = 34;
  static const double smallHeight = 48;

  /// 选中态上移量。
  static const double selectedLift = 10;
}

/// 单张扑克牌（纯绘制，无图片资源）。
///
/// - [selected]：选中态（上移 + 蓝色蒙层 + 金边）。
/// - [faceDown]：显示牌背。
/// - [dimmed]：灰化（联网 pending / 被压过的牌）。
/// - [highlight]：地主底牌等需要强调的金色描边。
/// - [width] / [height]：显式尺寸；缺省按 [small] 取常量尺寸。
/// - [liftOnSelect]：选中时是否上移（手牌区自行处理位移时可关闭）。
class CardWidget extends StatelessWidget {
  final Card card;
  final bool selected;
  final bool faceDown;
  final bool small;
  final bool dimmed;
  final bool highlight;
  final bool liftOnSelect;
  final double? width;
  final double? height;
  final VoidCallback? onTap;

  const CardWidget({
    super.key,
    required this.card,
    this.selected = false,
    this.faceDown = false,
    this.small = false,
    this.dimmed = false,
    this.highlight = false,
    this.liftOnSelect = true,
    this.width,
    this.height,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final w = width ?? (small ? CardSizes.smallWidth : CardSizes.bigWidth);
    final h = height ?? (small ? CardSizes.smallHeight : CardSizes.bigHeight);
    final radius = BorderRadius.circular(math.max(3.0, w * 0.09));
    final lift = liftOnSelect && selected ? h * 0.14 : 0.0;

    final Widget body = faceDown
        ? CardBack(width: w, height: h)
        : _CardFace(card: card, width: w, height: h, radius: radius);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        width: w,
        height: h,
        transform: Matrix4.translationValues(0, -lift, 0),
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: selected ? 0.45 : 0.32),
              blurRadius: selected ? 6 : 3,
              offset: Offset(-0.5, selected ? 3 : 1.5),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF3D7BFF).withValues(alpha: 0.22),
                  borderRadius: radius,
                  border: Border.all(
                    color: const Color(0xFFFFC94A),
                    width: 1.6,
                  ),
                ),
              ),
            if (highlight && !selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: const Color(0xFFFFC94A),
                    width: 1.4,
                  ),
                ),
              ),
            if (dimmed)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: radius,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.card,
    required this.width,
    required this.height,
    required this.radius,
  });

  final Card card;
  final double width;
  final double height;
  final BorderRadius radius;

  static const _red = Color(0xFFD0212B);
  static const _black = Color(0xFF1E1E24);

  bool get _isRed => switch (card.suit) {
    Suit.heart || Suit.diamond || Suit.jokerBig => true,
    _ => false,
  };

  String get _suitGlyph => switch (card.suit) {
    Suit.spade => '♠',
    Suit.heart => '♥',
    Suit.diamond => '♦',
    Suit.club => '♣',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final w = width;
    final h = height;
    final color = _isRed ? _red : _black;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFF3EFE6)],
        ),
        border: Border.all(color: const Color(0xFFB9B2A3), width: 0.8),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: card.rank.isJoker
            ? _buildJoker(w, h, color)
            : _buildNormal(w, h, color),
      ),
    );
  }

  Widget _buildNormal(double w, double h, Color color) {
    final label = card.rank.label;
    final isTen = label.length > 1;
    final rankSize = w * (isTen ? 0.36 : 0.40);
    final suitSize = w * 0.27;
    final bigSuit = w * 0.56;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: w * 0.06,
          top: h * 0.035,
          width: w * 0.30,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontSize: rankSize,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  letterSpacing: isTen ? -rankSize * 0.12 : 0,
                  color: color,
                ),
              ),
              Text(
                _suitGlyph,
                style: TextStyle(fontSize: suitSize, height: 1.0, color: color),
              ),
            ],
          ),
        ),
        Positioned(
          right: w * 0.07,
          bottom: h * 0.03,
          child: Text(
            _suitGlyph,
            style: TextStyle(fontSize: bigSuit, height: 1.0, color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildJoker(double w, double h, Color color) {
    final big = card.rank == Rank.rj;
    final letterSize = w * 0.20;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: w * 0.07,
          top: h * 0.04,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ch in const ['J', 'O', 'K', 'E', 'R'])
                Text(
                  ch,
                  style: TextStyle(
                    fontSize: letterSize,
                    fontWeight: FontWeight.w900,
                    height: 1.02,
                    color: color,
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: w * 0.06,
          bottom: h * 0.05,
          child: Icon(
            big ? Icons.auto_awesome : Icons.star_rounded,
            size: w * 0.52,
            color: big ? const Color(0xFFE53935) : const Color(0xFF424242),
          ),
        ),
      ],
    );
  }
}

/// 牌背：深红底 + 菱格暗纹 + 金色内框 + 中心徽记。
class CardBack extends StatelessWidget {
  const CardBack({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(math.max(3.0, width * 0.09));
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: Colors.white,
        border: Border.all(color: const Color(0xFFB9B2A3), width: 0.8),
      ),
      padding: EdgeInsets.all(math.max(1.5, width * 0.05)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(math.max(2.0, width * 0.06)),
        child: CustomPaint(
          painter: _BackPainter(),
          child: Center(
            child: Container(
              width: width * 0.48,
              height: width * 0.48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7A0F1A),
                border: Border.all(
                  color: const Color(0xFFE9C46A),
                  width: math.max(0.8, width * 0.025),
                ),
              ),
              child: Text(
                '斗',
                style: TextStyle(
                  color: const Color(0xFFE9C46A),
                  fontSize: width * 0.26,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB3202F), Color(0xFF7E0F1C)],
        ).createShader(rect),
    );
    final line = Paint()
      ..color = const Color(0x33FFD58A)
      ..strokeWidth = 0.8;
    final step = math.max(4.0, size.width / 6);
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), line);
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    final inset = size.width * 0.08;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(inset),
        Radius.circular(size.width * 0.05),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xAAE9C46A)
        ..strokeWidth = math.max(0.6, size.width * 0.02),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
