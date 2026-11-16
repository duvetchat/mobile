import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/glass.dart';

/// The notices of mentions of the user in chats that aren't on screen
/// ([ChatRepository.mentionNotices]), at the top of the app over every
/// screen, the newest first: who, where, and what they wrote. A tap opens the
/// message, on [navigator]; a swipe up takes the notice away.
///
/// Each new one plays the mention sound (main.dart), unless the phone is on
/// silent or Do not disturb.
class MentionNotices extends StatelessWidget {
  final GlobalKey<NavigatorState> navigator;
  const MentionNotices({required this.navigator, super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ValueListenableBuilder(
      valueListenable: repository.mentionNotices,
      builder: (context, notices, _) {
        if (notices.isEmpty) return const SizedBox.shrink();
        return SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final notice in notices)
                      _Notice(
                        key: ValueKey(notice.messageId),
                        notice: notice,
                        onOpen: () => _open(repository, notice),
                        onDismiss: () => repository.dismissMentionNotice(notice.messageId),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _open(ChatRepository repository, MentionNotice notice) {
    repository.dismissMentionNotice(notice.messageId);
    final context = navigator.currentContext;
    if (context == null) return;
    // Over a page left open (a form half filled): the notice doesn't close it.
    openChatRoute(
      context,
      ChatRoute(target: notice.target, title: notice.title, jumpTo: notice.messageId),
      reveal: false,
    );
  }
}

class _Notice extends StatelessWidget {
  final MentionNotice notice;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  const _Notice({required this.notice, required this.onOpen, required this.onDismiss, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final still = MediaQuery.disableAnimationsOf(context);
    final card = Semantics(
      container: true,
      button: true,
      liveRegion: true,
      label: '${notice.authorName} mentioned you ${notice.where}: ${notice.text}',
      excludeSemantics: true,
      onTap: onOpen,
      onDismiss: onDismiss,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: GlassSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserAvatar(name: notice.authorName, url: notice.authorAvatarUrl, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: notice.authorName,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(
                              text: ' ${notice.where}',
                              style: TextStyle(color: colors.mutedForeground),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.caption.copyWith(color: colors.foreground),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notice.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.snippet.copyWith(color: colors.foreground),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey(notice.messageId),
        direction: DismissDirection.up,
        onDismissed: (_) => onDismiss(),
        // Slides down into place.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: still ? Duration.zero : DuvetTokens.panelIn,
          curve: DuvetTokens.decelerate,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset(0, -16 * (1 - t)), child: child),
          ),
          child: card,
        ),
      ),
    );
  }
}
