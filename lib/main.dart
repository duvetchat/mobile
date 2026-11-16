import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:forui/forui.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:audio_service/audio_service.dart';
import 'package:workmanager/workmanager.dart';

import 'data/appearance.dart';
import 'data/sounds.dart';
import 'data/voice_prefs.dart';
import 'data/launchpad.dart';
import 'data/recent_emoji.dart';
import 'data/call_history.dart';
import 'data/duvet_repository.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'data/webrtc_engine.dart';
import 'calls.dart';
import 'deep_links.dart';
import 'mention_notices.dart';
import 'push/background.dart';
import 'push/notifications.dart';
import 'push/push_message.dart';
import 'push/registration.dart';
import 'push/renewal.dart';
import 'account.dart';
import 'welcome.dart';
import 'tabs.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/media.dart';
import 'widgets/playback_bar.dart';
import 'widgets/scrolling.dart';
import 'widgets/youtube_dock.dart';

Future<void> main() async {
  DuvetBinding();
  // Android's Photo Picker for every picture, as Android 16 does anyway: before
  // it, a pick of photos and GIFs opened the file chooser, and one of a single
  // picture Google Photos (#77).
  if (ImagePickerPlatform.instance case final ImagePickerAndroid android) android.useAndroidPhotoPicker = true;
  // A playing voice note in the media notification and quick settings (#42),
  // before the first player.
  // A failure here costs the notification, never the app's start.
  try {
    await AudioService.init(
      builder: () => VoiceNoteHandler.instance,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'chat.duvet.playback',
        androidNotificationChannelName: 'Voice messages',
        androidNotificationIcon: 'mipmap/ic_launcher_monochrome',
      ),
    );
  } catch (e) {
    debugPrint('AudioService.init failed: $e');
  }
  final repository = DuvetRepository(forgetNotifications: forgetChat);
  // The background renewal asks this isolate first: the session keeps one owner while the app runs
  // (lib/push/renewal.dart).
  answerRenewals(() => repository.renewForBackground(renewalEvery));
  // Push notifications (lib/push). Without Firebase set up (no android/app/google-services.json) the app runs without
  // them, and asks nothing of the user for them: a failure here costs the push, never the app's start.
  PushRegistrar? push;
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    push = const FirebasePushRegistrar();
  } catch (e) {
    debugPrint("push: Firebase isn't set up: $e");
  }
  // Signing out leaves none of the account's notifications on the phone.
  repository.signedOut.listen(
    (_) => unawaited(forgetAllNotifications().catchError((Object e) => debugPrint('push: forgetting: $e'))),
  );
  // A notification's tap opens its message, once signed in; one that started the app too.
  void openTapped(String? link) {
    if (link != null) unawaited(openWhenSignedIn(repository.profile, Uri.parse(link)));
  }

  // A call's notification opens the app, where the call rings once the gateway lists it; its Answer answers it then.
  void openCall(String conversationId, {required bool answer}) {
    if (answer) callAnswered.value = conversationId;
  }

  try {
    await initNotifications(onTap: openTapped, onCall: openCall);
  } catch (e) {
    debugPrint('push: notifications: $e');
  }
  runApp(
    DuvetApp(
      repository: repository,
      push: push,
      // It doesn't hold the first frame back.
      readLaunch: () => unawaited(
        launchedWith().then((response) {
          if (response != null) routeNotificationResponse(response, onTap: openTapped, onCall: openCall);
        }, onError: (Object e) => debugPrint('push: notifications: $e')),
      ),
    ),
  );
  unawaited(_renewInBackground());
}

/// Whether the app shows as it starts: in a state that shows it, or, before any state comes, with a screen to show on.
/// An engine audio_service starts for its media service runs main() with neither.
@visibleForTesting
bool shownAtStart(AppLifecycleState? state, Size viewSize) => state == null ? !viewSize.isEmpty : _shows(state);

// Resumed, or inactive (a dialog or the notification shade over it): on screen.
bool _shows(AppLifecycleState state) => state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

// The session renews every few hours while the app sits closed, so the pushes keep coming (lib/push/renewal.dart).
Future<void> _renewInBackground() async {
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      renewalTask,
      renewalTask,
      frequency: renewalEvery,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (e) {
    debugPrint('session: the background renewal: $e');
  }
}

class DuvetApp extends StatefulWidget {
  final ChatRepository repository;

  /// System, light or dark; tests pass one kept in memory.
  final Appearance? appearance;

  /// The Spaces tab's view and order; tests pass one kept in memory.
  final LaunchpadPrefs? launchpad;

  /// Voice rooms and calls; tests pass one over fakes. By default, WebRTC
  /// and the call history in the keystore.
  final VoiceController? voice;

  /// The sounds and their volumes, and the voice settings (faces, noise
  /// suppression); tests pass ones kept in memory.
  final Sounds? sounds;
  final VoicePrefs? voicePrefs;

  /// Registers the phone for push notifications; tests pass none, which registers nothing.
  final PushRegistrar? push;

  /// Reads the notification whose tap or button started the app, and does what it asks (main), once the app shows:
  /// audio_service's engine may run main() with no screen before the activity a tap launches comes to it.
  final void Function()? readLaunch;
  const DuvetApp({
    required this.repository,
    this.appearance,
    this.launchpad,
    this.voice,
    this.sounds,
    this.voicePrefs,
    this.push,
    this.readLaunch,
    super.key,
  });

  @override
  State<DuvetApp> createState() => _DuvetAppState();
}

class _DuvetAppState extends State<DuvetApp> {
  // The app's own navigator: the notices of mentions, over it, open chats on it.
  final _navigator = GlobalKey<NavigatorState>();
  late final _appearance = widget.appearance ?? (Appearance()..load());
  late final _launchpad = widget.launchpad ?? (LaunchpadPrefs()..load());
  late final Sounds _sounds =
      widget.sounds ??
      (Sounds(
        busy: () =>
            _voice.inVoice ||
            VoiceNoteHandler.instance.player.playing ||
            VideoPage.playing ||
            RecordVoiceRecorder.recording,
      )..load());
  late final _voicePrefs = widget.voicePrefs ?? (VoicePrefs()..load());
  late final _voice =
      widget.voice ??
      VoiceController(
        repository: widget.repository,
        engine: WebRtcVoiceEngine(),
        historyStore: const SecureCallHistoryStore(),
        sounds: _sounds,
        // A call ringing here rings through its notification off screen, which the app puts up when no push did, and
        // takes away on screen, where it rings itself.
        callNotices: (
          show: (call) =>
              ringCallAway(
                CallPush(
                  conversationId: call.conversationId,
                  initiatorId: call.initiatorId,
                  initiatorName: call.initiatorName,
                  initiatorAvatar: call.initiatorAvatar ?? '',
                  // A group's own name, as the API's push gives it.
                  place:
                      widget.repository.conversations.value
                          .where((c) => c.id == call.conversationId)
                          .firstOrNull
                          ?.name ??
                      '',
                  startedAt: call.startedAt,
                  ringUntil: call.startedAt.add(VoiceController.ringWindow),
                ),
              ).catchError((Object e) {
                debugPrint('push: a call\'s notification: $e');
                return false;
              }),
          hide: (conversationId) => unawaited(
            hideCallNotification(
              conversationId,
            ).catchError((Object e) => debugPrint('push: a call\'s notification: $e')),
          ),
        ),
      );

  // The mentions already sounded: the list keeps a notice until it is dismissed.
  Set<String> _mentionsHeard = const {};

  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<void> _signedOut;
  late final PushRegistration? _pushRegistration = switch (widget.push) {
    final registrar? => PushRegistration(widget.repository, registrar),
    null => null,
  };

  // Android's proximity wake lock (MainActivity.kt), held while the sound
  // plays from the earpiece: the screen goes off at the ear (#81).
  static const _proximity = MethodChannel('chat.duvet/proximity');
  bool _atEar = false;

  @override
  void initState() {
    super.initState();
    RecentEmoji.instance.load();
    // Back in sight, the session catches up on a renewal its timer missed.
    // Out of sight the phone's notifications tell of what comes, and the app's own notices keep quiet: in sight is
    // in front for FCM too, which hands the app its messages from then (lib/push). It starts out of sight when
    // nothing shows it: audio_service runs main() on an engine of its own for its media service.
    final binding = WidgetsBinding.instance;
    var shown = shownAtStart(
      binding.lifecycleState,
      binding.platformDispatcher.implicitView?.physicalSize ?? Size.zero,
    );
    if (!shown) widget.repository.wentToBack();
    var launchRead = shown;
    if (shown) widget.readLaunch?.call();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (_shows(state) == shown) return;
        shown = !shown;
        shown ? widget.repository.cameToFront() : widget.repository.wentToBack();
        if (shown && !launchRead) {
          launchRead = true;
          widget.readLaunch?.call();
        }
      },
    );
    _signedOut = widget.repository.signedOut.listen((_) => VideoTile.releaseParked());
    callAnswered.addListener(_answerFromNotification);
    _answerFromNotification();
    _voice.addListener(_followEarpiece);
    _voice.routes.addListener(_followEarpiece);
    _voicePrefs.addListener(_followVoicePrefs);
    _followVoicePrefs();
    _mentionsHeard = {for (final n in widget.repository.mentionNotices.value) n.messageId};
    widget.repository.mentionNotices.addListener(_soundMentions);
    _pushRegistration;
  }

  void _followVoicePrefs() => _voice.setNoiseSuppression(_voicePrefs.noiseSuppression);

  // A call's notification's Answer: the call is answered as it rings here (lib/push).
  void _answerFromNotification() {
    final conversationId = callAnswered.value;
    if (conversationId == null) return;
    callAnswered.value = null;
    _voice.answerWhenRinging(conversationId);
  }

  // A new mention notice comes with the mention sound (#23).
  void _soundMentions() {
    final ids = {for (final n in widget.repository.mentionNotices.value) n.messageId};
    if (ids.difference(_mentionsHeard).isNotEmpty) _sounds.play(Sound.mention);
    _mentionsHeard = ids;
  }

  void _followEarpiece() {
    final atEar = _voice.inVoice && _voice.routes.value.current?.kind == AudioRouteKind.earpiece;
    if (atEar == _atEar || !Platform.isAndroid) return;
    _atEar = atEar;
    _proximity.invokeMethod<void>('hold', atEar).catchError((Object e) => debugPrint('proximity: $e'));
  }

  @override
  void dispose() {
    callAnswered.removeListener(_answerFromNotification);
    _voice.removeListener(_followEarpiece);
    _voice.routes.removeListener(_followEarpiece);
    _voicePrefs.removeListener(_followVoicePrefs);
    widget.repository.mentionNotices.removeListener(_soundMentions);
    if (_atEar) _proximity.invokeMethod<void>('hold', false).catchError((Object e) => debugPrint('proximity: $e'));
    _lifecycle.dispose();
    unawaited(_signedOut.cancel());
    _pushRegistration?.dispose();
    // Before the repository: it listens to it.
    if (widget.voice == null) _voice.dispose();
    widget.repository.dispose();
    if (widget.appearance == null) _appearance.dispose();
    if (widget.launchpad == null) _launchpad.dispose();
    if (widget.sounds == null) _sounds.dispose();
    if (widget.voicePrefs == null) _voicePrefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    appearance: _appearance,
    child: LaunchpadScope(
      prefs: _launchpad,
      child: ValueListenableBuilder(valueListenable: _appearance, builder: (context, _, _) => _app(context)),
    ),
  );

  Widget _app(BuildContext context) {
    final brightness = _appearance.resolve(MediaQuery.platformBrightnessOf(context));
    final theme = Duvet.theme(brightness);

    return RepositoryScope(
      repository: widget.repository,
      child: VoiceScope(
        voice: _voice,
        child: SoundsScope(
          sounds: _sounds,
          child: VoicePrefsScope(
            prefs: _voicePrefs,
            child: MaterialApp(
              navigatorKey: _navigator,
              debugShowCheckedModeBanner: false,
              scrollBehavior: const DuvetScrollBehavior(),
              // forui's list brings material_ui's and cupertino_ui's localizations; the framework's widgets
              // (TextField first) read their own, which only English has without these, and fail to build.
              localizationsDelegates: const [
                ...FLocalizations.localizationsDelegates,
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: FLocalizations.supportedLocales,
              theme: Duvet.material(brightness),
              builder: (context, child) => FTheme(
                data: theme,
                child: FToaster(
                  child: Stack(
                    children: [
                      child!,
                      // Over every screen, the chats opened from Chats and Spaces too.
                      MentionNotices(navigator: _navigator),
                    ],
                  ),
                ),
              ),
              // Duvet's links open whether signed in or not: verifying an email
              // and resetting a password come from links too.
              home: const DeepLinkHandler(child: SessionGate()),
            ),
          ),
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
          builder: (context, profile, _) => profile == null ? const WelcomeScreen() : const HomeTabs(),
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
  final _playback = AudioPlayback.instance;
  late bool _playbackBar = MediaPlaybackBar.shows(_playback.state.value);

  @override
  void initState() {
    super.initState();
    _playback.state.addListener(_followPlayback);
  }

  @override
  void dispose() {
    _playback.state.removeListener(_followPlayback);
    super.dispose();
  }

  // Only when the bar comes or goes: the state changes as often as it plays.
  void _followPlayback() {
    final shows = MediaPlaybackBar.shows(_playback.state.value);
    if (shows != _playbackBar) setState(() => _playbackBar = shows);
  }

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
      child: ListenableBuilder(
        listenable: Listenable.merge([voice, dockedYouTube]),
        builder: (context, _) => _tabs(context, VoiceBar.shows(voice)),
      ),
    );
  }

  Widget _tabs(BuildContext context, bool voiceBar) {
    final media = MediaQuery.of(context);
    final colors = context.theme.colors;
    final barHeight = DuvetTabBar.heightOf(context);
    final voiceHeight = voiceBar ? VoiceBar.height : 0.0;
    final playbackHeight = _playbackBar ? MediaPlaybackBar.height : 0.0;
    final docked = dockedYouTube.value;
    final dockHeight = docked == null ? 0.0 : YouTubeDock.height;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          // The tabs scroll under the bars: they're their bottom padding.
          MediaQuery(
            data: media.copyWith(
              padding: media.padding.copyWith(bottom: barHeight + voiceHeight + playbackHeight + dockHeight),
            ),
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
          // A voice note playing or paused, over the voice bar if there's one.
          if (_playbackBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: barHeight + voiceHeight,
              child: MediaPlaybackBar(playback: _playback),
            ),
          // A YouTube video handed on from a chat, over the rest.
          if (docked != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: barHeight + voiceHeight + playbackHeight,
              child: YouTubeDock(key: ValueKey(docked), video: docked),
            ),
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
