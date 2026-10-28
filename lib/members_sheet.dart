import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'people.dart' show showProfileSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// What a member's row can do.
enum MemberAction { mention, message }

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
  builder: (context, scroll) => _MembersSheet(repository: repository, target: target, scroll: scroll),
);

class _MembersSheet extends StatefulWidget {
  final ChatRepository repository;
  final ChatTarget target;
  final ScrollController scroll;
  const _MembersSheet({required this.repository, required this.target, required this.scroll});

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
              Text('Couldn’t load members', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
              const SizedBox(height: 12),
              DuvetButton(
                label: 'Try again',
                onPressed: () => setState(() => _members = widget.repository.members(widget.target, refresh: true)),
              ),
            ],
          );
        }
        final all = snapshot.data;
        if (all == null) return const Center(child: FCircularProgress());
        return ListenableBuilder(
          // Presence, and roles: a role hoisted or taken while it's open
          // regroups it.
          listenable: Listenable.merge([widget.repository.presence, widget.repository.spaces]),
          builder: (context, _) {
            final presence = widget.repository.presence.value;
            final q = _search.text.trim().toLowerCase();
            final shown = q.isEmpty
                ? all
                : all
                      .where((m) => m.displayName.toLowerCase().contains(q) || m.username.toLowerCase().contains(q))
                      .toList();
            // Not reported isn't offline: those go under Members, with no
            // status shown.
            // In a Space, a bot's there comes first.
            final spaceId = switch (widget.target) {
              RoomTarget(:final spaceId) => spaceId,
              ConversationTarget() => null,
            };
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
            // Their highest colored role's color, in a Space.
            int? roleColor(Member m) => spaceId == null
                ? null
                : widget.repository.rolesOf(spaceId, m.userId).map((r) => r.color).nonNulls.firstOrNull;
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
                            '$label — ${members.length}',
                            style: DuvetType.overline.copyWith(color: colors.mutedForeground),
                          ),
                        ),
                      ),
                    ),
                    // Those connected as a grid of faces; those away as a
                    // compact list under them.
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      sliver: identical(members, rest)
                          ? SliverList.builder(
                              itemCount: members.length,
                              itemBuilder: (context, i) => _MemberRow(
                                member: members[i],
                                presence: of(members[i]),
                                me: widget.repository.profile.value?.id == members[i].userId,
                                spaceId: spaceId,
                                roleColor: roleColor(members[i]),
                              ),
                            )
                          : SliverGrid.builder(
                              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 96,
                                mainAxisExtent: MemberFace.extent(context),
                              ),
                              itemCount: members.length,
                              itemBuilder: (context, i) {
                                final me = widget.repository.profile.value?.id == members[i].userId;
                                return MemberFace(
                                  member: members[i],
                                  presence: of(members[i]),
                                  detail: _memberDetail(members[i], of(members[i]), me: me),
                                  hint: me ? null : 'Double tap for options',
                                  roleColor: roleColor(members[i]),
                                  onTap: () => _openMember(context, members[i], spaceId),
                                );
                              },
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

/// What a member reads as, after their name: their status, then who they
/// are ("Online · @maya · you").
String _memberDetail(Member member, Presence? presence, {required bool me}) {
  final status = switch (presence) {
    Presence.online => 'Online',
    Presence.doNotDisturb => 'Do not disturb',
    Presence.offline => 'Offline',
    null => null,
  };
  return [?status, '@${member.username}', if (member.isBot) 'bot', if (me) 'you'].join(' · ');
}

/// Their profile over the sheet; the sheet closes only for what's picked
/// there.
Future<void> _openMember(BuildContext context, Member member, String? spaceId) async {
  final action = await showProfileSheet(context, member: member, spaceId: spaceId, canMention: true);
  if (action != null && context.mounted) Navigator.of(context).pop((member, action));
}

/// Someone connected, in a grid of faces (the members sheet's, Friends'):
/// their face with their presence, their name under it (in their role's
/// color, in a Space), their banner faintly behind. Read as their row is:
/// their name, then [detail].
class MemberFace extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final String detail;
  final String? hint;
  final int? roleColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const MemberFace({
    required this.member,
    required this.presence,
    required this.detail,
    required this.onTap,
    this.hint,
    this.roleColor,
    this.onLongPress,
    super.key,
  });

  static const _face = 56.0;

  /// A tile's height: the face, the name under it at any text size, and
  /// the padding around them.
  static double extent(BuildContext context) =>
      _face + 6 + MediaQuery.textScalerOf(context).scale(DuvetType.caption.fontSize! * 1.4) * 2 + 16;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Semantics(
      button: true,
      label: '${member.displayName}, $detail',
      hint: hint,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        builder: (context, pressed) => AnimatedContainer(
          duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          decoration: BoxDecoration(
            color: pressed ? colors.foreground.withValues(alpha: 0.08) : Colors.transparent,
            image: memberBanner(context, member.bannerUrl, offline: isOffline(presence)),
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
          ),
          child: Column(
            children: [
              PresenceAvatar(member: member, presence: presence, size: _face),
              const SizedBox(height: 6),
              Text(
                member.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: DuvetType.caption.copyWith(
                  fontWeight: FontWeight.w500,
                  color: roleColor == null ? colors.foreground : readableOn(Color(roleColor!), colors.card),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final bool me;
  final String? spaceId;

  /// Their highest colored role's color (ARGB): it tints the name, never fills.
  final int? roleColor;
  const _MemberRow({required this.member, required this.presence, required this.me, this.spaceId, this.roleColor});

  @override
  Widget build(BuildContext context) => GlassRow(
    label: member.displayName,
    labelColor: roleColor == null ? null : readableOn(Color(roleColor!), context.theme.colors.card),
    // The status as the caption line, then who they are.
    detail: _memberDetail(member, presence, me: me),
    hint: me ? null : 'Double tap for options',
    leading: PresenceAvatar(member: member, presence: presence, size: 48),
    banner: member.bannerUrl,
    bannerOffline: isOffline(presence),
    onPressed: () => _openMember(context, member, spaceId),
  );
}

/// A member's avatar with their presence: a filled dot when online, a dot with
/// a bar for do not disturb, a ring when offline. Shape tells them apart, not
/// color alone. Not reported: no status at all.
class PresenceAvatar extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final double size;

  /// The ground the dot is cut out of: the card it sits on, by default.
  final Color? ring;
  const PresenceAvatar({required this.member, required this.presence, this.size = 40, this.ring, super.key});

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
            Positioned(right: -1, bottom: -1, child: dotFor(context, presence, dot, ring: ring)),
        ],
      ),
    );
  }

  /// Presence by shape: a filled ice dot online, a dot with a bar for do not
  /// disturb, a ring offline.
  static Widget dotFor(BuildContext context, Presence presence, double dot, {Color? ring}) {
    final colors = context.theme.colors;
    final ground = ring ?? colors.card;
    // Online is the mascot's ice: what's alive.
    final online = context.duvet.alive;
    return Container(
      width: dot,
      height: dot,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: ground, shape: BoxShape.circle),
      child: switch (presence) {
        Presence.online => DecoratedBox(
          decoration: BoxDecoration(color: online, shape: BoxShape.circle),
        ),
        Presence.doNotDisturb => DecoratedBox(
          decoration: BoxDecoration(color: colors.destructive, shape: BoxShape.circle),
          child: Center(
            child: Container(width: dot * 0.45, height: 2, color: ground),
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
