import 'dart:async';
import 'dart:math' as math;

import 'package:duvet_client/duvet.dart' as duvet;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/images.dart';
import 'data/links.dart' show isDuvetId;
import 'data/models.dart';
import 'data/scope.dart';
import 'e2e/members.dart' show maxGroupMembers;
import 'e2e/notices.dart';
import 'members_sheet.dart' show MemberAction, PresenceAvatar;
import 'space_admin.dart' show RoleSwatch, adminTry, confirmDestructive, managesRoleAt, mayRemove;
import 'shell.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/message_content.dart';
import 'widgets/role_name.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderRows;

/// What a presence reads as; nothing when it isn't known.
String presenceText(Presence? p) => switch (p) {
  Presence.online => 'Online',
  Presence.doNotDisturb => 'Do not disturb',
  Presence.offline => 'Offline',
  null => '',
};

/// Asks, then takes [bot] out of the Space; true once it's gone. Says the
/// API's reason when it refuses, as adding a bot does.
Future<bool> removeBotAsking(
  BuildContext context, {
  required String spaceId,
  required Member bot,
  required String spaceName,
}) async {
  final name = bot.displayName;
  final sure = await confirmDestructive(
    context,
    title: 'Remove $name from $spaceName?',
    body: 'It leaves the Space and loses its roles. It can be added again later.',
    action: 'Remove from Space',
  );
  if (!sure || !context.mounted) return false;
  try {
    await context.repository.removeBot(spaceId, bot.userId);
    return true;
  } catch (e) {
    if (context.mounted) {
      showFToast(
        context: context,
        title: Text(e is ActionFailed ? e.message : 'Couldn’t remove $name'),
        duration: const Duration(seconds: 3),
      );
    }
    return false;
  }
}

/// Kick and Ban for a person, each only for who may ([mayRemove]), after
/// [gap]; nothing for a bot, which has Remove from Space. [onGone] once
/// they're out. Both greyed out once they're [banned].
List<Widget> removeMemberButtons(
  BuildContext context, {
  required String spaceId,
  required Member member,
  required String spaceName,
  required double gap,
  required VoidCallback onGone,
  bool banned = false,
}) {
  final repository = context.repository;
  final kick = !member.isBot && mayRemove(repository, spaceId, member.userId, Perm.kickMembers);
  final ban = !member.isBot && mayRemove(repository, spaceId, member.userId, Perm.banMembers);
  if (!kick && !ban) return const [];
  final name = member.displayName;
  Future<void> remove(String done, String failed, Future<void> Function() call) async {
    try {
      await call();
      // Before onGone closes the sheet: the toaster sits above it.
      if (context.mounted) showFToast(context: context, title: Text(done), duration: const Duration(seconds: 3));
      onGone();
    } catch (e) {
      if (context.mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : failed),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  return [
    SizedBox(height: gap),
    if (kick)
      DuvetButton(
        label: 'Kick from Space',
        icon: FLucideIcons.userMinus,
        variant: ButtonVariant.destructive,
        expand: true,
        onPressed: banned
            ? null
            : () async {
                final sure = await confirmDestructive(
                  context,
                  title: 'Kick $name from $spaceName?',
                  body: 'They leave the Space and lose their roles. They can join again with an invite.',
                  action: 'Kick',
                );
                if (sure && context.mounted) {
                  await remove(
                    'Kicked $name from $spaceName',
                    'Couldn’t kick $name',
                    () => repository.kick(spaceId, member.userId),
                  );
                }
              },
      ),
    if (kick && ban) const SizedBox(height: 12),
    if (ban)
      DuvetButton(
        label: banned ? 'Banned' : 'Ban from Space',
        icon: FLucideIcons.ban,
        variant: ButtonVariant.destructive,
        expand: true,
        onPressed: banned
            ? null
            : () async {
                final reason = await _askBanReason(context, title: 'Ban $name from $spaceName?');
                if (reason != null && context.mounted) {
                  await remove(
                    'Banned $name from $spaceName',
                    'Couldn’t ban $name',
                    () => repository.ban(spaceId, member.userId, reason: reason),
                  );
                }
              },
      ),
  ];
}

/// Asks before a ban, with a reason or none (empty); null when cancelled.
Future<String?> _askBanReason(BuildContext context, {required String title}) {
  var reason = '';
  return showGlassDialogSheet<String>(
    context,
    label: title,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
          const SizedBox(height: 12),
          Text(
            'They leave the Space, lose their roles and can’t join again while banned.',
            style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Reason',
            hint: 'Optional',
            maxLines: 3,
            keyboardType: TextInputType.multiline,
            // As the API keeps it.
            maxLength: 512,
            onChanged: (v) => reason = v,
          ),
          const SizedBox(height: 24),
          DuvetButton(
            label: 'Ban',
            variant: ButtonVariant.destructive,
            expand: true,
            onPressed: () => Navigator.of(context).pop(reason.trim()),
          ),
          const SizedBox(height: 12),
          DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    ),
  );
}

/// Someone's profile, in a glass sheet: banner, avatar, presence, name, what
/// they wrote, their roles in the Space; Message, Mention, Add friend, and in
/// an encrypted conversation Share history ([canShareHistory]). Answers
/// Mention, Message or Share history when the caller handles them.
Future<MemberAction?> showProfileSheet(
  BuildContext context, {
  required Member member,
  String? spaceId,
  bool canMention = false,
  bool canShareHistory = false,
}) => showGlassSheet<MemberAction>(
  context,
  label: '${member.displayName}’s profile',
  initialSize: 0.72,
  builder: (context, scroll) => _Profile(
    member: member,
    spaceId: spaceId,
    canMention: canMention,
    canShareHistory: canShareHistory,
    scroll: scroll,
  ),
);

class _Profile extends StatefulWidget {
  final Member member;
  final String? spaceId;
  final bool canMention;
  final bool canShareHistory;
  final ScrollController scroll;
  const _Profile({
    required this.member,
    required this.spaceId,
    required this.canMention,
    required this.scroll,
    this.canShareHistory = false,
  });

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  bool _asked = false;
  bool _accepting = false;

  // Banned from the Space; only asked by who holds Ban Members, as the API
  // lists bans only to them.
  bool _banned = false;
  StreamSubscription<String>? _bansChanged;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = context.repository;
    repository.loadFriends().catchError((Object e) => debugPrint('friends: $e'));
    if (_bansChanged == null) {
      _bansChanged = repository.bansChanged.listen((id) {
        if (id == widget.spaceId) _checkBan();
      });
      _checkBan();
    }
  }

  @override
  void dispose() {
    _bansChanged?.cancel();
    super.dispose();
  }

  // shortcut: reads the whole ban list (the API has no single-ban lookup); fine while bans stay few.
  Future<void> _checkBan() async {
    final repository = context.repository;
    final spaceId = widget.spaceId;
    final userId = widget.member.userId;
    if (spaceId == null ||
        widget.member.isBot ||
        repository.isMember(spaceId, userId) ||
        !(repository.spaceProfile(spaceId)?.can(Perm.banMembers) ?? false)) {
      return;
    }
    try {
      final banned = (await repository.bans(spaceId)).any((b) => b.user.userId == userId);
      if (mounted) setState(() => _banned = banned);
    } catch (e) {
      debugPrint('bans: $e');
    }
  }

  Future<void> _removeBot(String spaceId, String spaceName) async {
    final navigator = Navigator.of(context);
    if (await removeBotAsking(context, spaceId: spaceId, bot: widget.member, spaceName: spaceName)) navigator.pop();
  }

  Future<void> _message() async {
    final repository = context.repository;
    final sheet = Navigator.of(context);
    final root = Navigator.of(context, rootNavigator: true);
    try {
      final dm = await repository.directMessage(widget.member.userId);
      sheet.pop();
      if (root.mounted) openChat(root.context, dm.target, dm.title);
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
    final spaceName = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull?.name;
    final removable =
        m.isBot && widget.spaceId != null && (repository.spaceProfile(widget.spaceId!)?.can(Perm.manageBots) ?? false);
    return ListenableBuilder(
      // spaces: a role given or taken here shows at once.
      listenable: Listenable.merge([
        repository.presence,
        repository.mobileOnly,
        repository.friends,
        repository.spaces,
        repository.activities,
      ]),
      builder: (context, _) {
        final spaceId = widget.spaceId;
        final roles = spaceId == null ? const <RoleTag>[] : repository.rolesOf(spaceId, m.userId);
        // As MemberAdminPage; on their own profile only if a role is theirs to change.
        final assignsRoles =
            spaceId != null &&
            (repository.spaceProfile(spaceId)?.can(Perm.manageRoles) ?? false) &&
            (!me ||
                repository.roles(spaceId).any((r) => !r.everyone && managesRoleAt(repository, spaceId, r.position)));
        final held = {for (final r in roles) r.id};
        final spaceRoles = assignsRoles
            ? repository.roles(spaceId).where((r) => !r.everyone).toList()
            : const <SpaceRole>[];
        final presence = presenceIn(repository.presence.value, m.userId, spaceId: widget.spaceId);
        final f = repository.friends.value;
        final isFriend = f.friends.any((x) => x.userId == m.userId);
        final pending = _asked || f.outgoing.any((r) => r.person.userId == m.userId);
        // They asked the user: Accept request, as on the desktop's profile.
        final asking = f.incoming.where((r) => r.person.userId == m.userId).firstOrNull;
        final mutual = repository.spaces.value.where((s) => repository.isMember(s.id, m.userId)).length;
        final gone = spaceId != null && !repository.isMember(spaceId, m.userId);
        // Between the card's sections, as the hairlines elsewhere.
        final divider = Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Container(height: 1, color: tokens.hairline),
        );
        return ListView(
          controller: widget.scroll,
          padding: EdgeInsets.zero,
          children: [
            // Their banner, 5:2 as it's cropped, or a soft block until they
            // set one.
            AspectRatio(
              aspectRatio: bannerAspect,
              child: m.bannerUrl == null
                  ? ColoredBox(color: colors.secondary)
                  : Image(
                      image: cachedImage(m.bannerUrl!),
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
                          child: Semantics(
                            // Its own node, not merged into the card's text.
                            container: gone,
                            label: gone ? 'Not in this Space' : null,
                            child: ExcludeSemantics(
                              // Grey once they've left, been kicked or banned.
                              child: gone
                                  ? ColorFiltered(
                                      colorFilter: const ColorFilter.matrix(_greyscale),
                                      child: Opacity(
                                        opacity: 0.6,
                                        child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 80),
                                      ),
                                    )
                                  : UserAvatar(name: m.displayName, url: m.avatarUrl, size: 80),
                            ),
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
                                  PresenceAvatar.dotFor(
                                    context,
                                    presence,
                                    10,
                                    mobileOnly: repository.mobileOnly.value.contains(m.userId),
                                  ),
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
                      child: switch (nameColorsOf(roles)) {
                        final c? => RoleName(m.displayName, colors: c, style: DuvetType.title),
                        null => Text(m.displayName, style: DuvetType.title.copyWith(color: colors.foreground)),
                      },
                    ),
                    // No handle where only their name is known (a mention of
                    // someone the app hasn't met).
                    if (m.username.isNotEmpty || m.isBot) ...[
                      const SizedBox(height: 4),
                      Text(
                        [if (m.username.isNotEmpty) '@${m.username}', if (m.isBot) 'bot'].join(' · '),
                        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
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
                      if (widget.canShareHistory && !m.isBot) ...[
                        const SizedBox(height: 8),
                        DuvetButton(
                          label: Notice.shareHistory.text,
                          icon: FLucideIcons.history,
                          expand: true,
                          onPressed: () => Navigator.of(context).pop(MemberAction.shareHistory),
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
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
                          const SizedBox(height: 8),
                          if (m.bio case final bio?)
                            // With the messages' markdown, as the desktop's About me.
                            MessageText(
                              content: bio,
                              directory: MessageDirectory(
                                me: context.repository.profile.value?.id,
                                nameOf: context.repository.nameOf,
                                emojiOf: (_) => null,
                                // A bio's emojis can be of any Space.
                                emojiUrl: context.repository.emojiUrl,
                              ),
                              style: DuvetType.body.copyWith(color: colors.foreground),
                            )
                          else
                            Text('Nothing here yet.', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                          if (repository.activities.value[m.userId] case final doing? when doing.isNotEmpty)
                            ProfileActivities(doing, divider: divider),
                          if (roles.isNotEmpty || assignsRoles) ...[
                            divider,
                            _Label('Roles in ${spaceName ?? 'this Space'}'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (!assignsRoles)
                                  for (final r in roles) RoleChip(role: r)
                                else ...[
                                  // As the desktop: every role, colored if held, a tap gives or takes it.
                                  for (final r in spaceRoles)
                                    RoleChip(
                                      role: RoleTag(
                                        r.name,
                                        color: r.color,
                                        colorVia: r.colorVia,
                                        colorTo: r.colorTo,
                                        id: r.id,
                                      ),
                                      held: held.contains(r.id),
                                      onTap: managesRoleAt(repository, spaceId, r.position)
                                          ? () => adminTry(
                                              context,
                                              'Couldn’t change ${m.displayName}’s roles',
                                              () => repository.setRole(
                                                spaceId,
                                                r.id,
                                                m.userId,
                                                has: !held.contains(r.id),
                                              ),
                                            )
                                          : null,
                                    ),
                                  // Held but not in the Space's list (yet): it still shows, unchangeable here.
                                  for (final r in roles)
                                    if (!spaceRoles.any((s) => s.id == r.id)) RoleChip(role: r),
                                ],
                              ],
                            ),
                          ],
                          if (!me && mutual > 0) ...[
                            divider,
                            _Label('Mutual Spaces'),
                            const SizedBox(height: 8),
                            Text('$mutual', style: DuvetType.body.copyWith(color: colors.foreground)),
                          ],
                        ],
                      ),
                    ),
                    if (removable) ...[
                      const SizedBox(height: 16),
                      DuvetButton(
                        label: 'Remove from Space',
                        icon: FLucideIcons.userMinus,
                        variant: ButtonVariant.destructive,
                        expand: true,
                        onPressed: () => _removeBot(widget.spaceId!, spaceName ?? 'this Space'),
                      ),
                    ],
                    if (spaceId != null)
                      ...removeMemberButtons(
                        context,
                        spaceId: spaceId,
                        member: m,
                        spaceName: spaceName ?? 'this Space',
                        gap: 16,
                        onGone: Navigator.of(context).pop,
                        // A ban lifted and the person back in: no longer shown banned.
                        banned: _banned && gone,
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

// -----------------------------------------------------------------------------
// Activities
// -----------------------------------------------------------------------------

/// Spotify's activity, as the desktop app shares it: the song in details, the
/// artist in state, the album in the large image's text, and the song's start
/// and end. It has no cover.
bool isSpotify(duvet.Activity a) => a.type == duvet.ActivityType.listening && a.name == 'Spotify';

/// The activities worth showing, as the desktop's: all but a Spotify song that
/// ended over 30 seconds ago, whose app stopped updating it (closed, asleep).
List<duvet.Activity> shownActivities(List<duvet.Activity> list, DateTime now) => [
  for (final a in list)
    if (!isSpotify(a) || a.timestamps?.end == null || now.millisecondsSinceEpoch <= a.timestamps!.end! + 30000) a,
];

/// A playback time as m:ss, or h:mm:ss from an hour on.
String playbackTime(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  final ss = '${s % 60}'.padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${'${s % 3600 ~/ 60}'.padLeft(2, '0')}:$ss' : '${s ~/ 60}:$ss';
}

// The image types the gateway keeps an activity's pictures in.
const _activityImageTypes = {'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml'};

/// [value] when it's a picture an activity may show: a data URI of a type the
/// gateway keeps, which draws without loading anything; null for any other,
/// one by URL above all, whose host would learn who views it.
({String type, Uint8List bytes})? inlineActivityImage(String? value) {
  if (value == null || !value.startsWith('data:')) return null;
  try {
    final data = UriData.parse(value);
    final type = data.mimeType.toLowerCase();
    return _activityImageTypes.contains(type) ? (type: type, bytes: data.contentAsBytes()) : null;
  } on FormatException {
    return null;
  }
}

const _spotifyLogo =
    '<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#1ED760" d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z"/></svg>';

/// What someone is doing, on their profile, as the desktop's ActivityList:
/// Spotify's song with its progress, any other with its pictures and how long
/// it has been going. Ticks each second; nothing once none is worth showing.
class ProfileActivities extends StatefulWidget {
  final List<duvet.Activity> activities;

  /// Above the section, between it and the one before.
  final Widget divider;
  const ProfileActivities(this.activities, {required this.divider, super.key});

  @override
  State<ProfileActivities> createState() => _ProfileActivitiesState();
}

class _ProfileActivitiesState extends State<ProfileActivities> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final now = DateTime.now();
    final shown = shownActivities(widget.activities, now);
    if (shown.isEmpty) return const SizedBox.shrink();
    final muted = DuvetType.caption.copyWith(color: colors.mutedForeground);
    Widget line(String text, TextStyle style) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    Widget tile(Widget child) => Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(DuvetTokens.radiusChip)),
      child: child,
    );
    final unknown = tile(Text('?', style: DuvetType.label.copyWith(color: colors.mutedForeground)));
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.divider,
        _Label(shown.length == 1 ? 'Activity' : 'Activities'),
        for (final a in shown) ...[
          const SizedBox(height: 8),
          if (isSpotify(a))
            Builder(
              builder: (context) {
                final start = a.timestamps?.start ?? now.millisecondsSinceEpoch;
                final length = Duration(milliseconds: math.max((a.timestamps?.end ?? start) - start, 0));
                final elapsed = Duration(
                  milliseconds: (now.millisecondsSinceEpoch - start).clamp(0, length.inMilliseconds),
                );
                final song = a.details ?? '';
                final query = [song, ?a.state].where((t) => t.isNotEmpty).join(' ');
                void find() =>
                    MessageText.launch(Uri.parse('https://open.spotify.com/search/${Uri.encodeComponent(query)}'));
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    line('Listening to Spotify', muted.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ExcludeSemantics(child: tile(SvgPicture.string(_spotifyLogo, width: 24, height: 24))),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // No track ID to link the song itself: a search for it, as the desktop's.
                              Semantics(
                                container: true,
                                link: true,
                                label: 'Find $song on Spotify',
                                excludeSemantics: true,
                                onTap: find,
                                child: GestureDetector(
                                  onTap: find,
                                  child: line(song, DuvetType.label.copyWith(color: colors.foreground)),
                                ),
                              ),
                              if (a.state case final artist?) line('by $artist', muted),
                              if (a.assets?.largeText case final album?) line('on $album', muted),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (length > Duration.zero) ...[
                      const SizedBox(height: 6),
                      Semantics(
                        label: '${playbackTime(elapsed)} of ${playbackTime(length)}',
                        excludeSemantics: true,
                        child: Row(
                          children: [
                            Text(playbackTime(elapsed), style: muted),
                            const SizedBox(width: 8),
                            Expanded(
                              // `ink` on its track, as the password's strength.
                              child: Container(
                                height: 4,
                                alignment: Alignment.centerLeft,
                                decoration: BoxDecoration(
                                  color: colors.secondary,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                child: FractionallySizedBox(
                                  widthFactor: elapsed.inMilliseconds / length.inMilliseconds,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.foreground,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(playbackTime(length), style: muted),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            )
          else
            Row(
              children: [
                ExcludeSemantics(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _ActivityImage(a.assets?.largeImage, size: 40, fallback: unknown),
                      if (inlineActivityImage(a.assets?.smallImage) != null)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            width: 20,
                            height: 20,
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: colors.secondary,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: colors.card),
                            ),
                            child: _ActivityImage(a.assets?.smallImage, size: 14, fallback: const SizedBox.shrink()),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      line(a.name, DuvetType.label.copyWith(color: colors.foreground)),
                      if (a.details case final details?) line(details, muted.copyWith(color: colors.foreground)),
                      if (a.state case final state?) line(state, muted),
                      if (a.timestamps?.start case final start?)
                        line('${playbackTime(now.difference(at(start)))} elapsed', muted),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

/// An activity's picture, decoded once: only from a data URI
/// ([inlineActivityImage]), else [fallback].
class _ActivityImage extends StatefulWidget {
  final String? value;
  final double size;
  final Widget fallback;
  const _ActivityImage(this.value, {required this.size, required this.fallback});

  @override
  State<_ActivityImage> createState() => _ActivityImageState();
}

class _ActivityImageState extends State<_ActivityImage> {
  late var _image = inlineActivityImage(widget.value);

  @override
  void didUpdateWidget(_ActivityImage old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _image = inlineActivityImage(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final picture = switch (_image) {
      null => null,
      (type: 'image/svg+xml', :final bytes) => SvgPicture.memory(
        bytes,
        width: size,
        height: size,
        errorBuilder: (_, _, _) => widget.fallback,
      ),
      (:final bytes, type: _) => Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      ),
    };
    return picture == null
        ? widget.fallback
        : ClipRRect(borderRadius: BorderRadius.circular(size / 10), child: picture);
  }
}

// Luminance only (Rec. 709 weights), as glass.dart's saturate at 0.
const _greyscale = <double>[
  0.213, 0.715, 0.072, 0, 0, //
  0.213, 0.715, 0.072, 0, 0, //
  0.213, 0.715, 0.072, 0, 0, //
  0, 0, 0, 1, 0,
];

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text.toUpperCase(), style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground)),
  );
}

/// A role, as a flat chip. Held, it's tinted with the role's color or
/// gradient, the name in it as members see it; a role the member lacks stays
/// grey. Either way a dot beside the name: the role's colors, or grey.
class RoleChip extends StatelessWidget {
  final RoleTag role;

  /// False: a role the member lacks, in grey.
  final bool held;

  /// Gives or takes it; null when it can't change.
  final VoidCallback? onTap;
  const RoleChip({required this.role, this.held = true, this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final background = colors.background;
    // Solid tints, each stop a fifth over the background, so the name's
    // contrast is checked against what it's drawn on: the tint furthest from
    // the background, the hardest to read on.
    final tints = [
      if (held)
        for (final c in [role.color, role.colorVia, role.colorTo].nonNulls)
          Color.alphaBlend(Color(0xFF000000 | c).withValues(alpha: 0.2), background),
    ];
    final on = tints.isEmpty
        ? null
        : tints.reduce((a, b) => contrastOf(a, background) >= contrastOf(b, background) ? a : b);
    final chip = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: tints.firstOrNull ?? colors.secondary,
        // A gradient only with both ends, as [RoleName] reads one.
        gradient: tints.length > 1 && role.colorTo != null ? LinearGradient(colors: tints) : null,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (role.color != null) ...[
            held
                ? RoleSwatch(colors: role.colors, width: 8, height: 8)
                : Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: colors.mutedForeground, borderRadius: BorderRadius.circular(6)),
                  ),
            const SizedBox(width: 6),
          ],
          if (held)
            RoleName(role.name, colors: role.colors, style: DuvetType.caption, on: on)
          else
            Text(role.name, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
        ],
      ),
    );
    if (onTap == null && held) return chip;
    return Semantics(
      button: onTap != null,
      toggled: held,
      label: role.name,
      excludeSemantics: true,
      // Padded past 44pt for the finger.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: chip),
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
          decoration: BoxDecoration(color: tokens.secondaryFill, borderRadius: radius),
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
        color: checked ? Duvet.accent : context.duvet.secondaryFill,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
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

/// Friends: add one by user ID or username, then everyone, the requests to
/// the user, and theirs.
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

  Future<void> _addFriend() async {
    final repository = context.repository;
    final typed = _add.text.trim();
    final name = typed.replaceFirst('@', '').toLowerCase();
    if (name.isEmpty) return;
    // A username only among the people the app knows; a user ID, anyone's.
    final person = repository.people.where((p) => p.username.toLowerCase() == name).firstOrNull;
    final userId = person?.userId ?? (isDuvetId(typed) ? typed : null);
    if (userId == null) {
      setState(() => _addError = 'No one called @$name shares a Space or a chat with you');
      return;
    }
    try {
      await repository.sendFriendRequest(userId);
      _add.clear();
      setState(() => _addError = null);
      if (mounted) {
        showFToast(
          context: context,
          title: Text(person == null ? 'Friend request sent' : 'Asked ${person.displayName}'),
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _addError = e is ActionFailed ? e.message : 'Couldn’t send the request');
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
        listenable: Listenable.merge([repository.friends, repository.presence, repository.mobileOnly]),
        builder: (context, _) {
          final f = repository.friends.value;
          final presence = repository.presence.value;
          bool away(Member m) => isOffline(presence[m.userId]);
          final online = f.friends.where((m) => !away(m)).toList();
          final offline = f.friends.where(away).toList();
          Widget friendRow(Member m) => ListRow(
            leading: PresenceAvatar(
              member: m,
              presence: presence[m.userId],
              mobileOnly: repository.mobileOnly.value.contains(m.userId),
              size: 48,
            ),
            title: m.displayName,
            snippet: '@${m.username}',
            banner: m.bannerUrl,
            bannerOffline: away(m),
            onTap: () => showProfileSheet(context, member: m),
            onLongPress: () => _confirmUnfriend(m),
          );
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
                              hint: 'Add a friend by user ID or username',
                              onChanged: (_) {
                                if (_addError != null) setState(() => _addError = null);
                              },
                            ),
                          ),
                          TextAction(label: 'Add', onPressed: _addFriend),
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
                    // As the desktop adds friends: by the ID they share.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Friends add you by your user ID.',
                              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                            ),
                          ),
                          TextAction(
                            label: 'Copy your ID',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: repository.profile.value!.id));
                              showFToast(
                                context: context,
                                title: const Text('ID copied'),
                                duration: const Duration(seconds: 3),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    // Edge to edge: the tabs scroll to the screen's edge, 16 in at rest.
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            for (final (t, label) in [
                              (_FriendsTab.all, 'All ${f.friends.length}'),
                              (_FriendsTab.pending, 'Pending ${f.incoming.length}'),
                              (_FriendsTab.sent, 'Sent ${f.outgoing.length}'),
                            ]) ...[
                              if (t != _FriendsTab.all) const SizedBox(width: 24),
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
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (_loading && f.friends.isEmpty && f.incoming.isEmpty)
                      LoadingSkeleton(
                        label: 'Loading friends',
                        children: [const Overline('Lorem ipsum'), ...placeholderRows(avatar: 48)],
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
    ).readable;
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
      // In place of this page; a wide window shows the chat in its pane instead.
      if (mounted && (Shell.maybeOf(context)?.wide ?? false)) {
        navigator.pop();
        openChat(navigator.context, chat.target, chat.title);
      } else {
        navigator.pushReplacement(ChatRoute(target: chat.target, title: chat.title));
      }
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
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                                  color: tokens.selectedFill,
                                  borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
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
    ).readable;
  }
}

// -----------------------------------------------------------------------------
// Group info
// -----------------------------------------------------------------------------

/// A group's info: its mark and name, its people, leave. Its owner renames
/// it, and adds and removes people, as the API allows only the owner.
class GroupInfoPage extends StatefulWidget {
  final String conversationId;
  const GroupInfoPage({required this.conversationId, super.key});

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
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
    // A full group says so as the sheet opens, and its rows take no tap (the desktop's way).
    final full = here.length >= maxGroupMembers;
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
              if (full) ListNote(Notice.groupFull.text),
              for (final m in candidates)
                ListRow(
                  leading: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 48),
                  title: m.displayName,
                  snippet: '@${m.username}',
                  banner: m.bannerUrl,
                  bannerOffline: isOffline(context.repository.presence.value[m.userId]),
                  onTap: full ? null : () => Navigator.of(context).pop(m),
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
                    // The group's mark, as wherever it shows: its people are listed under it, each with their face.
                    const GroupMark(size: 72),
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
        ).readable;
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
