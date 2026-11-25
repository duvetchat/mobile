import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../e2e/notices.dart';
import '../e2e/sync.dart';
import '../theme.dart';
import '../widgets/depth.dart';
import '../widgets/rows.dart';

/// What a conversation says over its message box of its encrypted group (PLAN-E2E-CLIENTES.md, «Avisos»): nothing
/// while the group goes on. Blocked, with its restart for whoever may make it and the wait for the others; waiting for
/// its owner to open it, or for another member to let this device back in; members other than those this device first
/// saw, with the person's yes. The desktop's ConversationState.svelte, in the encryption banner's look.
class ConversationStateBar extends StatefulWidget {
  const ConversationStateBar({
    super.key,
    required this.state,
    required this.ownerName,
    required this.onRestart,
    required this.onAccept,
  });

  final ConversationState? state;

  /// The conversation's owner, by the name the app shows them.
  final String ownerName;
  final Future<void> Function() onRestart;
  final Future<void> Function() onAccept;

  @override
  State<ConversationStateBar> createState() => _ConversationStateBarState();
}

class _ConversationStateBarState extends State<ConversationStateBar> {
  var _busy = false;

  /// The state's words, and what the person can do in it.
  ({String text, String? action, Future<void> Function()? run})? get _shown {
    final owner = {'owner': widget.ownerName};
    return switch (widget.state?.name) {
      null => null,
      ConversationNotice.blocked => switch (widget.state!.restart) {
        Restart.mine => (text: Notice.blocked.text, action: Notice.blockedOwner.text, run: widget.onRestart),
        Restart.owner => (text: '${Notice.blocked.text} ${Notice.blockedWait.fill(owner)}', action: null, run: null),
        _ => (text: Notice.blocked.text, action: null, run: null),
      },
      ConversationNotice.waitOwner => (text: Notice.waitOwner.fill(owner), action: null, run: null),
      ConversationNotice.waitRejoin => (text: Notice.waitRejoin.text, action: null, run: null),
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
