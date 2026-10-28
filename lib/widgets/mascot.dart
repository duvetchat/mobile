import 'package:flutter/material.dart';

import '../theme.dart';

/// Duvet's mascot, the pillow with a cat's ears, as the desktop app's icon
/// draws it. Awake where there's nothing yet; asleep where Duvet can't be
/// reached. It is decoration: screen readers skip it.
class Mascot extends StatelessWidget {
  final double size;
  final bool asleep;

  /// On the slate pill of something chosen, where its own slate would
  /// vanish at night: its body the shade of its ear tips.
  final bool onSlate;

  const Mascot({this.size = 96, this.asleep = false, this.onSlate = false, super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size * _aspect,
        child: CustomPaint(
          painter: _MascotPainter(asleep: asleep, glow: dark, onSlate: onSlate),
        ),
      ),
    );
  }
}

// The icon's drawing spans x 56–456 and y 82–456 of its 512 square.
const _left = 56.0;
const _top = 82.0;
const _width = 400.0;
const _height = 374.0;
const _aspect = _height / _width;

class _MascotPainter extends CustomPainter {
  final bool asleep;

  /// At night it sits in a faint periwinkle glow, as on duvet.chat.
  final bool glow;
  final bool onSlate;
  _MascotPainter({required this.asleep, required this.glow, required this.onSlate});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _width;
    if (glow) {
      final center = Offset(size.width / 2, size.height * 0.62);
      canvas.drawCircle(
        center,
        size.width * 0.62,
        Paint()
          ..shader = RadialGradient(
            colors: [Duvet.periwinkle.withValues(alpha: 0.16), Duvet.periwinkle.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: size.width * 0.62)),
      );
    }
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-_left, -_top);

    final body = Paint()..color = onSlate ? Duvet.slateDeep : Duvet.slate;
    final inner = Paint()..color = Duvet.ice.withValues(alpha: 0.35);
    final tip = Paint()..color = Duvet.slateDeep;
    final white = Paint()..color = const Color(0xFFFFFFFF);

    // The pillow: puffy, wider in the middle.
    canvas.drawPath(
      Path()
        ..moveTo(100, 240)
        ..quadraticBezierTo(82, 250, 78, 290)
        ..quadraticBezierTo(72, 340, 82, 390)
        ..quadraticBezierTo(90, 430, 120, 440)
        ..quadraticBezierTo(180, 455, 256, 455)
        ..quadraticBezierTo(332, 455, 392, 440)
        ..quadraticBezierTo(422, 430, 430, 390)
        ..quadraticBezierTo(440, 340, 434, 290)
        ..quadraticBezierTo(430, 250, 412, 240)
        ..quadraticBezierTo(370, 222, 256, 222)
        ..quadraticBezierTo(142, 222, 100, 240)
        ..close(),
      body,
    );

    // The ears, each with its ice lining and a darker tip.
    for (final mirror in [false, true]) {
      double x(double v) => mirror ? 512 - v : v;
      canvas.drawPath(_triangle(x(105), 240, x(60), 90, x(220), 224), body);
      canvas.drawPath(_triangle(x(125), 234, x(80), 115, x(200), 224), inner);
      canvas.drawPath(
        Path()
          ..moveTo(x(60), 90)
          ..quadraticBezierTo(x(75), 82, x(95), 105)
          ..lineTo(x(72), 112)
          ..close(),
        tip,
      );
    }

    final line = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (asleep) {
      // Eyes shut: two lids, lashes down.
      for (final cx in [200.0, 312.0]) {
        canvas.drawPath(
          Path()
            ..moveTo(cx - 22, 328)
            ..quadraticBezierTo(cx, 346, cx + 22, 328),
          line..strokeWidth = 7,
        );
      }
    } else {
      canvas.drawCircle(const Offset(200, 330), 25, white);
      canvas.drawCircle(const Offset(312, 330), 25, white);
      // The lashes.
      canvas.drawLine(const Offset(178, 312), const Offset(172, 304), line..strokeWidth = 2.5);
      canvas.drawLine(const Offset(184, 308), const Offset(180, 299), line..strokeWidth = 2);
      canvas.drawLine(const Offset(334, 312), const Offset(340, 304), line..strokeWidth = 2.5);
      canvas.drawLine(const Offset(328, 308), const Offset(332, 299), line..strokeWidth = 2);
      // The smile.
      canvas.drawPath(
        Path()
          ..moveTo(230, 390)
          ..quadraticBezierTo(256, 406, 282, 390),
        Paint()
          ..color = const Color(0x8CFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 4,
      );
    }
    canvas.restore();
  }

  static Path _triangle(double x1, double y1, double x2, double y2, double x3, double y3) => Path()
    ..moveTo(x1, y1)
    ..lineTo(x2, y2)
    ..lineTo(x3, y3)
    ..close();

  @override
  bool shouldRepaint(_MascotPainter old) => old.asleep != asleep || old.glow != glow || old.onSlate != onSlate;
}
