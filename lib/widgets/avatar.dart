import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/images.dart';
import '../theme.dart';
import 'facehash.dart';

/// A person's avatar: their image once it loads, a `base-sunken` circle until
/// then, and their [Facehash] when they have none or it doesn't load.
class UserAvatar extends StatelessWidget {
  final String name;
  final String? url;
  final double size;

  /// The face's mouth and eyes, in voice: see [Facehash]. An image shows
  /// neither.
  final double mouthOpen;
  final Offset eyeOffset;

  const UserAvatar({
    required this.name,
    this.url,
    this.size = 40,
    this.mouthOpen = 0,
    this.eyeOffset = Offset.zero,
    super.key,
  });

  // Centered at its own size: a parent's tight constraints (a fixed-width
  // gutter, say) would otherwise stretch the circle into an oval.
  @override
  Widget build(BuildContext context) => Center(
    widthFactor: 1,
    heightFactor: 1,
    child: SizedBox.square(dimension: size, child: _avatar(context)),
  );

  Widget _avatar(BuildContext context) {
    final face = Facehash(name: name, size: size, mouthOpen: mouthOpen, eyeOffset: eyeOffset);
    final url = this.url;
    if (url == null) return face;
    return ClipOval(
      child: Image(
        // Decoded at the size shown, not the upload's.
        image: cachedImage(url, cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round()),
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: name,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => frame == null && !wasSynchronouslyLoaded
            ? Semantics(
                label: name,
                image: true,
                child: Container(width: size, height: size, color: context.theme.colors.secondary),
              )
            : child,
        errorBuilder: (context, error, stackTrace) => face,
      ),
    );
  }
}

/// A group's mark, where a group shows in a person's place: its row in the
/// chats, its call, its calls in the history, its info. A group has no
/// picture, and a face made from its name, as a person without one gets,
/// would read as someone's (#288). The desktop's (desktop#376): lucide's
/// users-round on the chosen fill. Its name is written beside it wherever it
/// shows, so it says nothing to screen readers.
class GroupMark extends StatelessWidget {
  final double size;
  const GroupMark({this.size = 40, super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    return ExcludeSemantics(
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: tokens.selectedFill, shape: BoxShape.circle),
          child: Icon(FLucideIcons.usersRound, size: size * 0.6, color: tokens.violetText),
        ),
      ),
    );
  }
}

/// A person in voice as the desktop draws everyone with "Faces in voice" on:
/// their [Facehash] whatever their picture, its mouth opening with their voice.
class VoiceFace extends StatelessWidget {
  final String name;

  /// Their audio level, 0–1: how open the mouth is.
  final double level;

  /// Where the eyes look, each axis in -1–1.
  final Offset eyeOffset;
  final double size;

  const VoiceFace({required this.name, this.level = 0, this.eyeOffset = Offset.zero, this.size = 72, super.key});

  // Eased toward each level rather than snapped to it: levels come a few times
  // a second. Decelerating, not overshooting: a mouth below 0 would flash the
  // initial back.
  @override
  Widget build(BuildContext context) => Center(
    widthFactor: 1,
    heightFactor: 1,
    // Just the name: the face's initial, there only while the mouth is shut,
    // would otherwise come and go from the label.
    child: Semantics(
      label: name,
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: level.clamp(0, 1).toDouble()),
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
          curve: DuvetTokens.decelerate,
          builder: (context, open, _) => Facehash(name: name, size: size, mouthOpen: open, eyeOffset: eyeOffset),
        ),
      ),
    ),
  );
}

/// A member's banner, faintly behind their row as the desktop's member list
/// has it: covering the row from its right edge, at 15%, 9% while they're
/// offline. A decoration's image, so screen readers never meet it and a
/// row's press and selection tints stay under it; nothing while it comes or
/// when it can't be had. None without a [url].
DecorationImage? memberBanner(BuildContext context, String? url, {bool offline = false}) {
  if (url == null) return null;
  // One size whatever the row, so each banner is fetched and decoded once:
  // half the screen's pixels across, more than a 15% wash shows.
  final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) / 2).round();
  if (width <= 0) return null;
  return DecorationImage(
    image: ResizeImage(cachedImage(url), width: width, policy: ResizeImagePolicy.fit),
    fit: BoxFit.cover,
    alignment: Alignment.centerRight,
    opacity: offline ? 0.09 : 0.15,
    onError: (error, stackTrace) {},
  );
}
