import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The ghost's flat layers and the night sky around it, light and dark, from
/// the Ghost design. Art only: the interface's colors live in theme.dart.
typedef _Art = ({
  String body,
  String shade,
  String cast,
  String eye,
  String sky,
  String lilac,
  String star,
  String moon,
});

const _Art _light = (
  body: '#ffffff',
  shade: '#dcd6ff',
  cast: '#d3dfff',
  eye: '#7a6ad8',
  sky: '#dce8ff',
  lilac: '#e9e3ff',
  star: '#b9c6ff',
  moon: '#fff1c9',
);
const _Art _dark = (
  body: '#f7f6f3',
  shade: '#c9cbe0',
  cast: '#1c1d28',
  eye: '#7a6ad8',
  sky: '#0d1222',
  lilac: '#141024',
  star: '#2a3050',
  moon: '#3a3420',
);

_Art _artOf(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? _dark : _light;

const _ghost =
    'M24 50 C24 35.6 35.6 24 50 24 C64.4 24 76 35.6 76 50 V74 Q69.5 84 63 74 Q56.5 84 50 74 Q43.5 84 37 74 '
    'Q33 80 25 86 Q24 78 24 68 Z';

/// Four-pointed star centered on 0,0, five units out.
const _star = 'M0 -5 L1.4 -1.4 L5 0 L1.4 1.4 L0 5 L-1.4 1.4 L-5 0 L-1.4 -1.4 Z';

/// The app icon, as on the home screen: the ghost on its black rounded tile,
/// with the design's faint edge. On the dark theme the black tile sinks into
/// the background, so it inverts: the brand's ink mark on a light tile.
///
/// It hops, a little squash and stretch, when tapped and when it comes into
/// view (its tab picked, the page over it popped). Never a tilt: the brand
/// doesn't rotate the logo.
class AppIcon extends StatefulWidget {
  final double size;
  const AppIcon({required this.size, super.key});

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> with SingleTickerProviderStateMixin {
  late final _hop = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
  bool _shown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // An IndexedStack's hidden tab reads as invisible; a covered route, as ticker-less.
    final shown = Visibility.of(context) && TickerMode.valuesOf(context).enabled;
    if (shown && !_shown) _play();
    _shown = shown;
  }

  void _play() {
    if (!MediaQuery.disableAnimationsOf(context)) _hop.forward(from: 0);
  }

  @override
  void dispose() {
    _hop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final radius = BorderRadius.circular(size * 0.22);
    // In front of the art: an edge only, never a shadow, which would dim it.
    Decoration edge(Color color) => BoxDecoration(
      borderRadius: radius,
      border: Border.all(color: color),
    );
    final icon = Theme.of(context).brightness == Brightness.dark
        ? Container(
            width: size,
            height: size,
            // The brand's clear space: about a third of the ghost's width all round.
            padding: EdgeInsets.all(size * 0.2),
            decoration: BoxDecoration(color: const Color(0xFFF7F6F3), borderRadius: radius),
            foregroundDecoration: edge(const Color(0x1415172B)),
            child: SvgPicture.asset('assets/logo/mark-on-light.svg', semanticsLabel: 'Duvet'),
          )
        : Container(
            foregroundDecoration: edge(const Color(0x14FFFFFF)),
            child: SvgPicture.asset(
              'assets/logo/app-icon-rounded.svg',
              width: size,
              height: size,
              semanticsLabel: 'Duvet',
            ),
          );
    return GestureDetector(
      onTap: _play,
      // A flourish, not an action: screen readers hear the logo, not a button.
      excludeFromSemantics: true,
      child: AnimatedBuilder(
        animation: _hop,
        builder: (context, child) {
          // Up and down in the first 70%, stretched; then a squash on landing.
          const air = 0.7;
          final t = _hop.value;
          final lift = t < air ? math.sin(math.pi * t / air) : 0.0;
          final land = t < air ? 0.0 : math.sin(math.pi * (t - air) / (1 - air));
          return Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.diagonal3Values(1 - 0.05 * lift + 0.1 * land, 1 + 0.08 * lift - 0.12 * land, 1)
              ..setTranslationRaw(0, -size * 0.22 * lift, 0),
            child: child,
          );
        },
        child: icon,
      ),
    );
  }
}

/// The logo's ghost without its square, in the theme's art colors: for where
/// the mascot would be too small (it needs 64pt).
class GhostMark extends StatelessWidget {
  /// Height; the mark is 64 wide for 72 tall.
  final double size;
  const GhostMark({this.size = 24, super.key});

  @override
  Widget build(BuildContext context) {
    final a = _artOf(context);
    return SvgPicture.string(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="20 20 64 72">'
      '<defs><clipPath id="c"><path d="$_ghost"/></clipPath></defs>'
      '<path d="$_ghost" fill="${a.cast}" transform="translate(3.5 4)"/>'
      '<path d="$_ghost" fill="${a.shade}"/>'
      '<g clip-path="url(#c)"><path d="$_ghost" fill="${a.body}" transform="translate(-3.2 -2.6)"/></g>'
      '<ellipse cx="42" cy="50" rx="4.4" ry="6" fill="${a.eye}"/>'
      '<ellipse cx="59" cy="50" rx="4.4" ry="6" fill="${a.eye}"/>'
      '</svg>',
      height: size,
      width: size * 64 / 72,
      excludeFromSemantics: true,
    );
  }
}

/// A flat night sky: a crescent moon and stars, with two clouds along the
/// bottom for [NightSky.welcome]. Decoration only, hidden from screen readers.
class NightSky extends StatelessWidget {
  final bool _welcome;
  final double width;

  /// The sign-in landing's sky, [width] wide (390 × 440 at a phone's width).
  const NightSky.welcome({required this.width, super.key}) : _welcome = true;

  /// The moon and two stars a root page's large title sits beside.
  const NightSky.title({this.width = 140, super.key}) : _welcome = false;

  @override
  Widget build(BuildContext context) {
    final a = _artOf(context);
    String star(double x, double y, double scale) =>
        '<path d="$_star" fill="${a.star}" transform="translate($x $y) scale($scale)"/>';
    final svg = _welcome
        ? '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 390 440">'
              '<path d="M308 72 a26 26 0 1 0 20 44 a20 20 0 1 1 -20 -44 z" fill="${a.moon}"/>'
              '${star(58, 106, 1.5)}${star(110, 64, 0.9)}${star(262, 175, 1.1)}'
              '${star(336, 238, 0.8)}${star(40, 226, 0.8)}'
              '<path d="M-20 400 C10 370 50 372 70 388 C84 362 128 360 146 386 C166 374 196 380 204 400 Z" '
              'fill="${a.sky}"/>'
              '<path d="M220 420 C240 396 274 396 290 410 C304 388 344 388 358 410 C376 404 400 410 410 420 Z" '
              'fill="${a.lilac}"/>'
              '</svg>'
        : '<svg xmlns="http://www.w3.org/2000/svg" viewBox="200 40 140 60">'
              '<path d="M300 62 a16 16 0 1 0 12 27 a12 12 0 1 1 -12 -27 z" fill="${a.moon}"/>'
              '${star(262, 56, 0.9)}${star(226, 88, 0.7)}'
              '</svg>';
    return ExcludeSemantics(
      child: SvgPicture.string(svg, width: width, height: width * (_welcome ? 440 / 390 : 60 / 140)),
    );
  }
}

/// Three violet dots fading in turn, the ghost's "typing". Still when the
/// system asks for less motion.
class TypingDots extends StatefulWidget {
  final Color color;
  const TypingDots({required this.color, super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Opacity(
              // Each dot peaks a third of the loop after the one before it.
              opacity: still ? const [1.0, 0.6, 0.35][i] : 0.35 + 0.65 * _pulse((_loop.value - i / 3) % 1),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 0 → 1 → 0 over the first half of [t]'s cycle, resting at 0 for the rest.
  static double _pulse(double t) => t < 0.5 ? 1 - (t * 4 - 1).abs() : 0;
}
