part of '../chat_view.dart';

/// A reaction's emoji as text: Unicode as it is, a custom one as `:name:`.
String _reactionName(Reaction r, MessageDirectory directory) =>
    r.emojiId == null ? r.emoji : ':${directory.emojiOf(r.emojiId!)?.name ?? r.emoji}:';

/// Who reacted to a message: its emoji and their counts along the top, and
/// for the one picked ([initial], else the first), who reacted with it,
/// oldest first. [known] gives those the app has; the API gives anyone
/// else, such as someone who left. Answers who was tapped.
Future<Member?> _showReactors(
  BuildContext context, {
  required List<Reaction> reactions,
  required Reaction? initial,
  required MessageDirectory directory,
  required Member? Function(String userId) known,
  required Presence? Function(String userId) presenceOf,
}) => showGlassSheet<Member>(
  context,
  label: 'Reactions',
  builder: (context, scroll) => _Reactors(
    reactions: reactions,
    initial: initial,
    directory: directory,
    known: known,
    presenceOf: presenceOf,
    scroll: scroll,
  ),
);

class _Reactors extends StatefulWidget {
  final List<Reaction> reactions;
  final Reaction? initial;
  final MessageDirectory directory;
  final Member? Function(String userId) known;
  final Presence? Function(String userId) presenceOf;
  final ScrollController scroll;
  const _Reactors({
    required this.reactions,
    required this.initial,
    required this.directory,
    required this.known,
    required this.presenceOf,
    required this.scroll,
  });

  @override
  State<_Reactors> createState() => _ReactorsState();
}

class _ReactorsState extends State<_Reactors> {
  late var _picked = max(
    0,
    widget.reactions.indexWhere((r) => r.emoji == widget.initial?.emoji && r.emojiId == widget.initial?.emojiId),
  );

  /// Those the API gave, and everyone it was asked for.
  final _fetched = <String, Member>{};
  final _asked = <String>{};

  Member _member(String userId) {
    if (widget.known(userId) ?? _fetched[userId] case final m?) return m;
    if (_asked.add(userId)) {
      context.repository
          .user(userId)
          .then(
            (m) => mounted ? setState(() => _fetched[userId] = m) : null,
            // Their name stays, if known, as a mention's does.
            onError: (_) {},
          );
    }
    // Their name if any list gave it, without a username rather than a
    // made-up one, until the API answers.
    return Member(userId: userId, username: '', alias: widget.directory.nameOf(userId) ?? 'Someone');
  }

  @override
  Widget build(BuildContext context) {
    final picked = widget.reactions[_picked];
    return ListView(
      controller: widget.scroll,
      children: [
        const SheetTitle(title: 'Reactions'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              for (final (i, r) in widget.reactions.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DuvetChip(
                    label: '${_reactionName(r, widget.directory)} ${r.count}',
                    selected: i == _picked,
                    onTap: () => setState(() => _picked = i),
                  ),
                ),
            ],
          ),
        ),
        for (final userId in picked.users)
          () {
            final m = _member(userId);
            return PersonRow(
              member: m,
              presence: widget.presenceOf(userId),
              username: m.username.isNotEmpty,
              onTap: () => Navigator.of(context).pop(m),
            );
          }(),
      ],
    );
  }
}
