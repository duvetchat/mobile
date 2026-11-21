part of '../chat_view.dart';

enum _Action {
  react,
  moreReactions,
  reactions,
  reply,
  thread,
  copy,
  copyLink,
  pin,
  unpin,
  edit,
  mention,
  retry,
  delete,
  discard,
}

/// The quick reactions: Unicode emoji, as reactions name them.
const _quickReactions = ['👍', '❤️', '😂', '😮', '👏'];
const _quickNames = {'👍': 'thumbs up', '❤️': 'heart', '😂': 'laughing', '😮': 'surprised', '👏': 'clapping'};

/// A long press on a message: the chat dims behind a scrim, the bubble lifts,
/// a glass bar of quick reactions sits over it and a glass menu of its
/// actions under it. Answers the action picked (with the emoji, for a
/// reaction), or null.
Future<(_Action, String?)?> _showMessageActions(
  BuildContext context, {
  required Rect bubble,
  required Widget lifted,
  required List<GlassMenuItem<_Action>> items,
  required String? me,
  List<Reaction>? reactions,
  EmojiCatalog? catalog,
}) => Navigator.of(context, rootNavigator: true).push(
  _MessageActionsRoute(
    bubble: bubble,
    lifted: lifted,
    items: items,
    me: me,
    reactions: reactions,
    catalog: catalog,
    capturedThemes: InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: true).context),
  ),
);

class _MessageActionsRoute extends PopupRoute<(_Action, String?)> {
  final Rect bubble;
  final Widget lifted;
  final List<GlassMenuItem<_Action>> items;
  final String? me;

  /// Null when the message can't take reactions (not sent yet).
  final List<Reaction>? reactions;
  final EmojiCatalog? catalog;
  final CapturedThemes capturedThemes;

  _MessageActionsRoute({
    required this.bubble,
    required this.lifted,
    required this.items,
    required this.me,
    required this.reactions,
    required this.catalog,
    required this.capturedThemes,
  });

  static const _menuWidth = 248.0;
  static const _rowHeight = 52.0;
  static const _barHeight = 56.0;
  static const _gap = 8.0;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Close message options';

  @override
  Duration get transitionDuration => DuvetTokens.dropdownIn;

  @override
  Duration get reverseTransitionDuration => DuvetTokens.panelOut;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final top = media.padding.top + 8;
    final bottom = screen.height - media.padding.bottom - 8;
    final menuHeight = items.length * _rowHeight + 16;
    final barSpace = reactions == null ? 0.0 : _barHeight + _gap;
    // The bubble where it was, moved up when the menu wouldn't fit under it,
    // and clipped when it's taller than the room left.
    final room = bottom - top - barSpace - _gap - menuHeight;
    final height = min(bubble.height, max(48.0, room));
    var y = bubble.top;
    y = min(y, bottom - menuHeight - _gap - height);
    y = max(y, top + barSpace);
    final rightAligned = bubble.center.dx > screen.width / 2;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final colors = context.theme.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;

    Positioned aligned(Widget child, double width) => Positioned(
      left: rightAligned ? null : bubble.left.clamp(16, max(16.0, screen.width - width - 16)),
      right: rightAligned ? (screen.width - bubble.right).clamp(16, max(16.0, screen.width - width - 16)) : null,
      width: width,
      child: Align(alignment: rightAligned ? Alignment.centerRight : Alignment.centerLeft, child: child),
    );

    return capturedThemes.wrap(
      Semantics(
        label: 'Message options',
        explicitChildNodes: true,
        scopesRoute: true,
        namesRoute: true,
        child: Stack(
          children: [
            // The scrim: the conversation softened behind, still there.
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: FadeTransition(
                  opacity: animation,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: ColoredBox(
                      color: (dark ? const Color(0xFF111113) : colors.background).withValues(alpha: dark ? 0.62 : 0.55),
                    ),
                  ),
                ),
              ),
            ),
            if (reactions case final reactions?)
              aligned(
                _Lift(
                  animation: animation,
                  reduce: reduce,
                  from: 8,
                  child: _QuickReactions(
                    mine: {
                      for (final r in reactions)
                        if (me != null && r.users.contains(me)) r.key,
                    },
                    catalog: catalog,
                  ),
                ),
                min(screen.width - 32, 320),
              ).withTop(y - barSpace),
            aligned(
              SizedBox(
                height: height,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    maxHeight: double.infinity,
                    child: IgnorePointer(child: ExcludeSemantics(child: lifted)),
                  ),
                ),
              ),
              bubble.width,
            ).withTop(y),
            aligned(
              _Lift(
                animation: animation,
                reduce: reduce,
                from: -8,
                child: GlassSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in items)
                          GlassRow(
                            icon: item.icon,
                            label: item.label,
                            hint: item.hint,
                            destructive: item.destructive,
                            onPressed: () => Navigator.of(context).pop((item.value, null)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              _menuWidth,
            ).withTop(y + height + _gap),
          ],
        ),
      ),
    );
  }
}

extension on Positioned {
  /// The same placement, at [top].
  Positioned withTop(double top) => Positioned(left: left, right: right, width: width, top: top, child: child);
}

/// Fades in and settles from [from] pt away, on the panel spring.
class _Lift extends AnimatedWidget {
  final double from;
  final bool reduce;
  final Widget child;
  const _Lift({required Animation<double> animation, required this.from, required this.reduce, required this.child})
    : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final animation = listenable as Animation<double>;
    final forward = animation.status != AnimationStatus.reverse;
    final fade = (forward ? DuvetTokens.decelerate : Curves.easeOut).transform(animation.value);
    if (reduce) return Opacity(opacity: fade, child: child);
    final travel = forward ? DuvetTokens.overshoot.transform(animation.value) : 1.0;
    return Opacity(
      opacity: fade,
      child: Transform.translate(offset: Offset(0, (1 - travel) * from), child: child),
    );
  }
}

/// The glass bar of quick reactions; the user's own are selected. The last
/// button opens the full picker.
class _QuickReactions extends StatelessWidget {
  final Set<String> mine;
  final EmojiCatalog? catalog;
  const _QuickReactions({required this.mine, required this.catalog});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    Widget button({required String label, required Widget child, required (_Action, String?) value, bool on = false}) =>
        Semantics(
          container: true,
          button: true,
          selected: on,
          label: label,
          excludeSemantics: true,
          onTap: () => Navigator.of(context).pop(value),
          child: Pressable(
            onTap: () => Navigator.of(context).pop(value),
            builder: (context, pressed) => Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? tokens.selectedFill : (pressed ? colors.secondary : null),
                borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
              ),
              child: child,
            ),
          ),
        );
    return Semantics(
      label: 'Quick reactions',
      explicitChildNodes: true,
      child: GlassSurface(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Your most used first, the defaults after, five in all; custom
              // emoji stay in the picker.
              for (final emoji in {
                ...EmojiCatalog.recent.where((e) => !e.startsWith('<:')),
                ..._quickReactions,
              }.take(_quickReactions.length))
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: button(
                    label:
                        'React ${catalog?.nameOf(emoji) ?? _quickNames[emoji] ?? emoji}${mine.contains(emoji) ? ', you reacted' : ''}',
                    on: mine.contains(emoji),
                    value: (_Action.react, emoji),
                    child: Text(emoji, style: DuvetType.emojiStyle(24, height: 1.1)),
                  ),
                ),
              button(
                label: 'More reactions',
                value: (_Action.moreReactions, null),
                child: Icon(FLucideIcons.smilePlus, size: 24, color: colors.mutedForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirms deleting a message, for everyone in [where]: the user's own, or
/// with ManageMessages someone else's.
Future<bool?> _showDeleteSheet(
  BuildContext context, {
  required ChatMessage message,
  required bool mine,
  required MessageDirectory directory,
  required String where,
}) => showGlassDialogSheet<bool>(
  context,
  label: 'Delete this message?',
  builder: (context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('Delete this message?', style: DuvetType.title.copyWith(color: colors.foreground)),
          ),
          const SizedBox(height: 16),
          // The message itself, in a recess.
          Container(
            decoration: BoxDecoration(
              color: colors.secondary,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
            ),
            child: InsetShadow(
              shadows: tokens.shadowWell,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              padding: const EdgeInsets.all(16),
              // Its bubble as the chat shows it: the user's own on the accent.
              child: Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: mine ? ownBubble.fill : colors.card,
                    borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                  ),
                  child: message.content.isEmpty
                      ? Text(
                          readableAttachments(message),
                          style: DuvetType.body.copyWith(color: mine ? ownBubble.ink : colors.foreground),
                        )
                      : MessageText(
                          content: message.content,
                          directory: directory,
                          onAccent: mine,
                          singleLine: true,
                          style: DuvetType.body.copyWith(color: mine ? ownBubble.ink : colors.foreground),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'It will be removed for everyone in $where. This can’t be undone.',
            style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 24),
          DuvetButton(
            label: 'Delete for everyone',
            variant: ButtonVariant.destructive,
            expand: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 12),
          DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
        ],
      ),
    );
  },
);

/// What a message with no text carries, in words.
String readableAttachments(ChatMessage m) => switch (m) {
  ChatMessage(stickerUrl: _?) => 'Sticker',
  ChatMessage(attachments: [_]) => '1 file',
  ChatMessage(:final attachments) when attachments.isNotEmpty => '${attachments.length} files',
  _ => 'Message',
};

/// A reply's original when it isn't loaded in the chat: on its own, in a sheet.
Future<void> _showOriginalSheet(
  BuildContext context, {
  required ChatMessage message,
  required MessageDirectory directory,
}) => showGlassDialogSheet<void>(
  context,
  label: 'Original message',
  builder: (context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: UserAvatar(name: message.authorName, url: message.authorAvatarUrl, size: 32),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message.authorName, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
              ),
              Text(shortTime(message.createdAt), style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              boxShadow: tokens.shadowRest,
            ),
            child: message.content.isEmpty
                ? Text(readableAttachments(message), style: DuvetType.body.copyWith(color: colors.foreground))
                : MessageText(
                    content: message.content,
                    directory: directory,
                    style: DuvetType.body.copyWith(color: colors.foreground),
                  ),
          ),
          if (message.attachments.isNotEmpty) ...[
            const SizedBox(height: 4),
            MessageAttachments(attachments: message.attachments),
          ],
        ],
      ),
    );
  },
);
