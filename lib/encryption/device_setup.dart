import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../data/repository.dart';
import '../data/scope.dart';
import '../e2e/engine.dart';
import '../e2e/host.dart' show CoreError;
import '../e2e/notices.dart';
import '../space_admin.dart' show confirmDestructive;
import '../theme.dart';
import '../widgets/rows.dart';
import 'qr.dart';

// The words of a new device's setup, as the desktop's say them (its en.json), but the QR's line: a phone shows it here.
const setupTitle = 'Set up this device';
const keyHeading = 'With your recovery key';
const recoveryKeyLabel = 'Recovery key';
const useRecoveryKey = 'Use recovery key';
const keyMistyped = "That isn't your recovery key: check what you typed, then try again.";
const keyWrong = "This recovery key doesn't open your encrypted conversations: check it's your latest one.";
const setupFailed = "Couldn't set up this device. Check your connection, then try again.";
const setupAgain = 'Your devices changed while this one was being set up: set it up again.';
const approveHeading = 'With another of your devices';
const approveBegin = 'Approve from another device';
const qrLine = 'Scan this code with Duvet on another of your phones.';
const fingerprintLine = 'Your other device shows the same 16 characters.';
const codeWaiting = 'Open Duvet on another of your devices: it asks whether this device is yours.';
const codeLabel = 'Code';
const codeAccept = 'Accept';
const noApprover = 'None of your other devices can approve this one: use your recovery key, or start over.';
const approvalOver = 'This attempt ended: begin again.';
const startOverHeading = 'Without your key or another device';
const startOverLine = 'New security keys for your account, and nothing from before on this device.';
const startOverAction = 'Start over';
const finishSetupText = 'Finish setting up this device.';
const resetFinishText = 'Finish starting over with new security keys.';

/// What a first list that leaves out devices a new password took off says, by the start of their IDs.
String leavesOut(List<String> devices) =>
    'Your password change took ${devices.length < 2 ? devices.join() : '${devices.take(devices.length - 1).join(', ')} '
              'and ${devices.last}'} off your account: Finish takes them off your device list too.';

String fingerprintOf(String fingerprint) => 'Fingerprint: $fingerprint';

/// What a recovery that failed says, by what failed.
String recoveryProblem(Object error) => switch (error) {
  CoreError(code: 'bad_command', field: 'recovery_key') => keyMistyped,
  CoreError(code: 'decrypt_failed') => keyWrong,
  CoreError(code: 'list_changed') => setupAgain,
  _ => setupFailed,
};

/// What an approval's step that failed says, by what failed.
String codeProblem(Object error) => switch (error) {
  CoreError(code: 'rule_violation', rule: 'code_mismatch') => Notice.codeMismatch.text,
  CoreError(code: 'not_found', what: 'approver') => noApprover,
  CoreError(code: 'list_changed') => setupAgain,
  CoreError(code: 'not_found') => approvalOver,
  _ => setupFailed,
};

/// Opens a new device's setup over the app, from the banner's Set up.
Future<void> openDeviceSetup(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => DeviceSetupPage(context.repository)));

/// A new device's setup (PLAN-E2E-CLIENTES.md, Task 27; decisions 22, 24 and 47): with the recovery key, with another
/// device of the person's (its QR, which a phone of theirs scans, or a code), or, with neither, by starting over, which
/// says what's lost and asks before anything runs. Its approval's attempt begins as the page opens, and ends as it
/// closes; it goes once the device is set up, or once what's left is starting over's key or its Finish, which the
/// banner and the key's page carry.
class DeviceSetupPage extends StatefulWidget {
  const DeviceSetupPage(this.repository, {super.key});

  final ChatRepository repository;

  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

class _DeviceSetupPageState extends State<DeviceSetupPage> {
  late final ValueListenable<EngineState> _state = widget.repository.encryption;
  DeviceSetupActions get _setup => widget.repository.deviceSetup;

  @override
  void initState() {
    super.initState();
    _state.addListener(_follow);
    unawaited(_setup.beginApproval().catchError(_failed));
  }

  @override
  void dispose() {
    _state.removeListener(_follow);
    unawaited(_setup.endApproval().catchError(_failed));
    super.dispose();
  }

  void _failed(Object error) => debugPrint("e2e: the setup's attempt: ${error.runtimeType}");

  // Set up, or past what this page does: it goes.
  void _follow() {
    final state = _state.value;
    final way = state.setup?.way;
    if (!mounted || (state.stage == EngineStage.newDevice && way != SetupWay.reset && way != SetupWay.finishing)) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _startOver() async {
    final sure = await confirmDestructive(
      context,
      title: startOverAction,
      body: Notice.startOverWarning.text,
      action: startOverAction,
    );
    if (sure) await _setup.resetIdentity();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    Widget heading(String text) => Semantics(
      header: true,
      child: Text(text, style: DuvetType.title.copyWith(color: colors.foreground)),
    );
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        foregroundColor: colors.foreground,
        title: Text(setupTitle, style: DuvetType.title.copyWith(color: colors.foreground)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading(keyHeading),
                  const SizedBox(height: 12),
                  RecoveryKeyField(onRecover: _setup.recover),
                  const SizedBox(height: 32),
                  heading(approveHeading),
                  const SizedBox(height: 12),
                  ValueListenableBuilder(
                    valueListenable: _state,
                    builder: (context, state, _) => switch (state.setup) {
                      final setup? when setup.way == SetupWay.qr || setup.way == SetupWay.code => KeyedSubtree(
                        // Each attempt anew, its code's field empty.
                        key: ValueKey(setup.fingerprint ?? setup.qr),
                        child: ApprovalNew(setup: setup, actions: _setup),
                      ),
                      _ => Align(
                        alignment: Alignment.centerLeft,
                        child: DuvetButton(label: approveBegin, onPressed: () => unawaited(_setup.beginApproval())),
                      ),
                    },
                  ),
                  const SizedBox(height: 32),
                  heading(startOverHeading),
                  const SizedBox(height: 8),
                  Text(startOverLine, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DuvetButton(
                      label: startOverAction,
                      variant: ButtonVariant.destructive,
                      onPressed: () => unawaited(_startOver()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The recovery key's field on a new device (decision 22): what the person types or pastes goes as it is, spaces and
/// dashes too, which the core reads aside, and a mistyped key is the core's word, said here at once. The keyboard
/// keeps nothing of it (no suggestions, corrections, learning or autofill), and it's kept nowhere but here until the
/// engine's recover takes it.
class RecoveryKeyField extends StatefulWidget {
  const RecoveryKeyField({required this.onRecover, super.key});

  final Future<void> Function(String recoveryKey) onRecover;

  @override
  State<RecoveryKeyField> createState() => _RecoveryKeyFieldState();
}

class _RecoveryKeyFieldState extends State<RecoveryKeyField> {
  final _key = TextEditingController();
  var _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _key.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    if (_busy || _key.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.onRecover(_key.text);
    } catch (error) {
      if (mounted) setState(() => _problem = recoveryProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DuvetTextField(
        label: recoveryKeyLabel,
        controller: _key,
        kept: false,
        // What Android's keyboards treat as a password: none learns it.
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_recover()),
        error: _problem,
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: DuvetButton(
          label: useRecoveryKey,
          variant: ButtonVariant.primary,
          busy: _busy,
          onPressed: _key.text.trim().isEmpty ? null : () => unawaited(_recover()),
        ),
      ),
    ],
  );
}

/// A new device approved by another device of the person's (decision 24): its QR, which a phone of theirs scans, or,
/// with «Use a code instead», the fingerprint of what it asks, which the approving device shows too, then, once that
/// device offered, an empty field for the six digits it shows: the person types them, and the core compares them with
/// its own, which nothing shows. Mounted anew for each attempt.
class ApprovalNew extends StatefulWidget {
  const ApprovalNew({required this.setup, required this.actions, super.key});

  final DeviceSetup setup;
  final DeviceSetupActions actions;

  @override
  State<ApprovalNew> createState() => _ApprovalNewState();
}

final _sixDigits = RegExp(r'^\d{6}$');

class _ApprovalNewState extends State<ApprovalNew> {
  final _code = TextEditingController();
  var _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _problem = codeProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final setup = widget.setup;
    final line = DuvetType.caption.copyWith(color: colors.mutedForeground);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (setup.qr case final qr?) ...[
          Center(child: ApprovalQr(qr)),
          const SizedBox(height: 12),
          Text(qrLine, textAlign: TextAlign.center, style: line),
          const SizedBox(height: 8),
          Center(
            child: TextAction(
              label: Notice.useCode.text,
              onPressed: _busy ? null : () => unawaited(_run(widget.actions.useCode)),
            ),
          ),
        ] else ...[
          Text(
            fingerprintOf(setup.fingerprint ?? ''),
            textAlign: TextAlign.center,
            style: DuvetType.code.copyWith(fontSize: 16, letterSpacing: 1, color: colors.foreground),
          ),
          const SizedBox(height: 4),
          Text(fingerprintLine, textAlign: TextAlign.center, style: line),
          const SizedBox(height: 16),
          if (setup.accepted)
            Semantics(
              liveRegion: true,
              child: Text(Notice.codeAccepted.text, style: DuvetType.body.copyWith(color: colors.foreground)),
            )
          else if (setup.offered) ...[
            DuvetTextField(
              label: codeLabel,
              controller: _code,
              kept: false,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              helper: Notice.approvalCodeHint.text,
              onSubmitted: (code) =>
                  _sixDigits.hasMatch(code) ? unawaited(_run(() => widget.actions.acceptCode(code))) : null,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: DuvetButton(
                label: codeAccept,
                variant: ButtonVariant.primary,
                busy: _busy,
                onPressed: _sixDigits.hasMatch(_code.text)
                    ? () => unawaited(_run(() => widget.actions.acceptCode(_code.text)))
                    : null,
              ),
            ),
          ] else
            Semantics(
              liveRegion: true,
              child: Text(codeWaiting, textAlign: TextAlign.center, style: line),
            ),
        ],
        if (_problem case final problem?) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              problem,
              textAlign: TextAlign.center,
              style: DuvetType.caption.copyWith(color: colors.error),
            ),
          ),
        ],
      ],
    );
  }
}
