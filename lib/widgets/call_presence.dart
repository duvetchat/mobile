import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'depth.dart';
import 'rows.dart';

/// Voice going on, above a list: a DM's call on Chats, a voice room in its
/// Space, that the user's voice isn't in (the voice bar shows that one).
/// Who's in, a live dot, and Join. A `base-raised` card at `radius-card`, as Space Cards are: no glass
/// inside a scrolling list.
class CallPresenceCard extends StatelessWidget {
  /// A 40pt avatar; without one, [icon] in a `base-sunken` well.
  final Widget? leading;
  final IconData icon;
  final String title;

  /// Who's in.
  final String detail;

  /// Null when it can't be joined (no JoinVoice): Join dims.
  final VoidCallback? onJoin;

  const CallPresenceCard({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onJoin,
    this.leading,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const well = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: tokens.shadowRaised,
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child:
                leading ??
                SizedBox.square(
                  dimension: 40,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: colors.secondary, borderRadius: well),
                    child: InsetShadow(
                      shadows: tokens.shadowWell,
                      borderRadius: well,
                      child: Icon(icon, size: 24, color: colors.foreground),
                    ),
                  ),
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              container: true,
              label: '$title, live, $detail',
              excludeSemantics: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: tokens.live, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Live · $detail',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          DuvetButton(label: 'Join', onPressed: onJoin),
        ],
      ),
    );
  }
}
