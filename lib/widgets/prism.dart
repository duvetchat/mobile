import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

// Prism: a mention of the user throws a soft violet light on the bubble around
// it. The light comes up once as the message first comes into sight, then its
// side lights slide as the list scrolls. The mention itself stays as it is
// anywhere else, in its member's role colors. The numbers are the design's.

/// How long the arrival is: the spill waits 250 ms, then comes up over 900.
const prismArrival = Duration(milliseconds: 1150);

/// How much of the spill shows [ms] into the arrival, 0 to 1.
double prismSpillAt(double ms) => const Cubic(0.2, 0.9, 0.3, 1.0).transform(((ms - 250) / 900).clamp(0.0, 1.0));

/// The mention's light under its bubble, after the bubble's own shadows.
BoxShadow prismShadow(PrismPalette palette) => BoxShadow(
  color: palette.gem.withValues(alpha: 0.45),
  blurRadius: palette.shadowBlur,
  spreadRadius: palette.shadowSpread,
  offset: const Offset(0, 8),
);

/// Whether what's built here is in a [PrismBubble]: its mentions of the user go in a [PrismAnchor].
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
/// [child]); with no bubble to light (a sticker, a bot's components), a frame
/// of the same light round [child], with no fill: the spill, centred on the first [PrismAnchor] if there's one, and the rim.
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
  final _anchors = _Anchors();
  // At 0 until the arrival plays, so the bubble waits unlit; at 1 at rest.
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
    _anchors.dispose();
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
              painter: _PrismPainter(this, Listenable.merge([_anchors, _arrival, if (!_still) ?_list?.position])),
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

/// The mentions of the user in a bubble's text: the painter finds them where the text laid them out.
class _Anchors extends ChangeNotifier {
  final boxes = <BuildContext>[];

  void add(BuildContext anchor) {
    boxes.add(anchor);
    notifyListeners();
  }

  void remove(BuildContext anchor) {
    if (boxes.remove(anchor)) notifyListeners();
  }
}

/// A mention of the user in a [PrismBubble]'s text, as [child] shows it: where
/// the bubble's light comes from. It draws nothing of its own.
class PrismAnchor extends StatefulWidget {
  final Widget child;
  const PrismAnchor({required this.child, super.key});

  @override
  State<PrismAnchor> createState() => _PrismAnchorState();
}

class _PrismAnchorState extends State<PrismAnchor> {
  _Anchors? _anchors;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final anchors = context.dependOnInheritedWidgetOfExactType<_PrismScope>()?.bubble._anchors;
    if (anchors == _anchors) return;
    _anchors?.remove(context);
    (_anchors = anchors)?.add(context);
  }

  // Out of the tree before its box is: the painter only looks for those still in it.
  @override
  void deactivate() {
    _anchors?.remove(context);
    _anchors = null;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PrismPainter extends CustomPainter {
  final _PrismBubbleState bubble;
  _PrismPainter(this.bubble, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final box = bubble.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final p = bubble.widget.palette;
    final place = bubble._still ? (t: 0.5, sighted: false) : bubble._place(box);
    if (place.sighted && bubble._due) bubble._arrive();
    // The side lights slide across as the bubble moves up the list.
    final slide = 1 - place.t;
    final all = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(all, Radius.circular(bubble.widget.radius));
    // In reading order: the spill centres on the first.
    final mentions = [
      for (final at in bubble._anchors.boxes)
        if (at.findRenderObject() case final RenderBox anchor when anchor.attached && anchor.hasSize)
          MatrixUtils.transformRect(anchor.getTransformTo(box), Offset.zero & anchor.size),
    ]..sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.left.compareTo(b.left));

    // The spill: three soft ellipses, each its color at the centre to nothing at its edge.
    final shows = p.intensity * (bubble._still ? 1 : prismSpillAt(bubble._arrival.value * prismArrival.inMilliseconds));
    // Drawn for a bubble a full line wide: in a shorter one the lights shrink
    // with it, or they'd flood it edge to edge.
    final scale = (size.width / 270).clamp(0.4, 1.0);
    void spill(Color color, double alpha, Offset centre, double rx, double ry) {
      final squash = ry / rx;
      rx *= scale;
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
      // No mention shows (a reply to the user, or it's in code, or under a
      // spoiler): from where a line's first word would be, as the design has it.
      spill(p.gem, p.mainSpill, mentions.firstOrNull?.center ?? const Offset(40, 20), 170, 80);
      spill(p.cool, p.coolSpill, Offset((70 + slide * 150) * scale, size.height * 0.7), 120, 50);
      spill(p.warm, p.warmSpill, Offset((30 + slide * 90) * scale, size.height), 90, 40);
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
          [for (final (color, share, _) in p.rim) color.withValues(alpha: share)],
          [for (final (_, _, at) in p.rim) at],
        ),
    );
  }

  // The bubble moves, its mentions too, with nothing here to tell: each new painter paints.
  @override
  bool shouldRepaint(_PrismPainter old) => true;
}
