import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/repository.dart';
import '../e2e/conventions.dart' show qrFingerprint;
import '../e2e/engine.dart';
import '../e2e/host.dart' show CoreError;
import '../e2e/notices.dart';
import '../theme.dart';
import '../widgets/rows.dart';
import 'device_setup.dart' show fingerprintOf;
import 'qr.dart';

// The approving device's words, as the desktop's say them (its en.json), and the scan's, which only Android has. A new
// device's name is whatever wrote its request says, which the fingerprint doesn't bind: it's quoted as the device's
// own word on a line of its own, never in a title or in what to compare or type (mobile#353).
const approvalAsks = 'A new device asks to read your encrypted conversations.';
const approvalUnfinished =
    "It was approved here before, but didn't finish setting up: it's taken off your device list first, then approved "
    'again.';
String approvalName(String name) => 'The device calls itself “$name”.';

/// What the new device's fingerprint is compared with, the desktop's box's words (its COMPARE_WITH_THE_BOX): a
/// computer's Duvet shows it in a box of its own, outside its window, as a script in its page could draw another there
/// (mobile#363, the desktop's #557). A phone draws its own.
const approvalFingerprintLine =
    "Approve it only if it's the device you're setting up now, and it shows the same 16 characters. The Duvet app on a "
    'computer shows them in a box of its own, outside its window.';
const approvalNo = 'No';
const approvalYes = "It's mine";
const approvalTitle = 'Approve your new device';
const approvalWaiting = 'Waiting for your new device…';
const approvalCodeFor = 'Type this code into your new device:';
const approvalConfirm = 'Confirm';
const approvalFailed = "Couldn't approve the device. Check your connection, then try again.";
const approvalListed = 'This device is set up for your account already.';
const approvalOverHere = "This approval can't go on any more: start it again on the new device.";
const approvalClose = 'Close';
const approvalWaits = "A device you approved is still setting up: you can change your devices once it's done.";
const anotherWaits = "A device you approved is still setting up: approve another once it's done.";
const deviceUnfinished =
    "A device you approved didn't finish setting up: approve it again from that device, or remove it here.";
const scanTitle = 'Set up a new device';
const scanLine = 'Point the camera at the code your new device shows.';
final cameraUnavailable =
    "Duvet can't use the camera here. On your new device, tap «${Notice.useCode.text}»: this device asks you then.";
const notACode = "This isn't a code for setting up a device.";
const notYours = "This code is for a device that isn't signed in to your account.";
const scanCheckFailed = "Couldn't check this code. Try again.";
const scanSent = 'Your new device finishes setting up now.';
const scanUnsent = "Couldn't reach your new device. Try again.";
const scanOver = "This approval can't go on any more: scan your new device's code again.";
const tryAgain = 'Try again';
const scanAgain = 'Scan again';

/// What an approval's step that failed says: while another device this one approved sets up, why it waits (review
/// 27's M5); anything else, to try again.
String approvalProblem(Object error) => switch (error) {
  CoreError(code: 'approval_waits') => anotherWaits,
  _ => approvalFailed,
};

/// The approval the approving device shows over the app while one asks or goes on: none once its transfer went.
DeviceApproval? shownApproval(EngineState state) => switch (state.approval) {
  final approval? when approval.phase != ApprovalPhase.confirmed => approval,
  _ => null,
};

/// What a device of the person's says of a new one that asks to be approved (PLAN-E2E-CLIENTES.md, Task 27; decision
/// 24), over the app: the fingerprint its screen shows (Ruling 35) and, after it, its name as its own word, with a yes
/// and a no before anything is offered; then the code to type into it, and when to confirm. Android has no box of the
/// system's: this page's Confirm, beside the fingerprint, is the person's act. It goes once the approval does, or its
/// transfer went.
class ApprovalPage extends StatefulWidget {
  const ApprovalPage(this.repository, {super.key});

  final ChatRepository repository;

  @override
  State<ApprovalPage> createState() => _ApprovalPageState();
}

class _ApprovalPageState extends State<ApprovalPage> {
  late final ValueListenable<EngineState> _state = widget.repository.encryption;
  var _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _state.addListener(_follow);
  }

  @override
  void dispose() {
    _state.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (!mounted || shownApproval(_state.value) != null) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await work();
    } catch (error) {
      debugPrint("e2e: the approval's step failed: ${error.runtimeType}");
      if (mounted) setState(() => _problem = approvalProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _state,
    builder: (context, state, _) {
      final approval = shownApproval(state);
      if (approval == null) return const SizedBox.shrink();
      final setup = widget.repository.deviceSetup;
      return ApprovalView(
        approval: approval,
        busy: _busy,
        problem: _problem,
        // The yes answers the question shown: one that replaced it meanwhile waits for its own (mobile#355).
        onApprove: () => _run(() => setup.approveDevice(approval.device, approval.question ?? '')),
        onDecline: () => _run(() => setup.declineDevice(approval.device)),
        onConfirm: () => _run(() => setup.confirmApproval(approval.device)),
      );
    },
  );
}

/// An approval as its page draws it, by its phase.
class ApprovalView extends StatelessWidget {
  const ApprovalView({
    required this.approval,
    required this.onApprove,
    required this.onDecline,
    required this.onConfirm,
    this.busy = false,
    this.problem,
    super.key,
  });

  final DeviceApproval approval;
  final bool busy;

  /// What the step that failed says, under the approval.
  final String? problem;
  final VoidCallback onApprove;
  final VoidCallback onDecline;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final body = DuvetType.body.copyWith(color: colors.foreground);
    final line = DuvetType.caption.copyWith(color: colors.mutedForeground);
    final phase = approval.phase;
    return _Page(
      title: phase == ApprovalPhase.asked ? Notice.approvalAsk.text : approvalTitle,
      children: [
        if (phase == ApprovalPhase.asked) ...[
          Text(approvalAsks, style: body),
          if (approval.unfinished) ...[const SizedBox(height: 8), Text(approvalUnfinished, style: line)],
          const SizedBox(height: 16),
        ],
        if (phase == ApprovalPhase.ended)
          Semantics(
            liveRegion: true,
            child: Text(approval.ended == ApprovalEnd.listed ? approvalListed : approvalOverHere, style: body),
          )
        else ...[
          Text(
            fingerprintOf(approval.fingerprint),
            style: DuvetType.code.copyWith(fontSize: 16, letterSpacing: 1, color: colors.foreground),
          ),
          const SizedBox(height: 4),
          Text(approvalFingerprintLine, style: line),
          if (approval.name.isNotEmpty) ...[const SizedBox(height: 4), Text(approvalName(approval.name), style: line)],
        ],
        if (phase == ApprovalPhase.offered) ...[
          const SizedBox(height: 16),
          Semantics(liveRegion: true, child: Text(approvalWaiting, style: line)),
        ] else if (phase == ApprovalPhase.code && approval.code != null) ...[
          const SizedBox(height: 16),
          Text(approvalCodeFor, style: line),
          const SizedBox(height: 8),
          Text(
            approval.code!,
            textAlign: TextAlign.center,
            style: DuvetType.code.copyWith(fontSize: 32, letterSpacing: 8, color: colors.foreground),
          ),
          const SizedBox(height: 8),
          Text(
            Notice.approvalConfirmAfter.text,
            style: DuvetType.body.copyWith(color: colors.foreground, fontWeight: FontWeight.w600),
          ),
        ],
        if (problem case final problem?) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(problem, style: DuvetType.caption.copyWith(color: colors.error)),
          ),
        ],
        const SizedBox(height: 24),
        ...switch (phase) {
          ApprovalPhase.asked => [
            DuvetButton(
              label: approvalYes,
              variant: ButtonVariant.primary,
              expand: true,
              busy: busy,
              onPressed: onApprove,
            ),
            const SizedBox(height: 12),
            DuvetButton(label: approvalNo, expand: true, onPressed: busy ? null : onDecline),
          ],
          ApprovalPhase.ended => [DuvetButton(label: approvalClose, expand: true, onPressed: onDecline)],
          _ => [
            if (phase == ApprovalPhase.code) ...[
              DuvetButton(
                label: approvalConfirm,
                variant: ButtonVariant.primary,
                expand: true,
                busy: busy,
                onPressed: onConfirm,
              ),
              const SizedBox(height: 12),
            ],
            DuvetButton(label: 'Cancel', expand: true, onPressed: busy ? null : onDecline),
          ],
        },
      ],
    );
  }
}

/// A page of the approval's, the recovery key's page's layout.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children});

  final String title;
  final List<Widget> children;

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
                      child: Text(title, style: DuvetType.largeTitle.copyWith(color: colors.foreground)),
                    ),
                    const SizedBox(height: 16),
                    ...children,
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

/// The scan of a new device's QR from this phone (Ruling 21; review 26's rules for task 27): the camera, opened only by
/// the person's tap, which is when Android asks for its permission; the device the QR names, asked about by its name
/// and the fingerprint of the text read, which the new device shows too (mobile#363), before anything is approved;
/// then, on the person's yes, its approval and its transfer, sent again on Try again after a send that failed. Without
/// a camera it says to approve by code.
class ScanDevicePage extends StatefulWidget {
  const ScanDevicePage(this.repository, {this.camera, super.key});

  final ChatRepository repository;

  /// The camera's view, a test's in place of the scanner: what it reads goes to its argument.
  @visibleForTesting
  final Widget Function(ValueChanged<String> onRead)? camera;

  @override
  State<ScanDevicePage> createState() => _ScanDevicePageState();
}

class _ScanDevicePageState extends State<ScanDevicePage> {
  MobileScannerController? _controller;
  String? _qr;
  ScannedDevice? _scanned;
  String? _said;
  var _busy = false;
  var _unsent = false;
  var _done = false;

  DeviceSetupActions get _setup => widget.repository.deviceSetup;

  @override
  void initState() {
    super.initState();
    if (widget.camera == null) _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  // A text read: once, the camera stopped while its device is asked about. Nothing of the QR goes anywhere else.
  Future<void> _read(String text) async {
    if (_qr != null || _busy) return;
    setState(() => _busy = true);
    _qr = text;
    unawaited(_controller?.stop());
    ScannedDevice? scanned;
    var unchecked = false;
    try {
      scanned = await _setup.scannedDevice(text);
    } catch (error) {
      // The user's devices didn't read: no word on the code itself (review 27's M7).
      debugPrint("e2e: a scanned code's device: ${error.runtimeType}");
      unchecked = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _scanned = scanned;
      // Never asked about without the fingerprint of the text read, which the person compares (mobile#363).
      _said = unchecked
          ? scanCheckFailed
          : scanned == null
          ? notACode
          : scanned.name == null
          ? notYours
          : scanned.listed
          ? approvalListed
          : qrFingerprint(text) == null
          ? notACode
          : null;
    });
  }

  void _again() {
    setState(() {
      _qr = null;
      _scanned = null;
      _said = null;
    });
    unawaited(_controller?.start());
  }

  // The person's yes, or their Try again of a transfer whose send failed: what the engine says it did is what's said
  // (review 27's M2). Approved, its transfer not sent, the same bytes go on Try again; none waiting any more, the code
  // is scanned again.
  Future<void> _approve() async {
    final (qr, scanned) = (_qr, _scanned);
    if (qr == null || scanned == null) return;
    setState(() => _busy = true);
    try {
      final sent = _unsent
          ? await _setup.sendScanned(scanned.id).then((_) => true)
          : await _setup.approveScanned(qr, scanned);
      _done = sent;
      _unsent = !sent;
      _said = sent ? scanSent : scanUnsent;
    } catch (error) {
      debugPrint("e2e: a scanned device's approval: ${error.runtimeType}");
      if (error case CoreError(code: 'not_found', what: 'transfer')) {
        _unsent = false;
        _said = scanOver;
      } else {
        // A transfer kept stays kept: another failed send of it is said as one.
        _said = _unsent ? scanUnsent : approvalProblem(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final scanned = _scanned;
    final asking = scanned != null && _said == null && !_done;
    final name = scanned?.name ?? '';
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        foregroundColor: colors.foreground,
        title: Text(scanTitle, style: DuvetType.title.copyWith(color: colors.foreground)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_qr == null) ...[
              Text(scanLine, style: DuvetType.body.copyWith(color: colors.foreground)),
              const SizedBox(height: 16),
              AspectRatio(
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
                            child: Text(cameraUnavailable, style: DuvetType.body.copyWith(color: colors.foreground)),
                          ),
                        ),
                      ),
                ),
              ),
            ] else if (asking) ...[
              Semantics(
                header: true,
                child: Text(Notice.approvalAsk.text, style: DuvetType.largeTitle.copyWith(color: colors.foreground)),
              ),
              const SizedBox(height: 16),
              Text(approvalAsks, style: DuvetType.body.copyWith(color: colors.foreground)),
              if (scanned.unfinished) ...[
                const SizedBox(height: 8),
                Text(approvalUnfinished, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              ],
              // The fingerprint of the very text read, which the yes approves from (mobile#363).
              const SizedBox(height: 16),
              Text(
                fingerprintOf(qrFingerprint(_qr ?? '') ?? ''),
                style: DuvetType.code.copyWith(fontSize: 16, letterSpacing: 1, color: colors.foreground),
              ),
              const SizedBox(height: 4),
              Text(approvalFingerprintLine, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              if (name.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(approvalName(name), style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              ],
              const SizedBox(height: 24),
              DuvetButton(
                label: approvalYes,
                variant: ButtonVariant.primary,
                expand: true,
                busy: _busy,
                onPressed: () => unawaited(_approve()),
              ),
              const SizedBox(height: 12),
              DuvetButton(label: approvalNo, expand: true, onPressed: _busy ? null : () => Navigator.of(context).pop()),
            ] else ...[
              Semantics(
                liveRegion: true,
                child: Text(_said ?? '', style: DuvetType.body.copyWith(color: colors.foreground)),
              ),
              const SizedBox(height: 24),
              if (_unsent)
                DuvetButton(
                  label: tryAgain,
                  variant: ButtonVariant.primary,
                  expand: true,
                  busy: _busy,
                  onPressed: () => unawaited(_approve()),
                )
              else if (!_done)
                DuvetButton(label: scanAgain, expand: true, onPressed: _busy ? null : _again),
              const SizedBox(height: 12),
              DuvetButton(label: approvalClose, expand: true, onPressed: () => Navigator.of(context).pop()),
            ],
          ],
        ),
      ),
    );
  }
}
