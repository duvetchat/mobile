// M12 · Video in voice: the camera button, the More sheet, camera and screen
// tiles, focus, faces, the call screen's video, and who's live on Chats, over
// a fake gateway and a fake WebRTC.
import 'dart:async';

import 'package:duvet/data/admin.dart' show Perm;
import 'package:duvet/data/call_history.dart';
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

duvet.VoiceStateUpdatedEvent _state(
  String user,
  int version, {
  String room = 'r-lounge',
  bool camera = false,
  bool screen = false,
}) => duvet.VoiceStateUpdatedEvent(
  duvet.VoiceStateEvent(
    roomId: room,
    userId: user,
    joined: true,
    camera: camera,
    screenSharing: screen,
    version: version,
  ),
);

VoiceRemoteVideo _video(String user, VideoKind kind) => VoiceRemoteVideo(
  userId: user,
  kind: kind,
  view: (_) => SizedBox.expand(key: Key('$user-${kind.name}')),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<_App> pumpApp(WidgetTester tester, {VoicePrefs? prefs}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
    await tester.tap(find.text('Back Camera'));
    await settle(tester);
    expect(app.engine.openedCameras.last.deviceId, '0');
    expect(app.voice.cameraOn, isTrue);

    await openMore(tester);
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
    semantics.dispose();
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
}
