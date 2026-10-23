import 'package:flutter/material.dart';

import 'facehash.dart';

/// A person's avatar: their image once it loads, their [Facehash] until then
/// and when they have none.
class UserAvatar extends StatelessWidget {
  final String name;
  final String? url;
  final double size;

  const UserAvatar({required this.name, this.url, this.size = 40, super.key});

  // Centered at its own size: a parent's tight constraints (a fixed-width
  // gutter, say) would otherwise stretch the circle into an oval.
  @override
  Widget build(BuildContext context) => Center(
    widthFactor: 1,
    heightFactor: 1,
    child: SizedBox.square(dimension: size, child: _avatar(context)),
  );

  Widget _avatar(BuildContext context) {
    final face = Facehash(name: name, size: size);
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
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            frame == null && !wasSynchronouslyLoaded ? face : child,
        errorBuilder: (context, error, stackTrace) => face,
      ),
    );
  }
}
