import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';

/// Inner shadows inside [borderRadius], over [child]: `cushion` (a raised
/// surface, lit along its top edge),
/// `shadow-well` (a field's resting recess) and `shadow-pressed` (a control
/// pushed into the screen). Flutter's [BoxShadow] only falls outward, so
/// these are painted.
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
      final paint = Paint()..color = s.color;
      // A sharp edge (the cushion's lit top) has no blur to give.
      if (s.blurRadius > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(s.blurRadius));
      }
      canvas.drawPath(frame, paint);
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
      // With only a double tap (a text bubble's reply), its tap-down for the
      // press would read as a tap that does nothing, and keep a message's text
      // from joining the rest of it for screen readers.
      excludeFromSemantics: widget.onTap == null && widget.onLongPress == null,
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

/// A raised surface in Duvet's one material: a cushion in `card`, lit along
/// its top edge, resting on [shadows] (`shadow-rest` by default).
class Cushion extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final List<BoxShadow>? shadows;
  final Clip clipBehavior;

  /// The fill; the theme's card unless the cushion sits on something else,
  /// such as a sheet ([DuvetTokensContext.cushionOnSheet]).
  final Color? color;

  const Cushion({
    required this.child,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.radius = DuvetTokens.radiusCard,
    this.shadows,
    this.clipBehavior = Clip.none,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final shape = BorderRadius.circular(radius);
    return Container(
      width: width,
      height: height,
      margin: margin,
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: color ?? context.theme.colors.card,
        borderRadius: shape,
        boxShadow: shadows ?? tokens.shadowRest,
      ),
      child: InsetShadow(
        shadows: tokens.cushion,
        borderRadius: shape,
        child: padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );
  }
}
