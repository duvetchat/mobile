import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../e2e/notices.dart';
import '../e2e/sync.dart';
import '../theme.dart';
import '../widgets/depth.dart';
import '../widgets/glass.dart';
import '../widgets/rows.dart';

/// What a conversation says over its message box of its encrypted group (PLAN-E2E-CLIENTES.md, «Avisos»): nothing
/// while the group goes on. Blocked, with its restart for whoever may make it and the wait for the others; waiting for
/// its owner to open it, or for another member to let this device back in; members other than those this device first
/// saw, with the person's yes; and, while it goes on, the members who can't receive what's sent yet, before anything is
/// sent. The desktop's ConversationState.svelte, in the encryption banner's look.
class ConversationStateBar extends StatefulWidget {
  const ConversationStateBar({
    super.key,
    required this.state,
    required this.nameOf,
    required this.onRestart,
    required this.onAccept,
  });

  final ConversationState? state;

  /// A member of the conversation, by the name the app shows them.
  final String Function(String userId) nameOf;
  final Future<void> Function() onRestart;
  final Future<void> Function() onAccept;

  @override
  State<ConversationStateBar> createState() => _ConversationStateBarState();
}

class _ConversationStateBarState extends State<ConversationStateBar> {
  var _busy = false;

  /// The state's words, and what the person can do in it.
  ({String text, String? action, Future<void> Function()? run})? get _shown {
    final state = widget.state;
    final owner = {'owner': widget.nameOf(state?.owner ?? '')};
    return switch (state?.name) {
      null => null,
      ConversationNotice.blocked => switch (state!.restart) {
        Restart.mine => (text: Notice.blocked.text, action: Notice.blockedOwner.text, run: widget.onRestart),
        Restart.owner => (text: '${Notice.blocked.text} ${Notice.blockedWait.fill(owner)}', action: null, run: null),
        _ => (text: Notice.blocked.text, action: null, run: null),
      },
      ConversationNotice.waitOwner => (text: Notice.waitOwner.fill(owner), action: null, run: null),
      ConversationNotice.waitRejoin => (text: Notice.waitRejoin.text, action: null, run: null),
      ConversationNotice.noDevice => (
        text: Notice.noDevice.fill({
          'name': peopleNamed([for (final user in state!.users) widget.nameOf(user)]),
        }),
        action: null,
        run: null,
      ),
      ConversationNotice.membersChanged => (
        text: Notice.membersChanged.text,
        action: Notice.membersAccept.text,
        run: widget.onAccept,
      ),
    };
  }

  Future<void> _act(Future<void> Function() run) async {
    setState(() => _busy = true);
    try {
      await run();
    } catch (error) {
      debugPrint('e2e: what the person asked for failed: ${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    final run = shown.run;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: context.duvet.shadowWell,
            borderRadius: radius,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                ExcludeSemantics(child: Icon(FLucideIcons.lockKeyhole, size: 16, color: colors.foreground)),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(shown.text, style: DuvetType.caption.copyWith(color: colors.foreground)),
                  ),
                ),
                if (shown.action case final action?)
                  TextAction(label: action, onPressed: run == null || _busy ? null : () => _act(run)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// People's names as one, for a notice's {name} or {names}: "Ana", "Ana and Bo", "Ana, Bo and Cy".
String peopleNamed(List<String> names) => switch (names) {
  [] => '',
  [final one] => one,
  [...final rest, final last] => '${rest.join(', ')} and $last',
};

/// Asks the person whether to restart the conversation's encryption without these people ([names], as one), whom the
/// restart leaves out (the core's #46): true on their yes.
Future<bool> confirmRestart(BuildContext context, String names) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: Notice.blockedOwner.text,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Notice.blockedOwner.text, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 12),
            Text(
              Notice.restartLeavesOut.fill({'names': names}),
              style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
            ),
            const SizedBox(height: 24),
            DuvetButton(
              label: Notice.blockedOwner.text,
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    ) ??
    false;
