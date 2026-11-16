// M12 · Video in voice: the camera button, the More sheet, camera and screen
// tiles, focus, faces, the call screen's video, and who's live on Chats, over
// a fake gateway and a fake WebRTC.
import 'dart:async';

import 'package:duvet/data/admin.dart' show Perm;
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/models.dart' show ConversationSummary;
import 'package:duvet/data/voice.dart';
import 'package:duvet/data/voice_engine.dart';
import 'package:duvet/data/voice_prefs.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

/// Holds openCamera while [hold] is set: the permission dialog.
class _Engine extends FakeVoiceEngine {
  Completer<void>? hold;

  @override
  Future<VoiceCamera?> openCamera({String? deviceId}) async {
    if (hold case final hold?) await hold.future;
    return super.openCamera(deviceId: deviceId);
  }
}

class _App {
  final repository = FakeRepository();
  final engine = _Engine();
  late final voice = VoiceController(
    repository: repository,
    engine: engine,
    historyStore: MemoryCallHistoryStore(),
    clock: () => DateTime(2026, 10, 23, 10),
  );

  FakeVoiceSignaling get gateway => repository.voiceSignaling;
}

const _maya = FakeRepository.maya;
const _leo = FakeRepository.leo;

duvet.VoiceStateUpdatedEvent _state(
  String user,
  int version, {
  String room = 'r-lounge',
  bool camera = false,
  bool screen = false,
  List<String> watching = const [],
}) => duvet.VoiceStateUpdatedEvent(
  duvet.VoiceStateEvent(
    roomId: room,
    userId: user,
    joined: true,
    camera: camera,
    screenSharing: screen,
    version: version,
    watching: watching,
  ),
);

VoiceRemoteVideo _video(String user, VideoKind kind) => VoiceRemoteVideo(
  userId: user,
  kind: kind,
  view: (_) => SizedBox.expand(key: Key('$user-${kind.name}')),
);

/// A video view that counts its builds.
class _Counted extends StatelessWidget {
  final VoidCallback onBuild;
  const _Counted(this.onBuild);

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}

/// A video view that counts its starts: a renderer made.
class _Started extends StatefulWidget {
  final VoidCallback onStart;
  const _Started(this.onStart);

  @override
  State<_Started> createState() => _StartedState();
}

class _StartedState extends State<_Started> {
  @override
  void initState() {
    super.initState();
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<_App> pumpApp(WidgetTester tester, {VoicePrefs? prefs}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // On screen, as Android says of the app it shows: voice reads levels and video only there.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final app = _App();
    await tester.pumpWidget(DuvetApp(repository: app.repository, voice: app.voice, voicePrefs: prefs));
    await tester.pumpAndSettle();
    return app;
  }

  // The screens tick (a call's clock): settle by time, not by frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> finish(WidgetTester tester, _App app) async {
    await tester.pumpWidget(const SizedBox());
    app.voice.dispose();
  }

  // Opens the lounge and joins its voice, connected and answered: the screen can be shared.
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

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('More voice options'));
    await settle(tester);
  }

  testWidgets('the camera button turns the camera on and off, once however fast it\'s tapped', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);

    // A second tap while the first waits on the permission dialog opens nothing more.
    final hold = app.engine.hold = Completer();
    await tester.tap(find.bySemanticsLabel('Camera'));
    await tester.tap(find.bySemanticsLabel('Camera'), warnIfMissed: false);
    await settle(tester);
    hold.complete();
    app.engine.hold = null;
    await settle(tester);
    expect(app.engine.openedCameras, hasLength(1));
    expect(app.voice.cameraOn, isTrue);
    expect(app.gateway.last('VOICE_SYNC')!['camera'], isTrue);
    expect(find.bySemanticsLabel('Gaby (you), camera on'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Camera'));
    await settle(tester);
    expect(app.voice.cameraOn, isFalse);
    expect(app.engine.openedCameras.single.stopped, isTrue);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('without Video the camera button is disabled, and says why', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.repository.deniedInRoom['r-lounge'] = Perm.video;
    await joinLounge(tester, app);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Camera')),
      matchesSemantics(
        label: 'Camera',
        hint: 'You can’t use video in this room',
        isButton: true,
        hasToggledState: true,
        hasEnabledState: true,
      ),
    );
    await tester.tap(find.bySemanticsLabel('Camera'), warnIfMissed: false);
    await settle(tester);
    expect(app.engine.openedCameras, isEmpty);

    await openMore(tester);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Share screen')),
      matchesSemantics(
        label: 'Share screen',
        hint: 'You can’t use video in this room',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    await tester.tap(find.text('Share screen'), warnIfMissed: false);
    await settle(tester);
    expect(app.engine.screens, isEmpty);

    // Flip camera and the cameras show too, out of reach, saying why.
    for (final label in ['Flip camera', 'Back Camera, Back']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(label: label, hint: 'You can’t use video in this room', isButton: true, isEnabled: false),
      );
    }
    await tester.tap(find.text('Back Camera'), warnIfMissed: false);
    await settle(tester);
    expect(app.voice.selectedCameraId, isNull);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('More: share the screen and stop, flip and pick the camera, incoming video', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);

    await openMore(tester);
    expect(find.text('Flip camera'), findsNothing);
    await tester.tap(find.text('Share screen'));
    await settle(tester);
    expect(app.voice.screenSharing, isTrue);
    expect(app.engine.screens, hasLength(1));
    expect(find.bySemanticsLabel('Your screen'), findsOneWidget);
    expect(find.text('You’re sharing your screen'), findsOneWidget);

    await openMore(tester);
    await tester.tap(find.text('Stop sharing'));
    await settle(tester);
    expect(app.voice.screenSharing, isFalse);
    expect(app.engine.screens.single.stopped, isTrue);

    await tester.tap(find.bySemanticsLabel('Camera'));
    await settle(tester);
    await openMore(tester);
    await tester.tap(find.text('Flip camera'));
    await settle(tester);
    expect(app.engine.openedCameras.single.switches, 1);

    await openMore(tester);
    expect(find.byIcon(FLucideIcons.check), findsNothing);
    await tester.tap(find.text('Back Camera'));
    await settle(tester);
    expect(app.engine.openedCameras.last.deviceId, '0');
    expect(app.voice.cameraOn, isTrue);

    // The camera picked is checked.
    await openMore(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Back Camera, Back')), isSemantics(isSelected: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Front Camera, Front')), isSemantics(isSelected: false));
    expect(find.byIcon(FLucideIcons.check), findsOneWidget);
    // Incoming video reads once, with its state.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Incoming video')),
      isSemantics(label: 'Incoming video', isToggled: true, hasToggledState: true, hasTapAction: true),
    );
    await tester.tap(find.byWidgetPredicate((w) => w is DuvetSwitch && w.label == 'Incoming video'));
    await settle(tester);
    expect(app.voice.incomingVideo, isFalse);
    expect(app.gateway.last('VOICE_SYNC')!['video_off'], isTrue);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('someone\'s camera shows on their tile; a tap shows it large, back returns', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    app.gateway.push(_state(_maya, 3, camera: true));
    app.engine.peer.remoteVideos.value = [_video(_maya, VideoKind.camera)];
    await settle(tester);
    expect(find.byKey(const Key('$_maya-camera')), findsOneWidget);
    final tile = find.bySemanticsLabel('Maya, camera on');
    expect(tile, findsOneWidget);
    expect(tester.getSemantics(tile).hint, 'Show large');

    await tester.tap(tile);
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya, camera on')).hint, 'Show everyone');
    // The others in a strip under it.
    expect(tester.getSize(find.bySemanticsLabel('Gaby (you)')).width, 160);

    await tester.tap(find.bySemanticsLabel('Back'));
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya, camera on')).hint, 'Show large');
    expect(find.bySemanticsLabel('More voice options'), findsOneWidget);

    // Incoming video off: her face, and the camera said to be off here.
    await app.voice.setIncomingVideo(false);
    await settle(tester);
    expect(find.byKey(const Key('$_maya-camera')), findsNothing);
    expect(find.bySemanticsLabel('Maya, camera on, video is off'), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('showing a camera large and back keeps its video view, renderer and all', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    var starts = 0;
    app.gateway.push(_state(_maya, 3, camera: true));
    app.engine.peer.remoteVideos.value = [
      VoiceRemoteVideo(userId: _maya, kind: VideoKind.camera, view: (_) => _Started(() => starts++)),
    ];
    await settle(tester);
    expect(starts, 1);

    await tester.tap(find.bySemanticsLabel('Maya, camera on'));
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya, camera on')).hint, 'Show everyone');
    await tester.tap(find.bySemanticsLabel('Maya, camera on'));
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya, camera on')).hint, 'Show large');
    expect(starts, 1);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a large tile that goes is forgotten: shared again, it comes back in the grid', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    app.gateway.push(_state(_maya, 3, screen: true));
    await settle(tester);
    // Its corner: Watch is in its middle.
    await tester.tapAt(tester.getTopLeft(find.bySemanticsLabel('Maya’s screen')) + const Offset(24, 24));
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya’s screen')).hint, 'Show everyone');

    app.gateway.push(_state(_maya, 4));
    await settle(tester);
    expect(find.bySemanticsLabel('Maya’s screen'), findsNothing);
    app.gateway.push(_state(_maya, 5, screen: true));
    await settle(tester);
    expect(tester.getSemantics(find.bySemanticsLabel('Maya’s screen')).hint, 'Show large');
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('out of the room\'s voice, a camera reads as on, not as off', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.gateway.push(_state(_maya, 3, camera: true));
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lounge').last);
    await settle(tester);
    expect(find.bySemanticsLabel('Maya, camera on'), findsOneWidget);
    expect(find.byIcon(FLucideIcons.videoOff), findsNothing);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a voice level tick moves the mouths, not the video views', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    var views = 0;
    app.gateway.push(_state(_maya, 3, camera: true));
    app.engine.peer.remoteVideos.value = [
      VoiceRemoteVideo(userId: _maya, kind: VideoKind.camera, view: (_) => _Counted(() => views++)),
    ];
    await settle(tester);
    final before = views;
    expect(before, greaterThan(0));

    app.engine.peer.levels = (local: null, remote: {_maya: 0.5});
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.bySemanticsLabel('Maya, camera on, speaking'), findsOneWidget);
    expect(views, before);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a shared screen waits for Watch, and Stop watching puts it away', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    app.gateway.push(_state(_maya, 3, screen: true));
    app.engine.peer.remoteVideos.value = [_video(_maya, VideoKind.screen)];
    await settle(tester);
    expect(find.bySemanticsLabel('Maya’s screen'), findsOneWidget);
    expect(find.byKey(const Key('$_maya-screen')), findsNothing);

    await tester.tap(find.text('Watch'));
    await settle(tester);
    expect(find.byKey(const Key('$_maya-screen')), findsOneWidget);

    await tester.tap(find.text('Stop watching'));
    await settle(tester);
    expect(find.byKey(const Key('$_maya-screen')), findsNothing);
    expect(find.text('Watch'), findsOneWidget);

    // A screen that doesn't come: a spinner a while, then a calm note, not an endless spin.
    app.engine.peer.remoteVideos.value = [];
    await tester.tap(find.text('Watch'));
    await settle(tester);
    expect(find.bySemanticsLabel('Loading the screen'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.bySemanticsLabel('Loading the screen'), findsNothing);
    expect(find.text('Waiting for Maya’s screen…'), findsOneWidget);
    await tester.tap(find.text('Stop watching'));
    await settle(tester);
    expect(find.text('Watch'), findsOneWidget);

    // Incoming video off: a quiet note, and a way back.
    await app.voice.setIncomingVideo(false);
    await settle(tester);
    expect(find.text('Video is off'), findsOneWidget);
    await tester.tap(find.text('Turn on video'));
    await settle(tester);
    expect(app.voice.incomingVideo, isTrue);
    expect(find.text('Watch'), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('Watch says so in VOICE_SYNC, a screen\'s eye lists who watches it, and closing stops it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await joinLounge(tester, app);
    app.gateway.push(_state(_leo, 3, screen: true));
    app.gateway.push(_state(_maya, 4, watching: [_leo]));
    app.engine.peer.remoteVideos.value = [_video(_leo, VideoKind.screen)];
    await settle(tester);
    expect(find.bySemanticsLabel('1 watching'), findsOneWidget);

    await tester.tap(find.text('Watch'));
    await settle(tester);
    expect(app.gateway.last('VOICE_SYNC')!['watching'], [_leo]);
    // The user counts at once, before the gateway's echo.
    expect(tester.getSemantics(find.bySemanticsLabel('2 watching')).hint, 'Show who');

    await tester.tap(find.bySemanticsLabel('2 watching'));
    await settle(tester);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.widgetWithText(ListRow, 'Maya'), findsOneWidget);
    expect(find.widgetWithText(ListRow, 'Gaby (you)'), findsOneWidget);
    Navigator.of(tester.element(find.byType(ListRow).first)).pop();
    await settle(tester);

    await tester.tap(find.text('Stop watching'));
    await settle(tester);
    expect(app.gateway.last('VOICE_SYNC')!['watching'], isEmpty);
    expect(find.bySemanticsLabel('1 watching'), findsOneWidget);

    // Still in voice, the room's screen closed: it shows no screen, so none is watched.
    await tester.tap(find.text('Watch'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Back'));
    await settle(tester);
    expect(app.voice.target, isNotNull);
    expect(app.voice.watching, isEmpty);
    expect(app.gateway.last('VOICE_SYNC')!['watching'], isEmpty);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('with Faces in voice, tiles show the animated face', (tester) async {
    final prefs = VoicePrefs();
    final app = await pumpApp(tester, prefs: prefs);
    await joinLounge(tester, app);
    expect(find.byType(VoiceFace), findsNothing);

    await prefs.setFacesInVoice(true);
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is VoiceFace && w.name == 'Gaby'), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('the call screen shows the others\' video too', (tester) async {
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
    expect(find.byKey(const Key('$_maya-camera')), findsOneWidget);
    expect(find.bySemanticsLabel('Maya, camera on'), findsOneWidget);
    expect(find.bySemanticsLabel('Camera'), findsOneWidget);

    // The clock ticks its text only, not the video views.
    var views = 0;
    app.engine.peer.remoteVideos.value = [
      VoiceRemoteVideo(userId: _maya, kind: VideoKind.camera, view: (_) => _Counted(() => views++)),
    ];
    await settle(tester);
    final before = views;
    expect(before, greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(views, before);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a Space\'s voice row and banner say who has a camera on or shares a screen', (tester) async {
    final app = await pumpApp(tester);
    app.gateway.push(_state(_maya, 3, camera: true));
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    expect(find.text('Maya · camera on'), findsOneWidget);
    expect(find.text('Live · Maya · camera on'), findsOneWidget);

    app.gateway.push(_state(_maya, 4, camera: true, screen: true));
    await tester.pumpAndSettle();
    expect(find.text('Maya · sharing screen'), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('Chats\' In voice now says who has a camera on or shares a screen', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.gateway.push(_state(_maya, 3, camera: true));
    app.gateway.push(_state(FakeRepository.leo, 4, screen: true));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^lounge, .*Maya, camera on')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^lounge, .*, sharing screen')), findsOneWidget);
    expect(find.byIcon(FLucideIcons.video), findsOneWidget);
    expect(find.byIcon(FLucideIcons.monitorUp), findsOneWidget);
    semantics.dispose();
    await finish(tester, app);
  });

  IconAction action(WidgetTester tester, String label) =>
      tester.widget(find.byWidgetPredicate((w) => w is IconAction && w.label == label));
  const accepted = duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: _maya));

  testWidgets('Video call calls as Call does, and turns the camera on once someone answers', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    // Just left of Call.
    expect(tester.getTopRight(find.bySemanticsLabel('Video call')), tester.getTopLeft(find.bySemanticsLabel('Call')));

    await tester.tap(find.bySemanticsLabel('Video call'));
    await settle(tester);
    expect(app.gateway.last('CALL_INITIATE'), {
      'conversation_id': 'c-maya',
      'member_ids': [FakeRepository.me.id, _maya],
    });
    expect(find.text('Calling…'), findsWidgets);
    // No camera while it rings: nothing shows it yet.
    expect(app.engine.cameraOpens, 0);

    app.gateway.push(accepted);
    await settle(tester);
    expect(app.voice.cameraOn, isTrue);
    expect(app.engine.cameraOpens, 1);
    expect(app.engine.peer.camera, isNotNull);
    expect(app.gateway.last('VOICE_SYNC')!['camera'], isTrue);
    expect(find.bySemanticsLabel('Camera'), findsOneWidget);

    // Off stays off: only the join turns it on.
    await tester.tap(find.bySemanticsLabel('Camera'));
    await settle(tester);
    app.engine.peer.stateHandler!(PeerState.connected);
    await settle(tester);
    expect(app.voice.cameraOn, isFalse);
    expect(app.engine.cameraOpens, 1);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a video call whose camera is refused goes on without video', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    app.engine.cameraAllowed = false;
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Video call'));
    await settle(tester);
    app.gateway.push(accepted);
    await settle(tester);
    expect(app.engine.cameraOpens, 1);
    expect(app.voice.cameraOn, isFalse);
    expect(app.voice.call?.phase, CallPhase.connected);
    expect(app.voice.target, const CallVoice('c-maya'));
    expect(app.gateway.types, contains('VOICE_JOIN'));
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('Call places a call without the camera; Video call joins a call going on with it', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Call'));
    await settle(tester);
    app.gateway.push(accepted);
    await settle(tester);
    expect(app.voice.target, const CallVoice('c-maya'));
    expect(app.engine.cameraOpens, 0);
    await tester.tap(find.bySemanticsLabel('Hang up the call'));
    await settle(tester);

    // Maya is still there: the call goes on, to join.
    app.gateway.push(_state(_maya, 3, room: 'c-maya'));
    await settle(tester);
    expect(find.text('Join'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Video call'));
    await settle(tester);
    expect(app.gateway.types, contains('CALL_ACCEPT'));
    expect(app.voice.cameraOn, isTrue);
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('Video call shows where Call does, and is out of reach when it is', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = await pumpApp(tester);
    // The user's own call from another device: neither button until someone answers.
    app.gateway.push(const duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: 'c-maya')));
    await settle(tester);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(action(tester, 'Call').onPressed, isNull);
    expect(action(tester, 'Video call').onPressed, isNull);

    // Answered, and joined from here: in a call, one call at a time.
    app.gateway.push(accepted);
    app.gateway.push(_state(FakeRepository.me.id, 1, room: 'c-maya'));
    app.gateway.push(_state(_maya, 2, room: 'c-maya'));
    await settle(tester);
    expect(action(tester, 'Video call').onPressed, isNotNull);
    await tester.tap(find.text('Join'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await settle(tester);
    expect(action(tester, 'Call').onPressed, isNull);
    expect(action(tester, 'Video call').onPressed, isNull);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await settle(tester);

    // A room's chat calls no one.
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('general', findRichText: true).last);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is IconAction && w.label == 'Search'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is IconAction && (w.label == 'Call' || w.label == 'Video call')),
      findsNothing,
    );
    semantics.dispose();
    await finish(tester, app);
  });

  testWidgets('a narrow phone fits the four buttons, and a long name ends before them', (tester) async {
    final app = await pumpApp(tester);
    tester.view.physicalSize = const Size(320 * 3, 568 * 3);
    const long = 'Maximiliana Featherstonehaugh-Cholmondeley';
    app.repository.conversations.value = [
      const ConversationSummary(id: 'c-maya', title: long, isGroup: false, otherUserId: _maya),
      ...app.repository.conversations.value.skip(1),
    ];
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Maximiliana').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final bar = find.byType(GlassTopBar);
    final actions = [
      for (final label in ['Video call', 'Call', 'Search', 'More'])
        tester.getRect(
          find.descendant(of: bar, matching: find.byWidgetPredicate((w) => w is IconAction && w.label == label)),
        ),
    ];
    // Full size, side by side, on screen.
    for (final (i, r) in actions.indexed) {
      expect(r.size, const Size(40, 40));
      if (i > 0) expect(r.left, actions[i - 1].right);
    }
    expect(actions.last.right, 320 - 8);
    final back = tester.getRect(
      find.descendant(of: bar, matching: find.byWidgetPredicate((w) => w is IconAction && w.label == 'Back')),
    );
    final title = tester.getRect(find.descendant(of: bar, matching: find.text(long)));
    expect(title.left, greaterThanOrEqualTo(back.right));
    expect(title.right, lessThanOrEqualTo(actions.first.left));
    expect(title.width, greaterThan(90));
    await finish(tester, app);
  });

  testWidgets('with four buttons a name that fits stays centered on the screen', (tester) async {
    final app = await pumpApp(tester);
    tester.view.physicalSize = const Size(430 * 3, 932 * 3);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.descendant(of: find.byType(GlassTopBar), matching: find.text('Maya')));
    expect(title.center.dx, moreOrLessEquals(215, epsilon: 0.5));
    await finish(tester, app);
  });
}
