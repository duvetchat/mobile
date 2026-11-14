import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

// Prism: a mention of the user is a small cut gem, which throws its light on
// the bubble around it. The gem shines once as its message first comes into
// sight, then catches the light as the list scrolls. The numbers are the
// design's; its angles are degrees clockwise from 12 o'clock.

/// The light on a bubble whose centre is [t] of the way down its list (0 at the
/// top, 1 at the bottom): the gradients' angle, and how far the spill's side
/// lights have slid.
({double angle, double slide}) prismLight(double t) => (angle: -124 + (0.5 - t) * 220, slide: 1 - t);

/// How long the arrival is: its last track, the gradients' turn, ends then.
const prismArrival = Duration(milliseconds: 1580);

const _ease = Cubic(0.2, 0.9, 0.3, 1.0);

/// The arrival [ms] in: the turn the gradients still have to make (degrees),
/// where the glint is (in its band's widths) and how opaque, and how much of
/// the spill shows (0 to 1). At rest from [prismArrival] on.
({double offset, double glintAt, double glint, double spill}) prismArrivalAt(double ms) {
  double track(double delay, double length) => ((ms - delay) / length).clamp(0.0, 1.0);
  final glint = track(150, 900);
  return (
    offset: -200 * (1 - _ease.transform(track(80, 1500))),
    glintAt: -1.6 + 4.4 * _ease.transform(glint),
    glint: glint < 0.15 ? _ease.transform(glint / 0.15) : 1 - _ease.transform((glint - 0.15) / 0.85),
    spill: _ease.transform(track(250, 900)),
  );
}

/// The gem's light under its bubble, after the bubble's own shadows.
BoxShadow prismShadow(PrismPalette palette) => BoxShadow(
  color: palette.gem.withValues(alpha: 0.45),
  blurRadius: 26,
  spreadRadius: -14,
  offset: const Offset(0, 8),
);

/// Whether what's built here is in a [PrismBubble]: its mentions of the user are [PrismChip]s.
bool inPrism(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PrismScope>() != null;

/// The part of a list its Prism bubbles take their light from: the list's own
/// box, less the bars drawn over its [top] and [bottom].
class PrismViewport extends InheritedWidget {
  final double top;
  final double bottom;
  const PrismViewport({required this.top, required this.bottom, required super.child, super.key});

  @override
  bool updateShouldNotify(PrismViewport old) => old.top != top || old.bottom != bottom;
}

/// The light of a bubble that mentions the user, between the bubble's fill and
/// its [child], which it covers edge to edge (the bubble's padding goes in
/// [child]): the spill, the rim, and the gem under each [PrismChip].
class PrismBubble extends StatefulWidget {
  final PrismPalette palette;

  /// The bubble's corner radius.
  final double radius;

  /// The arrival is due, and plays when all of the bubble is first in sight:
  /// called as it starts. Null when it has played, and on a copy of the bubble.
  final VoidCallback? onArrive;
  final Widget child;

  const PrismBubble({required this.palette, required this.radius, required this.child, this.onArrive, super.key});

  @override
  State<PrismBubble> createState() => _PrismBubbleState();
}

class _PrismBubbleState extends State<PrismBubble> with SingleTickerProviderStateMixin {
  final _chips = _Chips();
  // At 0 until the arrival plays, so the gem waits unlit; at 1 at rest.
  late final _arrival = AnimationController(
    vsync: this,
    duration: prismArrival,
    value: widget.onArrive == null ? 1 : 0,
  );
  bool _due = false;
  bool _arrived = false;
  ScrollableState? _list;
  PrismViewport? _bars;
  double _screen = 0;
  // Animations off: no arrival, and the light of a bubble mid-list wherever it is.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _due = widget.onArrive != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = Scrollable.maybeOf(context);
    _bars = context.dependOnInheritedWidgetOfExactType<PrismViewport>();
    _screen = MediaQuery.sizeOf(context).height;
    _still = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(PrismBubble old) {
    super.didUpdateWidget(old);
    // Found unread once its page came, the bubble already built.
    if (old.onArrive == null && widget.onArrive != null && !_arrived) {
      _due = true;
      _arrival.value = 0;
    }
  }

  @override
  void dispose() {
    _arrival.dispose();
    _chips.dispose();
    super.dispose();
  }

  /// Where the bubble [box] is in what shows of its list: how far down its
  /// centre is, and whether all of it shows, 8 px clear of the edges (or, when
  /// it's taller than that, it covers them).
  ({double t, bool sighted}) _place(RenderBox box) {
    final view = _list?.context.findRenderObject();
    final list = view is RenderBox && view.hasSize ? view : null;
    final rect = MatrixUtils.transformRect(box.getTransformTo(list), Offset.zero & box.size);
    final top = _bars?.top ?? 0;
    final bottom = (list?.size.height ?? _screen) - (_bars?.bottom ?? 0);
    if (bottom <= top) return (t: 0.5, sighted: false);
    return (
      t: ((rect.center.dy - top) / (bottom - top)).clamp(0.0, 1.0),
      sighted: (rect.top >= top + 8 && rect.bottom <= bottom - 8) || (rect.top <= top + 8 && rect.bottom >= bottom - 8),
    );
  }

  /// First sight, found while painting: the arrival starts once the frame is done.
  void _arrive() {
    _due = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _arrived = true;
      widget.onArrive?.call();
      _arrival.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) => _PrismScope(
    bubble: this,
    child: Stack(
      children: [
        // Scrolling repaints this layer alone: the text over it is another.
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _PrismPainter(this, Listenable.merge([_chips, _arrival, if (!_still) ?_list?.position])),
            ),
          ),
        ),
        widget.child,
      ],
    ),
  );
}

class _PrismScope extends InheritedWidget {
  final _PrismBubbleState bubble;
  const _PrismScope({required this.bubble, required super.child});

  @override
  bool updateShouldNotify(_PrismScope old) => old.bubble != bubble;
}

/// The chips in a bubble's text: the painter finds them where the text laid them out.
class _Chips extends ChangeNotifier {
  final boxes = <BuildContext>[];

  void add(BuildContext chip) {
    boxes.add(chip);
    notifyListeners();
  }

  void remove(BuildContext chip) {
    if (boxes.remove(chip)) notifyListeners();
  }
}

/// A mention of the user in a [PrismBubble]'s text: their [name] in white, a
/// box in the line that wraps as a word does. The bubble cuts the gem under it.
class PrismChip extends StatefulWidget {
  final String name;

  /// The message's text style, here.
  final TextStyle style;
  const PrismChip(this.name, {required this.style, super.key});

  @override
  State<PrismChip> createState() => _PrismChipState();
}

class _PrismChipState extends State<PrismChip> {
  _Chips? _chips;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chips = context.dependOnInheritedWidgetOfExactType<_PrismScope>()?.bubble._chips;
    if (chips == _chips) return;
    _chips?.remove(context);
    (_chips = chips)?.add(context);
  }

  // Out of the tree before its box is: the painter only looks for chips still in it.
  @override
  void deactivate() {
    _chips?.remove(context);
    _chips = null;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 7),
    child: Text(
      widget.name,
      style: widget.style.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
    ),
  );
}

class _PrismPainter extends CustomPainter {
  final _PrismBubbleState bubble;
  _PrismPainter(this.bubble, Listenable repaint) : super(repaint: repaint);

  static const _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final box = bubble.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final p = bubble.widget.palette;
    final place = bubble._still ? (t: 0.5, sighted: false) : bubble._place(box);
    if (place.sighted && bubble._due) bubble._arrive();
    final light = prismLight(place.t);
    final arrival = prismArrivalAt(bubble._still ? 1580 : bubble._arrival.value * 1580);
    final all = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(all, Radius.circular(bubble.widget.radius));
    // In reading order: the spill centres on the first.
    final chips = [
      for (final at in bubble._chips.boxes)
        if (at.findRenderObject() case final RenderBox chip when chip.attached && chip.hasSize)
          MatrixUtils.transformRect(chip.getTransformTo(box), Offset.zero & chip.size),
    ]..sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));

    // The spill: three soft ellipses, each its color at the centre to nothing at its edge.
    final shows = p.intensity * arrival.spill;
    void spill(Color color, double alpha, Offset centre, double rx, double ry) {
      final squash = ry / rx;
      canvas.drawRect(
        all,
        Paint()
          ..shader = ui.Gradient.radial(
            centre,
            rx,
            [color.withValues(alpha: alpha * shows), color.withValues(alpha: 0)],
            null,
            TileMode.clamp,
            // A circle of rx, squashed to ry about its centre.
            Float64List.fromList([1, 0, 0, 0, 0, squash, 0, 0, 0, 0, 1, 0, 0, centre.dy * (1 - squash), 0, 1]),
          ),
      );
    }

    if (shows > 0) {
      canvas.save();
      canvas.clipRRect(shape);
      // No chip shows (the mention is in code, or under a spoiler): no light of its own.
      if (chips.firstOrNull case final first?) spill(p.gem, 0.36, first.center, 170, 80);
      spill(p.cool, 0.14, Offset(70 + light.slide * 150, size.height * 0.7), 120, 50);
      spill(p.warm, 0.12, Offset(30 + light.slide * 90, size.height), 90, 40);
      canvas.restore();
    }

    // The bubble's rim: across it at 135°, each end's color reaching its corner.
    final reach = (size.width + size.height) / 4;
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          all.center - Offset(reach, reach),
          all.center + Offset(reach, reach),
          [
            p.gem.withValues(alpha: 0.8),
            _white.withValues(alpha: 0.08),
            _white.withValues(alpha: 0.08),
            p.cool.withValues(alpha: 0.35),
          ],
          const [0, 0.42, 0.70, 1],
        ),
    );

    // A sweep starts at 3 o'clock: a quarter turn back, to the design's 12.
    final turn = (light.angle + arrival.offset - 90) * math.pi / 180;
    final cos = math.cos(turn), sin = math.sin(turn);
    for (final chip in chips) {
      final gem = RRect.fromRectAndRadius(chip, const Radius.circular(8));
      final c = chip.center;
      final turned = Float64List.fromList([
        ...[cos, sin, 0, 0],
        ...[-sin, cos, 0, 0],
        ...[0, 0, 1, 0],
        ...[c.dx - cos * c.dx + sin * c.dy, c.dy - sin * c.dx - cos * c.dy, 0, 1],
      ]);
      Shader sweep(List<(Color, double)> stops) => ui.Gradient.sweep(
        c,
        [for (final (color, _) in stops) color],
        [for (final (_, degrees) in stops) degrees / 360],
        TileMode.clamp,
        0,
        math.pi * 2,
        turned,
      );
      final glow = BoxShadow(color: p.gem.withValues(alpha: 0.7), blurRadius: 14, spreadRadius: -2);
      canvas.drawRRect(gem.inflate(glow.spreadRadius), glow.toPaint());
      canvas.drawRRect(
        gem,
        Paint()
          ..shader = sweep([
            (p.deep, 0),
            (p.body, 50),
            (p.band, 70),
            (p.body, 100),
            (p.deep, 180),
            (p.body, 225),
            (p.band, 248),
            (p.body, 275),
            (p.deep, 360),
          ]),
      );
      if (arrival.glint > 0) {
        // The glint: a leaning band of light across the gem, once.
        final width = chip.width * 0.6;
        canvas.save();
        canvas.clipRRect(gem);
        canvas.translate(chip.left + width / 2 + arrival.glintAt * width, c.dy);
        canvas.skew(math.tan(-22 * math.pi / 180), 0);
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: width, height: chip.height * 2.2),
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(-width / 2, 0),
              Offset(width / 2, 0),
              [
                _white.withValues(alpha: 0),
                _white.withValues(alpha: 0.10 * arrival.glint),
                _white.withValues(alpha: 0.38 * arrival.glint),
                p.cool.withValues(alpha: 0.40 * arrival.glint),
                p.cool.withValues(alpha: 0),
              ],
              const [0, 0.30, 0.50, 0.56, 1],
            ),
        );
        canvas.restore();
      }
      canvas.drawRRect(
        gem.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = sweep([
            (p.deep, 0),
            (p.gem, 38),
            (p.hi, 58),
            (_white, 66),
            (p.cool, 76),
            (p.gem, 104),
            (p.deep, 170),
            (p.gem, 214),
            (p.warm, 238),
            (p.hi, 248),
            (p.gem, 276),
            (p.deep, 360),
          ]),
      );
    }
  }

  // The bubble moves, its chips too, with nothing here to tell: each new painter paints.
  @override
  bool shouldRepaint(_PrismPainter old) => true;
}
