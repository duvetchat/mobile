import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/links.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/scope.dart';
import '../theme.dart';
import 'avatar.dart';
import 'depth.dart';
import 'message_content.dart';
import 'rows.dart';
import 'skeleton.dart';

/// Duvet's own links in a message's text, each once: message links and
/// invites, which show as cards under it.
List<String> duvetLinksIn(String content) {
  final seen = <String>{};
  return [
    for (final m in RegExp(r'''(?:https?|duvet)://[^\s<>()\[\]"']+''').allMatches(content))
      if ((parseDeepLink(m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '')) != null ||
              parseBotInvite(m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '')) != null) &&
          seen.add(m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '')))
        m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), ''),
  ].take(3).toList();
}

/// [content] without the links its previews stand in for: one whose embed is
/// only a picture, a GIF or a video, and, with [cards], an invite shown as
/// its card. A link goes only alone on its line or at either end of it, so
/// the words around it stay; a code block keeps its links.
String withoutPreviewedLinks(String content, List<MessageEmbed> embeds, {bool cards = true}) {
  final bare = [
    for (final e in embeds)
      if (e.isWordless && (e.imageUrl != null || e.videoUrl != null)) e,
  ];
  final invites = {
    if (cards)
      for (final url in duvetLinksIn(content))
        if (parseInviteCode(url) != null || parseBotInvite(url) != null) url,
  };
  if (bare.isEmpty && invites.isEmpty) return content;
  final links = RegExp(r'''(?:https?|duvet)://\S+''').allMatches(content).length;
  bool previewed(String word) =>
      invites.contains(word.replaceFirst(RegExp(r'[.,;:!?]+$'), '')) ||
      (word.startsWith(RegExp('https?://')) &&
          (bare.any((e) => e.url == word) ||
              // Tenor's embed names no link: the only link and the only embed go together.
              (links == 1 && embeds.length == 1 && bare.length == 1 && bare.single.url == null)));

  var fenced = false;
  var changed = false;
  final lines = <String>[];
  for (final line in content.split('\n')) {
    final fences = '```'.allMatches(line).length;
    if (fences.isOdd) fenced = !fenced;
    if (fenced || fences > 0) {
      lines.add(line);
      continue;
    }
    var kept = line;
    if (RegExp(r'^\s*(\S+)\s*').firstMatch(kept) case final first? when previewed(first[1]!)) {
      kept = kept.substring(first.end);
    }
    if (RegExp(r'\s*(\S+)\s*$').firstMatch(kept) case final last? when previewed(last[1]!)) {
      kept = kept.substring(0, last.start);
    }
    if (kept == line) {
      lines.add(line);
    } else {
      changed = true;
      if (kept.trim().isNotEmpty) lines.add(kept);
    }
  }
  return changed ? lines.join('\n').trim() : content;
}

/// The chat a message link points into.
ChatTarget targetOf(MessageLink link) => link.conversationId != null
    ? ConversationTarget(link.conversationId!)
    : RoomTarget(spaceId: link.spaceId!, roomId: link.roomId!);

/// What's said of a link to a room the user can't see, which opens nothing.
const roomUnavailable = 'That room isn’t available';

/// Whether [link] points into a room its Space doesn't list to the user, one
/// they can't see (or that's gone): opening it would only fail. A Space not
/// known yet can't tell.
bool linksHiddenRoom(ChatRepository repository, MessageLink link) {
  if (link.conversationId != null) return false;
  final space = repository.spaces.value.where((s) => s.id == link.spaceId).firstOrNull;
  return space != null && space.rooms.every((r) => r.id != link.roomId);
}

/// A link to a message, quoted: where it is, who wrote it, and its text, in
/// a recess; tapping it jumps there.
class MessageLinkCard extends StatefulWidget {
  final MessageLink link;
  final MessageDirectory directory;
  final ValueChanged<MessageLink> onOpen;
  const MessageLinkCard({required this.link, required this.directory, required this.onOpen, super.key});

  @override
  State<MessageLinkCard> createState() => _MessageLinkCardState();
}

class _MessageLinkCardState extends State<MessageLinkCard> {
  late Future<ChatMessage> _message;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _message = context.repository.fetchMessage(targetOf(widget.link), widget.link.messageId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final repository = context.repository;
    final link = widget.link;
    final String where;
    if (link.conversationId case final id?) {
      where = repository.conversations.value.where((c) => c.id == id).firstOrNull?.title ?? 'Direct message';
    } else {
      final space = repository.spaces.value.where((s) => s.id == link.spaceId).firstOrNull;
      final room = space?.rooms.where((r) => r.id == link.roomId).firstOrNull;
      where = room == null ? 'A room' : '# ${room.name} · ${space!.name}';
    }
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    return FutureBuilder(
      future: _message,
      builder: (context, snapshot) {
        final m = snapshot.data;
        final label = m == null
            ? (snapshot.hasError ? 'Linked message, unavailable' : 'Linked message, loading')
            : 'Linked message from ${m.authorName} in $where. Jump to message';
        return Semantics(
          container: true,
          button: m != null,
          label: label,
          excludeSemantics: true,
          onTap: m == null ? null : () => widget.onOpen(link),
          child: GestureDetector(
            onTap: m == null ? null : () => widget.onOpen(link),
            child: Container(
              width: 280,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
              child: InsetShadow(
                shadows: tokens.shadowWell,
                borderRadius: radius,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(where, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    if (m == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          snapshot.hasError ? 'This message is unavailable' : 'Loading…',
                          style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
                        ),
                      )
                    else ...[
                      const SizedBox(height: 8),
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
                      if (m.content.isEmpty)
                        Text(
                          repository.previewOf(m),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.snippet.copyWith(color: colors.foreground),
                        )
                      else
                        // Its markdown as the chat shows it, cut off past a few lines.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 120),
                          child: SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            child: MessageText(
                              content: m.content,
                              directory: widget.directory,
                              style: DuvetType.snippet.copyWith(color: colors.foreground),
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            'Jump to message',
                            style: DuvetType.caption.copyWith(color: tokens.accentText, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 4),
                          Icon(FLucideIcons.arrowRight, size: 14, color: tokens.accentText),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// An invite link, as a card: the Space it leads to and a button to join;
/// an expired one reads quietly.
class InviteCard extends StatefulWidget {
  final String code;

  /// Opens the Space, once joined.
  final ValueChanged<String> onOpenSpace;
  const InviteCard({required this.code, required this.onOpenSpace, super.key});

  @override
  State<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<InviteCard> {
  late Future<InvitePreview> _invite;
  bool _joining = false;
  String? _joined;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _invite = context.repository.invite(widget.code);
  }

  Future<void> _join(InvitePreview invite) async {
    setState(() => _joining = true);
    try {
      final spaceId = await context.repository.joinInvite(invite.code);
      if (!mounted) return;
      setState(() => _joined = spaceId);
      showFToast(context: context, title: Text('You joined ${invite.spaceName}'), duration: const Duration(seconds: 3));
    } catch (e) {
      // The API's reason, as the desktop shows it.
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : 'Couldn’t join'),
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return FutureBuilder(
      future: _invite,
      builder: (context, snapshot) {
        final invite = snapshot.data;
        // One that doesn't load shows nothing, as on the desktop.
        if (snapshot.hasError) return const SizedBox.shrink();
        if (invite == null) return const InviteCardSkeleton();
        final joined = invite.joined || _joined != null;
        final spaceId = _joined ?? invite.spaceId;
        return Semantics(
          container: true,
          label: 'Invite to ${invite.spaceName}',
          explicitChildNodes: true,
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
              boxShadow: tokens.shadowRaised,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    'YOU’RE INVITED TO A SPACE',
                    style: DuvetType.overline.copyWith(color: colors.mutedForeground),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SpaceIcon(
                      space: Space(id: invite.spaceId, name: invite.spaceName),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            invite.spaceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                          ),
                          Text(
                            invite.memberCount == 1 ? '1 member' : '${invite.memberCount} members',
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (joined)
                  DuvetButton(
                    label: 'Open ${invite.spaceName}',
                    expand: true,
                    onPressed: () => widget.onOpenSpace(spaceId),
                  )
                else
                  DuvetButton(
                    label: 'Join ${invite.spaceName}',
                    variant: ButtonVariant.primary,
                    expand: true,
                    busy: _joining,
                    onPressed: () => _join(invite),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// An invite card while it loads, as the desktop's: pulsing blocks where its
/// header, icon, name and button go, at the card's own size, so nothing moves
/// when it lands.
class InviteCardSkeleton extends StatelessWidget {
  /// A bot's invite: its rounded square, and its name alone.
  final bool bot;
  const InviteCardSkeleton({this.bot = false, super.key});

  @override
  Widget build(BuildContext context) {
    const line = BorderRadius.all(Radius.circular(4));
    return Container(
      width: 280,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.theme.colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: context.duvet.shadowRaised,
      ),
      child: DuvetSkeleton(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The header's line is 16.8 high (12 at 1.4).
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.4),
              child: Bone(width: bot ? 144 : 176, height: 12, borderRadius: line),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Bone.square(size: 48, borderRadius: BorderRadius.circular(bot ? 48 * 0.3 : DuvetTokens.radiusField)),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone(width: bot ? 96 : 112, height: 16, borderRadius: line),
                    if (!bot) ...[const SizedBox(height: 6), const Bone(width: 80, height: 12, borderRadius: line)],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Bone(
              width: double.infinity,
              height: 48,
              borderRadius: BorderRadius.all(Radius.circular(DuvetTokens.radiusButton)),
            ),
          ],
        ),
      ),
    );
  }
}
