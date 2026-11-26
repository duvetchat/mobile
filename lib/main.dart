import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import 'data/images.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'data/webrtc_engine.dart';
import 'calls.dart';
import 'deep_links.dart';
// The core's gate needs dart:io and isolates, which the web build lacks.
import 'e2e/app_host_web.dart' if (dart.library.io) 'e2e/app_host.dart';
import 'e2e/push_decrypt.dart';
import 'encryption/change_refusals.dart';
import 'mention_notices.dart';
import 'push/background.dart';
import 'push/notifications.dart';
import 'push/push_message.dart';
import 'push/registration.dart';
import 'push/renewal.dart';
import 'account.dart';
import 'shell.dart';
import 'welcome.dart';
import 'tabs.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/ghost_art.dart';
import 'widgets/media.dart';
import 'widgets/notification_menu.dart';
import 'widgets/playback_bar.dart';
import 'widgets/rows.dart';
import 'widgets/scrolling.dart';
import 'widgets/youtube_dock.dart';

Future<void> main() async {
  final binding = DuvetBinding();
  // Asked once, and not of dart:io in a browser, where asking throws.
  final onAndroid = !kIsWeb && Platform.isAndroid;
  // The theme's mode is the first thing read: the first frame draws by it. The rest of it loads behind.
  final appearance = Appearance();
  unawaited(appearance.load());
  // Android's Photo Picker for every picture, as Android 16 does anyway: before
  // it, a pick of photos and GIFs opened the file chooser, and one of a single
  // picture Google Photos (#77).
  if (ImagePickerPlatform.instance case final ImagePickerAndroid android) android.useAndroidPhotoPicker = true;
  // A playing voice note in the media notification and quick settings (#42),
  // before the first player. The start doesn't wait for it: a note plays
  // without it, and no note plays before the first frame. Its artwork goes
  // in the pictures' store, not a second one of its own opened at each start.
  // A failure here costs the notification, never the app's start.
  unawaited(
    AudioService.init(
      builder: () => VoiceNoteHandler.instance,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'chat.duvet.playback',
        androidNotificationChannelName: 'Voice messages',
        androidNotificationIcon: 'mipmap/ic_launcher_monochrome',
      ),
      cacheManager: pictureStore,
    ).then((_) {}, onError: (Object e) => debugPrint('AudioService.init failed: $e')),
  );
  final repository = DuvetRepository(
    forgetNotifications: forgetChat,
    // A conversation's notice the app couldn't show, gone to the back while it waited, shows as the phone's
    // notification (Android's alone are set up).
    notifyAway: onAndroid
        ? (notice) => unawaited(showPush(MessagePush.away(notice)).catchError((Object e) => debugPrint('push: $e')))
        : null,
    // The encryption engine runs here, the app's engine, on its gate (lib/e2e), once the app is on a screen: main()
    // runs on audio_service's engine too, which may start with none (shownAtStart).
    encryptionHost: appCoreHost,
    onScreen: () =>
        shownAtStart(binding.lifecycleState, binding.platformDispatcher.implicitView?.physicalSize ?? Size.zero),
  );
  // The background renewal asks this isolate first: the session keeps one owner while the app runs
  // (lib/push/renewal.dart).
  answerRenewals(() => repository.renewForBackground(renewalEvery));
  // A push of a conversation's message asks this engine for its text while its device is ready, as it holds the core
  // then (lib/e2e/push_decrypt.dart). The notifications' histories of conversations a version before this one kept,
  // with their text in the clear, go as the app starts.
  answerPushesWhileReady(
    repository.encryption,
    (ask) => repository.pushTexts(ask.conversationId, ask.entry, ask.lines, ask.wait),
  );
  unawaited(
    pushHistory()
        .then((history) => history.forgetConversationTexts())
        .catchError((Object e) => debugPrint('push: the histories before: $e')),
  );
  // Signing out leaves none of the account's notifications on the phone. Before the session starts: one found
  // ended tells of it at once.
  repository.signedOut.listen(
    (_) => unawaited(forgetAllNotifications().catchError((Object e) => debugPrint('push: forgetting: $e'))),
  );
  // The session starts here, not with the first screen: its read of the keystore goes ahead of the plugins' work
  // below, and the API answers while the app builds. Whether the app is in sight is DuvetApp's to say, not said here
  // too: this early the activity may have given neither a state nor a size yet, and an app counted out of sight
  // here would stay so, its state never changing again under DuvetApp.
  final restoring = StartedRestore(repository.restore(), signedOut: repository.signedOut);
  // Push notifications (lib/push), on Android only: there is no Firebase app or notification setup for another
  // platform yet. Without Firebase set up (no android/app/google-services.json) the app runs without them, and asks
  // nothing of the user for them: a failure here costs the push, never the app's start.
  PushRegistrar? push;
  if (onAndroid) {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      push = const FirebasePushRegistrar();
    } catch (e) {
      debugPrint("push: Firebase isn't set up: $e");
    }
  }
  // A notification's tap opens its message, once signed in; one that started the app too.
  void openTapped(String? link) {
    if (link != null) unawaited(openWhenSignedIn(repository.profile, Uri.parse(link)));
  }

  // A call's notification opens the app, where the call rings once the gateway lists it; its Answer answers it then.
  void openCall(String conversationId, {required bool answer}) {
    if (answer) callAnswered.value = conversationId;
  }

  // Waited for: it is what hears a tap. The channels aren't (below).
  if (onAndroid) {
    try {
      await initNotifications(onTap: openTapped, onCall: openCall);
    } catch (e) {
      debugPrint('push: notifications: $e');
    }
  }
  // The first frame waits for what the phone itself keeps, never for the network: the theme's mode, so a forced
  // light or dark is right on it, and the session's read, so a home that was kept is on it instead of a spinner one
  // frame before it. Both reads began first; a keystore that hangs holds the frame no longer than this.
  await Future.wait([
    appearance.modeLoaded,
    repository.restoreRead,
  ]).timeout(const Duration(milliseconds: 500), onTimeout: () => const []);
  runApp(
    DuvetApp(
      repository: repository,
      appearance: appearance,
      push: push,
      restoring: restoring,
      // It doesn't hold the first frame back.
      readLaunch: () => unawaited(_readLaunch(onTap: openTapped, onCall: openCall)),
    ),
  );
  if (!onAndroid) return;
  // The channels after the first frame, which they'd hold back; a notification that shows before waits for them
  // itself, as does one on an engine with no screen, where no frame comes.
  binding.addPostFrameCallback((_) => unawaited(ensureChannels()));
  unawaited(_renewInBackground());
}

// Does what the notification that started the app asks, if one did. Nothing of it fails the app's start.
Future<void> _readLaunch({
  required void Function(String? payload) onTap,
  required void Function(String conversationId, {required bool answer}) onCall,
}) async {
  try {
    final response = await launchedWith();
    if (response != null) routeNotificationResponse(response, onTap: onTap, onCall: onCall);
  } catch (e) {
    debugPrint('push: notifications: $e');
  }
}

/// Whether the app shows as it starts: in a state that shows it, or, before any state comes, with a screen to show on.
/// An engine audio_service starts for its media service runs main() with neither.
@visibleForTesting
bool shownAtStart(AppLifecycleState? state, Size viewSize) => state == null ? !viewSize.isEmpty : _shows(state);

// Resumed, or inactive (a dialog or the notification shade over it): on screen.
bool _shows(AppLifecycleState state) => state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

// The session renews every few hours while the app sits closed, so the pushes keep coming (lib/push/renewal.dart).
// On Android only: iOS runs no such task for the app.
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

  /// The session's restore, started before the app's widgets (main); without one, as in tests, the session gate
  /// starts it.
  final StartedRestore? restoring;
  const DuvetApp({
    required this.repository,
    this.appearance,
    this.launchpad,
    this.voice,
    this.sounds,
    this.voicePrefs,
    this.push,
    this.readLaunch,
    this.restoring,
    super.key,
  });

  @override
  State<DuvetApp> createState() => _DuvetAppState();
}

class _DuvetAppState extends State<DuvetApp> {
  // The app's own navigator: the notices of mentions, over it, open chats on it.
  final _navigator = GlobalKey<NavigatorState>();
  // Where chats open: over everything, or in the wide layout's pane.
  late final _shell = Shell(_navigator);
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
    final registrar? => PushRegistration(widget.repository, registrar, signedOut: widget.restoring?.signedOut ?? false),
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
    _shell.dispose();
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
              navigatorObservers: [_shell.rootObserver],
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
              // The system bars' icons follow the theme. A screen under them that sets its own (the image
              // viewer's) wins while it's up; without this, theirs would stay once it's gone, as Flutter keeps
              // the last style set: light icons on the light theme.
              builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
                value: Duvet.systemBarsOver(brightness),
                child: FTheme(
                  data: theme,
                  child: ShellScope(
                    shell: _shell,
                    child: FToaster(
                      // An encrypted conversation's change the server refused, told over every screen.
                      child: ChangeRefusals(
                        refusals: widget.repository.changesRefused,
                        child: Stack(
                          children: [
                            child!,
                            // Over every screen, the chats opened from Chats and Spaces too.
                            MentionNotices(navigator: _navigator),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Duvet's links open whether signed in or not: verifying an email
              // and resetting a password come from links too.
              home: DeepLinkHandler(child: SessionGate(restoring: widget.restoring)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A restore of the session started before the widgets that follow it, and its outcome as soon as it has one: a
/// future tells of its answer only a turn after it's asked, which would be a frame of the spinner over a restore that
/// is done. Listening to it here also keeps a failure nobody follows yet from being an unhandled error.
class StartedRestore {
  final Future<bool> future;

  /// How it ended; null while it's on its way.
  AsyncSnapshot<bool>? outcome;

  /// Whether the session signed out since: found ended, it says so on [signedOut] as it happens, which those made
  /// with the app's widgets are too late to hear (the push registration unregisters the phone on it).
  bool signedOut = false;

  StartedRestore(this.future, {Stream<void>? signedOut}) {
    signedOut?.listen((_) => this.signedOut = true);
    future.then(
      (signedIn) => outcome = AsyncSnapshot.withData(ConnectionState.done, signedIn),
      onError: (Object e, StackTrace stack) => outcome = AsyncSnapshot.withError(ConnectionState.done, e, stack),
    );
  }
}

/// Resumes the saved session, then shows the app while signed in and the login
/// screen otherwise. The app shows as soon as there is a profile: a session
/// whose home was kept has one before the API answers.
class SessionGate extends StatefulWidget {
  /// The restore main() started; null starts one here.
  final StartedRestore? restoring;
  const SessionGate({this.restoring, super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  // The restore started before this, until another replaces it.
  late StartedRestore? _started = widget.restoring;
  Future<bool>? _restoring;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoring != null) return;
    _restoring = _started?.future ?? context.repository.restore();
    // Every screen after this one opens on the app's icon: parsed while the session is on its way, it is there
    // for that screen's first frame.
    AppIcon.warm(context);
  }

  // In a block: setState takes no callback that answers a future, and a debug
  // build throws on one before it rebuilds.
  void _retry() => setState(() {
    _started = null;
    _restoring = context.repository.restore();
  });

  void _signInInstead() => setState(() {
    _started = null;
    _restoring = Future.value(false);
  });

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    // The profile is followed inside the restore, not around it: a sign-out
    // then finds the restore done, and shows the welcome screen with no frame
    // of the spinner between.
    return FutureBuilder(
      future: _restoring,
      builder: (context, snapshot) => ValueListenableBuilder<Profile?>(
        valueListenable: repository.profile,
        builder: (context, profile, _) {
          if (profile != null) return const HomeTabs();
          // A restore that ended before the first build shows its outcome in it.
          final restore = _started?.outcome ?? snapshot;
          if (restore.connectionState != ConnectionState.done) {
            return const FScaffold(child: Center(child: FCircularProgress()));
          }
          if (restore.hasError) {
            return _Unreachable(onRetry: _retry, onSignIn: _signInInstead);
          }
          return const WelcomeScreen();
        },
      ),
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
///
/// On a wide window (a tablet, a desktop, a long phone on its side) it is the desktop's layout instead: the tabs
/// down a rail with the Spaces, the open tab as a list beside it, and the chat in a pane of its own.
class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int index = 0;
  // The tabs built so far: the open one, each opened since, and the others once the home has gone quiet. The rest
  // are empty slots, so the frame the home first shows in builds one tab, not four.
  final _built = <int>{0};
  final _spaces = GlobalKey<NavigatorState>();
  // The tabs keep their state as the window crosses between the layouts.
  final _tabs = GlobalKey();
  final _playback = AudioPlayback.instance;
  late bool _playbackBar = MediaPlaybackBar.shows(_playback.state.value);

  // The Space whose directory the Spaces tab shows, for the rail.
  late final _spaceRoutes = RouteStack(_followSpace);
  String? _spaceId;

  // The pane's chat, and whether the app listed it: a conversation left or a room deleted closes it.
  Listenable? _chats;
  Shell? _shell;
  String? _openId;
  bool _openListed = false;

  @override
  void initState() {
    super.initState();
    _playback.state.addListener(_followPlayback);
    _buildRestWhenQuiet();
  }

  // The tabs not opened yet, one a frame, each after a frame that ends with nothing animating: a tap then finds
  // its tab built, and none of them is built in the frames the home comes up in (its icon hops, and it spins
  // while it connects). Not SchedulerBinding.scheduleTask at Priority.idle: a task of its that finds an animation
  // running asks again in a timer of no length, on and on until the animation ends.
  void _buildRestWhenQuiet() => SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final next = [
      for (var i = 0; i < _items.length; i++)
        if (!_built.contains(i)) i,
    ].firstOrNull;
    if (next == null) return;
    if (SchedulerBinding.instance.transientCallbackCount == 0) setState(() => _built.add(next));
    _buildRestWhenQuiet();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_chats != null) return;
    final repository = context.repository;
    _shell = Shell.maybeOf(context);
    _chats = Listenable.merge([repository.conversations, repository.spaces, ?_shell])..addListener(_followOpen);
  }

  @override
  void dispose() {
    _playback.state.removeListener(_followPlayback);
    _chats?.removeListener(_followOpen);
    super.dispose();
  }

  void _followOpen() {
    final repository = context.repository;
    final id = _shell?.openId;
    final listed =
        id != null &&
        (repository.conversations.value.any((c) => c.id == id) ||
            repository.spaces.value.any((s) => s.rooms.any((r) => r.id == id)));
    if (id != null && id == _openId && _openListed && !listed) _shell!.close();
    _openId = id;
    _openListed = listed;
  }

  // Only when the bar comes or goes: the state changes as often as it plays.
  void _followPlayback() {
    final shows = MediaPlaybackBar.shows(_playback.state.value);
    if (shows != _playbackBar) setState(() => _playbackBar = shows);
  }

  void _followSpace() {
    final name = _spaceRoutes.routes.lastOrNull?.settings.name;
    final id = name != null && name.startsWith(spaceRoutePrefix) ? name.substring(spaceRoutePrefix.length) : null;
    if (id == _spaceId) return;
    afterBuild(() {
      if (mounted) setState(() => _spaceId = id);
    });
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
    setState(() {
      index = i;
      _built.add(i);
    });
  }

  // From the rail: the Space's directory, in place of the one open.
  void _openSpace(Space space) {
    setState(() {
      index = 1;
      _built.add(1);
    });
    if (space.id == _spaceId) return;
    _spaces.currentState?.pushAndRemoveUntil(spaceRoute(space, instant: true), (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.voice;
    final shell = Shell.watch(context);
    final media = MediaQuery.of(context);
    // Outside the app's shell (pumped alone), the phone's layout. The width is what the notch's sides leave.
    final size = shell == null ? SizeClass.compact : SizeClass.of(media.size.width - media.padding.horizontal);
    shell?.layout(wide: size.wide);
    // The rail opens a Space on the Spaces tab's navigator, which has to be there for the first tap.
    if (size.wide) _built.add(1);
    return VoiceListener(
      // Between the notch's sides, on a phone turned.
      child: SafeSides(
        child: ListenableBuilder(
          listenable: Listenable.merge([voice, dockedYouTube]),
          builder: (context, _) => size.wide
              ? _wide(context, shell!, size, VoiceBar.shows(voice))
              : _narrow(context, shell, VoiceBar.shows(voice)),
        ),
      ),
    );
  }

  // The system's Back, on a wide window: the pane's thread or search first, else the Space the list shows. One
  // press goes back one step, though both navigators are asked.
  void _backInSpaces() {
    final shell = _shell;
    if (shell != null && shell.wide) {
      if (shell.pane.currentState?.canPop() ?? false) return;
      if (index != 1) return;
    }
    _spaces.currentState?.maybePop();
  }

  Widget _stack() {
    Widget slot(int i, Widget tab) => _built.contains(i) ? tab : const SizedBox.shrink();
    return KeyedSubtree(
      key: _tabs,
      child: IndexedStack(
        index: index,
        children: [
          slot(0, const ChatsTab()),
          slot(
            1,
            NavigatorPopHandler(
              // Behind another tab on a wide window, its Space isn't what Back leaves.
              enabled: !(_shell?.wide ?? false) || index == 1,
              onPopWithResult: (_) => _backInSpaces(),
              child: Navigator(
                key: _spaces,
                observers: [_spaceRoutes],
                onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const SpacesTab()),
              ),
            ),
          ),
          slot(2, const CallsTab()),
          slot(3, const YouTab()),
        ],
      ),
    );
  }

  // The chats open in the pane; on a compact window only for the frame before they move over everything.
  Widget _pane(Shell shell, {bool roomForMembers = false}) => PaneScope(
    roomForMembers: roomForMembers,
    showMembers: shell.showMembers,
    toggleMembers: shell.toggleMembers,
    child: NavigatorPopHandler(
      onPopWithResult: (_) => shell.pane.currentState?.maybePop(),
      child: Navigator(key: shell.pane, observers: [shell.paneObserver], onGenerateRoute: (_) => shell.emptyRoute()),
    ),
  );

  Widget _wide(BuildContext context, Shell shell, SizeClass size, bool voiceBar) {
    final media = MediaQuery.of(context);
    final colors = context.theme.colors;
    final repository = context.repository;
    final listWidth = ShellSizes.list(media.size.width);
    final paneWidth = media.size.width - ShellSizes.rail - listWidth - 2;
    final voiceHeight = voiceBar ? VoiceBar.height : 0.0;
    final playbackHeight = _playbackBar ? MediaPlaybackBar.height : 0.0;
    final docked = dockedYouTube.value;
    final dockHeight = docked == null ? 0.0 : YouTubeDock.height;
    final below = media.padding.bottom;
    final rule = SizedBox(width: 1, child: ColoredBox(color: context.duvet.hairline));
    final keyboard = media.viewInsets.bottom;
    return Scaffold(
      backgroundColor: colors.background,
      // Each column makes room for the keyboard itself, once: the chat's own page does in the pane, the list is
      // padded here, and the rail stays as it is behind it.
      resizeToAvoidBottomInset: false,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Each column is a container of its own to screen readers: a navigator's routes hide what was drawn
          // before them in theirs, which would be the rail and the list behind an open chat.
          _column(
            width: ShellSizes.rail,
            child: ListenableBuilder(
              listenable: Listenable.merge([repository.spaces, repository.unread, repository.notificationLevels]),
              builder: (context, _) => DuvetNavRail(
                index: index == 1 && _spaceId != null ? -1 : index,
                items: _items,
                onChange: _select,
                children: [
                  for (final space in sortedSpaces(repository.spaces.value, LaunchpadScope.of(context).value.sort))
                    Builder(
                      key: ValueKey(space.id),
                      builder: (anchor) => RailButton(
                        label: space.name,
                        selected: index == 1 && space.id == _spaceId,
                        unread: space.rooms.any((r) => repository.shownUnread(r.id)),
                        onTap: () => _openSpace(space),
                        onLongPress: () =>
                            showNotificationMenu(anchor, targetId: space.id, target: NotificationTarget.space),
                        child: SpaceIcon(space: space, size: 44),
                      ),
                    ),
                ],
              ),
            ),
          ),
          rule,
          _column(
            width: listWidth,
            child: Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              child: Stack(
                children: [
                  // The tab scrolls under the bars: they're its bottom padding.
                  MediaQuery(
                    data: media.copyWith(
                      size: Size(listWidth, media.size.height),
                      padding: media.padding.copyWith(bottom: below + voiceHeight + playbackHeight + dockHeight),
                      viewInsets: media.viewInsets.copyWith(bottom: 0),
                    ),
                    child: _stack(),
                  ),
                  if (voiceBar) Positioned(left: 0, right: 0, bottom: below, child: const VoiceBar()),
                  if (_playbackBar)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: below + voiceHeight,
                      child: MediaPlaybackBar(playback: _playback),
                    ),
                  if (docked != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: below + voiceHeight + playbackHeight,
                      child: YouTubeDock(key: ValueKey(docked), video: docked),
                    ),
                ],
              ),
            ),
          ),
          rule,
          Expanded(
            // The chat measures itself by its pane, not the window.
            child: _column(
              child: MediaQuery(
                data: media.copyWith(size: Size(paneWidth, media.size.height)),
                child: _pane(shell, roomForMembers: size == SizeClass.expanded),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _column({double? width, required Widget child}) => SizedBox(
    width: width,
    child: Semantics(container: true, explicitChildNodes: true, child: child),
  );

  Widget _narrow(BuildContext context, Shell? shell, bool voiceBar) {
    final tabs = _compact(context, voiceBar);
    if (shell == null || !shell.paneOpen) return tabs;
    return Stack(
      children: [
        tabs,
        Positioned.fill(child: _pane(shell)),
      ],
    );
  }

  Widget _compact(BuildContext context, bool voiceBar) {
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
            child: _stack(),
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
