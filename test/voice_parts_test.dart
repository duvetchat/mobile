// Voice's small parts: where the sound plays, the call history kept on the
// phone, and a voice's level as a mouth.
import 'dart:async';
import 'dart:convert';

import 'package:duvet/calls.dart' show callClock, CallHistoryList;
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/voice.dart' show mouthFor, speakingLevel;
import 'package:duvet/data/voice_engine.dart';
import 'package:duvet/data/webrtc_engine.dart';
import 'package:flutter/services.dart';
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

  group('the WebRTC engine, over its plugins\' channels', () {
    final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    tearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), null);
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

    test('offers audio alone, in the shape flutter_webrtc reads (it ignores a flat map)', () async {
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
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
        'optional': <Object?>[],
      });
    });
  });
}

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
