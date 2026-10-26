part of '../chat_view.dart';

/// Above the field, inside the bar: what the composer is doing besides a new
/// message. "Replying to **Maya** — text" or "Editing message", 40pt,
/// `base-sunken`, with a close button. It springs up and the field slides
/// down with it.
class _ComposerStrip extends StatelessWidget {
  final MessageReply? reply;
  final bool editing;
  final VoidCallback onClose;
  const _ComposerStrip({required this.reply, required this.editing, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final reply = this.reply;
    final Widget? strip = editing
        ? _strip(
            context,
            key: const ValueKey('edit'),
            icon: FLucideIcons.pencil,
            text: TextSpan(
              text: 'Editing message',
              style: TextStyle(color: colors.foreground, fontWeight: FontWeight.w500),
            ),
            closeLabel: 'Cancel editing',
          )
        : reply == null
        ? null
        : _strip(
            context,
            key: ValueKey(reply.messageId),
            text: TextSpan(
              children: [
                const TextSpan(text: 'Replying to '),
                TextSpan(
                  text: reply.authorName,
                  style: TextStyle(color: colors.foreground, fontWeight: FontWeight.w500),
                ),
                if (reply.content.isNotEmpty) TextSpan(text: ' — ${reply.content}'),
              ],
            ),
            closeLabel: 'Cancel reply',
          );
    return AnimatedSize(
      duration: reduce ? Duration.zero : DuvetTokens.replyStrip,
      curve: DuvetTokens.overshoot,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: reduce ? Duration.zero : DuvetTokens.replyStrip,
        reverseDuration: reduce ? Duration.zero : const Duration(milliseconds: 200),
        switchInCurve: DuvetTokens.overshoot,
        switchOutCurve: Curves.easeOut,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: strip ?? const SizedBox(width: double.infinity, key: ValueKey('none')),
      ),
    );
  }

  Widget _strip(
    BuildContext context, {
    required Key key,
    required InlineSpan text,
    required String closeLabel,
    IconData? icon,
  }) {
    final colors = context.theme.colors;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            color: colors.secondary,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                ExcludeSemantics(child: Icon(icon, size: 16, color: colors.mutedForeground)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text.rich(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
              IconAction(icon: FLucideIcons.x, label: closeLabel, color: colors.mutedForeground, onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

/// The composer: one `radius-card` field holding exactly four controls,
/// Attach, the text, Emoji and Send. While there's nothing to send, Send is a
/// mic to hold for a voice note; then a 32pt accent square; editing, it saves.
class _ComposerField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool canSend;
  final bool editing;
  final void Function(BuildContext anchor) onAttach;
  final VoidCallback onEmoji;
  final VoidCallback onSend;

  /// Holding Send while there's nothing to send, its mic, records a voice
  /// note: no fifth control.
  final VoidCallback onHoldStart;
  final ValueChanged<Offset> onHoldMove;
  final VoidCallback onHoldEnd;

  const _ComposerField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.canSend,
    required this.editing,
    required this.onAttach,
    required this.onEmoji,
    required this.onSend,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: radius,
        border: Border.all(color: tokens.hairline),
      ),
      child: InsetShadow(
        shadows: tokens.shadowWell,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            // The controls stay on the bottom line as the text grows.
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Builder(
                builder: (anchor) => IconAction(
                  icon: FLucideIcons.plus,
                  label: 'Add photos, a sticker or a mention',
                  color: colors.mutedForeground,
                  onPressed: editing ? null : () => onAttach(anchor),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    // Return starts a new line, for lists, quotes and code;
                    // only Send sends.
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    cursorColor: tokens.accentText,
                    style: DuvetType.body.copyWith(color: colors.foreground),
                    decoration: InputDecoration.collapsed(
                      hintText: hint,
                      hintStyle: DuvetType.body.copyWith(color: colors.mutedForeground),
                    ),
                  ),
                ),
              ),
              IconAction(
                icon: FLucideIcons.smilePlus,
                label: 'Emoji and stickers',
                color: colors.mutedForeground,
                onPressed: onEmoji,
              ),
              GestureDetector(
                onLongPressStart: canSend || editing ? null : (_) => onHoldStart(),
                onLongPressMoveUpdate: canSend || editing ? null : (d) => onHoldMove(d.offsetFromOrigin),
                onLongPressEnd: canSend || editing ? null : (_) => onHoldEnd(),
                child: _SendButton(enabled: canSend, editing: editing, onPressed: onSend),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool editing;
  final VoidCallback onPressed;
  const _SendButton({required this.enabled, required this.editing, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    // Nothing to send: a voice note, held to record (or from Add).
    final voice = !enabled && !editing;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled || voice,
      label: editing
          ? 'Save edit'
          : voice
          ? 'Voice note, touch and hold to record'
          : 'Send',
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Pressable(
        onTap: enabled ? onPressed : null,
        builder: (context, pressed) => SizedBox.square(
          dimension: 40,
          child: Center(
            child: AnimatedContainer(
              duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: enabled ? Duvet.accent : Colors.transparent,
                borderRadius: radius,
                boxShadow: enabled && !pressed ? tokens.shadowControl : null,
              ),
              child: InsetShadow(
                shadows: enabled && pressed ? tokens.shadowPressed : const [],
                borderRadius: radius,
                child: Icon(
                  editing
                      ? FLucideIcons.check
                      : voice
                      ? FLucideIcons.mic
                      : FLucideIcons.arrowUp,
                  size: 24,
                  color: enabled ? colors.primaryForeground : colors.mutedForeground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer while recording: the same field, now the time and the voice's
/// level as it comes. Held, it says how to cancel or lock; locked, it has its
/// own Cancel and Send.
class _RecordingField extends StatelessWidget {
  final Duration elapsed;
  final List<double> levels;
  final bool locked;
  final Offset slide;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  const _RecordingField({
    required this.elapsed,
    required this.levels,
    required this.locked,
    required this.slide,
    required this.onCancel,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    final seconds = elapsed.inSeconds;
    final bars = [
      ...List.filled(math.max(0, 24 - levels.length), 0.0),
      ...levels.skip(math.max(0, levels.length - 24)),
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      explicitChildNodes: true,
      label: locked
          ? 'Recording voice note, $seconds seconds'
          : 'Recording voice note, $seconds seconds. Release to send, slide left to cancel, slide up to lock',
      child: Container(
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: radius,
          border: Border.all(color: tokens.hairline),
        ),
        child: InsetShadow(
          shadows: tokens.shadowWell,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Text(
                    clock(elapsed),
                    style: DuvetType.label.copyWith(
                      color: colors.foreground,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ExcludeSemantics(
                    child: ClipRect(
                      child: Transform.translate(
                        offset: Offset(math.min(0, slide.dx), 0),
                        child: Waveform(
                          bars: [for (final b in bars) 0.12 + b * 0.88],
                          color: tokens.accentText,
                          height: 24,
                        ),
                      ),
                    ),
                  ),
                ),
                if (locked) ...[
                  // The mic's opposite, in red: this one throws the recording away.
                  IconAction(
                    icon: FLucideIcons.micOff,
                    label: 'Cancel recording',
                    color: colors.destructive,
                    onPressed: onCancel,
                  ),
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Send voice note',
                    excludeSemantics: true,
                    onTap: onSend,
                    child: _SendButton(enabled: true, editing: false, onPressed: onSend),
                  ),
                ] else
                  const SizedBox(width: 44, height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Above the recorder while Send is held: how to cancel, send or lock.
class _RecordingHint extends StatelessWidget {
  const _RecordingHint();

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FLucideIcons.chevronLeft, size: 14, color: colors.mutedForeground),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Slide to cancel · release to send · up to lock',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The glass dropdown of mention or emoji suggestions: it drops in on a spring
/// and tells screen readers how many there are.
class _SuggestionsPanel extends StatelessWidget {
  final String label;
  final List<Widget> children;
  const _SuggestionsPanel({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : DuvetTokens.dropdownIn,
      reverseDuration: reduce ? Duration.zero : DuvetTokens.panelOut,
      switchInCurve: DuvetTokens.overshoot,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: children.isEmpty
          ? const SizedBox.shrink(key: ValueKey('none'))
          : Padding(
              key: const ValueKey('some'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Semantics(
                liveRegion: true,
                label: '$label, ${children.length}',
                explicitChildNodes: true,
                child: GlassSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(mainAxisSize: MainAxisSize.min, children: children),
                  ),
                ),
              ),
            ),
    );
  }
}

/// The picked files, above the composer, each removable.
class _AttachmentTray extends StatelessWidget {
  final List<OutgoingFile> files;
  final ValueChanged<OutgoingFile> onRemove;
  const _AttachmentTray({required this.files, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return SizedBox(
      height: 84,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final f in files)
            // The thumbnail sits bottom-left; the remove button's whole 40px
            // target fits in the top-right, where taps reach it.
            SizedBox(
              width: 84,
              height: 76,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Semantics(
                      container: true,
                      image: true,
                      label: '${_kind(f.contentType)}, ${f.name}',
                      excludeSemantics: true,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                        child: Container(
                          width: 64,
                          height: 64,
                          color: colors.secondary,
                          child: f.contentType.startsWith('image/')
                              ? Image(image: ResizeImage(FileImage(File(f.path)), width: 192), fit: BoxFit.cover)
                              : Icon(f.contentType.startsWith('video/') ? FLucideIcons.film : FLucideIcons.file),
                        ),
                      ),
                    ),
                  ),
                  if (f.contentType == 'image/gif')
                    const Positioned(
                      left: 4,
                      bottom: 4,
                      child: ExcludeSemantics(child: _TrayBadge(text: 'GIF')),
                    ),
                  Positioned(
                    top: 0,
                    left: 44,
                    child: Semantics(
                      container: true,
                      button: true,
                      label: 'Remove ${f.name}',
                      excludeSemantics: true,
                      onTap: () => onRemove(f),
                      child: GestureDetector(
                        onTap: () => onRemove(f),
                        behavior: HitTestBehavior.opaque,
                        // 40px to hit, a 22px disc to see, on the thumbnail's corner.
                        child: SizedBox.square(
                          dimension: 40,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 9, top: 1),
                              child: Container(
                                width: 22,
                                height: 22,
                                // A rounded square: circles are for people.
                                decoration: BoxDecoration(
                                  color: colors.foreground,
                                  borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                                  border: Border.all(color: colors.background, width: 1.5),
                                ),
                                child: Icon(FLucideIcons.x, size: 13, color: colors.background),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _kind(String type) => type == 'image/gif'
      ? 'GIF'
      : type.startsWith('image/')
      ? 'Photo'
      : type.startsWith('video/')
      ? 'Video'
      : 'File';
}

class _TrayBadge extends StatelessWidget {
  final String text;
  const _TrayBadge({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(color: const Color(0xB3141416), borderRadius: BorderRadius.circular(6)),
    child: Text(
      text,
      style: DuvetType.tabLabel.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
}
