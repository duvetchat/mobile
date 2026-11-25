import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../e2e/notices.dart';
import '../theme.dart';
import '../widgets/depth.dart';
import '../widgets/rows.dart';

/// Why the key matters, as the desktop says it.
const recoveryWhy =
    "It's the only way to read your encrypted conversations on a new device if you don't have this one. Keep it "
    "somewhere safe: Duvet can't show it again.";

/// What a failed upload says, the key still shown.
const recoveryFailed = "Your keys couldn't be saved. Check your connection, then try again.";

/// A recovery key in its groups of 4: 12 of them (decision 22).
List<String> keyGroups(String key) => [
  for (var at = 0; at < key.length; at += 4) key.substring(at, min(at + 4, key.length)),
];

/// The first device's recovery key (decision 23): its 48 characters in 12 groups of 4, which the person copies or saves
/// to a file, then says they saved; nothing goes on before, and Back leaves nothing (Ruling 13). Continue uploads the
/// identity ([onSaved]): a failure keeps the key here, says so, and offers Later ([onLater]), which closes the
/// screen while the upload waits for Finish, as the key is saved by then (I2 of the desktop's review). Whoever shows
/// the screen takes it away once the key is done with.
class RecoveryKeyPage extends StatefulWidget {
  const RecoveryKeyPage({required this.recoveryKey, required this.onSaved, required this.onLater, super.key});

  final String recoveryKey;
  final Future<void> Function() onSaved;
  final Future<void> Function() onLater;

  @override
  State<RecoveryKeyPage> createState() => _RecoveryKeyPageState();
}

class _RecoveryKeyPageState extends State<RecoveryKeyPage> {
  var _saved = false;
  var _busy = false;
  var _failed = false;
  var _copied = false;
  Timer? _copiedFor;

  String get _text => keyGroups(widget.recoveryKey).join(' ');

  @override
  void dispose() {
    _copiedFor?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedFor?.cancel();
    _copiedFor = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  // A text file of its own, written only where the person picks in Android's save dialog (ACTION_CREATE_DOCUMENT):
  // file_picker hands the dialog's document the bytes and keeps no copy. Never the share sheet, whose copies stay in
  // the app's cache, as the key opens the identity and the backup (I1 of the review).
  Future<void> _saveFile() async {
    try {
      await FilePicker.saveFile(
        fileName: 'duvet-recovery-key.txt',
        bytes: Uint8List.fromList(utf8.encode('Duvet recovery key\n\n$_text\n')),
        mimeType: 'text/plain',
      );
    } catch (error) {
      debugPrint("e2e: the recovery key's file: ${error.runtimeType}");
    }
  }

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.onSaved();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        Notice.recoveryTitle.text,
                        style: DuvetType.largeTitle.copyWith(color: colors.foreground),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(recoveryWhy, style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                    const SizedBox(height: 24),
                    _KeyGroups(groups: keyGroups(widget.recoveryKey)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DuvetButton(
                            label: _copied ? 'Copied' : 'Copy',
                            icon: FLucideIcons.copy,
                            expand: true,
                            onPressed: _copy,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DuvetButton(
                            label: 'Save file',
                            icon: FLucideIcons.download,
                            expand: true,
                            onPressed: _saveFile,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    MergeSemantics(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _busy ? null : () => setState(() => _saved = !_saved),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                Notice.recoverySaved.text,
                                style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                              ),
                            ),
                            DuvetSwitch(
                              value: _saved,
                              label: Notice.recoverySaved.text,
                              onChanged: _busy ? null : (value) => setState(() => _saved = value),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_failed) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(recoveryFailed, style: DuvetType.caption.copyWith(color: colors.error)),
                      ),
                    ],
                    const SizedBox(height: 24),
                    DuvetButton(
                      label: 'Continue',
                      variant: ButtonVariant.primary,
                      expand: true,
                      busy: _busy,
                      onPressed: _saved ? _continue : null,
                    ),
                    if (_failed) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: TextAction(label: 'Later', onPressed: _busy ? null : widget.onLater),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The key's groups, four to a row, in the sunk well the app's fields are drawn in.
class _KeyGroups extends StatelessWidget {
  const _KeyGroups({required this.groups});

  final List<String> groups;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      label: 'Recovery key',
      // Read a group at a time.
      value: groups.join(', '),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: context.duvet.shadowWell,
          borderRadius: radius,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Column(
            children: [
              for (var row = 0; row * 4 < groups.length; row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : 10),
                  child: Row(
                    children: [
                      for (final group in groups.skip(row * 4).take(4))
                        Expanded(
                          child: Text(
                            group,
                            textAlign: TextAlign.center,
                            style: DuvetType.code.copyWith(fontSize: 17, letterSpacing: 1.2, color: colors.foreground),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
