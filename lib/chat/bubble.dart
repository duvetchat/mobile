part of '../chat_view.dart';

/// Whether [m] mentions the user [me], as the desktop has it: its text (a v2
/// message's text displays) names them, or it replies to them and mentions
/// them. Never their own message.
bool _mentionsUser(ChatMessage m, String? me) =>
    me != null &&
    m.authorId != me &&
    (mentionedIn(m.text).contains(me) || (m.reply?.mentionAuthor == true && m.reply?.authorId == me));

/// The unread mentions of [me] among [messages] (oldest first): the newest
/// [count] that mention them, [count] being how many the app has unread there.
Set<String> unreadMentions(Iterable<ChatMessage> messages, String? me, int count) => {
  if (count > 0)
    for (final m in messages.toList().reversed.where((m) => _mentionsUser(m, me)).take(count)) m.id,
};

/// One message: the sender's name over a run's first bubble, the reply it
/// quotes, the bubble, its reactions, and the time under a run's last one.
///
/// The reply gesture the user picked in Appearance replies: a swipe left or
/// right, or a double tap (the bubble does the press); a long press opens its
/// actions.
class _Bubble extends StatelessWidget {
  final _Entry entry;
  final bool mine;
  final String? me;
  final bool firstOfRun;
  final bool lastOfRun;

  /// The copy shown over the scrim with its actions: the bubble alone.
  final bool lifted;
  final MessageDirectory directory;
  final String? stickerName;

  /// Being edited in the composer.
  final bool editing;

  /// Just jumped to.
  final bool flash;

  /// Sending, while the socket is down.
  final bool waiting;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;
  final VoidCallback onReply;
  final ValueChanged<String> onJump;
  final void Function(String emoji, String? emojiId) onReact;
  final VoidCallback onMoreReactions;

  /// A reaction chip held: who reacted with it.
  final ValueChanged<Reaction> onOpenReactors;

  /// Held: its options. Null where it has none, as in the pins.
  final ValueChanged<BuildContext>? onLongPress;

  /// How far its files have uploaded, 0 to 1, while sending.
  final double? progress;
  final VoidCallback? onCancelUpload;

  /// The server refused its files as too large.
  final bool tooLarge;
  final ValueChanged<MessageLink> onOpenLink;
  final ValueChanged<String> onOpenSpace;

  /// Their avatar or name was tapped: their profile.
  final VoidCallback onOpenAuthor;

  /// A mention in the text tapped: the user it names.
  final ValueChanged<String> onOpenMention;

  /// A room mention in the text tapped: the room.
  final ValueChanged<Room> onOpenRoom;

  /// A bot's button or select used.
  final Future<void> Function(UiComponent component, List<String>? values) onUseComponent;
  final SelectChoices selectChoices;

  /// Dismisses a bot's answer to the user alone.
  final VoidCallback? onDismiss;

  /// An unread mention of the user, its light yet to come up: called when it
  /// does, as all of the bubble first comes into sight.
  final VoidCallback? onShine;

  const _Bubble({
    required this.entry,
    required this.mine,
    required this.me,
    required this.firstOfRun,
    required this.lastOfRun,
    required this.directory,
    required this.onReply,
    required this.onJump,
    required this.onReact,
    required this.onMoreReactions,
    required this.onOpenReactors,
    required this.onLongPress,
    this.lifted = false,
    this.stickerName,
    this.editing = false,
    this.flash = false,
    this.waiting = false,
    this.onRetry,
    this.onDiscard,
    this.progress,
    this.onCancelUpload,
    this.tooLarge = false,
    required this.onOpenLink,
    required this.onOpenSpace,
    required this.onOpenAuthor,
    required this.onOpenMention,
    required this.onOpenRoom,
    required this.onUseComponent,
    required this.selectChoices,
    this.onDismiss,
    this.onShine,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final m = entry.message;
    final mentionsMe = !mine && _mentionsUser(m, directory.me);
    final text = withoutPreviewedLinks(m.content, m.embeds, cards: !lifted);
    final textBubble = text.isNotEmpty && !isJumboEmoji(text);
    // Prism: a text bubble that mentions the user, in its text or as a reply
    // to them, is lit. With no text bubble (a sticker, a bot's components),
    // the light frames the whole message.
    final prism = mentionsMe && textBubble ? tokens.prism : null;
    const bubblePadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.75;
    final secondary = DuvetType.caption.copyWith(color: colors.mutedForeground);
    final faded = entry.delivery != _Delivery.sent;

    // With double tap picked, double-tap a text bubble (which does the press),
    // a sticker, a big emoji or a picture to reply; files, videos and voice
    // keep their single taps at once. A long press anywhere is the bubble's. A
    // bot's answer to the user alone takes no reply.
    final repliable = entry.delivery == _Delivery.sent && !m.isEphemeral;
    final gesture = AppearanceScope.maybeOf(context)?.replyGesture ?? ReplyGesture.swipeLeft;
    final onDoubleTap = repliable && !lifted && gesture == ReplyGesture.doubleTap ? onReply : null;
    // The message's own actions for screen readers. A text bubble offers them
    // with its text's (its mentions, links, spoilers), so all of it is one
    // stop: two nodes with actions don't merge. They anchor where a long
    // press does.
    Map<CustomSemanticsAction, VoidCallback> actionsAt(BuildContext anchor) => {
      if (repliable) const CustomSemanticsAction(label: 'Reply'): onReply,
      if (onLongPress case final hold?) const CustomSemanticsAction(label: 'Message options'): () => hold(anchor),
    };

    Widget bodyAt(BuildContext? anchor) {
      final parts = <Widget>[
        if (m.isLoading) _Thinking(name: m.authorName, since: m.createdAt),
        if (m.stickerUrl != null)
          GestureDetector(
            onDoubleTap: onDoubleTap,
            child: StickerView(url: m.stickerUrl!, name: stickerName, zoomable: !lifted),
          ),
        if (text.isNotEmpty)
          if (isJumboEmoji(text))
            GestureDetector(
              onDoubleTap: onDoubleTap,
              child: MessageText(
                content: text,
                directory: directory,
                style: DuvetType.body.copyWith(color: colors.foreground),
              ),
            )
          else
            Pressable(
              scale: 0.98,
              onDoubleTap: onDoubleTap,
              builder: (context, _) {
                final message = MessageText(
                  content: text,
                  directory: directory,
                  onAccent: mine,
                  style: DuvetType.body.copyWith(color: mine ? ownBubble(context).ink : colors.foreground),
                  onMention: onOpenMention,
                  onRoom: onOpenRoom,
                  messageActions: anchor == null ? const {} : actionsAt(anchor),
                );
                if (prism == null) {
                  return Container(
                    padding: bubblePadding,
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    decoration: BoxDecoration(
                      color: mine ? ownBubble(context).fill : colors.card,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                      boxShadow: editing ? null : (lifted ? tokens.shadowFloat : tokens.shadowRest),
                    ),
                    child: message,
                  );
                }
                // The same bubble, the mention's light between its fill and its
                // text: the padding goes inside, so the light reaches the edges.
                return Container(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                    boxShadow: [...(lifted ? tokens.shadowFloat : tokens.shadowRest), prismShadow(prism)],
                  ),
                  child: PrismBubble(
                    palette: prism,
                    radius: DuvetTokens.radiusButton,
                    // A copy held up is lit already.
                    onArrive: lifted ? null : onShine,
                    child: Padding(padding: bubblePadding, child: message),
                  ),
                );
              },
            ),
        if (m.isVoice && m.attachments.isNotEmpty)
          VoiceNotePlayer(
            attachment: m.attachments.first,
            mine: mine,
            authorName: m.authorName,
            authorAvatarUrl: m.authorAvatarUrl,
          )
        else if (m.attachments.isNotEmpty)
          MessageAttachments(attachments: m.attachments, uploadProgress: progress, onDoubleTap: onDoubleTap),
        for (final a in m.deletedAttachments) DeletedAttachment(attachment: a, voice: m.isVoice, maxWidth: maxWidth),
        // Duvet's own links, as cards: a quoted message, an invite.
        if (!lifted)
          for (final url in duvetLinksIn(m.content))
            if (parseMessageLink(url) case final link?)
              MessageLinkCard(link: link, directory: directory, onOpen: onOpenLink)
            else if (parseBotInvite(url) case final bot?)
              BotInviteCard(botId: bot)
            else if (parseInviteCode(url) case final code?)
              InviteCard(code: code, onOpenSpace: onOpenSpace),
        for (final e in m.embeds) EmbedCard(embed: e),
        if (m.components.isNotEmpty && !lifted)
          BotComponents(
            components: m.components,
            directory: directory,
            choices: selectChoices,
            onUse: entry.delivery == _Delivery.sent ? onUseComponent : (_, _) async {},
          ),
      ];

      Widget content = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, part) in parts.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
              child: part,
            ),
        ],
      );
      // A mention with no text bubble to light (a bot's components, a
      // sticker): a frame of the same light round the whole message, 8 out
      // from it, with no fill and no shadow, which would show through it.
      if (mentionsMe && !textBubble) {
        content = PrismBubble(
          palette: tokens.prism,
          radius: DuvetTokens.radiusButton,
          onArrive: lifted ? null : onShine,
          child: Padding(padding: const EdgeInsets.all(8), child: content),
        );
      }
      return Opacity(opacity: editing ? 0.55 : (faded ? 0.7 : 1), child: content);
    }

    if (lifted) {
      return Transform.scale(
        scale: 1.02,
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: bodyAt(null),
      );
    }

    // The time under the run's last bubble; "edited" under the edited one.
    final meta = [if (lastOfRun) _time(m.createdAt), if (m.edited) 'edited'].join(' · ');
    final status = switch (entry.delivery) {
      _ when editing => _Caption(icon: FLucideIcons.pencil, text: 'Editing', style: secondary),
      _Delivery.failed => _FailedActions(onRetry: tooLarge ? null : onRetry, onDiscard: onDiscard, tooLarge: tooLarge),
      _Delivery.sending when waiting => _Caption(
        icon: FLucideIcons.clock,
        text: 'Waiting for connection',
        style: secondary,
      ),
      _Delivery.sending when m.attachments.isNotEmpty && !m.isVoice => _UploadStatus(
        files: m.attachments,
        progress: progress ?? 0,
        onCancel: onCancelUpload,
      ),
      _Delivery.sending when m.isVoice => _Caption(text: 'Sending…', style: secondary),
      _ when meta.isNotEmpty => _Caption(text: meta, style: secondary),
      _ => null,
    };

    final column = Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (firstOfRun && !mine)
          GestureDetector(
            onTap: onOpenAuthor,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: m.fromBot || m.fromWebhook
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(m.authorName, style: secondary)),
                        const SizedBox(width: 6),
                        BotTag(webhook: m.fromWebhook),
                      ],
                    )
                  : Text(m.authorName, style: secondary),
            ),
          ),
        if (m.reply case final reply?)
          _ReplyRef(reply: reply, directory: directory, onTap: () => onJump(reply.messageId))
        else if (m.interaction case final used?)
          _UsedRef(
            used: used,
            botName: m.authorName,
            onTap: switch (used.interactedMessageId) {
              final id? => () => onJump(id),
              null => null,
            },
          ),
        Builder(
          builder: (anchor) => GestureDetector(
            onLongPress: switch (onLongPress) {
              final hold? => () {
                HapticFeedback.mediumImpact();
                hold(anchor);
              },
              null => null,
            },
            child: bodyAt(anchor),
          ),
        ),
        if (m.reactions.isNotEmpty)
          _Reactions(
            reactions: m.reactions,
            me: me,
            directory: directory,
            onReact: onReact,
            onReactors: onOpenReactors,
            onMore: onMoreReactions,
          ),
        if (m.isEphemeral) _EphemeralNote(onDismiss: onDismiss),
        ?status,
      ],
    );

    // A jump lands here: a brief `accent-tint` behind the message. One
    // message is one stop for screen readers, its name, text and time read
    // together; its pictures, quote and reactions are stops inside it, and its
    // actions are custom actions.
    final highlighted = Builder(
      builder: (whole) => Semantics(
        container: true,
        // A text bubble's text carries them, with its own.
        customSemanticsActions: textBubble ? null : actionsAt(whole),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: DuvetTokens.decelerate,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: flash ? tokens.accentTint : const Color(0x00000000),
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          ),
          child: column,
        ),
      ),
    );

    // 4pt between bubbles of a run, 12pt between runs (less the highlight's
    // own 4pt).
    final gap = EdgeInsets.only(top: firstOfRun ? 8 : 0);
    final onSwipe = repliable && gesture != ReplyGesture.doubleTap ? onReply : null;
    final left = gesture != ReplyGesture.swipeRight;
    if (mine) {
      return Padding(
        padding: gap,
        child: _SwipeToReply(
          onReply: onSwipe,
          left: left,
          child: Align(alignment: Alignment.centerRight, child: highlighted),
        ),
      );
    }
    return Padding(
      padding: gap,
      child: _SwipeToReply(
        onReply: onSwipe,
        left: left,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // The avatar beside the run's last bubble, above its time.
            SizedBox(
              width: 36,
              child: lastOfRun
                  ? Padding(
                      padding: EdgeInsets.only(
                        bottom:
                            4 +
                            (status == null ? 0 : 22) +
                            (m.reactions.isEmpty ? 0 : 32) +
                            (m.isEphemeral ? _EphemeralNote.height : 0),
                      ),
                      child: Semantics(
                        container: true,
                        button: true,
                        label:
                            '${m.authorName}${m.fromWebhook
                                ? ', webhook,'
                                : m.fromBot
                                ? ', bot,'
                                : ''}’s profile',
                        excludeSemantics: true,
                        onTap: onOpenAuthor,
                        child: GestureDetector(
                          onTap: onOpenAuthor,
                          child: m.fromBot
                              ? const BotAvatar()
                              : UserAvatar(name: m.authorName, url: m.authorAvatarUrl, size: 32),
                        ),
                      ),
                    )
                  : null,
            ),
            Flexible(child: highlighted),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// A chat's messages while its first page loads, as the desktop draws them
/// (every third one longer), in [_Bubble]'s places: the avatar beside a run's
/// last bubble, the name over its first, the time's room under it, and some
/// runs the user's own on the right. From the bottom up, as many as fill the
/// screen, the oldest cut off at the top; it never scrolls.
class _MessagesSkeleton extends StatelessWidget {
  /// The list's own, so the blocks land where the messages will.
  final EdgeInsets padding;
  const _MessagesSkeleton({required this.padding});

  // The shortest run, a lone one-line bubble with its name and time.
  static const _shortest = 96.0;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.75;
    // A one-line text bubble: the body's line and its padding.
    Widget bubble(double share) => Bone(
      width: maxWidth * share,
      height: DuvetType.body.fontSize! * DuvetType.body.height! + 16,
      borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
    );

    Widget run(int i) {
      final wide = i % 3 == 0;
      final mine = i % 3 == 1;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine) const Padding(padding: EdgeInsets.only(right: 4, bottom: 26), child: Bone.circle(size: 32)),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (!mine)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 3, 0, 7),
                        child: Bone(width: 96, height: 12, borderRadius: BorderRadius.all(Radius.circular(4))),
                      ),
                    bubble(wide ? 0.8 : 0.4),
                    if (wide) ...[const SizedBox(height: 8), bubble(0.6)],
                    const SizedBox(height: 22),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Semantics(
      container: true,
      label: 'Loading messages',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) => ClipRect(
          child: OverflowBox(
            alignment: Alignment.bottomCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Padding(
              padding: padding,
              child: DuvetSkeleton(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = (constraints.maxHeight / _shortest).ceil(); i >= 0; i--) run(i)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Swiping a message [left] (as in WhatsApp) or right replies to it: the
/// message follows the finger, the reply icon grows in behind it on the side
/// it leaves, a tick says a release will reply, and it slides back. Scrollers
/// and sliders inside the message keep their own horizontal drags.
class _SwipeToReply extends StatefulWidget {
  /// Null while the message can't be replied to: no swipe.
  final VoidCallback? onReply;

  /// The way the user picked, on screen whatever the text direction.
  final bool left;
  final Widget child;
  const _SwipeToReply({required this.onReply, required this.left, required this.child});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> with SingleTickerProviderStateMixin {
  // The message follows the finger to the threshold, where a release replies,
  // then a fifth as fast, up to [_max].
  static const _threshold = 64.0;
  static const _max = 96.0;
  late final _shift = AnimationController(vsync: this, upperBound: _max, duration: const Duration(milliseconds: 250));
  double _travel = 0;

  bool get _armed => _shift.value >= _threshold;

  @override
  void dispose() {
    _shift.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails d) {
    _travel = math.max(0, _travel + (widget.left ? -d.delta.dx : d.delta.dx));
    final wasArmed = _armed;
    _shift.value = _travel <= _threshold ? _travel : _threshold + (_travel - _threshold) / 5;
    if (_armed && !wasArmed) HapticFeedback.selectionClick();
  }

  void _release() {
    if (_armed) widget.onReply?.call();
    _travel = 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _shift.value = 0;
    } else {
      _shift.animateTo(0, curve: DuvetTokens.decelerate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final accent = context.duvet.accentText;
    final left = widget.left;
    // The same tree whether or not it can be replied to, so a message being
    // sent isn't mounted again once it is.
    final enabled = widget.onReply != null;
    return GestureDetector(
      // All of the row takes the swipe, not only the bubble.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: enabled ? _drag : null,
      onHorizontalDragEnd: enabled ? (_) => _release() : null,
      onHorizontalDragCancel: enabled ? _release : null,
      child: AnimatedBuilder(
        animation: _shift,
        child: widget.child,
        builder: (context, child) {
          final shown = (_shift.value / _threshold).clamp(0.0, 1.0);
          return Stack(
            alignment: left ? Alignment.centerRight : Alignment.centerLeft,
            children: [
              if (shown > 0)
                Padding(
                  padding: left ? const EdgeInsets.only(right: 12) : const EdgeInsets.only(left: 12),
                  child: Opacity(
                    opacity: shown,
                    child: Transform.scale(
                      scale: 0.6 + 0.4 * shown,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: colors.secondary, shape: BoxShape.circle),
                        child: Icon(FLucideIcons.reply, size: 16, color: _armed ? accent : colors.mutedForeground),
                      ),
                    ),
                  ),
                ),
              Transform.translate(offset: Offset(left ? -_shift.value : _shift.value, 0), child: child),
            ],
          );
        },
      ),
    );
  }
}

/// A line under a bubble: its time, "Editing", "Uploading…".
class _Caption extends StatelessWidget {
  final IconData? icon;
  final String text;
  final TextStyle style;
  const _Caption({required this.text, required this.style, this.icon});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ExcludeSemantics(child: Icon(icon, size: 14, color: style.color)),
          const SizedBox(width: 4),
        ],
        Flexible(child: Text(text, style: style)),
      ],
    ),
  );
}

/// Under a bot's answer to the user alone: "Only you can see this · Dismiss
/// message", as on the desktop.
class _EphemeralNote extends StatelessWidget {
  final VoidCallback? onDismiss;
  const _EphemeralNote({this.onDismiss});

  /// Dismiss's tap target.
  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final style = DuvetType.caption.copyWith(color: colors.mutedForeground);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(child: Icon(FLucideIcons.eye, size: 14, color: colors.mutedForeground)),
            const SizedBox(width: 4),
            Flexible(
              child: Text('Only you can see this', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
            ExcludeSemantics(child: Text(' · ', style: style)),
            Semantics(
              container: true,
              button: true,
              label: 'Dismiss message',
              excludeSemantics: true,
              onTap: onDismiss,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: Center(
                  child: Text(
                    'Dismiss message',
                    style: style.copyWith(color: context.duvet.accentText, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A bot's deferred answer until it completes it: "Ballot is thinking…",
/// and past the 15 minutes it has, "The application did not respond", as on
/// the desktop.
class _Thinking extends StatefulWidget {
  final String name;
  final DateTime since;
  const _Thinking({required this.name, required this.since});

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> {
  static const _window = Duration(minutes: 15);
  Timer? _late;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_Thinking old) {
    super.didUpdateWidget(old);
    if (old.since != widget.since) _schedule();
  }

  @override
  void dispose() {
    _late?.cancel();
    super.dispose();
  }

  // A redraw once the window has passed.
  void _schedule() {
    _late?.cancel();
    final left = widget.since.add(_window).difference(time.clock.now());
    if (!left.isNegative) _late = Timer(left + const Duration(milliseconds: 1), () => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    if (time.clock.now().difference(widget.since) > _window) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(FLucideIcons.circleAlert, size: 16, color: colors.destructive)),
          const SizedBox(width: 6),
          Flexible(
            child: Text('The application did not respond', style: DuvetType.body.copyWith(color: colors.destructive)),
          ),
        ],
      );
    }
    return Text(
      '${widget.name} is thinking…',
      style: DuvetType.body.copyWith(color: colors.mutedForeground, fontStyle: FontStyle.italic),
    );
  }
}

/// Under a message that didn't send: "Not sent", then Retry and Delete.
class _FailedActions extends StatelessWidget {
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  /// Refused as too large: retrying wouldn't help.
  final bool tooLarge;
  const _FailedActions({this.onRetry, this.onDiscard, this.tooLarge = false});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    Widget action(String label, Color color, VoidCallback? onTap, {IconData? icon}) => Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
              Text(
                label,
                style: DuvetType.caption.copyWith(color: color, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: tooLarge ? 'Message not sent: too large' : 'Message not sent',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(child: Icon(FLucideIcons.circleAlert, size: 14, color: colors.destructive)),
            const SizedBox(width: 4),
            ExcludeSemantics(
              child: Text(
                tooLarge ? 'Too large to send' : 'Not sent',
                style: DuvetType.caption.copyWith(color: colors.destructive),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: 12),
              action('Retry', tokens.accentText, onRetry, icon: FLucideIcons.rotateCw),
            ],
            const SizedBox(width: 12),
            action('Delete', colors.destructive, onDiscard),
          ],
        ),
      ),
    );
  }
}

/// Under a message whose files are uploading: "Uploading 2 of 3 · 64%", and
/// Cancel while bytes are still going up.
class _UploadStatus extends StatelessWidget {
  final List<MessageAttachment> files;
  final double progress;
  final VoidCallback? onCancel;
  const _UploadStatus({required this.files, required this.progress, this.onCancel});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final current = math.min(files.length, uploadingIndex(files, progress) + 1);
    final percent = (progress * 100).round();
    final text = files.length == 1 ? 'Uploading · $percent%' : 'Uploading $current of ${files.length} · $percent%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
              ),
            ),
          ),
          if (onCancel != null) ...[
            const SizedBox(width: 8),
            Semantics(
              container: true,
              button: true,
              label: 'Cancel upload',
              excludeSemantics: true,
              onTap: onCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: SizedBox(
                  height: 40,
                  child: Center(
                    child: Text(
                      'Cancel',
                      style: DuvetType.caption.copyWith(color: tokens.accentText, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Above a reply: the message it answers, one line, "**Jon** text…", or
/// "**@Jon** text…" when the reply mentioned them. Tapping it jumps there.
class _ReplyRef extends StatelessWidget {
  final MessageReply reply;
  final MessageDirectory directory;
  final VoidCallback onTap;
  const _ReplyRef({required this.reply, required this.directory, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    if (reply.deleted) {
      return Semantics(
        container: true,
        label: 'Original message was deleted',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FLucideIcons.cornerUpLeft, size: 14, color: colors.mutedForeground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Original message was deleted',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground, fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final text = readableContent(
      plainInline(parseLine(reply.content)),
      nameOf: directory.nameOf,
      emojiNameOf: (id) => directory.emojiOf(id)?.name,
      roomNameOf: (id) => directory.roomOf(id)?.name,
    ).trim();
    final shown = text.isEmpty ? 'a message' : text;
    return Semantics(
      container: true,
      button: true,
      label: 'Replying to ${reply.authorName}: $shown. Jump to message',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260, minHeight: 24),
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FLucideIcons.cornerUpLeft, size: 14, color: colors.mutedForeground),
              const SizedBox(width: 6),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: reply.mentionAuthor ? '@${reply.authorName}' : reply.authorName,
                        style: TextStyle(color: colors.foreground, fontWeight: FontWeight.w500),
                      ),
                      TextSpan(text: ' $shown'),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Above a bot's answer, as the desktop's: the avatar, then "**Jon** used **/ping**",
/// or the bot's name for a component's. Tapping it goes to the message whose
/// component was used.
class _UsedRef extends StatelessWidget {
  final MessageInteraction used;
  final String botName;
  final VoidCallback? onTap;
  const _UsedRef({required this.used, required this.botName, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final what = switch (used.command) {
      final name? => '/$name',
      null => botName,
    };
    final strong = TextStyle(color: colors.foreground, fontWeight: FontWeight.w500);
    return Semantics(
      container: true,
      button: onTap != null,
      label: '${used.userName} used $what${onTap == null ? '' : '. Jump to message'}',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260, minHeight: 24),
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              UserAvatar(name: used.userName, url: used.userAvatarUrl, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: used.userName, style: strong),
                      const TextSpan(text: ' used '),
                      TextSpan(text: what, style: strong),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reaction chips under a bubble: the emoji and its count; the user's
/// own in the selected state; held, who reacted. A last chip adds one.
class _Reactions extends StatelessWidget {
  final List<Reaction> reactions;
  final String? me;
  final MessageDirectory directory;
  final void Function(String emoji, String? emojiId) onReact;
  final ValueChanged<Reaction> onReactors;
  final VoidCallback onMore;
  const _Reactions({
    required this.reactions,
    required this.me,
    required this.directory,
    required this.onReact,
    required this.onReactors,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    Widget chip({
      required String label,
      required Widget child,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
      bool mine = false,
      bool? toggled,
    }) => Semantics(
      container: true,
      button: true,
      toggled: toggled,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      customSemanticsActions: {const CustomSemanticsAction(label: 'See who reacted'): ?onLongPress},
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        builder: (context, pressed) => Container(
          height: 28,
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: mine ? tokens.selectedFill : colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            boxShadow: mine || pressed ? null : tokens.shadowRest,
          ),
          child: DefaultTextStyle.merge(
            style: DuvetType.caption.copyWith(
              color: mine ? tokens.violetText : colors.foreground,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [child]),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final r in reactions)
            () {
              final mine = me != null && r.users.contains(me);
              final custom = r.emojiId == null ? null : directory.emojiOf(r.emojiId!);
              final name = _reactionName(r, directory);
              return chip(
                label: '$name ${r.count}${mine ? ', you reacted' : ''}',
                mine: mine,
                toggled: mine,
                onTap: () => onReact(r.emoji, r.emojiId),
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  onReactors(r);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (custom != null)
                      Image(
                        image: cachedImage(
                          custom.url,
                          cacheWidth: (18 * MediaQuery.devicePixelRatioOf(context)).round(),
                        ),
                        width: 18,
                        height: 18,
                        excludeFromSemantics: true,
                        // Its name until the image arrives, and if it never does.
                        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? Text(name) : child,
                        errorBuilder: (_, _, _) => Text(name),
                      )
                    else
                      r.emojiId == null
                          ? Text(r.emoji, style: TextStyle(fontFamily: DuvetType.emoji, fontSize: 15))
                          : Text(name, style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 4),
                    Text('${r.count}'),
                  ],
                ),
              );
            }(),
          chip(
            label: 'Add reaction',
            onTap: onMore,
            child: Icon(FLucideIcons.smilePlus, size: 16, color: colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// Where the day changes: centered `caption`, no rule.
class _DaySeparator extends StatelessWidget {
  final DateTime day;
  const _DaySeparator({required this.day});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Center(
      child: Semantics(
        header: true,
        child: Text(dayLabel(day), style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground)),
      ),
    ),
  );
}

/// Before the first unread message: "New messages" between two hairlines.
class _NewMessagesDivider extends StatelessWidget {
  final String text;

  /// The thread's "3 replies": `ink-secondary`, regular.
  final bool quiet;
  const _NewMessagesDivider({this.text = 'New messages', this.quiet = false, super.key});

  @override
  Widget build(BuildContext context) {
    final hairline = Expanded(child: Container(height: 1, color: context.duvet.hairline));
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            hairline,
            const SizedBox(width: 12),
            Text(
              text,
              style: DuvetType.caption.copyWith(
                color: quiet ? context.theme.colors.mutedForeground : context.theme.colors.foreground,
                fontWeight: quiet ? FontWeight.w400 : FontWeight.w500,
              ),
            ),
            const SizedBox(width: 12),
            hairline,
          ],
        ),
      ),
    );
  }
}

/// A pin notice, as the desktop's: who pinned "a message", which shows it
/// ([onJump]; null when the notice names none), and "pinned messages", which
/// lists them all. Held, its options ([onHold]; null for those who may not
/// delete it). Screen readers have it as one stop, its links as actions.
class _Notice extends StatefulWidget {
  final String who;
  final String where;
  final VoidCallback? onJump;
  final VoidCallback onPins;
  final ValueChanged<BuildContext>? onHold;
  const _Notice({required this.who, required this.where, required this.onJump, required this.onPins, this.onHold});

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> {
  late final _jump = TapGestureRecognizer()..onTap = () => widget.onJump?.call();
  late final _pins = TapGestureRecognizer()..onTap = () => widget.onPins();

  @override
  void dispose() {
    _jump.dispose();
    _pins.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final link = TextStyle(color: colors.foreground, fontWeight: FontWeight.w500);
    return Builder(
      builder: (anchor) => Semantics(
        container: true,
        label: '${widget.who} pinned a message to this ${widget.where}',
        excludeSemantics: true,
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Show the message'): ?widget.onJump,
          const CustomSemanticsAction(label: 'See all pinned messages'): widget.onPins,
          if (widget.onHold case final onHold?) const CustomSemanticsAction(label: 'Options'): () => onHold(anchor),
        },
        child: GestureDetector(
          onLongPress: widget.onHold == null ? null : () => widget.onHold!(anchor),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(FLucideIcons.pin, size: 14, color: colors.mutedForeground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: widget.who, style: link),
                        const TextSpan(text: ' pinned '),
                        TextSpan(text: 'a message', style: link, recognizer: widget.onJump == null ? null : _jump),
                        TextSpan(text: ' to this ${widget.where}. See all '),
                        TextSpan(text: 'pinned messages', style: link, recognizer: _pins),
                        const TextSpan(text: '.'),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A call notice, as the desktop's: who called and how long the call lasted,
/// or that the reader missed it, by a phone that's red then. Held, its
/// options ([onHold]; null for those who may not delete it).
class _CallNoticeRow extends StatelessWidget {
  final CallNoticeLine line;
  final ValueChanged<BuildContext>? onHold;
  const _CallNoticeRow({required this.line, this.onHold});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Builder(
      builder: (anchor) => Semantics(
        container: true,
        label: '${line.before}${line.name}${line.after}',
        excludeSemantics: true,
        customSemanticsActions: {
          if (onHold case final onHold?) const CustomSemanticsAction(label: 'Options'): () => onHold(anchor),
        },
        child: GestureDetector(
          onLongPress: onHold == null ? null : () => onHold!(anchor),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  line.missed ? FLucideIcons.phoneMissed : FLucideIcons.phone,
                  size: 14,
                  color: line.missed ? colors.destructive : colors.mutedForeground,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (line.before.isNotEmpty) TextSpan(text: line.before),
                        if (line.name.isNotEmpty)
                          TextSpan(
                            text: line.name,
                            style: TextStyle(color: colors.foreground, fontWeight: FontWeight.w500),
                          ),
                        if (line.after.isNotEmpty) TextSpan(text: line.after),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Above the composer: the ghost and its typing dots, then who's typing and
/// who's recording a voice message, as the desktop's typing indicator says it.
class _TypingLine extends StatelessWidget {
  final List<TypingUser> users;
  const _TypingLine({required this.users});

  @override
  Widget build(BuildContext context) {
    final who = typingSentence(users);
    if (who == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Semantics(
          liveRegion: true,
          label: who,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const GhostMark(size: 20),
              const SizedBox(width: 6),
              TypingDots(color: context.duvet.violetText),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  who,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
