import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme.dart';

export 'package:skeletonizer/skeletonizer.dart' show Bone, Skeleton;

/// What shows while content loads, as the desktop draws it: blocks in the
/// shape of what's coming, pulsing (Tailwind's `animate-pulse` there: full to
/// half strength and back over two seconds).
///
/// Around real rows built from placeholder data it draws their text, pictures
/// and icons as bones; [Bone]s in it are drawn as they are. Still when the
/// system asks for no motion.
class DuvetSkeleton extends StatelessWidget {
  /// Off in tests (test/flutter_test_config.dart): a pulse never settles, so
  /// `pumpAndSettle` would time out on any screen still loading.
  static bool animate = true;

  final bool enabled;
  final Widget child;
  const DuvetSkeleton({required this.child, this.enabled = true, super.key});

  /// The pulse in this theme's tint, or the tint alone where nothing moves.
  static PaintingEffect effectOf(BuildContext context) {
    final tint = context.duvet.secondaryFill;
    return animate && !MediaQuery.disableAnimationsOf(context)
        ? PulseEffect(
            from: tint,
            to: tint.withValues(alpha: tint.a / 2),
          )
        : SolidColorEffect(color: tint);
  }

  @override
  Widget build(BuildContext context) => Skeletonizer(enabled: enabled, effect: effectOf(context), child: child);
}

/// One pulsing block: behind a picture or a video until it shows (the
/// desktop's `img-skeleton`), or a row of a list still loading. It fills its
/// parent on an axis left without a size, so that axis must be bounded.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final BorderRadiusGeometry borderRadius;
  const SkeletonBox({this.width, this.height, this.borderRadius = BorderRadius.zero, super.key});

  // Hit like the block it draws, which a bone isn't: a picture still loading
  // opens on a tap, as it did behind the box this replaced.
  @override
  Widget build(BuildContext context) => MetaData(
    behavior: HitTestBehavior.opaque,
    child: Skeletonizer.zone(
      effect: DuvetSkeleton.effectOf(context),
      child: Bone(width: width ?? double.infinity, height: height ?? double.infinity, borderRadius: borderRadius),
    ),
  );
}
