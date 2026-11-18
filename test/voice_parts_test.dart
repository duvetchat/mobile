// Voice's small parts: where the sound plays, the call history kept on the
// phone, and a voice's level as a mouth.
import 'dart:async';
import 'dart:convert';

import 'package:duvet/calls.dart' show callClock, CallHistoryList;
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/recent_chats.dart' show SecureRecentChatsStore;
import 'package:duvet/data/voice.dart' show mouthFor, speakingLevel;
import 'package:duvet/data/voice_engine.dart';
import 'package:duvet/data/webrtc_engine.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCRtpCodecCapability;
import 'package:flutter_test/flutter_test.dart';

const _speaker = AudioRoute(id: 'speaker', kind: AudioRouteKind.speaker, label: 'Speakerphone');
const _earpiece = AudioRoute(id: 'earpiece', kind: AudioRouteKind.earpiece, label: 'Earpiece');
const _headset = AudioRoute(id: 'bluetooth', kind: AudioRouteKind.bluetooth, label: 'Pixel Buds');

CallRecord _record(int minute, {CallOutcome outcome = CallOutcome.answered}) => CallRecord(
  conversationId: 'c-$minute',
  title: 'Maya',
  outgoing: minute.isEven,
  outcome: outcome,
  at: DateTime(2026, 10, 23, 10, minute),
  duration: outcome == CallOutcome.answered ? const Duration(seconds: 65) : null,
);

void main() {
  test('outputs by what Android and iOS call them', () {
    expect(routeKind('speaker', 'speaker'), AudioRouteKind.speaker);
    expect(routeKind('earpiece', 'earpiece'), AudioRouteKind.earpiece);
    expect(routeKind('bluetooth', 'bluetooth'), AudioRouteKind.bluetooth);
    expect(routeKind('wired-headset', 'wired-headset'), AudioRouteKind.wired);
    // iOS: a port's UID, and its type as the group.
    expect(routeKind('Speaker', 'Speaker'), AudioRouteKind.speaker);
    expect(routeKind('Built-In Receiver', 'Receiver'), AudioRouteKind.earpiece);
    expect(routeKind('00:11:22:33:44:55-tsco', 'BluetoothHFP'), AudioRouteKind.bluetooth);
    expect(routeKind('Wired Headphones', 'Headphones'), AudioRouteKind.wired);
  });

  test('the route playing: the one chosen, else a headset, else as the session prefers', () {
    expect(currentRoute([_speaker, _earpiece], null, true), _speaker);
    expect(currentRoute([_speaker, _earpiece], null, false), _earpiece);
    expect(currentRoute([_speaker, _earpiece, _headset], null, true), _headset);
    expect(currentRoute([_speaker, _earpiece, _headset], _speaker, false), _speaker);
    // The headset chosen went away.
    expect(currentRoute([_speaker, _earpiece], _headset, false), _earpiece);
    expect(currentRoute(const [], null, true), isNull);
  });

  test('whose video a stream is: <id>.camera a camera, <id> a screen, else no one\'s', () {
    expect(videoOwner('u1.camera'), (userId: 'u1', kind: VideoKind.camera));
    expect(videoOwner('u1'), (userId: 'u1', kind: VideoKind.screen));
    expect(videoOwner('u1.screen'), isNull);
    expect(videoOwner('u1.camera.x'), isNull);
    expect(videoOwner('.camera'), isNull);
    expect(videoOwner(''), isNull);
  });

  test('VP8 first, the other codecs in their order', () {
    RTCRtpCodecCapability codec(String mime) => RTCRtpCodecCapability(mimeType: mime, clockRate: 90000);
    final ordered = vp8First([codec('video/H264'), codec('video/rtx'), codec('video/VP8'), codec('video/AV1')]);
    expect([for (final c in ordered) c.mimeType], ['video/VP8', 'video/H264', 'video/rtx', 'video/AV1']);
    expect(vp8First(const []), isEmpty);
  });

  test('which way a camera faces, from Android\'s and iOS\'s names', () {
    expect(cameraFacing('Camera 1, Facing front, Orientation 270'), CameraFacing.front);
    expect(cameraFacing('Camera 0, Facing back, Orientation 90'), CameraFacing.back);
    expect(cameraFacing('Front Camera'), CameraFacing.front);
    expect(cameraFacing('Back Dual Wide Camera'), CameraFacing.back);
    expect(cameraFacing('USB Webcam'), CameraFacing.external);
  });

  test('the microphone with and without noise suppression, echo cancellation and gain control on', () {
    Object? mandatory(bool on) => (microphoneConstraints(noiseSuppression: on)['audio'] as Map)['mandatory'];
    expect(mandatory(true), {
      'googNoiseSuppression': 'true',
      'googEchoCancellation': 'true',
      'googAutoGainControl': 'true',
    });
    expect(mandatory(false), containsPair('googNoiseSuppression', 'false'));
    expect(mandatory(false), containsPair('googEchoCancellation', 'true'));
    expect(microphoneConstraints(noiseSuppression: true)['video'], false);
  });

  test('the camera at 640x360, 30 fps: the one picked, else the front one', () {
    expect(cameraConstraints(null)['video'], {'facingMode': 'user', 'width': 640, 'height': 360, 'frameRate': 30});
    expect(cameraConstraints('0')['video'], {'deviceId': '0', 'width': 640, 'height': 360, 'frameRate': 30});
    expect(cameraConstraints('0')['audio'], false);
  });

  test('a voice\'s level as a mouth: shut in silence, wide open loud', () {
    expect(mouthFor(0), 0);
    expect(mouthFor(speakingLevel), 0);
    expect(mouthFor(0.12), closeTo(0.5, 1e-9));
    expect(mouthFor(0.9), 1);
  });

  test('a call\'s clock', () {
    expect(callClock(const Duration(seconds: 5)), '0:05');
    expect(callClock(const Duration(minutes: 12, seconds: 30)), '12:30');
    expect(callClock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  test('how a call went, as the Calls tab says it', () {
    expect(CallHistoryList.describe(_record(1)), 'Incoming · 1:05');
    expect(CallHistoryList.describe(_record(2)), 'Outgoing · 1:05');
    expect(CallHistoryList.describe(_record(3, outcome: CallOutcome.missed)), 'Missed call');
    expect(CallHistoryList.describe(_record(4, outcome: CallOutcome.unanswered)), 'No answer');
    expect(CallHistoryList.describe(_record(5, outcome: CallOutcome.failed)), 'Couldn’t connect');
  });

  test('the call history: per account, the newest first, 100 at most, gone at sign-out', () async {
    final store = MemoryCallHistoryStore();
    final history = CallHistory(store);
    await history.load('me');
    for (var i = 0; i < 105; i++) {
      history.add(_record(i % 60, outcome: i == 104 ? CallOutcome.missed : CallOutcome.answered));
    }
    await pumpEventQueue();
    expect(history.calls.value, hasLength(100));
    expect(history.calls.value.first.outcome, CallOutcome.missed);

    // Another launch reads it back.
    final again = CallHistory(store);
    await again.load('me');
    expect(again.calls.value, hasLength(100));
    final first = again.calls.value.first;
    expect((first.title, first.outcome, first.duration), ('Maya', CallOutcome.missed, null));
    expect(again.calls.value[1].duration, const Duration(seconds: 65));
    // Someone else's account has its own.
    await again.load('someone-else');
    expect(again.calls.value, isEmpty);

    await history.close(forget: true);
    expect(store.data, isEmpty);
    expect(history.calls.value, isEmpty);
  });

  test('a call recorded while the history loads is kept, with what was saved', () async {
    final store = _SlowStore()..data['me'] = jsonEncode([_record(1).toJson()]);
    final history = CallHistory(store);
    final loading = history.load('me');
    history.add(_record(2, outcome: CallOutcome.missed));
    store.release.complete();
    await loading;
    expect(history.calls.value.map((c) => c.conversationId), ['c-2', 'c-1']);
    await pumpEventQueue();
    expect(jsonDecode(store.data['me']!), hasLength(2));
  });

  test('a damaged history starts empty', () async {
    final store = MemoryCallHistoryStore()
      ..data['me'] = jsonEncode([
        {'title': 'no id'},
        42,
      ]);
    final history = CallHistory(store);
    await history.load('me');
    expect(history.calls.value, isEmpty);
    store.data['me'] = '{not json';
    await CallHistory(store).load('me');
  });

  group('the WebRTC engine and the keystore, over their plugins\' channels', () {
    final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    const keystore = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    tearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), null);
      messenger.setMockMethodCallHandler(keystore, null);
      messenger.setMockMethodCallHandler(_screenService, null);
    });

    // Every call to flutter_webrtc and the screen service, in order; getDisplayMedia answers [display].
    List<String> mockScreenCapture({bool consent = true, Object? display}) {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_screenService, (call) async {
        calls.add('service ${call.method}');
        return null;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        // flutter_webrtc's own set-up, once per run.
        if (call.method != 'initialize') calls.add(call.method);
        return switch (call.method) {
          'requestCapturePermission' => consent,
          'getDisplayMedia' => display is Exception ? throw display : display,
          _ => null,
        };
      });
      return calls;
    }

    const screenStream = {
      'streamId': 's-1',
      'audioTracks': <Object?>[],
      'videoTracks': [
        {'id': 'v-1', 'kind': 'video', 'label': 'video', 'enabled': true},
      ],
    };

    test('shares the screen under its service: the consent, the service, then the capture', () async {
      final calls = mockScreenCapture(display: screenStream);
      final screen = await WebRtcVoiceEngine(android: true).openScreen();
      expect(screen, isNotNull);
      expect(calls, ['requestCapturePermission', 'service start', 'getDisplayMedia']);

      calls.clear();
      await screen!.stop();
      await screen.stop();
      expect(calls.last, 'service stop');
      expect(calls.where((c) => c == 'service stop'), hasLength(1));
    });

    test('a refused consent starts no service and captures nothing', () async {
      final calls = mockScreenCapture(consent: false);
      expect(await WebRtcVoiceEngine(android: true).openScreen(), isNull);
      expect(calls, ['requestCapturePermission']);
    });

    test('a capture that fails stops the service again', () async {
      final calls = mockScreenCapture(display: PlatformException(code: 'getDisplayMedia'));
      expect(await WebRtcVoiceEngine(android: true).openScreen(), isNull);
      expect(calls, ['requestCapturePermission', 'service start', 'getDisplayMedia', 'service stop']);
    });

    test('a capture without a track is disposed and stops the service', () async {
      final calls = mockScreenCapture(display: {...screenStream, 'videoTracks': <Object?>[]});
      expect(await WebRtcVoiceEngine(android: true).openScreen(), isNull);
      expect(calls, ['requestCapturePermission', 'service start', 'getDisplayMedia', 'streamDispose', 'service stop']);
    });

    group('on iOS, through the broadcast extension (#264)', () {
      final binding = TestWidgetsFlutterBinding.instance;
      late List<String> calls;
      late List<Object?> displayArguments;

      setUp(() {
        WebRtcVoiceEngine.resetBroadcast();
        calls = mockScreenCapture(display: screenStream);
        displayArguments = [];
        final webrtc = const MethodChannel('FlutterWebRTC.Method');
        messenger.setMockMethodCallHandler(webrtc, (call) async {
          if (call.method != 'initialize') calls.add(call.method);
          if (call.method == 'getDisplayMedia') displayArguments.add(call.arguments);
          return call.method == 'getDisplayMedia' ? screenStream : null;
        });
      });
      tearDown(() {
        WebRtcVoiceEngine.resetBroadcast();
        _screenService.setMethodCallHandler(null);
      });

      // The extension, through ios/Runner/ScreenShare.swift.
      Future<void> extensionSays(String method) => messenger.handlePlatformMessage(
        _screenService.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );

      WebRtcVoiceEngine engine() => WebRtcVoiceEngine(
        android: false,
        ios: true,
        pickerGrace: const Duration(milliseconds: 20),
        pickerTimeout: const Duration(milliseconds: 300),
      );

      // Until flutter_webrtc has been asked for the capture, which opens the picker.
      Future<void> pickerOpen() async {
        while (!calls.contains('getDisplayMedia')) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      test('asks for the broadcast, and shares once the extension starts; stopping stops the extension', () async {
        final opening = engine().openScreen();
        await pickerOpen();
        final constraints = (displayArguments.single as Map)['constraints'] as Map;
        expect(((constraints['video'] as Map)['deviceId'], constraints['audio']), ('broadcast', false));
        await extensionSays('started');
        final screen = await opening;
        expect(screen, isNotNull);
        expect(calls, ['getDisplayMedia']);

        await screen!.stop();
        await screen.stop();
        expect(calls.where((c) => c == 'service stop'), hasLength(1));
      });

      test('stopped from the status bar or Control Center, the share ends', () async {
        final opening = engine().openScreen();
        await pickerOpen();
        await extensionSays('started');
        final screen = (await opening)!;
        final ended = expectLater(screen.onEnded, emits(null));
        await extensionSays('stopped');
        await ended;
        // The app stops what's left; the extension has stopped already.
        await screen.stop();
        expect(calls.where((c) => c == 'service stop'), hasLength(1));
      });

      test('back from the picker without starting, nothing is shared and the capture goes', () async {
        final opening = engine().openScreen();
        await pickerOpen();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        expect(await opening, isNull);
        expect(calls, ['getDisplayMedia', 'streamDispose']);
      });

      test('a start within the countdown after the picker still shares', () async {
        final opening = engine().openScreen();
        await pickerOpen();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await extensionSays('started');
        expect(await opening, isNotNull);
      });

      test('a picker that never answers times out', () async {
        expect(await engine().openScreen(), isNull);
        expect(calls, ['getDisplayMedia', 'streamDispose']);
      });

      test('an extension that stops before it starts (nothing listened) shares nothing', () async {
        final opening = engine().openScreen();
        await pickerOpen();
        await extensionSays('stopped');
        expect(await opening, isNull);
      });
    });

    test('a share stopped while it starts is stopped once its sender is added', () async {
      mockScreenCapture(display: screenStream);
      final screen = await WebRtcVoiceEngine(android: true).openScreen();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'createPeerConnection' => {'peerConnectionId': 'pc-1'},
          'addTrack' => {
            'senderId': 's-1',
            'track': {'id': 'v-1', 'kind': 'video', 'label': 'video', 'enabled': true},
            'rtpParameters': {
              'encodings': <Object?>[],
              'headerExtensions': <Object?>[],
              'codecs': <Object?>[],
              'rtcp': {'cname': '', 'reducedSize': false},
            },
            'ownsTrack': false,
          },
          'removeTrack' => {'result': true},
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        const EventChannel('FlutterWebRTC/peerConnectionEventpc-1'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      final peer = await WebRtcVoiceEngine().createPeer(const []);
      final started = peer.setScreen(screen);
      await peer.setScreen(null);
      await started;
      expect(calls.where((c) => c == 'addTrack' || c == 'removeTrack'), ['addTrack', 'removeTrack']);
    });

    test('no screen share on iOS', () async {
      final calls = mockScreenCapture(display: screenStream);
      expect(await WebRtcVoiceEngine(android: false).openScreen(), isNull);
      expect(calls, isEmpty);
    });

    test('the camera faces the way the one that opened does: a back-only phone opens its back one', () async {
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        return switch (call.method) {
          'getUserMedia' => {
            'streamId': 's-1',
            'audioTracks': <Object?>[],
            'videoTracks': [
              {
                'id': 'v-1',
                'kind': 'video',
                'label': 'v-1',
                'enabled': true,
                // flutter_webrtc keeps the facing asked for, and names the camera that opened.
                'settings': {'deviceId': '0', 'facingMode': 'user'},
              },
            ],
          },
          'getSources' => {
            'sources': [
              {'deviceId': '0', 'label': 'Camera 0, Facing back, Orientation 90', 'kind': 'videoinput'},
            ],
          },
          _ => null,
        };
      });
      // Not Android: no permission_handler to mock.
      final camera = await WebRtcVoiceEngine(android: false).openCamera();
      expect(camera?.facing, CameraFacing.back);
    });

    test('forgetting deletes every account\'s call history and recent chats, and nothing else', () async {
      final kept = {
        'duvet_session_token': 'access',
        'duvet_refresh_token': 'refresh',
        'duvet_appearance': 'dark',
        for (final account in ['a', 'b']) ...{'duvet_call_history_$account': '[]', 'duvet_recent_chats_$account': '[]'},
      };
      messenger.setMockMethodCallHandler(keystore, (call) async {
        if (call.method == 'readAll') return {...kept};
        if (call.method == 'delete') kept.remove((call.arguments as Map)['key']);
        return null;
      });
      await const SecureCallHistoryStore().clearAll();
      await const SecureRecentChatsStore().clearAll();
      expect(kept.keys, unorderedEquals(['duvet_session_token', 'duvet_refresh_token', 'duvet_appearance']));
    });

    test('asks for Nearby devices once: a refusal stands at the next launch', () async {
      final asked = <String>[];
      // Denied: as Android says of a permission never asked for, too.
      var rationale = false;
      messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
        asked.add(call.method);
        return switch (call.method) {
          'checkPermissionStatus' => 0,
          'shouldShowRequestPermissionRationale' => rationale,
          'requestPermissions' => {for (final p in call.arguments as List) p: 0},
          _ => null,
        };
      });
      await WebRtcVoiceEngine(android: true).prepare();
      expect(asked, contains('requestPermissions'));

      // Refused once, which Android remembers with the rationale: not again.
      asked.clear();
      rationale = true;
      await WebRtcVoiceEngine(android: true).prepare();
      expect(asked, isNot(contains('requestPermissions')));
    });

    test('offers audio without naming video, in the shape flutter_webrtc reads (it ignores a flat map)', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        calls.add(call);
        return switch (call.method) {
          'createPeerConnection' => {'peerConnectionId': 'pc-1'},
          'createOffer' => {'sdp': 'v=0', 'type': 'offer'},
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        const EventChannel('FlutterWebRTC/peerConnectionEventpc-1'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      final peer = await WebRtcVoiceEngine().createPeer(const []);
      await peer.createOffer();
      final offer = calls.singleWhere((c) => c.method == 'createOffer');
      expect((offer.arguments as Map)['constraints'], {
        // OfferToReceiveVideo false would stop the others' video coming in.
        'mandatory': {'OfferToReceiveAudio': true},
        'optional': <Object?>[],
      });
    });

    test('adds one camera transceiver, VP8 first, and labels it by the mid the local description gave', () async {
      final calls = <MethodCall>[];
      const parameters = {
        'encodings': <Object?>[],
        'headerExtensions': <Object?>[],
        'codecs': <Object?>[],
        'rtcp': {'cname': '', 'reducedSize': false},
      };
      Map<String, Object?> transceiver(String mid) => {
        'transceiverId': 't-1',
        'direction': 'sendrecv',
        'mid': mid,
        'sender': {'senderId': 's-1', 'track': <String, Object?>{}, 'rtpParameters': parameters, 'ownsTrack': false},
        'receiver': {
          'receiverId': 'r-1',
          'track': {'id': 'v-1', 'kind': 'video', 'label': '', 'enabled': true},
          'rtpParameters': parameters,
        },
      };
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
        calls.add(call);
        return switch (call.method) {
          'createPeerConnection' => {'peerConnectionId': 'pc-1'},
          'addTransceiver' => transceiver(''),
          'getRtpReceiverCapabilities' => {
            'codecs': [
              {'mimeType': 'video/H264', 'clockRate': 90000},
              {'mimeType': 'video/VP8', 'clockRate': 90000},
            ],
            'headerExtensions': <Object?>[],
            'fecMechanisms': <Object?>[],
          },
          'getTransceivers' => {
            'transceivers': [transceiver('1')],
          },
          _ => null,
        };
      });
      messenger.setMockStreamHandler(
        const EventChannel('FlutterWebRTC/peerConnectionEventpc-1'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
      final peer = await WebRtcVoiceEngine().createPeer(const []);
      await peer.addVideo();
      await peer.addVideo();
      final added = calls.where((c) => c.method == 'addTransceiver');
      expect(added, hasLength(1));
      final init = (added.single.arguments as Map)['transceiverInit'] as Map;
      expect(init['direction'], 'sendrecv');
      expect(init['sendEncodings'], [containsPair('maxBitrate', 500000)]);
      expect((init['sendEncodings'] as List).single, containsPair('maxFramerate', 30));
      final preferred = calls.singleWhere((c) => c.method == 'setCodecPreferences').arguments as Map;
      expect([for (final c in preferred['codecs'] as List) (c as Map)['mimeType']], ['video/VP8', 'video/H264']);

      expect(peer.trackLabels, isEmpty);
      await peer.setLocalDescription(const duvet.SessionDescription(type: 'offer', sdp: 'v=0'));
      expect(peer.trackLabels, {'1': 'camera'});
    });
  });
}

const _screenService = MethodChannel('chat.duvet/screen');

/// A keystore whose reads answer what was kept when they were asked, once
/// [release] completes.
class _SlowStore extends MemoryCallHistoryStore {
  final release = Completer<void>();

  @override
  Future<String?> read(String userId) async {
    final kept = data[userId];
    await release.future;
    return kept;
  }
}
