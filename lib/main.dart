import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/appearance.dart';
import 'data/call_history.dart';
import 'data/duvet_repository.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'data/webrtc_engine.dart';
import 'calls.dart';
import 'deep_links.dart';
import 'account.dart';
import 'login.dart';
import 'tabs.dart';
import 'theme.dart';
import 'widgets/chrome.dart';

void main() => runApp(DuvetApp(repository: DuvetRepository()));

class DuvetApp extends StatefulWidget {
  final ChatRepository repository;

  /// System, light or dark; tests pass one kept in memory.
  final Appearance? appearance;

  /// Voice rooms and calls; tests pass one over fakes. By default, WebRTC
  /// and the call history in the keystore.
  final VoiceController? voice;
  const DuvetApp({required this.repository, this.appearance, this.voice, super.key});

  @override
  State<DuvetApp> createState() => _DuvetAppState();
}

class _DuvetAppState extends State<DuvetApp> {
  late final _appearance = widget.appearance ?? (Appearance()..load());
  late final _voice =
      widget.voice ??
      VoiceController(
        repository: widget.repository,
        engine: WebRtcVoiceEngine(),
        historyStore: const SecureCallHistoryStore(),
      );

  @override
  void dispose() {
    // Before the repository: it listens to it.
    if (widget.voice == null) _voice.dispose();
    widget.repository.dispose();
    if (widget.appearance == null) _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    appearance: _appearance,
    child: ValueListenableBuilder(valueListenable: _appearance, builder: (context, _, _) => _app(context)),
  );

  Widget _app(BuildContext context) {
    final brightness = _appearance.resolve(MediaQuery.platformBrightnessOf(context));
    final theme = Duvet.theme(brightness);

    return RepositoryScope(
      repository: widget.repository,
      child: VoiceScope(
        voice: _voice,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: FLocalizations.localizationsDelegates,
          supportedLocales: FLocalizations.supportedLocales,
          theme: Duvet.material(brightness),
          builder: (context, child) => FTheme(
            data: theme,
            child: FToaster(child: child!),
          ),
          // Duvet's links open whether signed in or not: verifying an email
          // and resetting a password come from links too.
          home: const DeepLinkHandler(child: SessionGate()),
        ),
      ),
    );
  }
}

/// Resumes the saved session, then shows the app while signed in and the login
/// screen otherwise.
class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  Future<bool>? _restoring;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restoring ??= context.repository.restore();
  }

  void _retry() => setState(() => _restoring = context.repository.restore());

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return FutureBuilder(
      future: _restoring,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const FScaffold(child: Center(child: FCircularProgress()));
        }
        if (snapshot.hasError) {
          return _Unreachable(onRetry: _retry, onSignIn: () => setState(() => _restoring = Future.value(false)));
        }
        return ValueListenableBuilder<Profile?>(
          valueListenable: repository.profile,
          builder: (context, profile, _) => profile == null ? const LoginScreen() : const HomeTabs(),
        );
      },
    );
  }
}

class _Unreachable extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onSignIn;
  const _Unreachable({required this.onRetry, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FScaffold(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FLucideIcons.wifiOff, size: 32, color: colors.mutedForeground),
            const SizedBox(height: 12),
            Text('Couldn’t reach Duvet', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
            const SizedBox(height: 16),
            FButton(onPress: onRetry, mainAxisSize: MainAxisSize.min, child: const Text('Try again')),
            const SizedBox(height: 8),
            FButton(
              variant: .ghost,
              onPress: onSignIn,
              mainAxisSize: MainAxisSize.min,
              child: const Text('Sign in instead'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Root of the app: four tabs over a glass tab bar. Spaces drills down to a
/// Space's directory with the tab bar still showing; a chat covers it.
class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int index = 0;
  final _spaces = GlobalKey<NavigatorState>();

  static const _items = <TabItem>[
    (icon: FLucideIcons.messageCircle, label: 'Chats'),
    (icon: FLucideIcons.layoutGrid, label: 'Spaces'),
    (icon: FLucideIcons.phone, label: 'Calls'),
    (icon: FLucideIcons.user, label: 'You'),
  ];

  void _select(int i) {
    // The open tab again: back to its root.
    if (i == index && i == 1) _spaces.currentState?.popUntil((r) => r.isFirst);
    setState(() => index = i);
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.voice;
    return VoiceListener(
      child: ListenableBuilder(listenable: voice, builder: (context, _) => _tabs(context, VoiceBar.shows(voice))),
    );
  }

  Widget _tabs(BuildContext context, bool voiceBar) {
    final media = MediaQuery.of(context);
    final colors = context.theme.colors;
    final barHeight = DuvetTabBar.heightOf(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          // The tabs scroll under the bars: they're their bottom padding.
          MediaQuery(
            data: media.copyWith(padding: media.padding.copyWith(bottom: barHeight + (voiceBar ? VoiceBar.height : 0))),
            child: IndexedStack(
              index: index,
              children: [
                const ChatsTab(),
                NavigatorPopHandler(
                  onPopWithResult: (_) => _spaces.currentState?.maybePop(),
                  child: Navigator(
                    key: _spaces,
                    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const SpacesTab()),
                  ),
                ),
                const CallsTab(),
                const YouTab(),
              ],
            ),
          ),
          // In voice or a call: back to it, over the tab bar.
          if (voiceBar) Positioned(left: 0, right: 0, bottom: barHeight, child: const VoiceBar()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DuvetTabBar(index: index, items: _items, onChange: _select),
          ),
        ],
      ),
    );
  }
}
