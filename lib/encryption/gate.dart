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
/// in the Chats tab's header where the offline banner is: nothing while it starts or once it's ready, else a strip with
/// what the person can do, which its × hides until the state changes. A first device's tap makes its identity and shows
/// its recovery key ([RecoveryKeyPage]) until it's done with. What deletes the device's data asks first (M6 of the
/// desktop's review). The DMs' own views take the states with tasks 15 and 17.
class EncryptionBanner extends StatefulWidget {
  const EncryptionBanner({super.key});

  @override
  State<EncryptionBanner> createState() => _EncryptionBannerState();
}

class _EncryptionBannerState extends State<EncryptionBanner> {
  EngineStage? _hiddenFor;
  var _busy = false;

  _Bar? _bar(EngineState state) => switch (state.stage) {
    EngineStage.firstDevice when state.recoveryKey != null => (
      text: Notice.recoveryTitle.text,
      action: 'Show key',
      run: _showKey,
    ),
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
    EngineStage.newDevice => (
      text: 'Set up this device to read your encrypted conversations.',
      action: null,
      run: null,
    ),
    EngineStage.removed => (
      text: Notice.removedDevice.text,
      action: 'Set up again',
      run: (context) => _startOver(context, 'Set up again'),
    ),
    EngineStage.locked => (text: Notice.locked.text, action: null, run: null),
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
    EngineStage.starting || EngineStage.ready => null,
  };

  // Set up, or Finish: the identity made (or the one the core kept), then its key.
  Future<void> _setUp(BuildContext context) async {
    await context.repository.makeIdentity();
    if (context.mounted) await _showKey(context);
  }

  Future<void> _showKey(BuildContext context) async {
    final repository = context.repository;
    if (repository.encryption.value.recoveryKey == null) return;
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _KeyScreen(repository)));
  }

  Future<void> _startOver(BuildContext context, String action) async {
    final repository = context.repository;
    if (!await confirmDestructive(context, title: action, body: startOverQuestion, action: action)) return;
    await repository.startOver();
  }

  Future<void> _act(BuildContext context, Future<void> Function(BuildContext context) run) async {
    setState(() => _busy = true);
    try {
      await run(context);
    } catch (error) {
      debugPrint('e2e: what the person asked for failed: ${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: context.repository.encryption,
    builder: (context, state, _) {
      final bar = _bar(state);
      if (bar == null || _hiddenFor == state.stage) return const SizedBox.shrink();
      final run = bar.run;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: _Strip(
          text: bar.text,
          action: bar.action,
          onAction: run == null || _busy ? null : () => _act(context, run),
          onHide: () => setState(() => _hiddenFor = state.stage),
        ),
      );
    },
  );
}

/// The key's screen while the engine shows that key: it goes once the key is saved and uploaded, put off (Later), or
/// done with otherwise (an update, another first device that came first).
class _KeyScreen extends StatefulWidget {
  const _KeyScreen(this.repository);

  final ChatRepository repository;

  @override
  State<_KeyScreen> createState() => _KeyScreenState();
}

class _KeyScreenState extends State<_KeyScreen> {
  late final ValueListenable<EngineState> _state = widget.repository.encryption;
  late final String _key = _state.value.recoveryKey!;
  var _closed = false;

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
    if (_closed || _state.value.recoveryKey == _key) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) =>
      RecoveryKeyPage(recoveryKey: _key, onSaved: widget.repository.keySaved, onLater: widget.repository.uploadLater);
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
