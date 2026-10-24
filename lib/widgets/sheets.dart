import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../data/scope.dart';
import '../theme.dart';
import 'avatar.dart';
import 'glass.dart';
import 'message_content.dart';
import 'rows.dart';

/// The Channel Switcher: the Space's directory in a glass sheet, the current
/// room selected. Answers the room picked.
Future<Room?> showChannelSwitcher(BuildContext context, {required Space space, required String current}) =>
    showGlassSheet<Room>(
      context,
      label: space.name,
      builder: (context, scroll) {
        final repository = context.repository;
        repository.loadLatest([
          for (final r in space.rooms)
            if (r.kind == RoomKind.text) r.target,
        ]);
        return ListenableBuilder(
          listenable: Listenable.merge([repository.unread, repository.latest]),
          builder: (context, _) {
            final unread = repository.unread.value;
            final latest = repository.latest.value;
            final me = repository.profile.value?.id;
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                SheetTitle(title: space.name),
                for (final section in space.sections)
                  if (section.rooms.any((r) => r.kind == RoomKind.text)) ...[
                    Overline(section.name ?? 'Rooms'),
                    for (final room in section.rooms)
                      if (room.kind == RoomKind.text)
                        ListRow(
                          title: room.name,
                          hash: true,
                          selected: room.id == current,
                          unread: unread.contains(room.id),
                          snippet: switch (latest[room.id]) {
                            final m? => '${m.authorId == me ? 'You' : m.authorName}: ${repository.previewOf(m)}',
                            null => null,
                          },
                          onTap: () => Navigator.of(context).pop(room),
                        ),
                  ],
              ],
            );
          },
        );
      },
    );

/// The chat's pinned messages, each with Jump to message, and Unpin for those
/// who may ([onUnpin] null for the others). [pins] loads them again whenever
/// [changes] says a pin changed, as the desktop's list does. Answers the one
/// to jump to.
Future<ChatMessage?> showPinsSheet(
  BuildContext context, {
  required Future<List<ChatMessage>> Function() pins,
  Stream<void>? changes,
  required String where,
  required MessageDirectory directory,
  required Future<void> Function(ChatMessage m)? onUnpin,
}) => showGlassSheet<ChatMessage>(
  context,
  label: 'Pinned',
  builder: (context, scroll) =>
      _Pins(pins: pins, changes: changes, where: where, directory: directory, onUnpin: onUnpin, scroll: scroll),
);

class _Pins extends StatefulWidget {
  final Future<List<ChatMessage>> Function() pins;
  final Stream<void>? changes;
  final String where;
  final MessageDirectory directory;
  final Future<void> Function(ChatMessage m)? onUnpin;
  final ScrollController scroll;
  const _Pins({
    required this.pins,
    required this.changes,
    required this.where,
    required this.directory,
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
              child: Container(
                // Unpin's 40pt button keeps its own margin on the right.
                padding: EdgeInsets.fromLTRB(12, 12, widget.onUnpin == null ? 12 : 4, 12),
                decoration: BoxDecoration(
                  color: colors.card,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                  boxShadow: tokens.shadowRest,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        label:
                            'Pinned message from ${m.authorName}: ${context.repository.previewOf(m)}. Jump to message',
                        excludeSemantics: true,
                        onTap: () => Navigator.of(context).pop(m),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).pop(m),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  UserAvatar(name: m.authorName, url: m.authorAvatarUrl, size: 24),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      m.authorName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    shortTime(m.createdAt),
                                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                context.repository.previewOf(m),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.body.copyWith(color: colors.foreground),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Jump to message',
                                style: DuvetType.caption.copyWith(
                                  color: tokens.accentText,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (widget.onUnpin case final onUnpin?)
                      _UnpinButton(
                        name: m.authorName,
                        onPressed: () async {
                          await onUnpin(m);
                          if (mounted) setState(() => _pins = [...?_pins]..remove(m));
                        },
                      ),
                  ],
                ),
              ),
            ),
      ],
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
      child: SizedBox.square(
        dimension: 40,
        child: Icon(FLucideIcons.pinOff, size: 20, color: context.theme.colors.mutedForeground),
      ),
    ),
  );
}
