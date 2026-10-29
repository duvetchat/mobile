part of '../chat_view.dart';

/// The start of a chat, over its oldest message once there's nothing older to
/// load (alone in a chat with no messages): what it is, where a short chat
/// would leave the screen empty. The mascot peeks over the line under it.
class _ChatIntro extends StatelessWidget {
  final Widget face;
  final String title;
  final List<Widget> lines;
  final List<Widget> actions;

  const _ChatIntro({required this.face, required this.title, this.lines = const [], this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(right: 8, bottom: -14, child: const ExcludeSemantics(child: Mascot(size: 76))),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 24, 4, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(child: face),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.only(right: 72),
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.title.copyWith(fontSize: 24, color: colors.foreground),
                        ),
                      ),
                    ),
                    for (final line in lines) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(right: 72),
                        child: DefaultTextStyle.merge(
                          style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
                          child: line,
                        ),
                      ),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.only(right: 72),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: actions,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Space the user shares with someone, as a small chip.
class _SharedSpace extends StatelessWidget {
  final Space space;
  const _SharedSpace({required this.space});

  @override
  Widget build(BuildContext context) => Cushion(
    height: 32,
    radius: DuvetTokens.radiusChip,
    padding: const EdgeInsets.only(left: 4, right: 10),
    shadows: context.duvet.shadowRest,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: SpaceIcon(space: space, size: 24)),
        const SizedBox(width: 6),
        Text(space.name, style: DuvetType.caption.copyWith(color: context.theme.colors.foreground)),
      ],
    ),
  );
}
