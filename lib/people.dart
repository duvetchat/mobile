import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/scope.dart';
import 'members_sheet.dart' show MemberAction, PresenceAvatar;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// What a presence reads as; nothing when it isn't known.
String presenceText(Presence? p) => switch (p) {
  Presence.online => 'Online',
  Presence.doNotDisturb => 'Do not disturb',
  Presence.offline => 'Offline',
  null => '',
};

/// Someone's profile, in a glass sheet: banner, avatar, presence, name, what
/// they wrote, their roles in the Space; Message, Mention, Add friend.
/// Answers Mention or Message when the caller handles them.
Future<MemberAction?> showProfileSheet(
  BuildContext context, {
  required Member member,
  String? spaceId,
  bool canMention = false,
}) => showGlassSheet<MemberAction>(
  context,
  label: '${member.displayName}’s profile',
  initialSize: 0.72,
  builder: (context, scroll) => _Profile(member: member, spaceId: spaceId, canMention: canMention, scroll: scroll),
);

class _Profile extends StatefulWidget {
  final Member member;
  final String? spaceId;
  final bool canMention;
  final ScrollController scroll;
  const _Profile({required this.member, required this.spaceId, required this.canMention, required this.scroll});

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.repository.loadFriends().catchError((Object e) => debugPrint('friends: $e'));
  }

  Future<void> _message() async {
    final repository = context.repository;
    final sheet = Navigator.of(context);
    final root = Navigator.of(context, rootNavigator: true);
    try {
      final dm = await repository.directMessage(widget.member.userId);
      sheet.pop();
      root.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatView(target: dm.target, title: dm.title),
        ),
      );
    } catch (e) {
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : 'Couldn’t open a conversation'),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _addFriend() async {
    try {
      await context.repository.sendFriendRequest(widget.member.userId);
      if (mounted) setState(() => _asked = true);
    } catch (_) {
      if (mounted) {
        showFToast(
          context: context,
          title: const Text('Couldn’t send the request'),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    // The friends list has no bio or banner: a DM's or a Space's members do.
    final known = repository.people.where((p) => p.userId == widget.member.userId).firstOrNull;
    final m = known == null
        ? widget.member
        : Member(
            userId: widget.member.userId,
            username: widget.member.username,
            alias: widget.member.alias,
            avatarUrl: widget.member.avatarUrl,
            isBot: widget.member.isBot,
            bio: widget.member.bio ?? known.bio,
            bannerUrl: widget.member.bannerUrl ?? known.bannerUrl,
          );
    final me = repository.profile.value?.id == m.userId;
    final roles = widget.spaceId == null ? const <RoleTag>[] : repository.rolesOf(widget.spaceId!, m.userId);
    final spaceName = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull?.name;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.presence, repository.friends]),
      builder: (context, _) {
        final presence = repository.presence.value[m.userId];
        final f = repository.friends.value;
        final isFriend = f.friends.any((x) => x.userId == m.userId);
        final pending = _asked || f.outgoing.any((r) => r.person.userId == m.userId);
        final mutual = repository.spaces.value.where((s) => repository.isMember(s.id, m.userId)).length;
        return ListView(
          controller: widget.scroll,
          padding: EdgeInsets.zero,
          children: [
            // Their banner, or a soft block until they set one.
            SizedBox(
              height: 120,
              child: m.bannerUrl == null
                  ? ColoredBox(color: colors.secondary)
                  : Image.network(
                      m.bannerUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(color: colors.secondary),
                    ),
            ),
            Transform.translate(
              offset: const Offset(0, -40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: colors.background, width: 4),
                            boxShadow: tokens.shadowRaised,
                          ),
                          child: ExcludeSemantics(
                            child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 80),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (presence != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Container(
                              height: 28,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: colors.secondary,
                                borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PresenceAvatar.dotFor(context, presence, 10),
                                  const SizedBox(width: 6),
                                  Text(
                                    presenceText(presence),
                                    style: DuvetType.caption.copyWith(color: colors.foreground),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      header: true,
                      child: Text(m.displayName, style: DuvetType.title.copyWith(color: colors.foreground)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ['@${m.username}', if (m.isBot) 'bot'].join(' · '),
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                    if (!me) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: DuvetButton(
                              label: 'Message',
                              icon: FLucideIcons.messageCircle,
                              variant: ButtonVariant.primary,
                              expand: true,
                              onPressed: widget.canMention
                                  ? () => Navigator.of(context).pop(MemberAction.message)
                                  : _message,
                            ),
                          ),
                          if (widget.canMention) ...[
                            const SizedBox(width: 8),
                            _SquareButton(
                              label: 'Mention ${m.displayName}',
                              icon: FLucideIcons.atSign,
                              onPressed: () => Navigator.of(context).pop(MemberAction.mention),
                            ),
                          ],
                          if (!m.isBot) ...[
                            const SizedBox(width: 8),
                            _SquareButton(
                              label: isFriend
                                  ? 'Friends'
                                  : pending
                                  ? 'Friend request sent'
                                  : 'Add friend',
                              icon: isFriend
                                  ? FLucideIcons.userCheck
                                  : pending
                                  ? FLucideIcons.clock
                                  : FLucideIcons.userPlus,
                              onPressed: isFriend || pending ? null : _addFriend,
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                        boxShadow: tokens.shadowRest,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Label('About'),
                          const SizedBox(height: 4),
                          Text(
                            m.bio ?? 'Nothing here yet.',
                            style: DuvetType.body.copyWith(
                              color: m.bio == null ? colors.mutedForeground : colors.foreground,
                            ),
                          ),
                          if (roles.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _Label('Roles in ${spaceName ?? 'this Space'}'),
                            const SizedBox(height: 8),
                            Wrap(spacing: 8, runSpacing: 8, children: [for (final r in roles) RoleChip(role: r)]),
                          ],
                          if (!me && mutual > 0) ...[
                            const SizedBox(height: 16),
                            _Label('Mutual Spaces'),
                            Text('$mutual', style: DuvetType.body.copyWith(color: colors.foreground)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text.toUpperCase(), style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground)),
  );
}

/// A role, as a flat chip; its color as a small square beside the name.
class RoleChip extends StatelessWidget {
  final RoleTag role;
  const RoleChip({required this.role, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(DuvetTokens.radiusChip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (role.color case final c?) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: Color(c), borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 6),
          ],
          Text(role.name, style: DuvetType.caption.copyWith(color: colors.foreground)),
        ],
      ),
    );
  }
}

/// A secondary button holding just an icon, 48pt square.
class _SquareButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const _SquareButton({required this.label, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    final ink = onPressed == null ? colors.mutedForeground : tokens.accentText;
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) => Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: ink),
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : const [],
            borderRadius: radius,
            child: Icon(icon, size: 22, color: ink),
          ),
        ),
      ),
    );
  }
}

/// A square check: `accent` when on. (Circles are for people.)
class SquareCheck extends StatelessWidget {
  final bool checked;
  const SquareCheck({required this.checked, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return AnimatedContainer(
      duration: DuvetTokens.pressOut,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: checked ? Duvet.accent : null,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
        border: Border.all(color: checked ? Duvet.accent : colors.mutedForeground, width: 1.5),
      ),
      child: checked ? Icon(FLucideIcons.check, size: 16, color: colors.primaryForeground) : null,
    );
  }
}

// -----------------------------------------------------------------------------
// Friends
// -----------------------------------------------------------------------------

enum _FriendsTab { all, pending, sent }

/// Friends: add one by username, then everyone, the requests to the user,
/// and theirs.
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final _add = TextEditingController();
  _FriendsTab _tab = _FriendsTab.all;
  bool _loading = true;
  String? _addError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) {
      context.repository
          .loadFriends()
          .whenComplete(() {
            if (mounted) setState(() => _loading = false);
          })
          .catchError((Object e) => debugPrint('friends: $e'));
    }
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _addByName() async {
    final repository = context.repository;
    final name = _add.text.trim().replaceFirst('@', '').toLowerCase();
    if (name.isEmpty) return;
    final person = repository.people.where((p) => p.username.toLowerCase() == name).firstOrNull;
    if (person == null) {
      setState(() => _addError = 'No one called @$name shares a Space or a chat with you');
      return;
    }
    try {
      await repository.sendFriendRequest(person.userId);
      _add.clear();
      setState(() => _addError = null);
      if (mounted) {
        showFToast(context: context, title: Text('Asked ${person.displayName}'), duration: const Duration(seconds: 3));
      }
    } catch (_) {
      setState(() => _addError = 'Couldn’t send the request');
    }
  }

  Future<void> _act(Future<void> Function() action, String failure) async {
    try {
      await action();
    } catch (_) {
      if (mounted) showFToast(context: context, title: Text(failure), duration: const Duration(seconds: 3));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: ListenableBuilder(
        listenable: Listenable.merge([repository.friends, repository.presence]),
        builder: (context, _) {
          final f = repository.friends.value;
          final presence = repository.presence.value;
          bool away(Member m) => (presence[m.userId] ?? Presence.offline) == Presence.offline;
          final online = f.friends.where((m) => !away(m)).toList();
          final offline = f.friends.where(away).toList();
          Widget friendRow(Member m) => ListRow(
            leading: PresenceAvatar(member: m, presence: presence[m.userId], size: 48),
            title: m.displayName,
            snippet: '@${m.username}',
            onTap: () => showProfileSheet(context, member: m),
            onLongPress: () => _confirmUnfriend(m),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  padding: EdgeInsets.only(top: GlassTopBar.heightOf(context) + 8, bottom: padding.bottom + 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: SearchField(
                              controller: _add,
                              hint: 'Add a friend by username',
                              onChanged: (_) {
                                if (_addError != null) setState(() => _addError = null);
                              },
                            ),
                          ),
                          TextAction(label: 'Add', onPressed: _addByName),
                        ],
                      ),
                    ),
                    if (_addError != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_addError!, style: DuvetType.caption.copyWith(color: colors.destructive)),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final (t, label) in [
                              (_FriendsTab.all, 'All ${f.friends.length}'),
                              (_FriendsTab.pending, 'Pending ${f.incoming.length}'),
                              (_FriendsTab.sent, 'Sent ${f.outgoing.length}'),
                            ]) ...[
                              Semantics(
                                button: true,
                                selected: _tab == t,
                                label: label,
                                excludeSemantics: true,
                                onTap: () => setState(() => _tab = t),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _tab = t),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Text(
                                      label,
                                      style: DuvetType.label.copyWith(
                                        color: _tab == t ? tokens.accentText : colors.mutedForeground,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 24),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (_loading && f.friends.isEmpty && f.incoming.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: FCircularProgress()),
                      ),
                    if (_tab != _FriendsTab.sent && f.incoming.isNotEmpty) ...[
                      const Overline('Wants to be friends'),
                      for (final r in f.incoming)
                        _RequestRow(
                          request: r,
                          meta: 'Asked ${shortTime(r.at)}',
                          actions: [
                            IconAction(
                              icon: FLucideIcons.x,
                              label: 'Decline ${r.person.displayName}',
                              color: colors.mutedForeground,
                              onPressed: () =>
                                  _act(() => repository.rejectFriendRequest(r.id), 'Couldn’t decline the request'),
                            ),
                            const SizedBox(width: 4),
                            DuvetButton(
                              label: 'Accept',
                              onPressed: () =>
                                  _act(() => repository.acceptFriendRequest(r.id), 'Couldn’t accept the request'),
                            ),
                          ],
                        ),
                    ],
                    if (_tab != _FriendsTab.pending && f.outgoing.isNotEmpty) ...[
                      const Overline('You asked'),
                      for (final r in f.outgoing)
                        _RequestRow(
                          request: r,
                          meta: 'Sent ${shortTime(r.at)}',
                          actions: [
                            TextAction(
                              label: 'Cancel request',
                              onPressed: () =>
                                  _act(() => repository.rejectFriendRequest(r.id), 'Couldn’t cancel the request'),
                            ),
                          ],
                        ),
                    ],
                    if (_tab == _FriendsTab.all) ...[
                      if (online.isNotEmpty) ...[
                        Overline('Online — ${online.length}'),
                        for (final m in online) friendRow(m),
                      ],
                      if (offline.isNotEmpty) ...[
                        Overline('Offline — ${offline.length}'),
                        for (final m in offline) friendRow(m),
                      ],
                      if (!_loading && f.friends.isEmpty) const ListNote('No friends yet'),
                    ],
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(title: const Text('Friends'), onBack: () => Navigator.of(context).maybePop()),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmUnfriend(Member m) async {
    final sure = await showGlassDialogSheet<bool>(
      context,
      label: 'Remove ${m.displayName}?',
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Remove ${m.displayName}?', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 24),
            DuvetButton(
              label: 'Remove friend',
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    );
    if (sure == true && mounted) await _act(() => context.repository.unfriend(m.userId), 'Couldn’t remove them');
  }
}

class _RequestRow extends StatelessWidget {
  final FriendRequestItem request;
  final String meta;
  final List<Widget> actions;
  const _RequestRow({required this.request, required this.meta, required this.actions});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          ExcludeSemantics(
            child: UserAvatar(name: request.person.displayName, url: request.person.avatarUrl, size: 48),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.person.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                ),
                Text(meta, maxLines: 1, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// New conversation
// -----------------------------------------------------------------------------

/// New conversation: pick people (chips in the To field), name a group if
/// it's one, then start it.
class NewConversationPage extends StatefulWidget {
  const NewConversationPage({super.key});

  @override
  State<NewConversationPage> createState() => _NewConversationPageState();
}

class _NewConversationPageState extends State<NewConversationPage> {
  final _query = TextEditingController();
  final _name = TextEditingController();
  final _picked = <Member>[];
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  ValueListenable<Friends>? _friends;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_friends != null) return;
    _friends = context.repository.friends..addListener(_friendsChanged);
    context.repository.loadFriends().catchError((Object e) => debugPrint('friends: $e'));
  }

  void _friendsChanged() => setState(() {});

  @override
  void dispose() {
    _friends?.removeListener(_friendsChanged);
    _query.dispose();
    _name.dispose();
    super.dispose();
  }

  void _toggle(Member m) => setState(() {
    if (_picked.any((p) => p.userId == m.userId)) {
      _picked.removeWhere((p) => p.userId == m.userId);
    } else {
      _picked.add(m);
      _query.clear();
    }
  });

  Future<void> _start() async {
    if (_picked.isEmpty) return;
    final repository = context.repository;
    final navigator = Navigator.of(context);
    setState(() => _starting = true);
    try {
      final ConversationSummary chat;
      if (_picked.length == 1) {
        chat = await repository.directMessage(_picked.single.userId);
      } else {
        final name = _name.text.trim().isNotEmpty
            ? _name.text.trim()
            : _picked.map((p) => p.displayName.split(' ').first).join(', ');
        chat = await repository.createGroup(name, [for (final p in _picked) p.userId]);
      }
      navigator.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatView(target: chat.target, title: chat.title),
        ),
      );
    } catch (e) {
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : 'Couldn’t start the conversation'),
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    final q = _query.text.trim().toLowerCase();
    // Friends alone, as the desktop offers: the API opens DMs and groups only
    // between friends.
    final people = [
      for (final m in repository.friends.value.friends)
        if (q.isEmpty || m.displayName.toLowerCase().contains(q) || m.username.toLowerCase().contains(q)) m,
    ];
    final group = _picked.length > 1;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(top: GlassTopBar.heightOf(context) + 8, bottom: padding.bottom + 96),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                      border: Border.all(color: tokens.hairline),
                    ),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'To',
                          style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
                        ),
                        for (final p in _picked)
                          Semantics(
                            container: true,
                            button: true,
                            label: 'Remove ${p.displayName}',
                            excludeSemantics: true,
                            onTap: () => _toggle(p),
                            child: GestureDetector(
                              onTap: () => _toggle(p),
                              child: Container(
                                height: 28,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: tokens.accentTint,
                                  borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                                  border: Border.all(color: tokens.accentText),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    UserAvatar(name: p.displayName, url: p.avatarUrl, size: 20),
                                    const SizedBox(width: 6),
                                    Text(
                                      p.displayName.split(' ').first,
                                      style: DuvetType.caption.copyWith(color: tokens.accentText),
                                    ),
                                    Icon(FLucideIcons.x, size: 14, color: tokens.accentText),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 80, maxWidth: 240),
                          child: TextField(
                            controller: _query,
                            autofocus: true,
                            cursorColor: tokens.accentText,
                            style: DuvetType.body.copyWith(color: colors.foreground),
                            decoration: InputDecoration.collapsed(
                              hintText: _picked.isEmpty ? 'Name or username' : '',
                              hintStyle: DuvetType.body.copyWith(color: colors.mutedForeground),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (group)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: DuvetTextField(label: 'Group name · optional', controller: _name),
                  ),
                Overline(q.isEmpty ? 'Friends' : 'Matching “${_query.text.trim()}”'),
                for (final m in people)
                  Semantics(
                    container: true,
                    checked: _picked.any((p) => p.userId == m.userId),
                    label: '${m.displayName}, @${m.username}',
                    excludeSemantics: true,
                    onTap: () => _toggle(m),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggle(m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            UserAvatar(name: m.displayName, url: m.avatarUrl, size: 48),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.displayName, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                                  Text(
                                    '@${m.username}',
                                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                  ),
                                ],
                              ),
                            ),
                            SquareCheck(checked: _picked.any((p) => p.userId == m.userId)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (people.isEmpty) ListNote(q.isEmpty ? 'No friends added yet' : 'No one found'),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: const Text('New conversation'),
              leading: TextAction(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GlassChrome(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + padding.bottom),
                child: DuvetButton(
                  label: group ? 'Start group with ${_picked.length} people' : 'Start conversation',
                  variant: ButtonVariant.primary,
                  expand: true,
                  busy: _starting,
                  onPressed: _picked.isEmpty ? null : _start,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Group info
// -----------------------------------------------------------------------------

/// A group's info: its people (as people: overlapping circles), leave. Its
/// owner renames it, and adds and removes people, as the API allows only the
/// owner.
class GroupInfoPage extends StatefulWidget {
  final String conversationId;
  const GroupInfoPage({required this.conversationId, super.key});

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  List<Member> _members = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  Future<void> _reload({bool refresh = false}) async {
    try {
      final m = await context.repository.members(ConversationTarget(widget.conversationId), refresh: refresh);
      if (mounted) setState(() => _members = m);
    } catch (_) {}
  }

  Future<void> _act(Future<void> Function() action, String failure) async {
    try {
      await action();
      await _reload(refresh: true);
    } catch (e) {
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : failure),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _rename(ConversationSummary group) async {
    final picked = await showGlassDialogSheet<String>(
      context,
      label: 'Rename group',
      builder: (context) => _RenameSheet(initial: group.name ?? ''),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await _act(() => context.repository.renameConversation(widget.conversationId, picked), 'Couldn’t rename the group');
  }

  Future<void> _addPeople() async {
    final repository = context.repository;
    final here = {for (final m in _members) m.userId};
    // Friends alone, as the desktop offers: the API adds only the owner's.
    final candidates = [
      for (final m in repository.friends.value.friends)
        if (!here.contains(m.userId)) m,
    ];
    final picked = await showGlassSheet<Member>(
      context,
      label: 'Add people',
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          const SheetTitle(title: 'Add people'),
          for (final m in candidates)
            ListRow(
              leading: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 48),
              title: m.displayName,
              snippet: '@${m.username}',
              onTap: () => Navigator.of(context).pop(m),
            ),
          if (candidates.isEmpty) const ListNote('No friends available to add'),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _act(
      () => repository.addToConversation(widget.conversationId, picked.userId),
      'Couldn’t add ${picked.displayName}',
    );
  }

  Future<void> _leave() async {
    final sure = await showGlassDialogSheet<bool>(
      context,
      label: 'Leave the group?',
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Leave the group?', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 24),
            DuvetButton(
              label: 'Leave group',
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    );
    if (sure != true || !mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      await context.repository.leaveConversation(widget.conversationId);
      navigator.popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : 'Couldn’t leave'),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    final me = repository.profile.value?.id;
    return ValueListenableBuilder(
      valueListenable: repository.conversations,
      builder: (context, conversations, _) {
        final group = conversations.where((c) => c.id == widget.conversationId).firstOrNull;
        final owner = group != null && group.ownerId == me;
        final faces = _members.take(3).toList();
        final title = Text(
          group?.title ?? 'Group',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DuvetType.title.copyWith(color: colors.foreground),
        );
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, GlassTopBar.heightOf(context) + 16, 16, padding.bottom + 24),
                  children: [
                    // A group is people, so it's drawn as people.
                    ExcludeSemantics(
                      child: Center(
                        child: SizedBox(
                          width: 56.0 + 24 * (faces.length - 1).clamp(0, 2),
                          height: 72,
                          child: Stack(
                            children: [
                              for (final (i, m) in faces.indexed)
                                Positioned(
                                  left: 24.0 * i,
                                  top: i.isOdd ? 0 : 12,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: colors.background, width: 3),
                                    ),
                                    child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 56),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: owner
                          ? Semantics(
                              button: true,
                              label: 'Rename group, ${group.title}',
                              excludeSemantics: true,
                              onTap: () => _rename(group),
                              child: GestureDetector(
                                onTap: () => _rename(group),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(child: title),
                                    const SizedBox(width: 8),
                                    Icon(FLucideIcons.pencil, size: 16, color: colors.mutedForeground),
                                  ],
                                ),
                              ),
                            )
                          : Semantics(header: true, child: title),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        'Group · ${_members.length} people',
                        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                      ),
                    ),
                    const Overline('People'),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                        boxShadow: tokens.shadowRest,
                      ),
                      child: Column(
                        children: [
                          if (owner)
                            GlassRow(
                              label: 'Add people',
                              leading: Icon(FLucideIcons.userPlus, color: tokens.accentText),
                              selected: true,
                              onPressed: _addPeople,
                            ),
                          for (final m in _members)
                            Row(
                              children: [
                                Expanded(
                                  child: GlassRow(
                                    label: m.displayName,
                                    detail: [
                                      '@${m.username}',
                                      if (m.userId == me) 'you',
                                      if (m.userId == group?.ownerId) 'owner',
                                    ].join(' · '),
                                    leading: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 40),
                                    onPressed: () => showProfileSheet(context, member: m),
                                  ),
                                ),
                                if (owner && m.userId != me)
                                  IconAction(
                                    icon: FLucideIcons.userMinus,
                                    label: 'Remove ${m.displayName}',
                                    color: colors.mutedForeground,
                                    onPressed: () => _act(
                                      () => repository.removeFromConversation(widget.conversationId, m.userId),
                                      'Couldn’t remove ${m.displayName}',
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    DuvetButton(
                      label: 'Leave group',
                      icon: FLucideIcons.logOut,
                      variant: ButtonVariant.destructive,
                      expand: true,
                      onPressed: _leave,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(title: const Text('Group info'), onBack: () => Navigator.of(context).maybePop()),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A name to change, in a sheet; it owns its field.
class _RenameSheet extends StatefulWidget {
  final String initial;
  const _RenameSheet({required this.initial});

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Rename group', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
        const SizedBox(height: 16),
        DuvetTextField(label: 'Name', controller: _name, autofocus: true),
        const SizedBox(height: 16),
        DuvetButton(
          label: 'Save',
          variant: ButtonVariant.primary,
          expand: true,
          onPressed: () => Navigator.of(context).pop(_name.text.trim()),
        ),
      ],
    ),
  );
}
