import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../data/scope.dart';
import '../tabs.dart' show voiceSnippet;
import '../theme.dart';
import '../voice_room.dart' show voicePeople;
import 'avatar.dart';
import 'bot_ui.dart';
import 'depth.dart';
import 'glass.dart';
import 'message_content.dart';
import 'rows.dart';

/// The Channel Switcher: the Space's rooms in a glass sheet, by category.
/// What has news sits up on a cushion, its name in weight, with the
/// mentions' pill; a voice room shows who's in it; the current room is on the
/// chosen slate pill. Answers the room picked.
Future<Room?> showChannelSwitcher(BuildContext context, {required Space space, required String current}) =>
    showGlassSheet<Room>(
      context,
      label: space.name,
      builder: (context, scroll) {
        final repository = context.repository;
        final voice = context.voice;
        repository.loadLatest([
          for (final r in space.rooms)
            if (r.kind == RoomKind.text) r.target,
        ]);
        return ListenableBuilder(
          listenable: Listenable.merge([repository.unread, repository.latest, repository.mentions, voice]),
          builder: (context, _) {
            final unread = repository.unread.value;
            final latest = repository.latest.value;
            final mentions = repository.mentions.value;
            final me = repository.profile.value?.id;
            final cushion = context.cushionOnSheet;
            Widget row(Room room) => switch (room.kind) {
              RoomKind.text => ListRow(
                key: ValueKey(room.id),
                title: room.name,
                hash: true,
                selected: room.id == current,
                unread: unread.contains(room.id),
                cushionColor: cushion,
                mentions: mentions[room.id] ?? 0,
                snippet: switch (latest[room.id]) {
                  final m? => '${m.authorId == me ? 'You' : m.authorName}: ${repository.previewOf(m)}',
                  null => null,
                },
                onTap: () => Navigator.of(context).pop(room),
              ),
              RoomKind.voice => () {
                final people = voicePeople(repository, voice, room.id);
                return ListRow(
                  key: ValueKey(room.id),
                  leading: RoomMark(kind: RoomKind.voice, live: people.isNotEmpty, size: 40),
                  title: room.name,
                  snippet: voiceSnippet(repository, voice, room.id),
                  detail: people.isEmpty ? 'voice room' : 'voice room, ${people.length} in voice',
                  accessory: people.isEmpty
                      ? null
                      : InVoice(faces: [for (final p in people) (name: p.name, avatarUrl: p.avatarUrl)]),
                  onTap: () => Navigator.of(context).pop(room),
                );
              }(),
            };
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      SpaceIcon(space: space, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            space.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DuvetType.title.copyWith(color: context.theme.colors.foreground),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final section in space.sections)
                  if (section.rooms.isNotEmpty) ...[
                    Overline(section.name ?? 'Rooms'),
                    for (final room in section.rooms) row(room),
                  ],
              ],
            );
          },
        );
      },
    );

/// The chat's pinned messages, each whole, as [message] shows it in the chat,
/// with Jump to message, and Unpin for those who may ([onUnpin], which
/// answers whether it did; null for the others).
/// [pins] loads them again whenever [changes] says a pin changed, as the
/// desktop's list does. Answers the one to jump to.
Future<ChatMessage?> showPinsSheet(
  BuildContext context, {
  required Future<List<ChatMessage>> Function() pins,
  Stream<void>? changes,
  required String where,
  required MessageDirectory directory,
  required Widget Function(ChatMessage m) message,
  required Future<bool> Function(ChatMessage m)? onUnpin,
}) => showGlassSheet<ChatMessage>(
  context,
  label: 'Pinned',
  builder: (context, scroll) => _Pins(
    pins: pins,
    changes: changes,
    where: where,
    directory: directory,
    message: message,
    onUnpin: onUnpin,
    scroll: scroll,
  ),
);

class _Pins extends StatefulWidget {
  final Future<List<ChatMessage>> Function() pins;
  final Stream<void>? changes;
  final String where;
  final MessageDirectory directory;
  final Widget Function(ChatMessage m) message;
  final Future<bool> Function(ChatMessage m)? onUnpin;
  final ScrollController scroll;
  const _Pins({
    required this.pins,
    required this.changes,
    required this.where,
    required this.directory,
    required this.message,
    required this.onUnpin,
    required this.scroll,
  });

  @override
  State<_Pins> createState() => _PinsState();
}

class _PinsState extends State<_Pins> {
  List<ChatMessage>? _pins;
  Object? _error;
  StreamSubscription<void>? _changes;

  // The latest load: an older one answering after it doesn't count.
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = widget.changes?.listen((_) => _load());
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  void _load() {
    final load = ++_loads;
    widget.pins().then(
      (p) {
        if (mounted && load == _loads) {
          setState(() {
            _pins = p;
            _error = null;
          });
        }
      },
      onError: (Object e) {
        if (mounted && load == _loads) setState(() => _error = e);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final pins = _pins;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text('Pinned', style: DuvetType.title.copyWith(color: colors.foreground)),
              ),
              if (pins != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${pins.length == 1 ? '1 message' : '${pins.length} messages'} in ${widget.where}',
                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                  ),
                ),
            ],
          ),
        ),
        if (_error != null)
          const ListNote('Couldn’t load the pinned messages')
        else if (pins == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: FCircularProgress()),
          )
        else if (pins.isEmpty)
          const ListNote('Nothing pinned yet')
        else
          for (final m in pins)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Cushion(
                color: context.cushionOnSheet,
                // The message's own 4pt inset lines its text up with the byline.
                padding: const EdgeInsets.fromLTRB(8, 12, 4, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                      child: Byline(message: m),
                    ),
                    const SizedBox(height: 4),
                    widget.message(m),
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            container: true,
                            button: true,
                            label: 'Jump to ${m.authorName}’s message',
                            excludeSemantics: true,
                            onTap: () => Navigator.of(context).pop(m),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => Navigator.of(context).pop(m),
                              child: Container(
                                height: 44,
                                padding: const EdgeInsets.only(left: 4),
                                child: Row(
                                  children: [
                                    Text(
                                      'Jump to message',
                                      style: DuvetType.caption.copyWith(
                                        color: tokens.accentText,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(FLucideIcons.arrowRight, size: 14, color: tokens.accentText),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.onUnpin case final onUnpin?)
                          _UnpinButton(
                            name: m.authorName,
                            // A pin the server kept stays listed.
                            onPressed: () async {
                              if (await onUnpin(m) && mounted) setState(() => _pins = [...?_pins]..remove(m));
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// Who wrote a message and when, over it on a card (a pin, a thread's first
/// message): their face (a bot's square), their name, the day and time.
class Byline extends StatelessWidget {
  final ChatMessage message;

  /// Their face or name tapped: their profile.
  final VoidCallback? onAuthor;
  const Byline({required this.message, this.onAuthor, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final m = message;
    final t = m.createdAt;
    final when = '${dayLabel(t)} at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final line = Row(
      children: [
        ExcludeSemantics(
          child: m.fromBot
              ? const BotAvatar(size: 32)
              : UserAvatar(name: m.authorName, url: m.authorAvatarUrl, size: 32),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      m.authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground),
                    ),
                  ),
                  if (m.fromBot || m.fromWebhook) ...[const SizedBox(width: 6), BotTag(webhook: m.fromWebhook)],
                ],
              ),
              Text(
                when,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
              ),
            ],
          ),
        ),
      ],
    );
    if (onAuthor == null) return line;
    return Semantics(
      container: true,
      button: true,
      label: '${m.authorName}’s profile, $when',
      excludeSemantics: true,
      onTap: onAuthor,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onAuthor, child: line),
    );
  }
}

class _UnpinButton extends StatelessWidget {
  final String name;
  final VoidCallback onPressed;
  const _UnpinButton({required this.name, required this.onPressed});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: 'Unpin $name’s message',
    excludeSemantics: true,
    onTap: onPressed,
    child: GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.square(
        dimension: 44,
        child: Icon(FLucideIcons.pinOff, size: 20, color: context.theme.colors.mutedForeground),
      ),
    ),
  );
}
