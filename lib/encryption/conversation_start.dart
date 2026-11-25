import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../e2e/notices.dart';
import '../theme.dart';
import '../widgets/rows.dart';

/// What the start of an encrypted conversation says (PLAN-E2E-CLIENTES.md, «La vista de una conversación»): on one from
/// before end-to-end encryption ([legacy]), when its older messages went, by the server's cutover (decision 56); and
/// once, when rows from before the user joined gave way ([beforeJoining], Ruling 15), that they aren't on this device.
/// Nothing for a conversation that says neither. The desktop's ConversationStart.svelte.
class ConversationStart extends StatelessWidget {
  const ConversationStart({super.key, required this.legacy, required this.cutoverAt, required this.beforeJoining});

  final bool legacy;

  /// The cutover's instant, as GET /api/e2e gives it: null until the engine has it.
  final DateTime? cutoverAt;
  final bool beforeJoining;

  @override
  Widget build(BuildContext context) {
    final at = cutoverAt;
    final lines = [
      if (legacy && at != null) Notice.cutover.fill({'date': fullDate(at.toLocal())}),
      if (beforeJoining) Notice.beforeJoining.text,
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final style = DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(line, textAlign: TextAlign.center, style: style),
            ),
        ],
      ),
    );
  }
}
