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
import 'shell.dart';
import 'spaces.dart';
import 'theme.dart';
import 'voice_room.dart';
import 'widgets/avatar.dart';
import 'widgets/call_presence.dart';
import 'widgets/chrome.dart';
import 'widgets/duvet_mascot.dart';
import 'widgets/glass.dart';
import 'widgets/ghost_art.dart';
import 'widgets/notification_menu.dart';
import 'widgets/now.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderNames, placeholderRows;
import 'widgets/skeleton.dart' show Bone;

/// The unified inbox: the recent chats, rooms and DMs alike, then the DMs
/// never opened here; the newest first.
class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final shell = Shell.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository.recents,
        repository.conversations,
        repository.spaces,
        repository.unread,
        repository.mentions,
        repository.notificationLevels,
        repository.profile,
        repository.presence,
        repository.mobileOnly,
        repository.friends,
        repository.pinnedChats,
        repository.typingNow,
        repository.status,
        voice,
        // The chat open in the wide layout's pane: its row is marked.
        ?shell,
      ]),
      builder: (context, _) {
        final rows = _rows(
          repository.recents.value,
          repository.conversations.value,
          repository.spaces.value,
          repository.profile.value?.id,
          repository.presence.value,
          repository.mobileOnly.value,
          repository.pinnedChats.value,
        );
        // The requests to the user, counted on Friends as on the desktop's.
        final asking = repository.friends.value.incoming.length;
        return LargeTitlePage(
          title: 'Chats',
          titleLeading: const AppIcon(size: 32),
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
                const OnlineFriends(),
                const GlobalSearch(),
                // Opened from what's saved: says so, in the chrome of the list.
                if (status == LiveStatus.offline)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: ConnectionBanner(text: 'Offline', detail: '· showing saved messages'),
                  ),
                // Calls going on in the user's conversations, as their chat's
                // CallBanner has them; not the user's own still ringing the
                // others from another device: nothing to join yet.
                // Not the call the user is in: the voice bar already shows that one.
                for (final id in joinableCalls(
                  voice.callsInProgress,
                  (id) =>
                      callingElsewhere(voice, id) ||
                      (voice.call?.conversationId == id && voice.call?.phase != CallPhase.ringing),
                ))
                  Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: _ongoingCall(context, id)),
                const NowBlock(),
              ],
            ),
          ),
          onRefresh: repository.refreshConversations,
          slivers: [
            if (rows.isEmpty && repository.status.value == LiveStatus.connecting)
              SliverPadding(
                padding: const EdgeInsets.only(top: 16),
                sliver: SliverToBoxAdapter(
                  child: LoadingSkeleton(label: 'Loading chats', children: placeholderRows(avatar: 48)),
                ),
              )
            else if (rows.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(mascot: MascotState.empty, text: 'No conversations yet'),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(top: 16),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  // Rows keep their elements as the list moves (a message elsewhere), so a menu open on one keeps its
                  // anchor.
                  findChildIndexCallback: (key) {
                    final i = rows.indexWhere((r) => key == ValueKey(r.target.id));
                    return i < 0 ? null : i;
                  },
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    // The row's own context anchors its menu.
                    return Builder(
                      key: ValueKey(row.target.id),
                      builder: (rowContext) => ListRow(
                        leading: row.leading,
                        title: row.title,
                        hash: row.target is RoomTarget,
                        titleSuffix: row.space == null ? null : '· ${row.space}',
                        snippet: typingSentence(repository.typingNow.value[row.target.id] ?? const []) ?? row.snippet,
                        trailing: row.at == null ? null : shortTime(row.at!),
                        unread: repository.shownUnread(row.target.id),
                        selected: shell?.openId == row.target.id,
                        mentions: repository.shownMentions(row.target.id),
                        detail: row.pinned ? 'pinned' : null,
                        titleIcon: row.pinned
                            ? Icon(FLucideIcons.pin, size: 14, color: context.theme.colors.mutedForeground)
                            : null,
                        onTap: () => openChat(context, row.target, row.chatTitle),
                        onLongPress: () async {
                          final action = await showGlassMenu<String>(
                            rowContext,
                            label: row.title,
                            items: [
                              GlassMenuItem(
                                icon: row.pinned ? FLucideIcons.pinOff : FLucideIcons.pin,
                                label: row.pinned ? 'Unpin' : 'Pin to top',
                                value: 'pin',
                              ),
                              const GlassMenuItem(
                                icon: FLucideIcons.bell,
                                label: 'Notifications',
                                value: 'notifications',
                              ),
                            ],
                          );
                          if (action == 'pin') repository.setChatPinned(pinKey(row.target), !row.pinned);
                          if (action == 'notifications' && rowContext.mounted) {
                            await showNotificationMenu(
                              rowContext,
                              targetId: row.target.id,
                              target: switch (row.target) {
                                RoomTarget() => NotificationTarget.room,
                                ConversationTarget() => NotificationTarget.conversation,
                              },
                              spaceId: switch (row.target) {
                                RoomTarget(:final spaceId) => spaceId,
                                ConversationTarget() => null,
                              },
                            );
                          }
                        },
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

  static Widget _ongoingCall(BuildContext context, String conversationId) {
    final repository = context.repository;
    final voice = context.voice;
    final summary = repository.conversations.value.where((c) => c.id == conversationId).firstOrNull;
    final title = summary?.title ?? 'Call';
    return CallPresenceCard(
      key: ValueKey('call-$conversationId'),
      icon: FLucideIcons.phoneCall,
      leading: switch (summary) {
        null => null,
        ConversationSummary(otherUserId: null) => const GroupMark(),
        _ => UserAvatar(name: title, url: summary.avatarUrl, size: 40),
      },
      title: title,
      detail: voice.participants(conversationId).isEmpty
          ? 'Call in progress'
          : voiceSnippet(repository, voice, conversationId),
      onJoin: () => callConversation(context, conversationId),
    );
  }

  static List<_ChatRow> _rows(
    List<RecentChat> recents,
    List<ConversationSummary> conversations,
    List<Space> spaces,
    String? me,
    Map<String, Presence> presence,
    Set<String> mobileOnly,
    Set<String> pinned,
  ) {
    final conversationsById = {for (final c in conversations) c.id: c};
    final spacesById = {for (final s in spaces) s.id: s};

    // A DM's avatar shows the other person's presence. A group, or a
    // conversation not loaded yet, has no one's face: its mark, as the
    // desktop's chats have it.
    Widget avatar(String title, ConversationSummary? c) => switch (c?.otherUserId) {
      final id? => PresenceAvatar(
        member: Member(userId: id, username: title, avatarUrl: c!.avatarUrl),
        presence: presence[id],
        mobileOnly: mobileOnly.contains(id),
        size: 48,
      ),
      null => const GroupMark(size: 48),
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
    // A pinned room that dropped out of the recents comes back from its Space,
    // if the user still sees it.
    final shown = {for (final r in rows) r.target.id};
    for (final key in pinned) {
      if (!key.startsWith('room:') || shown.contains(key.substring(5))) continue;
      for (final space in spaces) {
        final room = space.rooms.where((r) => r.id == key.substring(5) && r.kind == RoomKind.text).firstOrNull;
        if (room == null) continue;
        rows.add(
          _ChatRow(
            target: room.target,
            title: room.name,
            chatTitle: '# ${room.name}',
            space: space.name,
            leading: SpaceIcon(space: space),
          ),
        );
        break;
      }
    }
    // Pinned first, then the newest; undated ones last, in the order they came.
    final dated = rows.where((r) => r.at != null).toList()..sort((a, b) => b.at!.compareTo(a.at!));
    final ordered = [...dated, ...rows.where((r) => r.at == null)];
    final isPinned = {
      for (final r in ordered)
        if (pinned.contains(pinKey(r.target))) r,
    };
    return [
      for (final r in ordered.where(isPinned.contains)) r.pinnedRow(),
      ...ordered.where((r) => !isPinned.contains(r)),
    ];
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
  final bool pinned;
  const _ChatRow({
    required this.target,
    required this.title,
    required this.chatTitle,
    this.space,
    this.snippet,
    this.leading,
    this.at,
    this.pinned = false,
  });

  _ChatRow pinnedRow() => _ChatRow(
    target: target,
    title: title,
    chatTitle: chatTitle,
    space: space,
    snippet: snippet,
    leading: leading,
    at: at,
    pinned: true,
  );
}

/// Names a [SpaceDirectory]'s route, before its Space's ID: the wide layout's rail marks the Space open.
const spaceRoutePrefix = 'space:';

/// A Space's directory in the Spaces tab; [instant] from the rail, which swaps one for another.
Route<void> spaceRoute(Space space, {bool instant = false}) {
  final settings = RouteSettings(name: '$spaceRoutePrefix${space.id}');
  Widget page(BuildContext _) => SpaceDirectory(spaceId: space.id, name: space.name);
  return instant
      ? PageRouteBuilder<void>(
          settings: settings,
          transitionDuration: Duration.zero,
          pageBuilder: (context, _, _) => page(context),
        )
      : MaterialPageRoute<void>(settings: settings, builder: page);
}

/// The Launchpad: the user's Spaces as a two-column grid of cards.
class SpacesTab extends StatelessWidget {
  const SpacesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository.spaces,
        repository.unread,
        repository.notificationLevels,
        repository.status,
      ]),
      builder: (context, _) {
        final prefs = LaunchpadScope.of(context).value;
        final spaces = sortedSpaces(repository.spaces.value, prefs.sort);
        bool news(Space space) => space.rooms.any((r) => repository.shownUnread(r.id));
        // A long press chooses the Space's notifications, under its own card or row.
        void notifications(BuildContext anchor, Space space) =>
            showNotificationMenu(anchor, targetId: space.id, target: NotificationTarget.space);
        void open(Space space) => Navigator.of(context).push(spaceRoute(space));
        // While the first READY comes: the chosen view's own tiles, as bones.
        final placeholders = [
          for (final (i, name) in placeholderNames.indexed) Space(id: 'placeholder-$i', name: name, onlineCount: 12),
        ];
        void none() {}
        return LargeTitlePage(
          title: 'Spaces',
          titleLeading: const AppIcon(size: 32),
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
              repository.status.value == LiveStatus.connecting
                  ? SliverToBoxAdapter(
                      child: LoadingSkeleton(
                        label: 'Loading spaces',
                        children: [
                          switch (prefs.view) {
                            SpaceView.grid => Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: Column(
                                spacing: 12,
                                children: [
                                  for (var i = 0; i < placeholders.length; i += 2)
                                    Row(
                                      spacing: 12,
                                      children: [
                                        for (final space in placeholders.skip(i).take(2))
                                          Expanded(
                                            child: SpaceCard(space: space, onTap: none),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                            SpaceView.list => Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                children: [
                                  for (final space in placeholders)
                                    ListRow(
                                      leading: const Bone.square(
                                        size: 48,
                                        borderRadius: BorderRadius.all(Radius.circular(DuvetTokens.radiusField)),
                                      ),
                                      title: space.name,
                                      snippet: '12 online',
                                    ),
                                ],
                              ),
                            ),
                            SpaceView.cards => Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: Column(
                                spacing: 12,
                                children: [for (final space in placeholders) SpaceWideCard(space: space, onTap: none)],
                              ),
                            ),
                          },
                        ],
                      ),
                    )
                  : const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(mascot: MascotState.empty, text: 'You’re not in any spaces'),
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
                    itemBuilder: (context, i) => Builder(
                      key: ValueKey(spaces[i].id),
                      builder: (cardContext) => SpaceCard(
                        space: spaces[i],
                        unread: news(spaces[i]),
                        onTap: () => open(spaces[i]),
                        onLongPress: () => notifications(cardContext, spaces[i]),
                      ),
                    ),
                  ),
                ),
                SpaceView.list => SliverPadding(
                  padding: const EdgeInsets.only(top: 8),
                  sliver: SliverList.builder(
                    itemCount: spaces.length,
                    itemBuilder: (context, i) => Builder(
                      key: ValueKey(spaces[i].id),
                      builder: (rowContext) => ListRow(
                        leading: SpaceIcon(space: spaces[i]),
                        title: spaces[i].name,
                        snippet: switch (spaces[i].onlineCount) {
                          final n? => '$n online',
                          null => null,
                        },
                        unread: news(spaces[i]),
                        onTap: () => open(spaces[i]),
                        onLongPress: () => notifications(rowContext, spaces[i]),
                      ),
                    ),
                  ),
                ),
                SpaceView.cards => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  sliver: SliverList.separated(
                    itemCount: spaces.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => Builder(
                      key: ValueKey(spaces[i].id),
                      builder: (cardContext) => SpaceWideCard(
                        space: spaces[i],
                        unread: news(spaces[i]),
                        onTap: () => open(spaces[i]),
                        onLongPress: () => notifications(cardContext, spaces[i]),
                      ),
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
    final shell = Shell.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        ?shell,
        repository.spaces,
        repository.unread,
        repository.notificationLevels,
        repository.latest,
        repository.profile,
        repository.collapsedCategories,
        repository.typingNow,
        voice,
      ]),
      builder: (context, _) {
        final space = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
        final collapsed = repository.collapsedCategories.value;
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
                    : space.sections.isEmpty && space.bannerUrl == null
                    ? const EmptyState(icon: FLucideIcons.hash, text: 'No rooms here yet')
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
                          // Voice going on here, above the rooms, to join; not the
                          // room the user is in: the voice bar already shows that one.
                          for (final room in space.rooms)
                            if (room.kind == RoomKind.voice &&
                                voice.target?.id != room.id &&
                                voice.participants(room.id).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: CallPresenceCard(
                                  key: ValueKey('voice-${room.id}'),
                                  icon: FLucideIcons.volume2,
                                  title: room.name,
                                  detail: voiceSnippet(repository, voice, room.id),
                                  onJoin: voice.canJoin(room)
                                      ? () {
                                          voice.joinRoom(room);
                                          openVoiceRoom(context, room);
                                        }
                                      : null,
                                ),
                              ),
                          if (space.sections.isEmpty)
                            const SizedBox(
                              height: 240,
                              child: EmptyState(icon: FLucideIcons.hash, text: 'No rooms here yet'),
                            ),
                          for (final (i, section) in space.sections.indexed) ...[
                            // Outside any category: a plain header. A category
                            // folds away, empty ones too.
                            if (section.id case final id?)
                              CategoryHeader(
                                key: ValueKey('category-$id'),
                                name: section.name ?? '',
                                collapsed: collapsed.contains(id),
                                unread: section.rooms.any((r) => repository.shownUnread(r.id)),
                                onToggle: () => repository.setCategoryCollapsed(id, !collapsed.contains(id)),
                              )
                            else if (section.rooms.isNotEmpty)
                              Overline(section.name ?? 'Rooms'),
                            CategoryFold(
                              key: ValueKey('fold-${section.id ?? i}'),
                              open: !collapsed.contains(section.id),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final room in section.rooms)
                                    switch (room.kind) {
                                      // A long press chooses its notifications, under its own row.
                                      RoomKind.text => Builder(
                                        key: ValueKey(room.id),
                                        builder: (rowContext) => ListRow(
                                          title: room.name,
                                          hash: true,
                                          snippet:
                                              typingSentence(repository.typingNow.value[room.id] ?? const []) ??
                                              switch (latest[room.id]) {
                                                final m? =>
                                                  '${m.authorId == me ? 'You' : m.authorName}: ${repository.previewOf(m)}',
                                                null => null,
                                              },
                                          unread: repository.shownUnread(room.id),
                                          selected: shell?.openId == room.id,
                                          onTap: () => openChat(context, room.target, '# ${room.name}'),
                                          onLongPress: () => showNotificationMenu(
                                            rowContext,
                                            targetId: room.id,
                                            target: NotificationTarget.room,
                                            spaceId: room.spaceId,
                                          ),
                                        ),
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

/// Who's in a voice room, for its row: "Maya, Leo and 2 more", or no one,
/// then what is live there, as Now's room cards say it: "· sharing screen".
String voiceSnippet(ChatRepository repository, VoiceController voice, String roomId) {
  final me = repository.profile.value?.id;
  final known = {for (final m in repository.people) m.userId: m.displayName};
  final people = voice.participants(roomId);
  final names = [
    for (final p in people) p.userId == me ? 'You' : known[p.userId] ?? repository.nameOf(p.userId) ?? 'Someone',
  ];
  if (voice.target?.id == roomId && !names.contains('You')) names.insert(0, 'You');
  final live = switch (liveIn(people)) {
    NowLive.screen => ' · sharing screen',
    NowLive.camera => ' · camera on',
    null => '',
  };
  return switch (names.length) {
        0 => 'No one’s here',
        1 || 2 => names.join(', '),
        final n => '${names.take(2).join(', ')} and ${n - 2} more',
      } +
      live;
}

/// The calls this phone saw: Duvet's servers keep no call history.
class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return LargeTitlePage(
      title: 'Calls',
      titleLeading: const AppIcon(size: 32),
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
