import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/appearance.dart';
import 'data/duvet_repository.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
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
  const DuvetApp({required this.repository, this.appearance, super.key});

  @override
  State<DuvetApp> createState() => _DuvetAppState();
}

class _DuvetAppState extends State<DuvetApp> {
  late final _appearance = widget.appearance ?? (Appearance()..load());

  @override
  void dispose() {
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

  static const _tabs = <TabItem>[
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
    final media = MediaQuery.of(context);
    final colors = context.theme.colors;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          // The tabs scroll under the bar: it's their bottom padding.
          MediaQuery(
            data: media.copyWith(padding: media.padding.copyWith(bottom: DuvetTabBar.heightOf(context))),
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DuvetTabBar(index: index, items: _tabs, onChange: _select),
          ),
        ],
      ),
    );
  }
}
