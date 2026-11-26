import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/models.dart' show ActionFailed;
import '../data/repository.dart';
import '../e2e/engine.dart' show SafetyNumber;
import '../e2e/host.dart' show CoreError;
import '../e2e/notices.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/rows.dart';
import 'conversation_state.dart' show peopleNamed;
import 'qr.dart';

// A contact's security number (PLAN-E2E-CLIENTES.md, Task 29; decision 25), the mark of one the person verified, and
// the question a verified contact's changed key asks before anything more goes to them. The desktop's SafetyNumber,
// VerifiedMark and askBeforeSend, and the scan only Android has (Ruling 21). The words beyond the shared notices are
// Android's, the desktop's where it has them.

String safetyCompare(String name) =>
    "Compare these numbers with the ones on $name's device, in person or on a call, or scan the code their phone "
    'shows.';
String safetyDigits(String name) => 'Security number with $name';
String safetyQrLabel(String name) => 'A code of your security number with $name';
const safetyLoading = 'Loading the security number…';
String safetyNone(String name) =>
    "$name hasn't set up encrypted conversations yet, so there's no security number to compare.";
const safetyFailed = "Couldn't load the security number. Check your connection, then try again.";
String safetyChanged(String name) =>
    "$name's security number changed: compare the new one before you mark them verified.";
const scanTheirCode = 'Scan their code';
const scanAgain = 'Scan again';
String scanLine(String name) => "Point the camera at the code on $name's phone.";
String codesDontMatch(String name) =>
    "These codes don't match: this isn't your security number with $name. Compare the numbers, or scan again.";
const notASecurityCode = "That isn't a security number's code.";
const scanFailed = "Couldn't check that code. Check your connection, then try again.";
const cameraUnavailable = "Duvet can't use the camera here. Compare the numbers instead.";
const closeNotice = 'Close this notice';

/// What waits for the person's yes says, naming whom it waits for: the strong notice's words.
String heldFor(List<String> names) => Notice.keyChangedVerified.fill({'name': peopleNamed(names)});

/// A verified contact's mark (decision 25): the person compared their security number and marked them verified on this
/// device, whose core keeps it. Beside their name in their DM and their profile, named for a screen reader.
class VerifiedMark extends StatelessWidget {
  const VerifiedMark({this.size = 16, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: Notice.verified.text,
    child: ExcludeSemantics(
      child: Icon(FLucideIcons.shieldCheck, size: size, color: context.duvet.live),
    ),
  );
}

/// Opens [name]'s security number over what's on screen.
Future<void> openSafetyNumber(BuildContext context, ChatRepository repository, String userId, String name) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => SafetyNumberPage(repository, userId: userId, name: name),
      ),
    );

/// Asks the person whether to send where a verified contact's key changed (decision 25): the strong words naming
/// them ([names], as one), and Send anyway; true on their yes. Closing the sheet is a no, which keeps what was written.
Future<bool> confirmSendAnyway(BuildContext context, List<String> names) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: Notice.sendAnyway.text,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(heldFor(names), style: DuvetType.body.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 24),
            DuvetButton(
              label: Notice.sendAnyway.text,
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

/// A contact's security number (decision 25): its 60 digits in 12 groups of 5, as the core gives them, and its QR,
/// the core's qr as its text, which the contact's phone scans (e2e-conventions.json's safety_qr); then Mark as
/// verified once the person compared them, or the mark of a contact they verified. Or their code scanned from their
/// phone (Ruling 21): the camera opens only on the person's tap, when Android asks for its permission, and the text it
/// reads goes to the core as read, for this contact. What went wrong, or that the number changed meanwhile, said.
class SafetyNumberPage extends StatefulWidget {
  const SafetyNumberPage(this.repository, {required this.userId, required this.name, this.camera, super.key});

  final ChatRepository repository;

  /// The contact, and the name the app shows them by.
  final String userId;
  final String name;

  /// The camera's view, a test's in place of the scanner: what it reads goes to its argument.
  @visibleForTesting
  final Widget Function(ValueChanged<String> onRead)? camera;

  @override
  State<SafetyNumberPage> createState() => _SafetyNumberPageState();
}

class _SafetyNumberPageState extends State<SafetyNumberPage> {
  SafetyNumber? _number;

  /// Why there's no number to compare, once its read said so.
  String? _problem;

  /// What the last Mark as verified or scan came to, when it isn't the mark.
  String? _said;
  var _busy = false;
  var _scanning = false;
  MobileScannerController? _controller;

  ChatRepository get _repository => widget.repository;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final number = await _repository.safetyNumber(widget.userId);
      if (mounted) {
        setState(() {
          _number = number;
          _problem = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _problem = switch (error) {
          CoreError(code: 'needs_identities') => safetyNone(widget.name),
          ActionFailed(:final message) => message,
          _ => safetyFailed,
        },
      );
    }
  }

  Future<void> _markVerified() async {
    final number = _number;
    if (number == null || _busy) return;
    setState(() {
      _busy = true;
      _said = null;
    });
    try {
      if (!await _repository.verifyContact(widget.userId, number.digits)) {
        // Another number than the one shown: shown anew, for the person to compare.
        await _load();
        if (mounted) setState(() => _said = safetyChanged(widget.name));
      }
    } catch (error) {
      debugPrint("e2e: a contact wasn't verified: ${error.runtimeType}");
      if (mounted) setState(() => _said = error is ActionFailed ? error.message : safetyFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scan() {
    if (widget.camera == null) {
      _controller ??= MobileScannerController(formats: const [BarcodeFormat.qrCode]);
      unawaited(_controller!.start());
    }
    setState(() {
      _scanning = true;
      _said = null;
    });
  }

  // A text read: once, the camera stopped while the core checks it. Nothing of the code goes anywhere else.
  Future<void> _read(String text) async {
    if (!_scanning || _busy) return;
    setState(() {
      _busy = true;
      _scanning = false;
    });
    unawaited(_controller?.stop());
    String? said;
    try {
      if (!await _repository.verifyScanned(widget.userId, text)) said = codesDontMatch(widget.name);
    } catch (error) {
      debugPrint("e2e: a scanned code wasn't checked: ${error.runtimeType}");
      said = switch (error) {
        CoreError(code: 'bad_command') => notASecurityCode,
        ActionFailed(:final message) => message,
        _ => scanFailed,
      };
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _said = said;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final number = _number;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        foregroundColor: colors.foreground,
        title: Text(Notice.verifyNumber.text, style: DuvetType.title.copyWith(color: colors.foreground)),
      ),
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: _repository.contacts,
          builder: (context, contacts, _) {
            final verified = contacts.verified[widget.userId] == true;
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (number == null && _problem == null)
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text(safetyLoading, style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                      ],
                    ),
                  ),
                if (_problem case final problem?)
                  Text(problem, style: DuvetType.body.copyWith(color: colors.foreground)),
                if (number != null) ...[
                  _Digits(number.digits, label: safetyDigits(widget.name)),
                  const SizedBox(height: 24),
                  if (_scanning)
                    _camera(context)
                  else
                    Center(
                      child: Semantics(
                        image: true,
                        label: safetyQrLabel(widget.name),
                        excludeSemantics: true,
                        child: ApprovalQr(number.qr),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    _scanning ? scanLine(widget.name) : safetyCompare(widget.name),
                    textAlign: TextAlign.center,
                    style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
                  ),
                  if (_said case final said?) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        said,
                        textAlign: TextAlign.center,
                        style: DuvetType.body.copyWith(color: colors.foreground),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (verified)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const ExcludeSemantics(child: VerifiedMark()),
                        const SizedBox(width: 8),
                        Text(Notice.verified.text, style: DuvetType.label.copyWith(color: context.duvet.live)),
                      ],
                    )
                  else
                    DuvetButton(
                      label: Notice.markVerified.text,
                      variant: ButtonVariant.primary,
                      expand: true,
                      busy: _busy && !_scanning,
                      onPressed: _scanning ? null : _markVerified,
                    ),
                  if (!_scanning) ...[
                    const SizedBox(height: 12),
                    DuvetButton(
                      label: _said == null ? scanTheirCode : scanAgain,
                      icon: FLucideIcons.scanLine,
                      expand: true,
                      onPressed: _busy ? null : _scan,
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _camera(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child:
          widget.camera?.call((text) => unawaited(_read(text))) ??
          QrScanner(
            controller: _controller!,
            onRead: (text) => unawaited(_read(text)),
            onUnavailable: (context) => Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  cameraUnavailable,
                  textAlign: TextAlign.center,
                  style: DuvetType.body.copyWith(color: context.theme.colors.foreground),
                ),
              ),
            ),
          ),
    ),
  );
}

/// The 60 digits in 12 groups of 5, four to a line as the desktop has them, read out whole.
class _Digits extends StatelessWidget {
  const _Digits(this.digits, {required this.label});

  final String digits;
  final String label;

  @override
  Widget build(BuildContext context) {
    final groups = digits.split(' ');
    final style = DuvetType.code.copyWith(fontSize: 19, letterSpacing: 0.8, color: context.theme.colors.foreground);
    return Semantics(
      label: '$label: $digits',
      excludeSemantics: true,
      child: Column(
        children: [
          for (var at = 0; at < groups.length; at += 4)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // Four to a line whatever the text's size: a line scales down rather than wrap a group away.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final group in groups.skip(at).take(4))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        child: Text(group, style: style),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
