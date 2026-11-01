import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'duvet_mascot.dart';
import 'glass.dart';
import 'rows.dart';

/// Keeps a page with a Save button from closing over [dirty] edits: back, the
/// back gesture and Cancel ask first, with [confirmDiscard]. A plain
/// `Navigator.pop` (after saving) still closes it.
class UnsavedChanges extends StatelessWidget {
  const UnsavedChanges({super.key, required this.dirty, required this.child});

  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (await confirmDiscard(context)) navigator.pop();
    },
    child: child,
  );
}

/// Asks whether to leave and lose the changes; true to discard them.
Future<bool> confirmDiscard(BuildContext context) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: 'Unsaved changes',
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: DuvetMascot(MascotState.oops, size: 120, excludeFromSemantics: true)),
            const SizedBox(height: 16),
            Text('Unsaved changes', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 12),
            Text(
              'Leave without saving? Your changes will be lost.',
              style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
            ),
            const SizedBox(height: 24),
            DuvetButton(
              label: 'Keep editing',
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: 12),
            DuvetButton(
              label: 'Discard',
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    ) ==
    true;
