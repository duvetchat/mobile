import 'package:flutter/material.dart';

import '../theme.dart';

/// Inner shadows inside [borderRadius], over [child]: `shadow-well` (a field's
/// resting recess) and `shadow-pressed` (a control pushed into the screen).
/// Flutter's [BoxShadow] only falls outward, so these are painted.
class InsetShadow extends StatelessWidget {
  final List<BoxShadow> shadows;
  final BorderRadius borderRadius;
  final Widget? child;

  const InsetShadow({required this.shadows, required this.borderRadius, this.child, super.key});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(foregroundPainter: _InsetPainter(shadows, borderRadius), child: child);
}

class _InsetPainter extends CustomPainter {
  final List<BoxShadow> shadows;
  final BorderRadius radius;
  _InsetPainter(this.shadows, this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    if (shadows.isEmpty) return;
    final shape = radius.toRRect(Offset.zero & size);
    canvas.save();
    canvas.clipRRect(shape);
    for (final s in shadows) {
      // A frame around the shape, offset and blurred, seen through it.
      final spread = s.blurRadius * 2 + s.offset.distance + 4;
      final frame = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(spread))
        ..addRRect(shape.shift(s.offset));
      canvas.drawPath(
        frame,
        Paint()
          ..color = s.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(s.blurRadius)),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetPainter old) => old.shadows != shadows || old.radius != radius;
}

/// Duvet's one press language: on touch-down the child scales to [scale]
/// (0.97, cards 0.98) in 120ms, and releases in 150ms. [builder] gets whether
/// it's pressed, to trade its outer shadow for `shadow-pressed`.
///
/// It's only the gesture: the caller gives it semantics.
class Pressable extends StatefulWidget {
  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final double scale;

  const Pressable({
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.scale = 0.97,
    super.key,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed && mounted) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onTap != null || widget.onLongPress != null || widget.onDoubleTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _press(true) : null,
      onTapUp: enabled ? (_) => _press(false) : null,
      onTapCancel: enabled ? () => _press(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onLongPressEnd: widget.onLongPress == null ? null : (_) => _press(false),
      onDoubleTap: widget.onDoubleTap,
      child: AnimatedScale(
        scale: _pressed && !reduce ? widget.scale : 1,
        duration: _pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
        curve: Curves.easeOutCubic,
        child: widget.builder(context, _pressed),
      ),
    );
  }
}
