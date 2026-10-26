import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

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
      child: Image.network(
        url,
        width: size,
        height: size,
        // Decoded at the size shown, not the upload's.
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
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
    image: ResizeImage(NetworkImage(url), width: width, policy: ResizeImagePolicy.fit),
    fit: BoxFit.cover,
    alignment: Alignment.centerRight,
    opacity: offline ? 0.09 : 0.15,
    onError: (error, stackTrace) {},
  );
}
