import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// One frame, decoded: its pixels and how long it shows.
typedef ApngFrame = ({Uint8List rgba, int width, int height, int ms});

/// An APNG, played. Flutter's own decoder stops at its first frame, so the
/// `image` package reads them all (off the UI thread) and a ticker turns
/// them; [placeholder] (the still Flutter shows) stays until then, and for
/// good if it isn't animated or can't be read.
class ApngImage extends StatefulWidget {
  final String url;
  final bool local;
  final double width;
  final BoxFit fit;
  final Widget placeholder;
  const ApngImage({
    required this.url,
    required this.local,
    required this.width,
    required this.fit,
    required this.placeholder,
    super.key,
  });

  /// Fetches the file's bytes; tests swap in their own.
  @visibleForTesting
  static Future<Uint8List> Function(String url, bool local) fetch = (url, local) async {
    if (local) return File(url).readAsBytes();
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw http.ClientException('APNG answered ${response.statusCode}');
    return response.bodyBytes;
  };

  /// The frames of [bytes], each no wider than [maxWidth], or null when it
  /// isn't an animated PNG. Pure Dart: runs in an isolate.
  static List<ApngFrame>? decode(Uint8List bytes, int maxWidth) {
    final image = img.PngDecoder().decode(bytes);
    if (image == null || image.numFrames <= 1) return null;
    return [
      // shortcut: 150 frames at most, so a long loop can't fill memory; stream frames to lift it.
      for (final f in image.frames.take(150))
        () {
          final sized = (f.width > maxWidth ? img.copyResize(f, width: maxWidth) : f).convert(
            format: img.Format.uint8,
            numChannels: 4,
          );
          return (
            rgba: sized.getBytes(order: img.ChannelOrder.rgba),
            width: sized.width,
            height: sized.height,
            // A frame with no delay shows for a tick, as browsers do.
            ms: f.frameDuration <= 0 ? 100 : f.frameDuration,
          );
        }(),
    ];
  }

  @override
  State<ApngImage> createState() => _ApngImageState();
}

// Top level, so it's sendable to the isolate from any zone (a closure made
// in the test zone isn't).
List<ApngFrame>? _decode((Uint8List, int) args) => ApngImage.decode(args.$1, args.$2);

class _ApngImageState extends State<ApngImage> with SingleTickerProviderStateMixin {
  List<ui.Image>? _frames;
  List<int>? _ends;
  int _index = 0;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      final maxWidth = (widget.width * dpr).round();
      final bytes = await ApngImage.fetch(widget.url, widget.local);
      final decoded = await compute(_decode, (bytes, maxWidth));
      if (decoded == null || !mounted) return;
      final frames = [
        for (final f in decoded)
          await () {
            final out = Completer<ui.Image>();
            ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, out.complete);
            return out.future;
          }(),
      ];
      if (!mounted) {
        for (final f in frames) {
          f.dispose();
        }
        return;
      }
      var end = 0;
      setState(() {
        _frames = frames;
        _ends = [for (final f in decoded) end += f.ms];
      });
      _ticker = createTicker(_tick)..start();
    } catch (e) {
      debugPrint('apng: $e');
    }
  }

  void _tick(Duration elapsed) {
    final ends = _ends!;
    final t = elapsed.inMilliseconds % ends.last;
    final i = ends.indexWhere((end) => t < end);
    if (i != _index) setState(() => _index = i);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    for (final f in _frames ?? const <ui.Image>[]) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    if (frames == null) return widget.placeholder;
    return RawImage(image: frames[_index], fit: widget.fit, width: double.infinity, height: double.infinity);
  }
}
