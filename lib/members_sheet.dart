import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'e2e/engine.dart' show EngineStage;
import 'people.dart' show showProfileSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderLines, placeholderNames;
import 'widgets/skeleton.dart' show Bone;

/// What a member's row can do: in an encrypted conversation, share its history with them too (Task 31).
enum MemberAction { mention, message, shareHistory }

/// The chat's members in a glass sheet, by presence, with search. Answers the
/// member and what to do with them, picked from their profile, or null.
Future<(Member, MemberAction)?> showMembersSheet(
  BuildContext context, {
  required ChatRepository repository,
  required ChatTarget target,
}) => showGlassSheet<(Member, MemberAction)>(
  context,
  label: 'Members',
  initialSize: 0.7,
  builder: (context, scroll) => _MembersSheet(
    repository: repository,
    target: target,
    scroll: scroll,
    onPicked: (member, action) => Navigator.of(context).pop((member, action)),
  ),
);

/// The same list beside the chat, on a window wide enough: the desktop's members column.
class MembersPanel extends StatefulWidget {
  final ChatRepository repository;
  final ChatTarget target;
  final void Function(Member member, MemberAction action) onPicked;
  const MembersPanel({required this.repository, required this.target, required this.onPicked, super.key});

  @override
  State<MembersPanel> createState() => _MembersPanelState();
}

class _MembersPanelState extends State<MembersPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: 'Members',
    child: SafeArea(
      left: false,
      right: false,
      // Its title level with the chat's.
      minimum: const EdgeInsets.only(top: 8),
      // The next chat's members, not the last one's.
      child: _MembersSheet(
        key: ValueKey(widget.target.id),
        repository: widget.repository,
        target: widget.target,
        scroll: _scroll,
        onPicked: widget.onPicked,
      ),
    ),
  );
}

class _MembersSheet extends StatefulWidget {
  final ChatRepository repository;
  final ChatTarget target;
  final ScrollController scroll;

  /// What was picked from a member's profile.
  final void Function(Member member, MemberAction action) onPicked;
  const _MembersSheet({
    required this.repository,
    required this.target,
    required this.scroll,
    required this.onPicked,
    super.key,
  });

  @override
  State<_MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends State<_MembersSheet> {
  late Future<List<Member>> _members = widget.repository.members(widget.target);
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FutureBuilder(
      future: _members,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Couldn’t load members', style: TextStyle(color: colors.mutedForeground)),
              const SizedBox(height: 12),
              FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: () => setState(() => _members = widget.repository.members(widget.target, refresh: true)),
                child: const Text('Try again'),
              ),
            ],
          );
        }
        final all = snapshot.data;
        if (all == null) {
          return ListView(
            controller: widget.scroll,
            padding: EdgeInsets.zero,
            children: [
              const SheetTitle(title: 'Members'),
              LoadingSkeleton(
                label: 'Loading members',
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Bone(
                      width: double.infinity,
                      height: 40,
                      borderRadius: BorderRadius.all(Radius.circular(DuvetTokens.radiusField)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('LOREM IPSUM — 4', style: DuvetType.overline),
                  ),
                  for (final (i, name) in placeholderNames.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: GlassRow(
                        leading: const Bone.circle(size: 48),
                        label: name,
                        detail: placeholderLines[i],
                        onPressed: () {},
                      ),
                    ),
                ],
              ),
            ],
          );
        }
        return ListenableBuilder(
          // Presence, and roles: a role hoisted or taken while it's open
          // regroups it.
          listenable: Listenable.merge([
            widget.repository.presence,
            widget.repository.mobileOnly,
            widget.repository.spaces,
          ]),
          builder: (context, _) {
            final presence = widget.repository.presence.value;
            final mobileOnly = widget.repository.mobileOnly.value;
            final spaceId = switch (widget.target) {
              RoomTarget(:final spaceId) => spaceId,
              ConversationTarget() => null,
            };
            final ownerId = widget.repository.spaces.value.where((s) => s.id == spaceId).firstOrNull?.ownerId;
            final q = _search.text.trim().toLowerCase();
            // Without those the gateway says left since the list came (a bot
            // removed, say).
            final shown = all
                .where((m) => spaceId == null || widget.repository.isMember(spaceId, m.userId))
                .where(
                  (m) => q.isEmpty || m.displayName.toLowerCase().contains(q) || m.username.toLowerCase().contains(q),
                )
                .toList();
            // Not reported isn't offline: those go under Members, with no
            // status shown.
            // In a Space, a bot's there comes first.
            Presence? of(Member m) => presenceIn(presence, m.userId, spaceId: spaceId);
            bool away(Member m) => of(m) == null || of(m) == Presence.offline;
            final rest = [
              for (final m in shown)
                if (away(m)) m,
            ]..sort(_byName);
            final offline = (rest.every((m) => of(m) == Presence.offline) ? 'Offline' : 'Members', rest);
            final List<(String, List<Member>)> groups;
            if (spaceId == null) {
              groups = [
                for (final (p, label) in const [(Presence.online, 'Online'), (Presence.doNotDisturb, 'Do not disturb')])
                  (
                    label,
                    [
                      for (final m in shown)
                        if (of(m) == p) m,
                    ]..sort(_byName),
                  ),
                offline,
              ];
            } else {
              // In a Space, as the desktop and Discord have it: those connected
              // (busy too) under their highest role shown apart, by rank; the
              // others connected under Online; then those away.
              final hoisted = <String, (RoleTag, List<Member>)>{};
              final connected = <Member>[];
              for (final m in shown) {
                if (away(m)) continue;
                final role = widget.repository.rolesOf(spaceId, m.userId).where((r) => r.hoisted).firstOrNull;
                if (role == null) {
                  connected.add(m);
                } else {
                  (hoisted[role.id] ??= (role, <Member>[])).$2.add(m);
                }
              }
              groups = [
                for (final (role, members)
                    in hoisted.values.toList()..sort((a, b) => b.$1.position.compareTo(a.$1.position)))
                  (role.name, members..sort(_byName)),
                ('Online', connected..sort(_byName)),
                offline,
              ];
            }
            final online = all.where((m) => !away(m)).length;
            return CustomScrollView(
              controller: widget.scroll,
              // Scrolling the members puts the search's keyboard away.
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(
                  child: SheetTitle(
                    title: 'Members',
                    caption: widget.target is RoomTarget ? '$online online · ${all.length}' : '${all.length}',
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SearchField(controller: _search, hint: 'Search members'),
                  ),
                ),
                if (shown.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        q.isEmpty ? 'No one here yet' : 'No members match “${_search.text.trim()}”',
                        textAlign: TextAlign.center,
                        style: DuvetType.body.copyWith(color: colors.mutedForeground),
                      ),
                    ),
                  ),
                for (final (label, members) in groups)
                  if (members.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Semantics(
                          header: true,
                          child: Text(
                            '${label.toUpperCase()} — ${members.length}',
                            style: DuvetType.overline.copyWith(color: colors.mutedForeground),
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      sliver: SliverList.builder(
                        itemCount: members.length,
                        itemBuilder: (context, i) => _MemberRow(
                          member: members[i],
                          presence: of(members[i]),
                          mobileOnly: mobileOnly.contains(members[i].userId),
                          me: widget.repository.profile.value?.id == members[i].userId,
                          owner: ownerId != null && ownerId == members[i].userId,
                          spaceId: spaceId,
                          // A conversation's history goes from this device's own, once it's ready.
                          canShareHistory:
                              widget.target is ConversationTarget &&
                              widget.repository.encryption.value.stage == EngineStage.ready,
                          onPicked: widget.onPicked,
                          roleColors: switch (widget.target) {
                            RoomTarget(:final spaceId) => nameColorsOf(
                              widget.repository.rolesOf(spaceId, members[i].userId),
                            ),
                            _ => null,
                          },
                        ),
                      ),
                    ),
                  ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            );
          },
        );
      },
    );
  }

  static int _byName(Member a, Member b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
}

class _MemberRow extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final bool mobileOnly;
  final bool me;

  /// Owns the Space: a crown after their name, as the desktop has it.
  final bool owner;
  final String? spaceId;

  /// Their profile offers to share the conversation's history with them: an encrypted conversation's.
  final bool canShareHistory;

  /// Their highest colored role's colors: they tint the name, or run across it as a gradient.
  final RoleColors? roleColors;
  final void Function(Member member, MemberAction action) onPicked;
  const _MemberRow({
    required this.member,
    required this.presence,
    required this.mobileOnly,
    required this.me,
    required this.onPicked,
    this.owner = false,
    this.spaceId,
    this.canShareHistory = false,
    this.roleColors,
  });

  @override
  Widget build(BuildContext context) {
    final status = switch (presence) {
      Presence.online => 'Online',
      Presence.doNotDisturb => 'Do not disturb',
      Presence.offline => 'Offline',
      null => null,
    };
    // The status as the caption line, then who they are.
    final detail = [
      ?status,
      '@${member.username}',
      if (owner) 'owner',
      if (member.isBot) 'bot',
      if (me) 'you',
    ].join(' · ');
    return Builder(
      builder: (rowContext) => GlassRow(
        label: member.displayName,
        labelColors: roleColors,
        labelIcon: owner ? OwnerCrown(offline: isOffline(presence)) : null,
        detail: detail,
        hint: me ? null : 'Double tap for options',
        leading: PresenceAvatar(member: member, presence: presence, mobileOnly: mobileOnly, size: 48),
        banner: member.bannerUrl,
        bannerOffline: isOffline(presence),
        // Their profile over this sheet; it closes only for what's picked there.
        onPressed: () async {
          final action = await showProfileSheet(
            context,
            member: member,
            spaceId: spaceId,
            canMention: true,
            canShareHistory: canShareHistory,
          );
          if (action != null && context.mounted) onPicked(member, action);
        },
      ),
    );
  }
}

/// A member's avatar with their presence: a filled dot when online, a dot with
/// a bar for do not disturb, a ring when offline; while connected only from
/// the mobile app ([mobileOnly]), a phone in place of the dot. Shape tells
/// them apart, not color alone. Not reported: no status at all.
class PresenceAvatar extends StatelessWidget {
  final Member member;
  final Presence? presence;

  /// They're connected only from the mobile app ([ChatRepository.mobileOnly]).
  final bool mobileOnly;
  final double size;
  const PresenceAvatar({
    required this.member,
    required this.presence,
    this.mobileOnly = false,
    this.size = 40,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final dot = size * 0.32;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(
            opacity: presence == Presence.offline ? 0.55 : 1,
            child: ExcludeSemantics(
              child: UserAvatar(name: member.displayName, url: member.avatarUrl, size: size),
            ),
          ),
          if (presence case final presence?)
            Positioned(right: -1, bottom: -1, child: dotFor(context, presence, dot, mobileOnly: mobileOnly)),
        ],
      ),
    );
  }

  /// Presence by shape: a filled dot online, a dot with a bar for do not
  /// disturb, a ring offline. Connected only from the mobile app
  /// ([mobileOnly]), a [PresencePhone] instead; offline, the ring all the same.
  static Widget dotFor(BuildContext context, Presence presence, double dot, {bool mobileOnly = false}) {
    if (mobileOnly && presence != Presence.offline) return PresencePhone(presence: presence, width: dot);
    final colors = context.theme.colors;
    final online = context.duvet.live;
    return Container(
      width: dot,
      height: dot,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.card, shape: BoxShape.circle),
      child: switch (presence) {
        Presence.online => DecoratedBox(
          decoration: BoxDecoration(color: online, shape: BoxShape.circle),
        ),
        Presence.doNotDisturb => DecoratedBox(
          decoration: BoxDecoration(color: colors.destructive, shape: BoxShape.circle),
          child: Center(
            child: Container(width: dot * 0.45, height: 2, color: colors.card),
          ),
        ),
        Presence.offline => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.mutedForeground, width: 2),
          ),
        ),
      },
    );
  }
}

/// The presence of someone connected only from the mobile app: a phone in
/// their status's color, as wide as the dot ([width]) and half as tall
/// again, cut out of what's behind it as the dot is, its screen the
/// cut-out's color. Do not disturb puts the dot's bar across the screen, so
/// shape still tells it from online.
class PresencePhone extends StatelessWidget {
  final Presence presence;
  final double width;
  const PresencePhone({required this.presence, required this.width, super.key})
    : assert(presence != Presence.offline, 'offline shows the ring');

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final busy = presence == Presence.doNotDisturb;
    final color = busy ? colors.destructive : context.duvet.live;
    // The phone, inside the cut-out's 2pt.
    final body = width - 4;
    return Container(
      width: width,
      height: width * 1.5,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(width * 0.3)),
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(body * 0.25)),
        child: Padding(
          // Its screen, with a deeper edge below it than above.
          padding: EdgeInsets.fromLTRB(body * 0.18, body * 0.2, body * 0.18, body * 0.45),
          child: DecoratedBox(
            decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(body * 0.08)),
            child: busy
                ? Center(
                    child: Container(width: body * 0.4, height: 2, color: color),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
