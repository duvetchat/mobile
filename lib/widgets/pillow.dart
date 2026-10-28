import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'depth.dart';

/// How the pillow's face looks at a form: at what's typed, eyes shut while a
/// password is typed, or one eye peeking while it's shown.
enum FaceMood { look, shut, peek }

/// The mood of a form with a password: [FaceMood.peek] while it's shown,
/// [FaceMood.shut] while it's typed hidden, else [FaceMood.look].
FaceMood passwordMood({required bool shown, required bool typing}) => shown
    ? FaceMood.peek
    : typing
    ? FaceMood.shut
    : FaceMood.look;

/// Where the eyes look while [text] is typed into a field under the face: down
/// at it, and along it as the text grows. Straight ahead when nothing is.
Offset gazeAlong(String text, {required bool typing}) {
  if (!typing) return Offset.zero;
  final along = (text.characters.length / 24).clamp(0.0, 1.0);
  return Offset(-0.8 + 1.6 * along, 0.7);
}

/// A form inside the mascot: a slate panel shaped like its pillow, its ears
/// (lined in ice) on top and its face above the fields, which look up at it.
///
/// The panel is slate in either theme, so what's in it is drawn in night's
/// colors: [child] reads `context.theme` and `context.duvet` as dark.
class PillowPanel extends StatelessWidget {
  final Widget child;
  final FaceMood mood;

  /// Where the eyes look, each axis -1 to 1: see [gazeAlong].
  final Offset gaze;

  const PillowPanel({required this.child, this.mood = FaceMood.look, this.gaze = Offset.zero, super.key});

  static const _radius = BorderRadius.all(Radius.circular(32));

  // Built once: a new theme each build would set FTheme animating to itself.
  static final _material = Duvet.material(Brightness.dark);
  static final _theme = Duvet.theme(Brightness.dark);

  /// How far the ears rise over the panel, for a panel [width] wide.
  static double earRise(double width) => width * 0.146;

  @override
  Widget build(BuildContext context) {
    final shadows = context.duvet.shadowFloat;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final rise = earRise(width);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: EdgeInsets.only(top: rise),
              child: DecoratedBox(
                decoration: BoxDecoration(color: Duvet.slate, borderRadius: _radius, boxShadow: shadows),
                child: InsetShadow(
                  shadows: DuvetTokens.dark.cushion,
                  borderRadius: _radius,
                  child: Theme(
                    data: _material,
                    child: FTheme(
                      data: _theme,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: PillowFace(mood: mood, gaze: gaze),
                            ),
                            const SizedBox(height: 12),
                            child,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // In front of the panel, so its lit top edge passes behind them.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: rise + width * 0.05,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: CustomPaint(painter: _EarsPainter(rise: rise)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The ears, as the desktop's sign-in has them: slate, each lined in ice,
/// their bases sunk a little into the panel's top corners.
class _EarsPainter extends CustomPainter {
  final double rise;
  _EarsPainter({required this.rise});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final body = Paint()..color = Duvet.slate;
    final lining = Paint()..color = Duvet.ice.withValues(alpha: 0.35);
    // Fractions of the panel's width, measured off the desktop's; y from the panel's top.
    for (final mirror in [false, true]) {
      Offset at(double x, double y) => Offset((mirror ? 1 - x : x) * w, rise + y * w);
      canvas.drawPath(_triangle(at(0.061, -0.146), at(0.122, 0.045), at(0.243, 0.033)), body);
      canvas.drawPath(_triangle(at(0.087, -0.105), at(0.13, 0.04), at(0.232, 0.031)), lining);
    }
  }

  static Path _triangle(Offset a, Offset b, Offset c) => Path()
    ..moveTo(a.dx, a.dy)
    ..lineTo(b.dx, b.dy)
    ..lineTo(c.dx, c.dy)
    ..close();

  @override
  bool shouldRepaint(_EarsPainter old) => old.rise != rise;
}

/// The pillow's face on its panel: two eyes with their lashes and a small
/// smile, as the mascot's. The eyes glide toward [gaze]; still where
/// animations are off. Decoration: screen readers skip it.
class PillowFace extends StatelessWidget {
  final FaceMood mood;
  final Offset gaze;
  const PillowFace({this.mood = FaceMood.look, this.gaze = Offset.zero, super.key});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<Offset>(
        tween: Tween(end: gaze),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
        curve: DuvetTokens.decelerate,
        builder: (context, gaze, _) => CustomPaint(
          size: const Size(96, 40),
          painter: _FacePainter(mood: mood, gaze: gaze),
        ),
      ),
    );
  }
}

class _FacePainter extends CustomPainter {
  final FaceMood mood;
  final Offset gaze;
  _FacePainter({required this.mood, required this.gaze});

  static const _eye = 8.0;
  static const _apart = 23.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final look = Offset(gaze.dx * 4, gaze.dy * 3);
    final white = Paint()..color = Colors.white;
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final side in [-1.0, 1.0]) {
      final eye = Offset(center + side * _apart, 15) + look;
      // Peeking, the right eye stays open.
      final open = mood == FaceMood.look || (mood == FaceMood.peek && side > 0);
      if (open) {
        canvas.drawCircle(eye, _eye, white);
        // The lash, up from the eye's outer edge.
        canvas.drawLine(eye + Offset(side * 6.5, -5.5), eye + Offset(side * 9, -9.5), line..strokeWidth = 2);
      } else {
        // Shut: a lid, its lash flicked up at the outer corner.
        final lid = eye + const Offset(0, 1);
        canvas.drawLine(lid - Offset(side * 8, 0), lid + Offset(side * 8, 0), line..strokeWidth = 3);
        canvas.drawLine(lid + Offset(side * 8, 0), lid + Offset(side * 10, -3.5), line..strokeWidth = 2);
      }
    }
    // The smile, under and between the eyes; it stays put as they look.
    canvas.drawPath(
      Path()
        ..moveTo(center - 7, 31)
        ..quadraticBezierTo(center, 37, center + 7, 31),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_FacePainter old) => old.mood != mood || old.gaze != gaze;
}

/// "Duvet.chat" as its wordmark is set, ".chat" in the accent, over its
/// tagline.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Duvet'),
              TextSpan(
                text: '.chat',
                style: TextStyle(color: colors.primary),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: DuvetType.largeTitle.copyWith(fontSize: 44, letterSpacing: -1, color: colors.foreground),
        ),
        const SizedBox(height: 6),
        Text(
          'A cozy place to talk',
          textAlign: TextAlign.center,
          style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
        ),
      ],
    );
  }
}
