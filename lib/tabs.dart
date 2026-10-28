import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'calls.dart';
import 'chat_view.dart';
import 'data/launchpad.dart';
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
import 'widgets/depth.dart';
import 'widgets/rows.dart';

/// The unified inbox: who's in voice now, then the recent chats, rooms and
/// DMs alike, then the DMs never opened here; what's new (unread, or
/// mentioning the user) above what came earlier, each the newest first.
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
        repository.friends,
        repository.typingNow,
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
        bool news(_ChatRow row) => unread.contains(row.target.id) || (mentions[row.target.id] ?? 0) > 0;
        final fresh = rows.where(news).toList();
        final earlier = rows.where((r) => !news(r)).toList();
        // What's new sits on a cushion, its snippet given a second line.
        Widget chatRow(_ChatRow row, {required bool isNew}) => ListRow(
          key: ValueKey(row.target.id),
          leading: row.leading,
          title: row.title,
          hash: row.target is RoomTarget,
          titleSuffix: row.space == null ? null : '· ${row.space}',
          snippet: typingSentence(repository.typingNow.value[row.target.id] ?? const []) ?? row.snippet,
          snippetLines: isNew ? 2 : 1,
          trailing: row.at == null ? null : shortTime(row.at!),
          unread: unread.contains(row.target.id),
          mentions: mentions[row.target.id] ?? 0,
          onTap: () => openChat(context, row.target, row.chatTitle),
        );
        // The requests to the user, counted on Friends as on the desktop's.
        final asking = repository.friends.value.incoming.length;
        return LargeTitlePage(
          title: 'Chats',
          titleTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiveIndicator(),
              IconAction(
                icon: FLucideIcons.users,
                label: switch (asking) {
                  0 => 'Friends',
                  1 => 'Friends, 1 friend request',
                  _ => 'Friends, $asking friend requests',
                },
                badge: asking,
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
            const SliverToBoxAdapter(child: _InVoiceNow()),
            if (rows.isEmpty)
              const SliverFillRemaining(hasScrollBody: false, child: EmptyState(text: 'No conversations yet'))
            else ...[
              if (fresh.isNotEmpty) ...[
                const SliverToBoxAdapter(child: Overline('New')),
                SliverList.builder(
                  itemCount: fresh.length,
                  itemBuilder: (context, i) => chatRow(fresh[i], isNew: true),
                ),
              ],
              if (earlier.isNotEmpty) ...[
                // With nothing new, there's nothing to set the rest apart from.
                SliverToBoxAdapter(child: fresh.isEmpty ? const SizedBox(height: 16) : const Overline('Earlier')),
                SliverList.builder(
                  itemCount: earlier.length,
                  itemBuilder: (context, i) => chatRow(earlier[i], isNew: false),
                ),
              ],
            ],
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

/// "In voice now": every Space's voice rooms with someone in, as a strip of
/// cards under the search field; nothing while they're all quiet. A card
/// opens its room, as the room's row in its Space does.
class _InVoiceNow extends StatelessWidget {
  const _InVoiceNow();

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    return ListenableBuilder(
      listenable: Listenable.merge([voice, repository.spaces, repository.profile]),
      builder: (context, _) {
        final live = [
          for (final space in repository.spaces.value)
            for (final room in space.rooms)
              if (room.kind == RoomKind.voice)
                if (voicePeople(repository, voice, room.id) case final people when people.isNotEmpty)
                  (space: space, room: room, people: people),
        ];
        if (live.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Overline('In voice now'),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // Room for the cards' shadows under them.
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  for (final (i, (:space, :room, :people)) in live.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    _VoiceNowCard(key: ValueKey(room.id), space: space, room: room, people: people),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A voice room in "In voice now": the first few faces in it, overlapping,
/// beside the room's name after an ice dot and "Design Guild · 3 in voice".
class _VoiceNowCard extends StatelessWidget {
  final Space space;
  final Room room;
  final List<VoicePerson> people;
  const _VoiceNowCard({required this.space, required this.room, required this.people, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final count = '${people.length} in voice';
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    void open() => openVoiceRoom(context, room);
    return Semantics(
      container: true,
      button: true,
      label:
          '${room.name}, voice room in ${space.name}, $count: ${voiceSnippet(context.repository, context.voice, room.id)}',
      excludeSemantics: true,
      onTap: open,
      child: Pressable(
        onTap: open,
        scale: 0.98,
        builder: (context, pressed) => AnimatedContainer(
          duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
          constraints: const BoxConstraints(maxWidth: 260, minHeight: DuvetTokens.sizeRow - 12),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: radius,
            boxShadow: pressed ? null : tokens.shadowRest,
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : tokens.cushion,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Faces(people: people),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _AliveDot(),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                room.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.rowTitleUnread.copyWith(fontSize: 15, color: colors.foreground),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${space.name} · $count',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The first three faces in a voice room, each overlapping the one before
/// it, ringed in the card they sit on.
class _Faces extends StatelessWidget {
  final List<VoicePerson> people;
  const _Faces({required this.people});

  static const _size = 28.0;
  static const _overlap = 8.0;

  @override
  Widget build(BuildContext context) {
    final card = context.theme.colors.card;
    final shown = people.take(3).toList();
    return SizedBox(
      width: _size + (shown.length - 1) * (_size - _overlap) + 4,
      height: _size + 4,
      child: Stack(
        children: [
          for (final (i, p) in shown.indexed)
            Positioned(
              left: i * (_size - _overlap),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: card, shape: BoxShape.circle),
                child: UserAvatar(name: p.name, url: p.avatarUrl, size: _size),
              ),
            ),
        ],
      ),
    );
  }
}

/// The ice dot of what's alive: someone online, someone in voice.
class _AliveDot extends StatelessWidget {
  const _AliveDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: context.duvet.alive, shape: BoxShape.circle),
  );
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
        final prefs = LaunchpadScope.of(context).value;
        final spaces = sortedSpaces(repository.spaces.value, prefs.sort);
        final unread = repository.unread.value;
        bool news(Space space) => space.rooms.any((r) => unread.contains(r.id));
        void open(Space space) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SpaceDirectory(spaceId: space.id, name: space.name),
          ),
        );
        return LargeTitlePage(
          title: 'Spaces',
          titleTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiveIndicator(),
              const LaunchpadOptionsButton(),
              SpacesMenuButton(onCreate: () => showCreateSpaceSheet(context)),
            ],
          ),
          slivers: [
            if (spaces.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: repository.status.value == LiveStatus.connecting
                    ? const Center(child: FCircularProgress())
                    : const EmptyState(text: 'You’re not in any spaces'),
              )
            else
              switch (prefs.view) {
                SpaceView.grid => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 160,
                    ),
                    itemCount: spaces.length,
                    itemBuilder: (context, i) => SpaceCard(
                      key: ValueKey(spaces[i].id),
                      space: spaces[i],
                      unread: news(spaces[i]),
                      onTap: () => open(spaces[i]),
                    ),
                  ),
                ),
                SpaceView.list => SliverPadding(
                  padding: const EdgeInsets.only(top: 8),
                  sliver: SliverList.builder(
                    itemCount: spaces.length,
                    itemBuilder: (context, i) => ListRow(
                      key: ValueKey(spaces[i].id),
                      leading: SpaceIcon(space: spaces[i]),
                      title: spaces[i].name,
                      snippet: switch (spaces[i].onlineCount) {
                        final n? => '$n online',
                        null => null,
                      },
                      unread: news(spaces[i]),
                      onTap: () => open(spaces[i]),
                    ),
                  ),
                ),
                SpaceView.cards => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverList.separated(
                    itemCount: spaces.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => SpaceWideCard(
                      key: ValueKey(spaces[i].id),
                      space: spaces[i],
                      unread: news(spaces[i]),
                      onTap: () => open(spaces[i]),
                    ),
                  ),
                ),
              },
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
        repository.collapsedCategories,
        repository.typingNow,
        voice,
      ]),
      builder: (context, _) {
        final space = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
        final collapsed = repository.collapsedCategories.value;
        final unread = repository.unread.value;
        final latest = repository.latest.value;
        final me = repository.profile.value?.id;
        final barHeight = GlassTopBar.heightOf(context);
        for (final room in space?.rooms ?? const <Room>[]) {
          if (room.kind == RoomKind.voice) _nameVoice(repository, room);
        }
        // The voice rooms with someone in take the stage, above the rest.
        final staged = {
          for (final section in space?.sections ?? const <RoomSection>[])
            for (final room in section.rooms)
              if (room.kind == RoomKind.voice)
                if (voicePeople(repository, voice, room.id) case final people when people.isNotEmpty) room: people,
        };
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: space == null
                    ? const EmptyState(icon: FLucideIcons.layoutGrid, text: 'This space is gone')
                    : space.sections.isEmpty && space.bannerUrl == null
                    ? const EmptyState(text: 'No rooms here yet')
                    : ListView(
                        controller: _scroll,
                        // A list with its own controller only scrolls once full; a short one bounces too.
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.only(top: barHeight, bottom: MediaQuery.paddingOf(context).bottom + 16),
                        children: [
                          if (space.bannerUrl case final banner?)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: SpaceBanner(key: ValueKey(banner), url: banner),
                            ),
                          _SpaceHeader(space: space),
                          for (final MapEntry(key: room, value: people) in staged.entries)
                            _VoiceStage(key: ValueKey('stage-${room.id}'), room: room, people: people, voice: voice),
                          if (space.sections.isEmpty)
                            const SizedBox(height: 240, child: EmptyState(text: 'No rooms here yet')),
                          for (final (i, section) in space.sections.indexed) ...[
                            // Outside any category: a plain header. A category
                            // folds away, empty ones too.
                            if (section.id case final id?)
                              CategoryHeader(
                                key: ValueKey('category-$id'),
                                name: section.name ?? '',
                                collapsed: collapsed.contains(id),
                                unread: section.rooms.any((r) => unread.contains(r.id)),
                                onToggle: () => repository.setCategoryCollapsed(id, !collapsed.contains(id)),
                              )
                            else if (section.rooms.any((r) => !staged.containsKey(r)))
                              Overline(section.name ?? 'Rooms'),
                            CategoryFold(
                              key: ValueKey('fold-${section.id ?? i}'),
                              open: !collapsed.contains(section.id),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final room in section.rooms)
                                    if (!staged.containsKey(room))
                                      switch (room.kind) {
                                        RoomKind.text => ListRow(
                                          key: ValueKey(room.id),
                                          title: room.name,
                                          hash: true,
                                          snippet:
                                              typingSentence(repository.typingNow.value[room.id] ?? const []) ??
                                              switch (latest[room.id]) {
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
                                          leading: _VoiceRoomMark(live: voice.participants(room.id).isNotEmpty),
                                          title: room.name,
                                          snippet: voiceSnippet(repository, voice, room.id),
                                          detail: voice.target?.id == room.id ? 'you’re in voice here' : null,
                                          onTap: () => openVoiceRoom(context, room),
                                        ),
                                      },
                                ],
                              ),
                            ),
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

/// A Space's face at the top of its rooms: its icon, its name and who's
/// online.
class _SpaceHeader extends StatelessWidget {
  final Space space;
  const _SpaceHeader({required this.space});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final online = space.onlineCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          SpaceIcon(space: space, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  space.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.title.copyWith(color: colors.foreground),
                ),
                if (online != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const _AliveDot(),
                      const SizedBox(width: 6),
                      Text('$online online', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A voice room with someone in, on the stage above its Space's rooms: an
/// ice dot, its name and how many are in (a tap opens the room), each face
/// with its name, ringed in ice while they speak, and Join voice; once the
/// user's voice is there, a note saying so instead.
class _VoiceStage extends StatelessWidget {
  final Room room;
  final List<VoicePerson> people;
  final VoiceController voice;
  const _VoiceStage({required this.room, required this.people, required this.voice, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final here = voice.target?.id == room.id;
    final count = '${people.length} in voice';
    void open() => openVoiceRoom(context, room);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Cushion(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              button: true,
              label: [room.name, count, if (here) 'you’re in voice here'].join(', '),
              excludeSemantics: true,
              onTap: open,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: open,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      const _AliveDot(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.rowTitleUnread.copyWith(color: colors.foreground),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(count, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                      Icon(FLucideIcons.chevronRight, size: 18, color: colors.mutedForeground),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Levels are read only for the user's own voice, and only watched
            // where it is.
            if (here)
              ValueListenableBuilder(
                valueListenable: voice.levels,
                builder: (context, levels, _) => _StageFaces(people: people, levels: levels),
              )
            else
              _StageFaces(people: people, levels: const {}),
            const SizedBox(height: 16),
            if (here)
              Text('You’re in voice here', style: DuvetType.caption.copyWith(color: colors.mutedForeground))
            else
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: JoinVoiceButton(room: room, voice: voice, onJoin: open),
              ),
          ],
        ),
      ),
    );
  }
}

/// The faces on a voice stage, each over its name.
class _StageFaces extends StatelessWidget {
  final List<VoicePerson> people;
  final Map<String, double> levels;
  const _StageFaces({required this.people, required this.levels});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Wrap(
      spacing: 14,
      runSpacing: 12,
      children: [
        for (final p in people)
          () {
            final speaking = (levels[p.id] ?? 0) > 0 && !p.muted;
            return Semantics(
              key: ValueKey(p.id),
              container: true,
              label: [
                p.isMe ? '${p.name} (you)' : p.name,
                if (p.deafened) 'deafened' else if (p.muted) 'muted',
                if (speaking) 'speaking',
              ].join(', '),
              excludeSemantics: true,
              child: SizedBox(
                width: 64,
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
                      padding: const EdgeInsets.all(2.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: speaking ? tokens.alive : Colors.transparent, width: 2.5),
                        boxShadow: speaking
                            ? [BoxShadow(color: tokens.alive.withValues(alpha: 0.35), blurRadius: 14)]
                            : null,
                      ),
                      child: UserAvatar(name: p.name, url: p.avatarUrl, size: 52),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }
}

/// A voice room's mark in its row: a small cushion with a speaker, ice while
/// someone's in.
class _VoiceRoomMark extends StatelessWidget {
  final bool live;
  const _VoiceRoomMark({required this.live});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return SizedBox.square(
      dimension: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(color: live ? tokens.chosen : colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: live ? tokens.cushion : tokens.shadowWell,
          borderRadius: radius,
          child: Icon(
            live ? FLucideIcons.audioLines : FLucideIcons.volume2,
            size: 22,
            color: live ? tokens.alive : colors.mutedForeground,
          ),
        ),
      ),
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
