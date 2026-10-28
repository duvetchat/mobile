import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/scope.dart';
import 'members_sheet.dart' show MemberAction, MemberFace, PresenceAvatar;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/message_content.dart';
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
  /// The face at the hero's foot.
  static const _face = 104.0;

  /// The banner's height at most: a phone's, 5:2 across it.
  static const _bannerMax = 180.0;

  bool _asked = false;
  bool _accepting = false;

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

  // Their request, which a request sent back wouldn't answer: the API refuses
  // one while theirs waits.
  Future<void> _accept(String requestId) async {
    setState(() => _accepting = true);
    try {
      await context.repository.acceptFriendRequest(requestId);
    } catch (_) {
      if (mounted) {
        showFToast(
          context: context,
          title: const Text('Couldn’t accept the request'),
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
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
        final presence = presenceIn(repository.presence.value, m.userId, spaceId: widget.spaceId);
        final f = repository.friends.value;
        final isFriend = f.friends.any((x) => x.userId == m.userId);
        final pending = _asked || f.outgoing.any((r) => r.person.userId == m.userId);
        // They asked the user: Accept request, as on the desktop's profile.
        final asking = f.incoming.where((r) => r.person.userId == m.userId).firstOrNull;
        final mutual = repository.spaces.value.where((s) => repository.isMember(s.id, m.userId)).toList();
        return ListView(
          controller: widget.scroll,
          padding: EdgeInsets.zero,
          children: [
            // The hero: their banner, 5:2 as it's cropped (no taller than a
            // phone's, on a wider screen), or the mascot's slate until they
            // set one, and their face large over its foot.
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: _face / 2),
                  child: LayoutBuilder(
                    builder: (context, constraints) => SizedBox(
                      height: (constraints.maxWidth / bannerAspect).clamp(0, _bannerMax),
                      width: double.infinity,
                      child: m.bannerUrl == null
                          ? const ColoredBox(color: Duvet.slate)
                          : Image.network(
                              m.bannerUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(color: Duvet.slate),
                            ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.background, width: 5),
                      boxShadow: tokens.shadowRaised,
                    ),
                    child: ExcludeSemantics(
                      child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: _face),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      m.displayName,
                      textAlign: TextAlign.center,
                      style: DuvetType.title.copyWith(fontSize: 24, color: colors.foreground),
                    ),
                  ),
                  // Their handle (none where only their name is known: a
                  // mention of someone the app hasn't met) beside their presence.
                  if (m.username.isNotEmpty || m.isBot || presence != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (m.username.isNotEmpty || m.isBot)
                          Text(
                            [if (m.username.isNotEmpty) '@${m.username}', if (m.isBot) 'bot'].join(' · '),
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        if (presence != null)
                          Container(
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
                      ],
                    ),
                  ],
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
                                : asking != null
                                ? 'Accept request'
                                : pending
                                ? 'Friend request sent'
                                : 'Add friend',
                            icon: isFriend
                                ? FLucideIcons.userCheck
                                : pending && asking == null
                                ? FLucideIcons.clock
                                : FLucideIcons.userPlus,
                            onPressed: isFriend
                                ? null
                                : asking != null
                                ? (_accepting ? null : () => _accept(asking.id))
                                : pending
                                ? null
                                : _addFriend,
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Cushion(
                    padding: const EdgeInsets.all(16),
                    shadows: tokens.shadowRest,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Label('About'),
                        const SizedBox(height: 4),
                        if (m.bio case final bio?)
                          // With the messages' markdown, as the desktop's About me.
                          MessageText(
                            content: bio,
                            directory: MessageDirectory(
                              me: context.repository.profile.value?.id,
                              nameOf: context.repository.nameOf,
                              emojiOf: (_) => null,
                            ),
                            style: DuvetType.body.copyWith(color: colors.foreground),
                          )
                        else
                          Text('Nothing here yet.', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                        if (roles.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _Label('Roles in ${spaceName ?? 'this Space'}'),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [for (final r in roles) RoleChip(role: r)]),
                        ],
                        if (!me && mutual.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _Label('Mutual Spaces'),
                          const SizedBox(height: 8),
                          _MutualSpaces(spaces: mutual),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The Spaces the user shares with someone, as a row of their icons, each
/// named under it.
class _MutualSpaces extends StatelessWidget {
  final List<Space> spaces;
  const _MutualSpaces({required this.spaces});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, space) in spaces.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Column(
              children: [
                SpaceIcon(space: space, size: 44),
                const SizedBox(height: 6),
                Text(
                  space.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: DuvetType.caption.copyWith(color: context.theme.colors.foreground),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground)),
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
            color: colors.card,
            borderRadius: radius,
            boxShadow: pressed ? null : tokens.shadowRest,
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : tokens.cushion,
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
        color: checked ? colors.primary : null,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
        border: Border.all(color: checked ? colors.primary : colors.mutedForeground, width: 1.5),
      ),
      child: checked ? Icon(FLucideIcons.check, size: 16, color: colors.primaryForeground) : null,
    );
  }
}

/// Someone in a full-width list, to open or pick: their avatar, name and
/// handle, their banner faintly behind ([memberBanner]). With [checked], a
/// pick, with its box.
class PersonRow extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final VoidCallback onTap;
  final bool? checked;

  /// Their handle under the name; read after it too.
  final bool username;
  final double avatarSize;
  final double verticalPadding;

  /// Their name as shown, e.g. with the search's match picked out.
  final List<InlineSpan>? name;

  const PersonRow({
    required this.member,
    required this.presence,
    required this.onTap,
    this.checked,
    this.username = true,
    this.avatarSize = 40,
    this.verticalPadding = 8,
    this.name,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Semantics(
      container: true,
      button: checked == null,
      checked: checked,
      label: username ? '${member.displayName}, @${member.username}' : member.displayName,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(image: memberBanner(context, member.bannerUrl, offline: isOffline(presence))),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: verticalPadding),
            child: Row(
              children: [
                UserAvatar(name: member.displayName, url: member.avatarUrl, size: avatarSize),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: name ?? [TextSpan(text: member.displayName)]),
                        style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                      ),
                      if (username)
                        Text('@${member.username}', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    ],
                  ),
                ),
                if (checked case final checked?) SquareCheck(checked: checked),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Friends
// -----------------------------------------------------------------------------

enum _FriendsTab { all, pending, sent }

/// Friends: add one by username; then who asked the user, waiting on an
/// answer; the friends online now, as faces; everyone else, as a list; and
/// whom the user asked.
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
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: ListenableBuilder(
        listenable: Listenable.merge([repository.friends, repository.presence]),
        builder: (context, _) {
          final f = repository.friends.value;
          final presence = repository.presence.value;
          bool away(Member m) => isOffline(presence[m.userId]);
          final online = f.friends.where((m) => !away(m)).toList();
          final offline = f.friends.where(away).toList();
          Widget friendRow(Member m) => ListRow(
            leading: PresenceAvatar(member: m, presence: presence[m.userId], size: 48),
            title: m.displayName,
            snippet: '@${m.username}',
            banner: m.bannerUrl,
            bannerOffline: away(m),
            onTap: () => showProfileSheet(context, member: m),
            onLongPress: () => _confirmUnfriend(m),
          );
          final requests = _tab != _FriendsTab.sent && f.incoming.isNotEmpty;
          final asked = _tab != _FriendsTab.pending && f.outgoing.isNotEmpty;
          return Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                          SizedBox(
                            height: 44,
                            child: TextAction(label: 'Add', onPressed: _addByName),
                          ),
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
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Segmented(
                        label: 'Show',
                        value: _tab,
                        options: {
                          _FriendsTab.all: 'All ${f.friends.length}',
                          _FriendsTab.pending: 'Pending ${f.incoming.length}',
                          _FriendsTab.sent: 'Sent ${f.outgoing.length}',
                        },
                        onChanged: (t) => setState(() => _tab = t),
                      ),
                    ),
                    if (_loading && f.friends.isEmpty && f.incoming.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: FCircularProgress()),
                      ),
                    // What waits on the user first: who asked, to answer.
                    if (requests) ...[
                      const Overline('Wants to be friends'),
                      for (final r in f.incoming)
                        _RequestRow(
                          request: r,
                          meta: 'Asked ${shortTime(r.at)}',
                          actions: [
                            _DeclineButton(
                              label: 'Decline ${r.person.displayName}',
                              onPressed: () =>
                                  _act(() => repository.rejectFriendRequest(r.id), 'Couldn’t decline the request'),
                            ),
                            const SizedBox(width: 8),
                            DuvetButton(
                              label: 'Accept',
                              onPressed: () =>
                                  _act(() => repository.acceptFriendRequest(r.id), 'Couldn’t accept the request'),
                            ),
                          ],
                        ),
                    ],
                    if (_tab == _FriendsTab.all) ...[
                      // Who's here now, as faces; everyone else, a list.
                      if (online.isNotEmpty) ...[
                        Overline('Online — ${online.length}'),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 96,
                            mainAxisExtent: MemberFace.extent(context),
                          ),
                          itemCount: online.length,
                          itemBuilder: (context, i) {
                            final m = online[i];
                            return MemberFace(
                              member: m,
                              presence: presence[m.userId],
                              detail: [presenceText(presence[m.userId]), '@${m.username}'].join(' · '),
                              onTap: () => showProfileSheet(context, member: m),
                              onLongPress: () => _confirmUnfriend(m),
                            );
                          },
                        ),
                      ],
                      if (offline.isNotEmpty) ...[
                        Overline('Offline — ${offline.length}'),
                        for (final m in offline) friendRow(m),
                      ],
                      if (!_loading && f.friends.isEmpty && !requests) const ListNote('No friends yet'),
                    ],
                    if (asked) ...[
                      const Overline('You asked'),
                      for (final r in f.outgoing)
                        _RequestRow(
                          request: r,
                          meta: 'Sent ${shortTime(r.at)}',
                          quiet: true,
                          actions: [
                            SizedBox(
                              height: 44,
                              child: TextAction(
                                label: 'Cancel request',
                                onPressed: () =>
                                    _act(() => repository.rejectFriendRequest(r.id), 'Couldn’t cancel the request'),
                              ),
                            ),
                          ],
                        ),
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

/// A friend request: an incoming one up on a cushion, waiting on the user,
/// with Decline and Accept; one the user sent lies flat ([quiet]), with
/// Cancel request.
class _RequestRow extends StatelessWidget {
  final FriendRequestItem request;
  final String meta;
  final List<Widget> actions;
  final bool quiet;
  const _RequestRow({required this.request, required this.meta, required this.actions, this.quiet = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final row = Row(
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
                style: (quiet ? DuvetType.rowTitle : DuvetType.rowTitleUnread).copyWith(color: colors.foreground),
              ),
              Text(meta, maxLines: 1, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
            ],
          ),
        ),
        ...actions,
      ],
    );
    if (quiet) {
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: row);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Cushion(radius: DuvetTokens.radiusRow, padding: const EdgeInsets.fromLTRB(8, 12, 8, 12), child: row),
    );
  }
}

/// Decline: a 44pt sunken square with an ×, beside Accept.
class _DeclineButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _DeclineButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) => Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(borderRadius: radius).copyWith(color: colors.secondary),
          child: InsetShadow(
            shadows: pressed ? context.duvet.shadowPressed : context.duvet.shadowWell,
            borderRadius: radius,
            child: Icon(FLucideIcons.x, size: 20, color: colors.mutedForeground),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// New conversation
// -----------------------------------------------------------------------------

/// New conversation: pick people (their faces at the top, a tap takes one
/// off), name a group if it's one, then start it.
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
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(top: GlassTopBar.heightOf(context) + 8, bottom: padding.bottom + 96),
              children: [
                // Who it's with so far, as their faces: a tap takes one off.
                if (_picked.isNotEmpty)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final p in _picked) _PickedFace(member: p, onRemove: () => _toggle(p))],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SearchField(controller: _query, autofocus: true, hint: 'Name or username'),
                ),
                if (group)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: DuvetTextField(label: 'Group name · optional', controller: _name),
                  ),
                Overline(q.isEmpty ? 'Friends' : 'Matching “${_query.text.trim()}”'),
                for (final m in people)
                  PersonRow(
                    member: m,
                    presence: repository.presence.value[m.userId],
                    checked: _picked.any((p) => p.userId == m.userId),
                    avatarSize: 48,
                    verticalPadding: 12,
                    onTap: () => _toggle(m),
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

/// Someone picked for a new conversation, at its top: their face with a
/// small × on its corner (a rounded square: it's a control), their first
/// name under it. A tap takes them off.
class _PickedFace extends StatelessWidget {
  final Member member;
  final VoidCallback onRemove;
  const _PickedFace({required this.member, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Semantics(
      container: true,
      button: true,
      label: 'Remove ${member.displayName}',
      excludeSemantics: true,
      onTap: onRemove,
      child: Pressable(
        onTap: onRemove,
        builder: (context, _) => SizedBox(
          width: 68,
          child: Column(
            children: [
              SizedBox.square(
                dimension: 56,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    UserAvatar(name: member.displayName, url: member.avatarUrl, size: 56),
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: tokens.chosen,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: colors.background, width: 2),
                        ),
                        child: Icon(FLucideIcons.x, size: 12, color: tokens.chosenText),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                member.displayName.split(' ').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Group info
// -----------------------------------------------------------------------------

/// A group's info, as a profile is: a hero of its people's faces (a group
/// is people, so it's drawn as people), its name, and the people; leave. Its
/// owner renames it, and adds and removes people, as the API allows only the
/// owner.
class GroupInfoPage extends StatefulWidget {
  final String conversationId;
  const GroupInfoPage({required this.conversationId, super.key});

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  /// Each face in the hero.
  static const _face = 72.0;

  List<Member> _members = const [];
  bool _friendsAsked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
    // The friends Add people offers, loaded as the new conversation does.
    if (_friendsAsked) return;
    _friendsAsked = true;
    context.repository.loadFriends().catchError((Object e) => debugPrint('friends: $e'));
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
    final picked = await showGlassSheet<Member>(
      context,
      label: 'Add people',
      // The friends as they come: the page's load may not have answered yet.
      builder: (context, scroll) => ValueListenableBuilder(
        valueListenable: repository.friends,
        builder: (context, friends, _) {
          // Friends alone, as the desktop offers: the API adds only the owner's.
          final candidates = [
            for (final m in friends.friends)
              if (!here.contains(m.userId)) m,
          ];
          return ListView(
            controller: scroll,
            children: [
              const SheetTitle(title: 'Add people'),
              for (final m in candidates)
                ListRow(
                  leading: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 48),
                  title: m.displayName,
                  snippet: '@${m.username}',
                  banner: m.bannerUrl,
                  bannerOffline: isOffline(context.repository.presence.value[m.userId]),
                  onTap: () => Navigator.of(context).pop(m),
                ),
              if (candidates.isEmpty) const ListNote('No friends available to add'),
            ],
          );
        },
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
          style: DuvetType.title.copyWith(fontSize: 24, color: colors.foreground),
        );
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, GlassTopBar.heightOf(context) + 8, 16, padding.bottom + 24),
                  children: [
                    // The profile's hero: the mascot's slate where a banner
                    // would be, and the group as people, its faces large
                    // over the slate's foot.
                    ExcludeSemantics(
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.topCenter,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: _face / 2),
                            child: LayoutBuilder(
                              builder: (context, constraints) => Container(
                                height: (constraints.maxWidth / bannerAspect).clamp(0, 140),
                                decoration: BoxDecoration(
                                  color: Duvet.slate,
                                  borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            child: FaceStack(
                              faces: [for (final m in faces) (name: m.displayName, avatarUrl: m.avatarUrl)],
                              size: _face,
                              ring: colors.background,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
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
                              labelColor: tokens.accentText,
                              leading: SizedBox.square(
                                dimension: 40,
                                child: Icon(FLucideIcons.userPlus, color: tokens.accentText),
                              ),
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
                                    banner: m.bannerUrl,
                                    bannerOffline: isOffline(repository.presence.value[m.userId]),
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
