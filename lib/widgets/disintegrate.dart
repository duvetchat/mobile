import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Breaks what [key] shows into specks that drift off and fade, over where it
/// was, sweeping from the leading edge to the trailing one. It takes the
/// picture at once, so whatever [key] shows can go right after. Nothing
/// happens with reduced motion, or when [key] isn't on screen in a
/// [RepaintBoundary]: then it's null, else done once the dust has gone, in
/// [_cap] at most.
Future<void>? disintegrate(BuildContext context, GlobalKey key) {
  if (MediaQuery.disableAnimationsOf(context)) return null;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final boundary = key.currentContext?.findRenderObject();
  final overlayBox = overlay?.context.findRenderObject();
  if (overlay == null || boundary is! RenderRepaintBoundary || !boundary.hasSize || overlayBox is! RenderBox) {
    return null;
  }
  final rect = MatrixUtils.transformRect(boundary.getTransformTo(overlayBox), Offset.zero & boundary.size);
  final scale = MediaQuery.devicePixelRatioOf(context);
  final ui.Image image;
  try {
    image = boundary.toImageSync(pixelRatio: scale);
  } catch (_) {
    return null;
  }
  final done = Completer<void>();
  late final OverlayEntry entry;
  late final Timer cap;
  // Its picture goes with it: disposed as the dust's state is.
  void finish() {
    if (done.isCompleted) return;
    cap.cancel();
    entry
      ..remove()
      ..dispose();
    done.complete();
  }

  entry = OverlayEntry(
    builder: (_) => Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: _Dust(image: image, scale: scale, onDone: finish),
      ),
    ),
  );
  overlay.insert(entry);
  // Not for ever, should its pixels never be read: else the picture would
  // stay drawn over the app.
  cap = Timer(_cap, finish);
  return done.future;
}

/// The longest the dust stays, reading the picture included.
const _cap = Duration(milliseconds: 2500);

/// How long the dust takes to go, from the moment the picture's pixels are
/// read.
const _duration = Duration(milliseconds: 1600);

/// A square of the picture at [origin], its color, where it heads, and how
/// late it sets off, as a share of the whole.
class _Speck {
  final Offset origin;
  final Color color;
  final Offset drift;
  final double delay;
  const _Speck(this.origin, this.color, this.drift, this.delay);
}

/// How wide each speck is, in logical pixels: small enough to read as dust,
/// few enough to draw every frame.
const _size = 3.0;

/// How long the sweep takes to cross, as a share of the whole.
const _sweep = 0.45;

/// The latest a speck sets off; each then takes the rest of the time.
const _lastDelay = _sweep + 0.12;

List<_Speck> _specks(ByteData rgba, int width, int height, double scale) {
  final random = Random();
  final step = max(1, (_size * scale).round());
  final logicalWidth = width / scale;
  final specks = <_Speck>[];
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      final i = (y * width + x) * 4;
      final a = rgba.getUint8(i + 3);
      if (a < 24) continue;
      final origin = Offset(x / scale, y / scale);
      final angle = -pi / 2 + (random.nextDouble() - 0.3) * pi * 0.7;
      final distance = 24 + random.nextDouble() * 56;
      specks.add(
        _Speck(
          origin,
          Color.fromARGB(a, rgba.getUint8(i), rgba.getUint8(i + 1), rgba.getUint8(i + 2)),
          Offset(cos(angle), sin(angle)) * distance,
          // The leading edge goes first; a little scatter so it isn't a line.
          _sweep * origin.dx / max(1, logicalWidth) + random.nextDouble() * 0.12,
        ),
      );
    }
  }
  return specks;
}

/// The picture as it was until its pixels are read, then its specks.
class _Dust extends StatefulWidget {
  final ui.Image image;
  final double scale;
  final VoidCallback onDone;
  const _Dust({required this.image, required this.scale, required this.onDone});

  @override
  State<_Dust> createState() => _DustState();
}

class _DustState extends State<_Dust> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: _duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  List<_Speck>? _found;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final image = widget.image;
    ByteData? bytes;
    try {
      bytes = await image.toByteData();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _found = bytes == null ? const [] : _specks(bytes, image.width, image.height, widget.scale));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_found) {
    null => RawImage(image: widget.image, scale: widget.scale),
    final specks => CustomPaint(painter: _DustPainter(widget.image, specks, _controller)),
  };
}

class _DustPainter extends CustomPainter {
  final ui.Image image;
  final List<_Speck> specks;
  final Animation<double> t;
  _DustPainter(this.image, this.specks, this.t) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    // The picture itself, crisp, where the sweep hasn't reached yet.
    final front = size.width * t.value / _sweep;
    if (front < size.width) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(front, 0, size.width, size.height));
      canvas.drawImageRect(
        image,
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
    final paint = Paint();
    for (final s in specks) {
      // Each speck's own time, after its delay: 0 still in the picture, 1
      // gone.
      final p = ((t.value - s.delay) / (1 - _lastDelay)).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final eased = Curves.easeOutCubic.transform(p);
      final side = _size * (1 - p * 0.6);
      paint.color = s.color.withValues(alpha: s.color.a * (1 - p));
      canvas.drawRect(s.origin + s.drift * eased & Size(side, side), paint);
    }
  }

  @override
  bool shouldRepaint(_DustPainter old) => old.specks != specks;
}
