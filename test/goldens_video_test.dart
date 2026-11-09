import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/data/voice_engine.dart';
import 'package:duvet/data/voice_prefs.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';
import 'support/fonts.dart';

const _maya = FakeRepository.maya;
const _leo = FakeRepository.leo;

class _App {
  final repository = FakeRepository();
  final engine = FakeVoiceEngine();
  late final voice = VoiceController(
    repository: repository,
    engine: engine,
    historyStore: MemoryCallHistoryStore(),
    clock: () => DateTime(2026, 10, 23, 10),
  );

  FakeVoiceSignaling get gateway => repository.voiceSignaling;
}

class _Player implements SoundPlayer {
  @override
  Future<void> play(Sound sound, double gain, {bool loop = false}) async {}

  @override
  Future<void> stop(Sound sound) async {}

  @override
  Future<void> dispose() async {}
}

class _Ringer implements RingerMode {
  @override
  Future<bool> quiet() async => false;
}

duvet.VoiceStateUpdatedEvent _state(
  String user,
  int version, {
  String room = 'r-lounge',
  bool camera = false,
  bool screen = false,
  bool muted = false,
}) => duvet.VoiceStateUpdatedEvent(
  duvet.VoiceStateEvent(
    roomId: room,
    userId: user,
    joined: true,
    muted: muted,
    camera: camera,
    screenSharing: screen,
    version: version,
  ),
);

/// A stand-in camera or screen: a gradient you can tell apart from black.
VoiceRemoteVideo _video(String user, VideoKind kind) => VoiceRemoteVideo(
  userId: user,
  kind: kind,
  view: (_) => SizedBox.expand(
    key: Key('$user-${kind.name}'),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: kind == VideoKind.camera
              ? const [Color(0xFFE8B28A), Color(0xFF7A4E6B), Color(0xFF2B3550)]
              : const [Color(0xFFDCE6F0), Color(0xFF9DB4C8), Color(0xFF4F6B84)],
        ),
      ),
    ),
  ),
);

/// The video-in-voice UI, drawn in both themes. Update them with
/// `flutter test --update-goldens test/goldens_video_test.dart`.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    await loadAppFonts();
    final icons = FontLoader('packages/forui_lucide/ForuiLucideIcons')
      ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf'));
    await icons.load();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  void phone(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  // Real soft shadows, not the test binding's solid stand-ins, while [body]
  // runs.
  Future<void> withShadows(Future<void> Function() body) async {
    debugDisableShadows = false;
    try {
      await body();
    } finally {
      debugDisableShadows = true;
    }
  }

  // The screens tick (a call's clock, the voice levels): settle by time, not by frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final b in Brightness.values) {
    Future<_App> pumpApp(WidgetTester tester) async {
      phone(tester);
      final app = _App();
      await tester.pumpWidget(
        DuvetApp(
          repository: app.repository,
          appearance: Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          voice: app.voice,
          voicePrefs: VoicePrefs(),
          sounds: Sounds(player: _Player(), ringer: _Ringer()),
        ),
      );
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> finish(WidgetTester tester, _App app) async {
      await tester.pumpWidget(const SizedBox());
      app.voice.dispose();
    }

    Future<void> joinLounge(WidgetTester tester, _App app) async {
      await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Design Guild'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lounge').last);
      await settle(tester);
      await tester.tap(find.text('Join voice'));
      await settle(tester);
      app.gateway.push(
        const duvet.VoiceJoinedPayloadEvent(
          duvet.VoiceJoinedEvent(
            roomId: 'r-lounge',
            answer: duvet.SessionDescription(type: 'answer', sdp: 'a1'),
          ),
        ),
      );
      app.engine.peer.stateHandler!(PeerState.connected);
      await settle(tester);
    }

    // Me muted, Maya on camera, Leo speaking.
    Future<void> threePeople(WidgetTester tester, _App app) async {
      app.gateway.push(_state(_maya, 3, camera: true));
      app.gateway.push(_state(_leo, 4));
      app.engine.peer.remoteVideos.value = [_video(_maya, VideoKind.camera)];
      await app.voice.toggleMute();
      app.engine.peer.levels = (local: null, remote: {_leo: 0.6});
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await settle(tester);
    }

    Future<void> golden(WidgetTester tester, String state) =>
        expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/video_${state}_${b.name}.png'));

    testWidgets(
      'voice room alone, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await joinLounge(tester, app);
        await golden(tester, 'alone');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'voice room with three, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await joinLounge(tester, app);
        await threePeople(tester, app);
        await golden(tester, 'people');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'screens shared, watched and not, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await joinLounge(tester, app);
        app.gateway.push(_state(_maya, 3, screen: true));
        app.gateway.push(_state(_leo, 4, screen: true));
        app.engine.peer.remoteVideos.value = [_video(_maya, VideoKind.screen), _video(_leo, VideoKind.screen)];
        await settle(tester);
        await golden(tester, 'screen_watch');
        await tester.tap(find.text('Watch').first);
        await settle(tester);
        await golden(tester, 'screen_watching');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'a tile shown large, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await joinLounge(tester, app);
        await threePeople(tester, app);
        await tester.tap(find.byKey(const Key('$_maya-camera')));
        await settle(tester);
        await golden(tester, 'focus');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'the More sheet, ${b.name}',
      (tester) => withShadows(() async {
        final semantics = tester.ensureSemantics();
        final app = await pumpApp(tester);
        await joinLounge(tester, app);
        await tester.tap(find.bySemanticsLabel('More voice options'));
        await settle(tester);
        await settle(tester);
        await golden(tester, 'more');
        semantics.dispose();
        await finish(tester, app);
      }),
    );

    Future<void> youVoice(WidgetTester tester) async {
      await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(find.text('Faces in voice')), alignment: 0.3);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the You page\'s Voice section, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await youVoice(tester);
        await golden(tester, 'you_voice');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'the Sounds page, ${b.name}',
      (tester) => withShadows(() async {
        final app = await pumpApp(tester);
        await youVoice(tester);
        await tester.tap(find.text('Sounds'));
        await tester.pumpAndSettle();
        await golden(tester, 'sounds');
        await finish(tester, app);
      }),
    );

    testWidgets(
      'the call screen with a camera, ${b.name}',
      (tester) => withShadows(() async {
        final semantics = tester.ensureSemantics();
        final app = await pumpApp(tester);
        app.gateway.push(
          const duvet.CallIncomingPayloadEvent(
            duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: _maya, initiatorName: 'Maya'),
          ),
        );
        await settle(tester);
        await tester.tap(find.bySemanticsLabel('Accept the call'));
        await settle(tester);
        app.engine.peer.stateHandler!(PeerState.connected);
        app.gateway.push(_state(_maya, 3, room: 'c-maya', camera: true));
        app.engine.peer.remoteVideos.value = [_video(_maya, VideoKind.camera)];
        await settle(tester);
        await golden(tester, 'call');
        semantics.dispose();
        await finish(tester, app);
      }),
    );
  }
}

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}
