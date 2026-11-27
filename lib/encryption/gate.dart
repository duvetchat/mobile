import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/repository.dart';
import '../data/scope.dart';
import '../e2e/engine.dart';
import '../e2e/notices.dart';
import '../space_admin.dart' show confirmDestructive;
import '../theme.dart';
import '../widgets/chrome.dart';
import '../widgets/depth.dart';
import '../widgets/rows.dart';
import 'approval.dart' show ApprovalPage, shownApproval;
import 'device_setup.dart' show finishSetupText, leavesOut, openDeviceSetup, resetFinishText, setupAgain, setupFailed;
import 'devices.dart' show backupLine, confirmChangeKeys, deleteThisDevice, finishWithout, keysAgainText, stuckText;
import 'recovery_key.dart';

/// Where a client too old gets the new one.
final downloadPage = Uri.parse('https://duvet.chat/download');

/// What starting over asks first, as the desktop asks it.
const startOverQuestion =
    "Delete this device's encrypted conversations and their keys, and set it up again as a new device? Your other "
    'devices keep theirs.';

/// A state's words, and what the person can do in it.
typedef _Bar = ({String text, String? action, Future<void> Function(BuildContext context)? run});

/// What the app says of encrypted conversations by its engine's state (PLAN-E2E-CLIENTES.md, «El motor», its states),
/// in the Chats tab's header where the offline banner is: nothing while it starts or once it's ready, but a new
/// device's restore of the encrypted backup as it goes (Task 33), else a strip with what the person can do, which its ×
/// hides until the state changes. A first device's tap makes its identity; its recovery key's page ([RecoveryKeyPage])
/// is up whenever the state has the key, as the desktop's dialog is, and no strip stands in for it (M3 of the review).
/// What deletes the device's data asks first (M6 of the desktop's review). The DMs' own views take the states with
/// tasks 15 and 17.
class EncryptionBanner extends StatefulWidget {
  const EncryptionBanner({super.key});

  @override
  State<EncryptionBanner> createState() => _EncryptionBannerState();
}

class _EncryptionBannerState extends State<EncryptionBanner> {
  /// What the × hid: a state's strip, by its stage, or a restore's, by its own key, so a later strip of the ready state
  /// still shows.
  Object? _hiddenFor;
  static const _restoring = 'restoring';

  var _busy = false;
  ChatRepository? _watched;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = context.repository;
    if (identical(repository, _watched)) return;
    _watched?.encryption.removeListener(_follow);
    _watched = repository..encryption.addListener(_follow);
    // A key the state had before this strip was built shows once this frame is drawn.
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  @override
  void dispose() {
    _watched?.encryption.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (_watched case final repository? when mounted) {
      final navigator = Navigator.of(context, rootNavigator: true);
      _showKeyPage(navigator, repository);
      _showApprovalPage(navigator, repository);
    }
  }

  _Bar? _bar(EngineState state) => switch (state.stage) {
    // The key's page has the screen: a first device's, a change of keys' (Task 25), or starting over's (Task 27).
    EngineStage.firstDevice || EngineStage.ready || EngineStage.newDevice when state.recoveryKey != null => null,
    EngineStage.firstDevice when state.finishing => (
      text: 'Finish setting up end-to-end encryption for your direct messages.',
      action: 'Finish',
      run: _setUp,
    ),
    EngineStage.firstDevice => (
      text: 'Set up end-to-end encryption for your direct messages.',
      action: 'Set up',
      run: _setUp,
    ),
    // A new device whose setup waits for the person's Finish (Task 27): its first list, naming the devices it leaves
    // out, or starting over's key, made before the app closed.
    EngineStage.newDevice when state.setup?.way == SetupWay.finishing => (
      text: state.setup!.leavingOut.isEmpty ? finishSetupText : leavesOut(state.setup!.leavingOut),
      action: 'Finish',
      run: (context) => context.repository.deviceSetup.finishSetup(),
    ),
    EngineStage.newDevice when state.setup?.way == SetupWay.reset => (
      text: resetFinishText,
      action: 'Finish',
      run: (context) => context.repository.deviceSetup.finishSetup(),
    ),
    // Started again as a new device: the user's devices changed while it was being set up (review 27's M3).
    EngineStage.newDevice when state.listChanged => (text: setupAgain, action: 'Set up', run: openDeviceSetup),
    // Its setup's page: the recovery key, another device's approval, or starting over.
    EngineStage.newDevice => (
      text: 'Set up this device to read your encrypted conversations.',
      action: 'Set up',
      run: openDeviceSetup,
    ),
    EngineStage.removed => (
      text: Notice.removedDevice.text,
      action: 'Set up again',
      run: (context) => _startOver(context, 'Set up again'),
    ),
    EngineStage.locked => (text: Notice.lockedPhone.text, action: null, run: null),
    EngineStage.unsupported => (text: Notice.noE2eHere.text, action: null, run: null),
    EngineStage.failed when state.lostKey => (
      text: "Your encrypted conversations can't be opened on this device: its key is gone.",
      action: Notice.deleteDevice.text,
      run: (context) => _startOver(context, Notice.deleteDevice.text),
    ),
    EngineStage.failed => (text: "Encrypted conversations couldn't open on this device.", action: null, run: null),
    EngineStage.update when state.minimum == null => (text: Notice.noE2eHere.text, action: null, run: null),
    EngineStage.update => (
      text: Notice.update.text,
      action: 'Download',
      run: (_) => launchUrl(downloadPage, mode: LaunchMode.externalApplication),
    ),
    // A change of the security keys that can't finish (review 24's I1): without the devices another device took off,
    // on the person's yes; else why, and deleting this device's data, beside another device's change of keys, whose
    // transfer now reaches this one (duvetchat/e2e#49).
    EngineStage.ready when state.stuck && state.gone.isNotEmpty && !state.relisted => (
      text: stuckText(state),
      action: finishWithout,
      run: (context) => context.repository.finishKeysWithout(),
    ),
    EngineStage.ready when state.stuck => (
      text: stuckText(state),
      action: Notice.deleteDevice.text,
      run: (context) => deleteThisDevice(context),
    ),
    // After a change of keys that left devices out: one of them may hold the keys (e2e#49). Asked as Settings asks it,
    // naming each device it takes off beside it (N-M6 of step 4's closing re-review).
    EngineStage.ready when state.keysAgain => (text: keysAgainText, action: 'Change keys', run: _changeKeys),
    // A change of the security keys put off, or cut by the app's close before its upload (Task 25): Finish runs the
    // same change again, whose recovery key's page the state then brings up.
    EngineStage.ready when state.rotating && state.recoveryKey == null => (
      text: 'Finish changing your security keys.',
      action: 'Finish',
      run: (context) => context.repository.changeKeys(),
    ),
    EngineStage.starting || EngineStage.ready => null,
  };

  // Change security keys on its yes alone, to the question Settings asks.
  Future<void> _changeKeys(BuildContext context) async {
    final repository = context.repository;
    final named = await confirmChangeKeys(context);
    if (named != null) await repository.changeKeys(named: named);
  }

  // Set up, or Finish: the identity made (or the one the core kept), whose key's page the state brings up.
  Future<void> _setUp(BuildContext context) => context.repository.makeIdentity();

  Future<void> _startOver(BuildContext context, String action) async {
    final repository = context.repository;
    if (!await confirmDestructive(context, title: action, body: startOverQuestion, action: action)) return;
    await repository.startOver();
  }

  /// A new device's setup act of the strip's that failed (its Finish), said in its place until the state changes
  /// (review 27's M7).
  EngineState? _failedIn;

  Future<void> _act(BuildContext context, EngineState state, Future<void> Function(BuildContext context) run) async {
    setState(() {
      _busy = true;
      _failedIn = null;
    });
    try {
      await run(context);
    } catch (error) {
      debugPrint('e2e: what the person asked for failed: ${error.runtimeType}');
      if (mounted && state.stage == EngineStage.newDevice) setState(() => _failedIn = state);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.encryption, repository.backup, repository.serverKeyChanged]),
      builder: (context, _) {
        final state = repository.encryption.value;
        var bar = _bar(state);
        Object key = state.stage;
        // A ready device with nothing else to say tells how its restore goes, with nothing to press but its ×.
        final backup = repository.backup.value;
        if (bar == null && state.stage == EngineStage.ready && backup.stage == BackupStage.restoring) {
          bar = (text: backupLine(backup), action: null, run: null);
          key = _restoring;
        }
        // Another server key than the one this device first saw, while it's served (Ruling 32).
        if (bar == null && repository.serverKeyChanged.value) {
          bar = (text: Notice.serverKeyChanged.text, action: null, run: null);
          key = Notice.serverKeyChanged;
        }
        if (bar == null || _hiddenFor == key) return const SizedBox.shrink();
        final run = bar.run;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _Strip(
            text: _failedIn == state ? setupFailed : bar.text,
            action: bar.action,
            onAction: run == null || _busy ? null : () => _act(context, state, run),
            onHide: () => setState(() => _hiddenFor = key),
          ),
        );
      },
    );
  }
}

/// The key's page while one is up, whichever strip put it there: never two.
Route<void>? _keyPage;

/// Puts the key's page up on [navigator] while [repository]'s state has a key and none is up. One taken away while the
/// key is still there, by another hand (a link that empties the navigator), goes up again after that frame.
void _showKeyPage(NavigatorState navigator, ChatRepository repository) {
  final key = repository.encryption.value.recoveryKey;
  if (key == null || (_keyPage?.isActive ?? false) || !navigator.mounted) return;
  final route = _keyPage = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _KeyScreen(repository, key));
  unawaited(
    navigator.push(route).whenComplete(() {
      if (identical(_keyPage, route)) _keyPage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showKeyPage(navigator, repository));
    }),
  );
}

/// The page of a new device's approval this device is asked about (Task 27) while one is up: never two. It takes
/// itself away once the approval goes, or its transfer went.
Route<void>? _approvalPage;

void _showApprovalPage(NavigatorState navigator, ChatRepository repository) {
  if (shownApproval(repository.encryption.value) == null || (_approvalPage?.isActive ?? false) || !navigator.mounted) {
    return;
  }
  final route = _approvalPage = MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ApprovalPage(repository),
  );
  unawaited(
    navigator.push(route).whenComplete(() {
      if (identical(_approvalPage, route)) _approvalPage = null;
    }),
  );
}

/// The key's page while the state shows its key. It goes once the key is saved and uploaded, put off (Later), or done
/// with otherwise (an update, another first device that came first), taking its own route away: never the one above
/// it, an incoming call's (M3 of the review).
class _KeyScreen extends StatefulWidget {
  const _KeyScreen(this.repository, this.recoveryKey);

  final ChatRepository repository;
  final String recoveryKey;

  @override
  State<_KeyScreen> createState() => _KeyScreenState();
}

class _KeyScreenState extends State<_KeyScreen> {
  late final ValueListenable<EngineState> _state = widget.repository.encryption;

  @override
  void initState() {
    super.initState();
    _state.addListener(_follow);
    // The key may have gone between the push and this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  @override
  void dispose() {
    _state.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (!mounted || _state.value.recoveryKey == widget.recoveryKey) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  @override
  Widget build(BuildContext context) => RecoveryKeyPage(
    recoveryKey: widget.recoveryKey,
    onSaved: widget.repository.keySaved,
    onLater: widget.repository.uploadLater,
    why: _state.value.rotating ? rotationWhy : recoveryWhy,
  );
}

/// A state as the offline banner says one, with its action and its ×.
class _Strip extends StatelessWidget {
  const _Strip({required this.text, required this.action, required this.onAction, required this.onHide});

  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: context.duvet.shadowWell,
          borderRadius: radius,
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              ExcludeSemantics(child: Icon(FLucideIcons.lockKeyhole, size: 16, color: colors.foreground)),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(text, style: DuvetType.caption.copyWith(color: colors.foreground)),
                ),
              ),
              if (action case final action?) TextAction(label: action, onPressed: onAction),
              IconAction(icon: FLucideIcons.x, label: 'Dismiss', onPressed: onHide),
            ],
          ),
        ),
      ),
    );
  }
}
