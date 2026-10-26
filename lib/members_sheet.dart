import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// What a member's row can do.
enum MemberAction { mention, message, profile }

/// The chat's members in a glass sheet, by presence, with search. Answers the
/// member and what to do with them, or null.
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
            return CustomScrollView(
              controller: widget.scroll,
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
                          me: widget.repository.profile.value?.id == members[i].userId,
                          roleColor: switch (widget.target) {
                            RoomTarget(:final spaceId) =>
                              widget.repository
                                  .rolesOf(spaceId, members[i].userId)
                                  .map((r) => r.color)
                                  .nonNulls
                                  .firstOrNull,
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
  final bool me;

  /// Their highest colored role's color (ARGB): it tints the name, never fills.
  final int? roleColor;
  const _MemberRow({required this.member, required this.presence, required this.me, this.roleColor});

  @override
  Widget build(BuildContext context) {
    final status = switch (presence) {
      Presence.online => 'Online',
      Presence.doNotDisturb => 'Do not disturb',
      Presence.offline => 'Offline',
      null => null,
    };
    // The status as the caption line, then who they are.
    final detail = [?status, '@${member.username}', if (member.isBot) 'bot', if (me) 'you'].join(' · ');
    return Builder(
      builder: (rowContext) => GlassRow(
        label: member.displayName,
        labelColor: roleColor == null ? null : readableOn(Color(roleColor!), context.theme.colors.card),
        detail: detail,
        hint: me ? null : 'Double tap for options',
        leading: PresenceAvatar(member: member, presence: presence, size: 48),
        banner: member.bannerUrl,
        bannerOffline: isOffline(presence),
        // Their profile opens once this sheet closes: never glass on glass.
        onPressed: () => Navigator.of(context).pop((member, MemberAction.profile)),
      ),
    );
  }
}

/// A member's avatar with their presence: a filled dot when online, a dot with
/// a bar for do not disturb, a ring when offline. Shape tells them apart, not
/// color alone. Not reported: no status at all.
class PresenceAvatar extends StatelessWidget {
  final Member member;
  final Presence? presence;
  final double size;
  const PresenceAvatar({required this.member, required this.presence, this.size = 40, super.key});

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
          if (presence case final presence?) Positioned(right: -1, bottom: -1, child: dotFor(context, presence, dot)),
        ],
      ),
    );
  }

  /// Presence by shape: a filled dot online, a dot with a bar for do not
  /// disturb, a ring offline.
  static Widget dotFor(BuildContext context, Presence presence, double dot) {
    final colors = context.theme.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final online = dark ? const Color(0xFF4CC38A) : const Color(0xFF2F9E62);
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
