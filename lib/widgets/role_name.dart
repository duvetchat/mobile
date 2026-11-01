import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';

/// A role's name color, readable on this theme's background.
Color? roleColorOn(BuildContext context, int? rgb) =>
    rgb == null ? null : readableOn(Color(0xFF000000 | rgb), context.theme.colors.background);

/// A role's name as members see it: in its color, or across its gradient
/// left to right, each stop made readable on this theme's background; the
/// default ink without one. Sized to the name, so a gradient spans the name.
class RoleName extends StatelessWidget {
  final String name;
  final RoleColors colors;
  final TextStyle style;
  const RoleName(this.name, {required this.colors, required this.style, super.key});

  @override
  Widget build(BuildContext context) {
    final ink = context.theme.colors.foreground;
    // A gradient only with both ends, as the desktop reads one; the text is
    // white only under the mask that colors it.
    final gradient = colors.from != null && colors.to != null;
    final stops = [colors.from, colors.via, colors.to].nonNulls.map((c) => roleColorOn(context, c)!).toList();
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(
        color: gradient ? const Color(0xFFFFFFFF) : (colors.from == null ? ink : roleColorOn(context, colors.from)),
      ),
    );
    if (!gradient) return text;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(colors: stops).createShader(bounds),
      child: text,
    );
  }
}
