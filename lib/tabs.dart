import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'calls.dart';
import 'chat_view.dart';
import 'data/models.dart';
import 'data/recent_chats.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'members_sheet.dart';
import 'people.dart';
import 'search.dart';
import 'spaces.dart';
import 'theme.dart';
import 'voice_room.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/rows.dart';

/// The unified inbox: the recent chats, rooms and DMs alike, then the DMs
/// never opened here; the newest first.
class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository.recents,
        repository.conversations,
        repository.spaces,
        repository.unread,
        repository.mentions,
        repository.profile,
        repository.presence,
      ]),
      builder: (context, _) {
        final mentions = repository.mentions.value;
        final rows = _rows(
          repository.recents.value,
          repository.conversations.value,
          repository.spaces.value,
          repository.profile.value?.id,
          repository.presence.value,
        );
        final unread = repository.unread.value;
        return LargeTitlePage(
          title: 'Chats',
          titleTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiveIndicator(),
              IconAction(
                icon: FLucideIcons.users,
                label: 'Friends',
                onPressed: () => Navigator.of(
                  context,
                  rootNavigator: true,
                ).push(MaterialPageRoute<void>(builder: (_) => const FriendsPage())),
              ),
              IconAction(
                icon: FLucideIcons.squarePen,
                label: 'New conversation',
                onPressed: () => Navigator.of(
                  context,
                  rootNavigator: true,
                ).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const NewConversationPage())),
              ),
            ],
          ),
          header: ValueListenableBuilder(
            valueListenable: repository.status,
            builder: (context, status, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GlobalSearch(),
                // Opened from what's saved: says so, in the chrome of the list.
                if (status == LiveStatus.offline)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ConnectionBanner(text: 'Offline', detail: '· showing saved messages'),
                  ),
              ],
            ),
          ),
          onRefresh: repository.refreshConversations,
          slivers: [
            if (rows.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(icon: FLucideIcons.messageCircle, text: 'No conversations yet'),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(top: 16),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    return ListRow(
                      key: ValueKey(row.target.id),
                      leading: row.leading,
                      title: row.title,
                      hash: row.target is RoomTarget,
                      titleSuffix: row.space == null ? null : '· ${row.space}',
                      snippet: row.snippet,
                      trailing: row.at == null ? null : shortTime(row.at!),
                      unread: unread.contains(row.target.id),
                      mentions: mentions[row.target.id] ?? 0,
                      onTap: () => openChat(context, row.target, row.chatTitle),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  static List<_ChatRow> _rows(
    List<RecentChat> recents,
    List<ConversationSummary> conversations,
    List<Space> spaces,
    String? me,
    Map<String, Presence> presence,
  ) {
    final conversationsById = {for (final c in conversations) c.id: c};
    final spacesById = {for (final s in spaces) s.id: s};

    // A DM's avatar shows the other person's presence; a group's doesn't.
    Widget avatar(String title, ConversationSummary? c) => switch (c?.otherUserId) {
      final id? => PresenceAvatar(
        member: Member(userId: id, username: title, avatarUrl: c!.avatarUrl),
        presence: presence[id],
        size: 48,
      ),
      null => UserAvatar(name: title, url: c?.avatarUrl, size: 48),
    };

    // "You:" for the user's own; the author for a room or a group.
    String? preview(RecentChat chat, {required bool named}) {
      final text = chat.previewText;
      if (text == null) return null;
      if (chat.previewAuthorId != null && chat.previewAuthorId == me) return 'You: $text';
      return named && chat.previewAuthor != null ? '${chat.previewAuthor}: $text' : text;
    }

    // A room the user can't see (any more) goes, once its Space lists its
    // rooms without it.
    bool hidden(ChatTarget t) => switch (t) {
      RoomTarget(:final spaceId, :final roomId) => spacesById[spaceId]?.rooms.every((r) => r.id != roomId) ?? false,
      ConversationTarget() => false,
    };

    final listed = {for (final r in recents) r.target.id};
    final rows = [
      for (final chat in recents.where((c) => !hidden(c.target)))
        switch (chat.target) {
          RoomTarget(:final spaceId, :final roomId) => () {
            final space = spacesById[spaceId];
            final room = space?.rooms.where((r) => r.id == roomId).firstOrNull;
            final name = room?.name ?? (chat.title.startsWith('# ') ? chat.title.substring(2) : chat.title);
            return _ChatRow(
              target: chat.target,
              title: name,
              chatTitle: '# $name',
              space: space?.name,
              snippet: preview(chat, named: true),
              leading: space == null ? null : SpaceIcon(space: space),
              at: chat.at,
            );
          }(),
          ConversationTarget(:final conversationId) => () {
            final summary = conversationsById[conversationId];
            final title = summary?.title ?? chat.title;
            return _ChatRow(
              target: chat.target,
              title: title,
              chatTitle: title,
              snippet: preview(chat, named: summary?.isGroup ?? false),
              leading: avatar(title, summary),
              at: chat.at,
            );
          }(),
        },
      for (final c in conversations)
        if (!listed.contains(c.id))
          _ChatRow(
            target: c.target,
            title: c.title,
            chatTitle: c.title,
            snippet: c.isGroup ? '${c.memberCount} members' : null,
            leading: avatar(c.title, c),
            at: c.updatedAt,
          ),
    ];
    // The newest first; undated ones last, in the order they came.
    final dated = rows.where((r) => r.at != null).toList()..sort((a, b) => b.at!.compareTo(a.at!));
    return [...dated, ...rows.where((r) => r.at == null)];
  }
}

class _ChatRow {
  final ChatTarget target;
  final String title;

  /// What the Chat View's top bar shows.
  final String chatTitle;
  final String? space;
  final String? snippet;
  final Widget? leading;
  final DateTime? at;
  const _ChatRow({
    required this.target,
    required this.title,
    required this.chatTitle,
    this.space,
    this.snippet,
    this.leading,
    this.at,
  });
}

/// The Launchpad: the user's Spaces as a two-column grid of cards.
class SpacesTab extends StatelessWidget {
  const SpacesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.spaces, repository.unread, repository.status]),
      builder: (context, _) {
        final spaces = repository.spaces.value;
        final unread = repository.unread.value;
        return LargeTitlePage(
          title: 'Spaces',
          titleTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiveIndicator(),
              SpacesMenuButton(onCreate: () => showCreateSpaceSheet(context)),
            ],
          ),
          slivers: [
            if (spaces.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: repository.status.value == LiveStatus.connecting
                    ? const Center(child: FCircularProgress())
                    : const EmptyState(icon: FLucideIcons.layoutGrid, text: 'You’re not in any spaces'),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 160,
                  ),
                  itemCount: spaces.length,
                  itemBuilder: (context, i) {
                    final space = spaces[i];
                    return SpaceCard(
                      key: ValueKey(space.id),
                      space: space,
                      unread: space.rooms.any((r) => unread.contains(r.id)),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SpaceDirectory(spaceId: space.id, name: space.name),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A Space's rooms, by category: each a ChannelRow with its last message.
class SpaceDirectory extends StatefulWidget {
  final String spaceId;
  final String name;
  const SpaceDirectory({required this.spaceId, required this.name, super.key});

  @override
  State<SpaceDirectory> createState() => _SpaceDirectoryState();
}

class _SpaceDirectoryState extends State<SpaceDirectory> {
  final _scroll = ScrollController();
  final _titleAnchor = GlobalKey();
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final scrolled = _scroll.offset > 0;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final space = context.repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
    if (space != null) {
      context.repository.loadLatest([
        for (final r in space.rooms)
          if (r.kind == RoomKind.text) r.target,
      ]);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _askedNames = false;

  // Someone in voice whom the app can't name yet: the space's members name
  // them, fetched once (and cached) after this frame.
  void _nameVoice(ChatRepository repository, Room room) {
    if (_askedNames) return;
    final me = repository.profile.value?.id;
    if (!context.voice.participants(room.id).any((p) => p.userId != me && repository.nameOf(p.userId) == null)) return;
    _askedNames = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      repository.members(room.target).then((_) {
        if (mounted) setState(() {});
      }, onError: (Object _) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final colors = context.theme.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository.spaces,
        repository.unread,
        repository.latest,
        repository.profile,
        voice,
      ]),
      builder: (context, _) {
        final space = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
        final unread = repository.unread.value;
        final latest = repository.latest.value;
        final me = repository.profile.value?.id;
        final barHeight = GlassTopBar.heightOf(context);
        for (final room in space?.rooms ?? const <Room>[]) {
          if (room.kind == RoomKind.voice) _nameVoice(repository, room);
        }
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: space == null
                    ? const EmptyState(icon: FLucideIcons.layoutGrid, text: 'This space is gone')
                    : space.rooms.isEmpty
                    ? const EmptyState(icon: FLucideIcons.hash, text: 'No rooms here yet')
                    : ListView(
                        controller: _scroll,
                        padding: EdgeInsets.only(top: barHeight, bottom: MediaQuery.paddingOf(context).bottom + 16),
                        children: [
                          for (final section in space.sections)
                            if (section.rooms.isNotEmpty) ...[
                              Overline(section.name ?? 'Rooms'),
                              for (final room in section.rooms)
                                switch (room.kind) {
                                  RoomKind.text => ListRow(
                                    key: ValueKey(room.id),
                                    title: room.name,
                                    hash: true,
                                    snippet: switch (latest[room.id]) {
                                      final m? =>
                                        '${m.authorId == me ? 'You' : m.authorName}: ${repository.previewOf(m)}',
                                      null => null,
                                    },
                                    unread: unread.contains(room.id),
                                    onTap: () => openChat(context, room.target, '# ${room.name}'),
                                  ),
                                  // Who's in, the user first when their voice is here (no
                                  // accent: the tab bar has the screen's).
                                  RoomKind.voice => ListRow(
                                    key: ValueKey(room.id),
                                    leading: Icon(FLucideIcons.volume2, size: 24, color: colors.mutedForeground),
                                    title: room.name,
                                    snippet: voiceSnippet(repository, voice, room.id),
                                    detail: voice.target?.id == room.id ? 'you’re in voice here' : null,
                                    onTap: () => openVoiceRoom(context, room),
                                  ),
                                },
                            ],
                        ],
                      ),
              ),
              Positioned(
                key: _titleAnchor,
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  title: Text(space?.name ?? widget.name),
                  onTitle: space == null
                      ? null
                      : () => showSpaceMenu(_titleAnchor.currentContext ?? context, space: space),
                  titleLabel: space == null ? null : '${space.name}, Space menu',
                  hairline: _scrolled,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Who's in a voice room, for its row: "Maya, Leo and 2 more", or no one.
String voiceSnippet(ChatRepository repository, VoiceController voice, String roomId) {
  final me = repository.profile.value?.id;
  final known = {for (final m in repository.people) m.userId: m.displayName};
  final names = [
    for (final p in voice.participants(roomId))
      p.userId == me ? 'You' : known[p.userId] ?? repository.nameOf(p.userId) ?? 'Someone',
  ];
  if (voice.target?.id == roomId && !names.contains('You')) names.insert(0, 'You');
  return switch (names.length) {
    0 => 'No one’s here',
    1 || 2 => names.join(', '),
    final n => '${names.take(2).join(', ')} and ${n - 2} more',
  };
}

/// The calls this phone saw: Duvet's servers keep no call history.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return LargeTitlePage(
      title: 'Calls',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(
          'Calls on this phone. Duvet keeps no call history, so your other devices’ calls aren’t here.',
          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
        ),
      ),
      slivers: const [CallHistoryList()],
    );
  }
}

/// A spinner beside the title while the gateway connects. The client doesn't
/// report a socket dropping later, so this never claims to be connected.
class LiveIndicator extends StatelessWidget {
  const LiveIndicator({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: context.repository.status,
    builder: (context, status, _) => status == LiveStatus.connecting
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: FCircularProgress(size: .sm, semanticsLabel: 'Connecting'),
          )
        : status == LiveStatus.reconnecting
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: FCircularProgress(size: .sm, semanticsLabel: 'Reconnecting'),
          )
        : const SizedBox.shrink(),
  );
}
