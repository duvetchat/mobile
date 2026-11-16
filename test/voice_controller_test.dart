// The voice controller against a fake gateway and a fake WebRTC: joining and
// negotiating as desktop's VoiceChat does, the whole state in every
// VOICE_SYNC, a new session (READY) joining again, calls, the camera and the
// screen, and the sounds of others in voice.
import 'dart:async';

import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/data/voice_engine.dart' show PeerState;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, SizedBox, VoidCallback;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

const _lounge = Room(id: 'r-lounge', spaceId: 's-guild', name: 'lounge', kind: RoomKind.voice, position: 1);
const _studio = Room(id: 'r-studio', spaceId: 's-guild', name: 'studio', kind: RoomKind.voice, position: 2);
const _attic = Room(id: 'r-attic', spaceId: 's-guild', name: 'attic', kind: RoomKind.voice, position: 3);

/// The whole voice state the phone always sends.
Map<String, Object?> _sync({
  bool muted = false,
  bool deafened = false,
  bool screen = false,
  bool camera = false,
  bool videoOff = false,
  List<String> watching = const [],
  String room = 'r-lounge',
}) => {
  'room_id': room,
  'muted': muted,
  'deafened': deafened,
  'screen_sharing': screen,
  'camera': camera,
  'video_off': videoOff,
  'watching': watching,
};

duvet.VoiceJoinedPayloadEvent _joined(String room, String sdp) => duvet.VoiceJoinedPayloadEvent(
  duvet.VoiceJoinedEvent(
    roomId: room,
    answer: duvet.SessionDescription(type: 'answer', sdp: sdp),
  ),
);

duvet.WebRTCIceCandidateEvent _candidate(String room, String line) => duvet.WebRTCIceCandidateEvent(
  duvet.IceCandidateEvent(
    roomId: room,
    candidate: duvet.IceCandidateInit(candidate: line, sdpMid: '0'),
  ),
);

duvet.WebRTCRenegotiateEvent _offer(String room, String sdp) => duvet.WebRTCRenegotiateEvent(
  duvet.RenegotiateOfferEvent(
    roomId: room,
    offer: duvet.SessionDescription(type: 'offer', sdp: sdp),
  ),
);

duvet.VoiceStateUpdatedEvent _state(
  String room,
  String user,
  int version, {
  bool joined = true,
  bool muted = false,
  bool screen = false,
}) => duvet.VoiceStateUpdatedEvent(
  duvet.VoiceStateEvent(
    roomId: room,
    userId: user,
    joined: joined,
    muted: muted,
    screenSharing: screen,
    version: version,
  ),
);

duvet.WebRTCRenegotiateAnswerEvent _answer(String room, String sdp) => duvet.WebRTCRenegotiateAnswerEvent(
  duvet.RenegotiateAnswerEvent(
    roomId: room,
    answer: duvet.SessionDescription(type: 'answer', sdp: sdp),
  ),
);

duvet.VoiceVideoRefusedPayloadEvent _refused(String kind, String reason, {int? limit, String room = 'r-lounge'}) =>
    duvet.VoiceVideoRefusedPayloadEvent(
      duvet.VoiceVideoRefusedEvent(roomId: room, kind: kind, reason: reason, limit: limit),
    );

class _Player implements SoundPlayer {
  final played = <(Sound, bool)>[];
  final stopped = <Sound>[];

  @override
  Future<void> play(Sound sound, double gain, {bool loop = false, bool aloud = false, VoidCallback? onDone}) async =>
      played.add((sound, loop));

  @override
  Future<void> stop(Sound sound) async => stopped.add(sound);

  @override
  Future<void> dispose() async {}
}

class _Ringer implements RingerMode {
  @override
  Future<bool> quiet() async => false;
}

class _Harness {
  final repository = FakeRepository();
  final engine = FakeVoiceEngine();
  final history = MemoryCallHistoryStore();
  late final VoiceController voice;
  final notices = <String>[];
  DateTime now = DateTime(2026, 10, 23, 10);

  /// Duvet on screen, not behind another app or a locked screen.
  bool inFront = true;

  final lifecycle = StreamController<AppLifecycleState>.broadcast(sync: true);
  final player = _Player();
  late final sounds = Sounds(player: player, ringer: _Ringer());

  /// The calls whose notification the app put up itself, off screen, and those whose notification it took away.
  final shownAway = <String>[];
  final hidden = <String>[];

  /// Whether the phone shows Duvet's notifications.
  bool notificationsOn = true;

  FakeVoiceSignaling get gateway => repository.voiceSignaling;

  _Harness(FakeAsync async) {
    repository.restore();
    voice = VoiceController(
      repository: repository,
      engine: engine,
      historyStore: history,
      clock: () => now,
      inFront: () => inFront,
      lifecycle: lifecycle.stream,
      cameraRefused: () async => !engine.cameraAllowed,
      sounds: sounds,
      callNotices: (
        show: (call) async {
          shownAway.add(call.conversationId);
          return notificationsOn;
        },
        hide: hidden.add,
      ),
    );
    voice.notices.listen(notices.add);
    async.flushMicrotasks();
  }

  void dispose() {
    voice.dispose();
    repository.dispose();
    lifecycle.close();
  }
}

/// Runs [body] on a fake clock with a fresh harness.
void _voice(String description, void Function(FakeAsync async, _Harness h) body) => test(description, () {
  fakeAsync((async) {
    final h = _Harness(async);
    body(async, h);
    h.dispose();
    async.flushMicrotasks();
  });
});

void main() {
  _voice('joining a room: microphone, foreground service, then VOICE_JOIN and the whole state', (async, h) {
    h.gateway.ready(
      number: 1,
      iceServers: const [
        duvet.IceServer(urls: ['stun:stun.l.google.com:19302']),
        duvet.IceServer(urls: ['turn:turn.duvet.chat:3478'], username: '1:me', credential: 'secret'),
      ],
    );
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();

    expect(h.engine.prepared, 1);
    expect(h.engine.mics, hasLength(1));
    expect(h.engine.keptAlive, ['In a voice room']);
    // A room plays on the loudspeaker (or a headset).
    expect(h.engine.defaults, [true]);
    // READY's TURN relay, with the user's credentials.
    expect(h.engine.iceServers.single.map((s) => s.urls.first), [
      'stun:stun.l.google.com:19302',
      'turn:turn.duvet.chat:3478',
    ]);
    // The camera's transceiver is in the first offer, with no track, tagged.
    expect(h.engine.peer.log, ['audio mic', 'video', 'sending true', 'local offer offer-1']);
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.gateway.last('VOICE_JOIN'), {
      'room_id': 'r-lounge',
      'offer': 'offer-1',
      'tracks': {'1': 'camera'},
      'video_off': false,
    });
    expect(h.gateway.last('VOICE_SYNC'), _sync());
    expect(h.voice.target, const RoomVoice(spaceId: 's-guild', roomId: 'r-lounge'));
    expect(h.voice.link, VoiceLink.connecting);

    // The peer's candidates go to the gateway, for this room.
    h.engine.peer.candidateHandler!(const duvet.IceCandidateInit(candidate: 'candidate:mine'));
    expect(h.gateway.last('WEBRTC_ICE_CANDIDATE'), {'room_id': 'r-lounge', 'candidate': 'candidate:mine'});

    h.engine.peer.stateHandler!(PeerState.connected);
    expect(h.voice.link, VoiceLink.connected);
  });

  _voice('the answer first, then the candidates and the gateway\'s offers, in order', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final peer = h.engine.peer;

    // Before the answer: the candidate waits, and so does the offer.
    h.gateway.push(_candidate('r-lounge', 'candidate:early'));
    h.gateway.push(_offer('r-lounge', 'o2'));
    // Another room's are none of this connection's.
    h.gateway.push(_candidate('r-other', 'candidate:other'));
    async.flushMicrotasks();
    expect(peer.candidates, isEmpty);
    expect(h.gateway.types, isNot(contains('WEBRTC_ANSWER')));

    h.gateway.push(_joined('r-lounge', 'a1'));
    h.gateway.push(_offer('r-lounge', 'o3'));
    async.flushMicrotasks();
    expect(peer.candidates, ['candidate:early']);
    expect(peer.log.where((l) => l.startsWith('remote')), ['remote answer a1', 'remote offer o2', 'remote offer o3']);
    expect(h.gateway.sent.where((s) => s.$1 == 'WEBRTC_ANSWER').map((s) => s.$2['room_id']), ['r-lounge', 'r-lounge']);

    h.gateway.push(_candidate('r-lounge', 'candidate:late'));
    async.flushMicrotasks();
    expect(peer.candidates, ['candidate:early', 'candidate:late']);
  });

  _voice('answers carry no tag: a second one for a join means the first was an older join\'s', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    // Left and joined again before the gateway answered the first join.
    h.voice.leave();
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final second = h.engine.peer;
    h.gateway.push(_joined('r-lounge', 'a1'));
    h.gateway.push(_joined('r-lounge', 'a2'));
    async.flushMicrotasks();
    // The connection that took the older join's answer starts over.
    expect(h.engine.peers, hasLength(3));
    expect(second.closed, isTrue);
    expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(3));

    h.gateway.push(_joined('r-lounge', 'a3'));
    async.flushMicrotasks();
    expect(h.engine.peer.log.where((l) => l.startsWith('remote')), ['remote answer a3']);
  });

  _voice('an offer the phone can\'t answer starts the connection over, twice in a row at most', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    for (var i = 1; i <= 3; i++) {
      final peer = h.engine.peer..failOffers = true;
      h.gateway.push(_joined('r-lounge', 'a$i'));
      h.gateway.push(_offer('r-lounge', 'o$i'));
      async.flushMicrotasks();
      if (i < 3) {
        // Unanswered, the gateway's side would wait for the answer forever: a
        // new connection, with a new join.
        expect(h.engine.peers, hasLength(i + 1));
        expect(peer.closed, isTrue);
        expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(i + 1));
        expect(h.voice.target, isNotNull);
      }
    }
    expect(h.voice.target, isNull);
    expect(h.notices, ['Lost the connection to voice']);
    expect(h.gateway.types, isNot(contains('WEBRTC_ANSWER')));
  });

  _voice('every VOICE_SYNC carries the whole state: mute, deafen, unmute', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final peer = h.engine.peer;

    h.voice.toggleMute();
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true));
    expect(peer.sending, isFalse);

    h.voice.toggleMute();
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_SYNC'), _sync());
    expect(peer.sending, isTrue);

    // Deafened: muted too, and nothing plays.
    h.voice.toggleDeafen();
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true, deafened: true));
    expect((peer.sending, peer.receiving), (false, false));

    // Hearing again keeps the mute, as the desktop does.
    h.voice.toggleDeafen();
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true));
    expect((peer.sending, peer.receiving), (false, true));

    // Unmuting while deafened hears again too.
    h.voice.toggleDeafen();
    h.voice.toggleMute();
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_SYNC'), _sync());
    expect((peer.sending, peer.receiving), (true, true));
  });

  _voice('a join made with the gateway out of reach waits for its next session', (async, h) {
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.voice.link, VoiceLink.waiting);
    expect(h.engine.peers, isEmpty);
    expect(h.gateway.sent, isEmpty);

    // No timeout in the meantime: it waits.
    async.elapse(const Duration(seconds: 30));
    expect(h.voice.target, isNotNull);

    h.gateway.ready(number: 3);
    async.flushMicrotasks();
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.voice.link, VoiceLink.connecting);
  });

  _voice('a join that waits for the gateway asks for a new session, whose READY joins', (async, h) {
    // Out of reach as it joins.
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.gateway.freshSessionsWanted, 1);

    // Gone while the connection was made.
    h.engine.holdPeer = Completer<void>();
    h.gateway.ready(number: 2);
    async.flushMicrotasks();
    h.gateway.socket = null;
    h.engine.holdPeer!.complete();
    h.engine.holdPeer = null;
    async.flushMicrotasks();
    expect(h.gateway.freshSessionsWanted, 2);
    expect(h.voice.link, VoiceLink.waiting);

    // Gone when the join's answer was due.
    h.gateway.ready(number: 3);
    async.flushMicrotasks();
    h.gateway.socket = null;
    async.elapse(const Duration(seconds: 15));
    expect(h.gateway.freshSessionsWanted, 3);

    // Gone as the connection failed.
    h.gateway.ready(number: 4);
    async.flushMicrotasks();
    h.gateway.socket = null;
    h.engine.peer.stateHandler!(PeerState.failed);
    expect(h.gateway.freshSessionsWanted, 4);
    expect(h.voice.link, VoiceLink.waiting);

    h.gateway.ready(number: 5);
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_JOIN')!['offer'], 'offer-4');
    expect(h.voice.link, VoiceLink.connecting);
  });

  _voice('a session the gateway resumes on a new socket keeps its voice: nothing joins again', (async, h) {
    h.gateway.ready(number: 1);
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(_joined('r-lounge', 'a1'));
    async.flushMicrotasks();
    h.engine.peer.stateHandler!(PeerState.connected);

    h.gateway.socket = null;
    h.gateway.resumed(number: 2);
    async.elapse(const Duration(minutes: 1));
    expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(1));
    expect(h.engine.peers, hasLength(1));
    expect(h.voice.link, VoiceLink.connected);
    expect(h.gateway.freshSessionsWanted, 0);
  });

  _voice('a join the gateway hadn\'t answered when its socket dropped goes again on the session it resumes', (
    async,
    h,
  ) {
    h.gateway.ready(number: 1);
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.socket = null;
    async.elapse(const Duration(seconds: 10));
    h.gateway.resumed(number: 2);
    async.flushMicrotasks();
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC', 'VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.gateway.last('VOICE_JOIN')!['offer'], 'offer-2');
    // Its wait for an answer starts over.
    async.elapse(const Duration(seconds: 14));
    expect(h.voice.target, isNotNull);

    // Answered: the next resume sends nothing again, nor does it time out.
    h.gateway.push(_joined('r-lounge', 'a2'));
    async.flushMicrotasks();
    h.gateway.resumed(number: 3);
    async.flushMicrotasks();
    expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(2));
    async.elapse(const Duration(seconds: 20));
    expect(h.voice.target, isNotNull);
    expect(h.notices, isEmpty);
  });

  _voice('an offline join waits 3 minutes at most, then leaves with the microphone and the service', (async, h) {
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    async.elapse(const Duration(minutes: 2, seconds: 59));
    expect(h.voice.target, isNotNull);

    async.elapse(const Duration(seconds: 1));
    expect(h.voice.target, isNull);
    expect(h.notices, ['You left voice: the connection was lost for a while']);
    expect(h.engine.mics.single.stopped, isTrue);
    expect(h.engine.sleeps, 1);
    expect(h.gateway.sent, isEmpty);
  });

  _voice('a join made offline long ago leaves on READY instead of opening the microphone to the room', (async, h) {
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    // The phone slept: no timer ran meanwhile.
    h.now = h.now.add(const Duration(minutes: 10));
    h.gateway.ready(number: 2, silence: const Duration(minutes: 10));
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    expect(h.engine.peers, isEmpty);
    expect(h.notices, ['You left voice: the connection was lost for a while']);
  });

  _voice('a join made offline long ago leaves on a new gateway client\'s first READY, which reports no silence', (
    async,
    h,
  ) {
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    // Suspended or in Doze: the 3 minutes' timer hadn't run yet.
    h.now = h.now.add(const Duration(minutes: 10));
    h.gateway.ready(number: 1);
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    expect(h.engine.peers, isEmpty);
    expect(h.notices, ['You left voice: the connection was lost for a while']);
  });

  _voice('a join made offline just now joins, however long the gateway had been silent before', (async, h) {
    h.gateway.socket = null;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.now = h.now.add(const Duration(seconds: 2));
    h.gateway.ready(number: 2, silence: const Duration(minutes: 5));
    async.flushMicrotasks();
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.notices, isEmpty);
  });

  _voice('a join the gateway doesn\'t answer in 15 s leaves, with a notice', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    async.elapse(const Duration(seconds: 14));
    expect(h.voice.target, isNotNull);

    async.elapse(const Duration(seconds: 1));
    expect(h.voice.target, isNull);
    expect(h.notices, ['Couldn’t connect to voice']);
    expect(h.gateway.types.last, 'VOICE_LEAVE');
    expect(h.engine.peer.closed, isTrue);
    expect(h.engine.mics.single.stopped, isTrue);
    expect(h.engine.sleeps, 1);
  });

  _voice('an answered join doesn\'t time out', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(_joined('r-lounge', 'a1'));
    async.elapse(const Duration(seconds: 20));
    expect(h.voice.target, isNotNull);
    expect(h.notices, isEmpty);
  });

  _voice('the timeout with the gateway down waits for its next session instead', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.socket = null;
    async.elapse(const Duration(seconds: 15));
    expect(h.voice.target, isNotNull);
    expect(h.voice.link, VoiceLink.waiting);
    expect(h.notices, isEmpty);
  });

  _voice('READY joins again on the new session, the old connection closed after the new one opens', (async, h) {
    h.gateway.ready(number: 1);
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(_joined('r-lounge', 'a1'));
    async.flushMicrotasks();
    final first = h.engine.peer;

    // The gateway restarted for a deploy: a new socket, a new session.
    h.gateway.ready(number: 2, silence: const Duration(seconds: 20));
    async.flushMicrotasks();
    expect(h.engine.peers, hasLength(2));
    expect(first.closed, isTrue);
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC', 'VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.gateway.last('VOICE_JOIN')!['offer'], 'offer-2');
    // The same microphone: it was never closed.
    expect(h.engine.mics.single.stopped, isFalse);
    expect(h.engine.keptAlive, hasLength(1));
  });

  _voice('a join sent on READY\'s own socket isn\'t sent again', (async, h) {
    // Joined while the new socket was open but before its READY came.
    h.gateway.socket = 5;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.ready(number: 5);
    async.flushMicrotasks();
    expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(1));
  });

  _voice('two new sessions at once: the old connections close only once the newest exists', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final first = h.engine.peer;
    h.engine.holdPeer = Completer<void>();
    h.gateway.ready(number: 2);
    async.flushMicrotasks();
    h.gateway.ready(number: 3);
    async.flushMicrotasks();
    // On Android a moment without any connection would end the audio session.
    expect(first.closed, isFalse);

    h.engine.holdPeer!.complete();
    h.engine.holdPeer = null;
    async.flushMicrotasks();
    expect(h.engine.peers.map((p) => (p.number, p.closed)), [(1, true), (2, true), (3, false)]);
    expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(2));
    expect(h.gateway.last('VOICE_JOIN')!['offer'], 'offer-3');
  });

  _voice('switching rooms closes the old connection only once the new one exists', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final first = h.engine.peer;
    h.engine.holdPeer = Completer<void>();
    h.voice.joinRoom(_studio);
    async.flushMicrotasks();
    expect(h.gateway.last('VOICE_LEAVE'), {'room_id': 'r-lounge'});
    // On Android the audio session ends with the last connection, and a new
    // one doesn't start it again.
    expect(first.closed, isFalse);

    h.engine.holdPeer!.complete();
    h.engine.holdPeer = null;
    async.flushMicrotasks();
    expect(first.closed, isTrue);
    expect(h.engine.peer.closed, isFalse);
    expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'r-studio');
  });

  _voice('switching twice before the next connection exists keeps the first until the last one exists', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final first = h.engine.peer;
    h.engine.holdPeer = Completer<void>();
    h.voice.joinRoom(_studio);
    async.flushMicrotasks();
    h.voice.joinRoom(_attic);
    async.flushMicrotasks();
    expect(first.closed, isFalse);

    h.engine.holdPeer!.complete();
    h.engine.holdPeer = null;
    async.flushMicrotasks();
    expect(h.engine.peers.map((p) => p.closed), [true, true, false]);
    expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'r-attic');
  });

  _voice('unmuting while the microphone opens opens no second one', (async, h) {
    h.engine.holdMic = Completer<void>();
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.voice.toggleMute();
    h.voice.toggleMute();
    async.flushMicrotasks();
    h.engine.holdMic!.complete();
    async.flushMicrotasks();
    expect(h.engine.mics, hasLength(1));
    expect(h.voice.muted, isFalse);
    expect(h.gateway.last('VOICE_SYNC'), _sync());
  });

  _voice('READY after more than 3 minutes of silence leaves voice rather than join again', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(_joined('r-lounge', 'a1'));
    async.flushMicrotasks();

    h.now = h.now.add(const Duration(minutes: 3, seconds: 1));
    h.gateway.ready(number: 2, silence: const Duration(minutes: 3, seconds: 1));
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    expect(h.engine.peers, hasLength(1));
    expect(h.notices, ['You left voice: the connection was lost for a while']);
  });

  _voice('a failed connection leaves with the gateway up, and waits with it down', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.socket = null;
    h.engine.peer.stateHandler!(PeerState.failed);
    expect(h.voice.link, VoiceLink.waiting);
    expect(h.voice.target, isNotNull);

    h.gateway.ready(number: 2);
    async.flushMicrotasks();
    expect(h.engine.peers, hasLength(2));
    h.engine.peer.stateHandler!(PeerState.failed);
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    expect(h.notices, ['Lost the connection to voice']);
  });

  _voice('voice moved to another device, or the room\'s access lost', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(const duvet.VoiceSessionReplacedPayloadEvent(duvet.VoiceSessionReplacedEvent(roomId: 'r-lounge')));
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    // The gateway already took the voice: nothing to leave.
    expect(h.gateway.types, isNot(contains('VOICE_LEAVE')));
    expect(h.notices, ['Your voice moved to another device']);

    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.gateway.push(
      const duvet.VoiceSessionReplacedPayloadEvent(
        duvet.VoiceSessionReplacedEvent(roomId: 'r-lounge', reason: 'permissions'),
      ),
    );
    async.flushMicrotasks();
    expect(h.notices.last, 'You can’t be in this voice room anymore');
  });

  _voice('who\'s in voice: SPACE_CREATE, then updates in version order', (async, h) {
    h.gateway.push(_state('r-lounge', FakeRepository.maya, 5));
    h.gateway.push(_state('r-lounge', FakeRepository.leo, 6, muted: true));
    // Late: before Maya joined.
    h.gateway.push(_state('r-lounge', FakeRepository.maya, 4, joined: false));
    expect(h.voice.participants('r-lounge').map((p) => (p.userId, p.muted)), [
      (FakeRepository.maya, false),
      (FakeRepository.leo, true),
    ]);
    h.gateway.push(_state('r-lounge', FakeRepository.maya, 7, joined: false));
    expect(h.voice.participants('r-lounge').map((p) => p.userId), [FakeRepository.leo]);

    // A new session starts over.
    h.gateway.ready();
    expect(h.voice.participants('r-lounge'), isEmpty);
  });

  _voice('without SpeakInVoice: joined muted, the microphone left shut', (async, h) {
    h.repository.noSpeak.add('r-lounge');
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.engine.mics, isEmpty);
    // Android starts a microphone service only with the microphone: listening
    // goes on only while Duvet is open, and the user is told.
    expect(h.engine.keptAlive, isEmpty);
    expect(h.notices, ['Listening only: keep Duvet open to stay in voice']);
    expect(h.engine.peer.log.first, 'audio none');
    expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true));

    h.voice.toggleMute();
    async.flushMicrotasks();
    expect(h.voice.muted, isTrue);
    expect(h.notices.last, 'You can’t speak in this room');
  });

  _voice('losing SpeakInVoice in the room mutes the user', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.voice.muted, isFalse);
    h.repository.noSpeak.add('r-lounge');
    h.repository.spaces.value = [...h.repository.spaces.value];
    async.flushMicrotasks();
    expect(h.voice.muted, isTrue);
    expect(h.notices.last, 'You can’t speak in this room now');
  });

  _voice('a room that goes while the user is in its voice leaves their microphone as it was', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    // Its ROOM_DELETE comes before the gateway ends its voice: the room is
    // gone, and so are its overwrites, with the SpeakInVoice they gave.
    h.repository.noSpeak.add('r-lounge');
    unawaited(h.repository.deleteRoom('s-guild', 'r-lounge'));
    async.flushMicrotasks();
    expect(h.voice.muted, isFalse);
    expect(h.notices, isNot(contains('You can’t speak in this room now')));
  });

  _voice('without JoinVoice nothing is joined', (async, h) {
    h.repository.noJoin.add('r-lounge');
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.voice.target, isNull);
    expect(h.gateway.sent, isEmpty);
    expect(h.notices, ['You can’t join this voice room']);
  });

  _voice('a microphone refused listens only, and unmuting asks again', (async, h) {
    h.engine.micAllowed = false;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.voice.muted, isTrue);
    expect(h.engine.keptAlive, isEmpty);
    expect(h.notices, ['Duvet can’t use the microphone. Listening only: keep Duvet open to stay in voice']);
    expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true));

    h.engine.micAllowed = true;
    h.voice.toggleMute();
    async.flushMicrotasks();
    expect(h.voice.muted, isFalse);
    expect(h.engine.peer.log, containsAllInOrder(['audio none', 'mic', 'sending true']));
    expect(h.engine.keptAlive, ['In a voice room']);
    expect(h.gateway.last('VOICE_SYNC'), _sync());
  });

  _voice('two quick taps on Unmute open one microphone', (async, h) {
    h.engine.micAllowed = false;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.engine.micAllowed = true;
    h.engine.holdMic = Completer<void>();
    h.voice.toggleMute();
    h.voice.toggleMute();
    async.flushMicrotasks();
    h.engine.holdMic!.complete();
    h.engine.holdMic = null;
    async.flushMicrotasks();
    expect(h.engine.mics, hasLength(2));
    expect(h.engine.mics.where((m) => !m.stopped), hasLength(1));
    expect(h.voice.muted, isFalse);
    expect(h.engine.keptAlive, hasLength(1));
  });

  _voice('leaving while the microphone is asked for joins nothing', (async, h) {
    h.engine.holdMic = Completer<void>();
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.voice.leave();
    h.engine.holdMic!.complete();
    async.flushMicrotasks();
    expect(h.engine.peers, isEmpty);
    expect(h.engine.mics.single.stopped, isTrue);
    expect(h.gateway.types, isNot(contains('VOICE_JOIN')));
  });

  _voice('the levels are read only while a screen shows them, with Duvet in front', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final peer = h.engine.peer..stateHandler!(PeerState.connected);
    async.elapse(const Duration(seconds: 1));
    expect(peer.reads, 0);

    void shown() {}
    h.voice.levels.addListener(shown);
    async.elapse(const Duration(seconds: 1));
    expect(peer.reads, 5);

    // The screen locked, or Duvet behind another app.
    h.inFront = false;
    async.elapse(const Duration(seconds: 1));
    expect(peer.reads, 5);

    h.inFront = true;
    h.voice.levels.removeListener(shown);
    async.elapse(const Duration(seconds: 1));
    expect(peer.reads, 5);
  });

  _voice('the ping is measured every 3 s while in voice, and stops after leave', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    final peer = h.engine.peer..rtt = const Duration(milliseconds: 42);
    async.elapse(const Duration(seconds: 6));
    // Not before the connection is up.
    expect(peer.pings, 0);
    expect(h.voice.ping.value, isNull);

    peer.stateHandler!(PeerState.connected);
    async.flushMicrotasks();
    expect(h.voice.ping.value, 42);

    peer.rtt = const Duration(milliseconds: 310);
    async.elapse(const Duration(seconds: 3));
    expect(h.voice.ping.value, 310);
    expect(peer.pings, 2);

    h.voice.leave();
    async.flushMicrotasks();
    expect(h.voice.ping.value, isNull);
    async.elapse(const Duration(seconds: 9));
    expect(peer.pings, 2);
  });

  _voice('the faces\' mouths follow the voices\' levels', (async, h) {
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    // The voice room's screen shows them.
    h.voice.levels.addListener(() {});
    final peer = h.engine.peer;
    peer.stateHandler!(PeerState.connected);
    peer.levels = (local: 0.12, remote: {FakeRepository.maya: 0.3, FakeRepository.leo: 0.001});
    async.elapse(const Duration(milliseconds: 200));
    expect(h.voice.levels.value, {FakeRepository.maya: 1.0, FakeRepository.me.id: closeTo(0.5, 0.001)});

    // Muted, the user's own mouth stays shut.
    h.voice.toggleMute();
    async.elapse(const Duration(milliseconds: 200));
    expect(h.voice.levels.value.keys, [FakeRepository.maya]);
    expect(mouthFor(0.01), 0);
  });

  group('calls', () {
    duvet.CallIncomingPayloadEvent incoming() => const duvet.CallIncomingPayloadEvent(
      duvet.CallIncomingEvent(conversationId: 'c-maya', initiatorId: FakeRepository.maya, initiatorName: 'Maya'),
    );

    int answers(FakeVoiceSignaling gateway) => gateway.types.where((t) => t == 'CALL_ACCEPT').length;
    int placed(FakeVoiceSignaling gateway) => gateway.types.where((t) => t == 'CALL_INITIATE').length;

    _voice(
      'a call placed on a socket that dropped before the gateway had it is placed again on the session it resumes',
      (async, h) {
        h.gateway.ready(number: 1);
        h.voice.startCall('c-maya');
        async.flushMicrotasks();
        final first = h.gateway.last('CALL_INITIATE');
        h.gateway.socket = null;
        h.gateway.resumed(number: 2);
        async.flushMicrotasks();
        expect(placed(h.gateway), 2);
        expect(h.gateway.last('CALL_INITIATE'), first);
        expect(h.voice.call?.phase, CallPhase.calling);

        // The gateway\'s word that it has the call: not again.
        h.gateway.push(const duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: 'c-maya')));
        h.gateway.resumed(number: 3);
        async.flushMicrotasks();
        expect(placed(h.gateway), 2);
      },
    );

    _voice('a placed call the gateway has isn\'t placed again: someone declined, or READY lists it', (async, h) {
      h.gateway.ready(number: 1);
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(
        const duvet.CallDeclinedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
      );
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(placed(h.gateway), 1);
      h.voice.hangUp();

      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.ready(
        number: 3,
        calls: [
          duvet.GatewayReadyActiveCall.fromJson({'conversation_id': 'c-maya', 'initiator_id': FakeRepository.me.id}),
        ],
      );
      async.flushMicrotasks();
      h.gateway.resumed(number: 4);
      async.flushMicrotasks();
      expect(placed(h.gateway), 2);
      expect(h.voice.call?.phase, CallPhase.calling);
    });

    _voice('a call cancelled, or answered, isn\'t placed again', (async, h) {
      h.gateway.ready(number: 1);
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(placed(h.gateway), 1);

      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(
        const duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
      );
      async.flushMicrotasks();
      h.gateway.resumed(number: 3);
      async.flushMicrotasks();
      expect(placed(h.gateway), 2);
    });

    _voice('an answer the gateway hadn\'t heard when its socket dropped goes again on the session it resumes', (
      async,
      h,
    ) {
      h.gateway.ready(number: 1);
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.socket = null;
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(answers(h.gateway), 2);
      expect(h.voice.call?.phase, CallPhase.connected);

      // Heard now: no more.
      h.gateway.push(
        duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.me.id)),
      );
      h.gateway.resumed(number: 3);
      async.flushMicrotasks();
      expect(answers(h.gateway), 2);
    });

    _voice('an answer the gateway heard isn\'t sent again, on a resumed session or a new one', (async, h) {
      h.gateway.ready(number: 1);
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.push(
        duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.me.id)),
      );
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);

      h.gateway.ready(
        number: 3,
        calls: [
          duvet.GatewayReadyActiveCall.fromJson({'conversation_id': 'c-maya', 'initiator_id': FakeRepository.maya}),
        ],
      );
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
      expect(h.voice.call?.phase, CallPhase.connected);
    });

    _voice('nor past the 30 s a call rings, after which the gateway would have ended it unanswered', (async, h) {
      h.gateway.ready(number: 1);
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.socket = null;
      h.now = h.now.add(const Duration(seconds: 31));
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
    });

    _voice('an incoming call answered: CALL_ACCEPT, then the call\'s voice on the earpiece', (async, h) {
      h.gateway.push(incoming());
      expect(h.voice.call?.phase, CallPhase.ringing);
      expect(h.voice.callsInProgress, {'c-maya'});

      h.voice.acceptCall();
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.gateway.types, ['CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'c-maya');
      expect(h.gateway.last('VOICE_SYNC'), _sync(room: 'c-maya'));
      expect(h.engine.defaults, [false]);
      expect(h.engine.keptAlive, ['In a call']);

      // The talk counts from when its voice connects.
      h.now = h.now.add(const Duration(seconds: 3));
      h.engine.peer.stateHandler!(PeerState.connected);
      h.now = h.now.add(const Duration(minutes: 2, seconds: 5));
      h.voice.hangUp();
      async.flushMicrotasks();
      expect(h.gateway.types.last, 'CALL_LEAVE');
      expect(h.voice.call, isNull);
      expect(h.voice.target, isNull);
      final record = h.voice.history.calls.value.single;
      expect(
        (record.title, record.outgoing, record.outcome, record.duration),
        ('Maya', false, CallOutcome.answered, const Duration(minutes: 2, seconds: 5)),
      );
    });

    _voice('a call answered whose voice never connected is kept as such, without a length', (async, h) {
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.now = h.now.add(const Duration(seconds: 15));
      async.elapse(const Duration(seconds: 15));
      expect(h.notices, ['Couldn’t connect to voice']);
      expect(h.voice.call, isNull);
      final record = h.voice.history.calls.value.single;
      expect((record.outcome, record.duration), (CallOutcome.failed, null));
    });

    _voice('a call that comes during another one is missed, and the user told', (async, h) {
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.push(
        const duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
        ),
      );
      async.flushMicrotasks();
      expect(h.voice.call?.conversationId, 'c-maya');
      expect(h.voice.callsInProgress, {'c-maya', 'c-leo'});
      expect(h.notices, ['Missed a call from Leo']);
      final missed = h.voice.history.calls.value.single;
      expect((missed.conversationId, missed.outcome, missed.outgoing), ('c-leo', CallOutcome.missed, false));
    });

    _voice('declined, or missed', (async, h) {
      h.gateway.push(incoming());
      h.voice.declineCall();
      expect(h.gateway.last('CALL_DECLINE'), {'conversation_id': 'c-maya'});
      expect(h.voice.call, isNull);

      h.gateway.push(incoming());
      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, isEmpty);
      expect(h.voice.history.calls.value.map((c) => c.outcome), [CallOutcome.missed, CallOutcome.declined]);
    });

    _voice('a call placed: the members, then voice once someone answers', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.calling);
      // The caller is one of the call's members, or the gateway doesn't tell them how it goes.
      expect(h.gateway.last('CALL_INITIATE'), {
        'conversation_id': 'c-maya',
        'member_ids': [FakeRepository.me.id, FakeRepository.maya],
      });
      expect(h.engine.peers, isEmpty);
      // The microphone and the foreground service now, with the app in front.
      expect(h.engine.mics, hasLength(1));
      expect(h.engine.keptAlive, ['In a call']);

      h.gateway.push(
        const duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-maya'));
      expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'c-maya');
      // The same microphone and service.
      expect(h.engine.mics, hasLength(1));
      expect(h.engine.keptAlive, hasLength(1));
      expect(h.engine.peer.log.first, 'audio mic');
      h.engine.peer.stateHandler!(PeerState.connected);

      // The call ends when everyone left: no leave comes for its voice.
      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));
      expect(h.voice.target, isNull);
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.answered);
      expect(h.voice.history.calls.value.single.outgoing, isTrue);
    });

    _voice('a call placed and hung up before an answer is cancelled; one nobody takes is unanswered', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      async.flushMicrotasks();
      expect(h.gateway.types.last, 'CALL_CANCEL');
      // What it opened goes with it.
      expect(h.engine.mics.single.stopped, isTrue);
      expect(h.engine.sleeps, 1);

      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(
        const duvet.CallDeclinedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
      );
      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-maya')));
      async.flushMicrotasks();
      expect(h.notices, ['Maya declined']);
      expect(h.voice.history.calls.value.map((c) => c.outcome), [CallOutcome.unanswered, CallOutcome.cancelled]);
      expect(h.engine.mics.map((m) => m.stopped), [true, true]);
      expect(h.engine.sleeps, 2);
    });

    _voice('a call placed from a voice room leaves the room at once', (async, h) {
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      expect(h.gateway.types, containsAllInOrder(['VOICE_JOIN', 'CALL_INITIATE', 'VOICE_LEAVE']));
      expect(h.voice.target, isNull);
      expect(h.engine.mics.map((m) => m.stopped), [true, false]);
      expect(h.engine.keptAlive, ['In a voice room', 'In a call']);
      // The room's connection stays until the call's exists: Android's audio
      // session ends with the last one.
      expect(h.engine.peers.single.closed, isFalse);

      h.gateway.push(
        const duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: 'c-maya', userId: FakeRepository.maya)),
      );
      async.flushMicrotasks();
      expect(h.engine.peers.map((p) => p.closed), [true, false]);
    });

    _voice('a call placed asks for its permissions before it rings anyone', (async, h) {
      h.engine.holdMic = Completer<void>();
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      expect(h.engine.prepared, 1);
      expect(h.gateway.sent, isEmpty);

      h.engine.holdMic!.complete();
      h.engine.holdMic = null;
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_INITIATE']);
      expect(h.voice.call?.phase, CallPhase.calling);
      expect(h.engine.mics.single.stopped, isFalse);
      expect(h.engine.keptAlive, hasLength(1));
    });

    _voice('a call can\'t be placed offline; one cut off while asking lets go of the microphone', (async, h) {
      h.gateway.socket = null;
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      expect(h.notices, ['You’re offline: call again once you’re back']);
      expect(h.engine.prepared, 0);

      h.gateway.socket = 1;
      h.engine.holdMic = Completer<void>();
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.socket = null;
      h.engine.holdMic!.complete();
      h.engine.holdMic = null;
      async.flushMicrotasks();
      expect(h.voice.call, isNull);
      expect(h.notices, hasLength(2));
      expect(h.engine.mics.single.stopped, isTrue);
      expect(h.engine.keptAlive, isEmpty);
    });

    _voice('a call placed on READY\'s own socket before READY came isn\'t over for not being listed', (async, h) {
      // The socket is open, and its READY on the way: built before the call.
      h.gateway.socket = 5;
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.ready(number: 5);
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.calling);
      expect(h.voice.callsInProgress, {'c-maya'});
      expect(h.voice.history.calls.value, isEmpty);

      // The next session's READY tells.
      h.gateway.ready(number: 6);
      async.flushMicrotasks();
      expect(h.voice.call, isNull);
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.unanswered);
    });

    _voice('a call the new session doesn\'t list is over', (async, h) {
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.push(_joined('c-maya', 'a1'));
      async.flushMicrotasks();
      h.engine.peer.stateHandler!(PeerState.connected);

      // The gateway restarted: calls live in its memory.
      h.gateway.ready(number: 2);
      async.flushMicrotasks();
      expect(h.voice.call, isNull);
      expect(h.voice.target, isNull);
      expect(h.engine.peers, hasLength(1));
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.answered);
    });

    _voice('a call the new session lists goes on: its voice joins again', (async, h) {
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.gateway.ready(
        number: 2,
        calls: [
          duvet.GatewayReadyActiveCall.fromJson({
            'conversation_id': 'c-maya',
            'initiator_id': FakeRepository.maya,
            'voice_states': [
              {'user_id': FakeRepository.maya, 'muted': false, 'version': 9},
            ],
          }),
        ],
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.engine.peers, hasLength(2));
      expect(h.voice.participants('c-maya').single.userId, FakeRepository.maya);
      // The answer again, in case the old socket lost it: a call nobody
      // answered ends 30 s after it started.
      expect(h.gateway.types, ['CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);

      // Not past those 30 s: each CALL_ACCEPTED makes the desktop app of a
      // member who isn't in the call join it.
      h.now = h.now.add(const Duration(seconds: 31));
      h.gateway.ready(
        number: 3,
        calls: [
          duvet.GatewayReadyActiveCall.fromJson({'conversation_id': 'c-maya', 'initiator_id': FakeRepository.maya}),
        ],
      );
      async.flushMicrotasks();
      expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(3));
      expect(h.gateway.types.where((t) => t == 'CALL_ACCEPT'), hasLength(2));
    });

    _voice('answering a call leaves the voice room', (async, h) {
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      h.gateway.push(incoming());
      h.voice.acceptCall();
      async.flushMicrotasks();
      expect(h.gateway.types, containsAllInOrder(['VOICE_JOIN', 'CALL_ACCEPT', 'VOICE_LEAVE', 'VOICE_JOIN']));
      expect(h.gateway.sent.firstWhere((s) => s.$1 == 'VOICE_LEAVE').$2, {'room_id': 'r-lounge'});
      expect(h.voice.target, const CallVoice('c-maya'));
      expect(h.engine.peers.first.closed, isTrue);
    });

    _voice('joining a call that rang out', (async, h) {
      h.gateway.push(incoming());
      h.voice.declineCall();
      h.voice.joinCall('c-maya');
      async.flushMicrotasks();
      expect(h.gateway.types, containsAllInOrder(['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN']));
      expect(h.voice.call?.phase, CallPhase.connected);
    });
  });

  // A call follows the user across their devices (duvetchat/gateway#25): what
  // the gateway tells each of their sessions, and what this phone does then.
  group('calls across devices', () {
    final me = FakeRepository.me.id;
    const maya = FakeRepository.maya;
    const leo = FakeRepository.leo;

    duvet.CallIncomingPayloadEvent incoming(String conversation, String caller, String name, {String? avatar}) =>
        duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(
            conversationId: conversation,
            initiatorId: caller,
            initiatorName: name,
            initiatorAvatar: avatar,
          ),
        );
    duvet.CallOutgoingPayloadEvent outgoing(String conversation) =>
        duvet.CallOutgoingPayloadEvent(duvet.CallOutgoingEvent(conversationId: conversation));
    duvet.CallOngoingPayloadEvent ongoing(String conversation, String caller, List<String> inVoice) =>
        duvet.CallOngoingPayloadEvent(
          duvet.CallOngoingEvent(
            conversationId: conversation,
            initiatorId: caller,
            voiceStates: inVoice.isEmpty
                ? null
                : [for (final u in inVoice) duvet.CallVoiceState(userId: u, version: 1)],
          ),
        );
    duvet.CallAcceptedEvent accepted(String conversation, String user) =>
        duvet.CallAcceptedEvent(duvet.CallResponseEvent(conversationId: conversation, userId: user));
    duvet.CallDeclinedEvent declined(String conversation, String user) =>
        duvet.CallDeclinedEvent(duvet.CallResponseEvent(conversationId: conversation, userId: user));
    duvet.CallEndedPayloadEvent ended(String conversation) =>
        duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: conversation));

    /// One of READY's calls; [ringing], [answered] and [name] are null from a
    /// gateway before calls across devices.
    duvet.GatewayReadyActiveCall listed(
      String conversation,
      String caller, {
      String? name,
      String? avatar,
      bool? ringing,
      bool? answered,
    }) => duvet.GatewayReadyActiveCall(
      conversationId: conversation,
      initiatorId: caller,
      initiatorName: name,
      initiatorAvatar: avatar,
      ringing: ringing,
      answered: answered,
    );

    _voice('the user\'s own call from another device rings nothing here, and can be joined once someone answers it', (
      async,
      h,
    ) {
      h.gateway.push(outgoing('c-team'));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
      expect(h.voice.ownCallRinging('c-team'), isTrue);

      // It still rings the others: the user's voice would be in it alone.
      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.sent, isEmpty);
      expect(h.voice.call, isNull);

      // A decline isn't an answer, and the device that placed the call says it.
      h.gateway.push(declined('c-team', maya));
      expect(h.voice.ownCallRinging('c-team'), isTrue);
      expect(h.notices, isEmpty);

      // Leo answered: nothing joins by itself, and Join moves the voice here.
      h.gateway.push(accepted('c-team', leo));
      async.flushMicrotasks();
      expect(h.voice.ownCallRinging('c-team'), isFalse);
      expect(h.gateway.sent, isEmpty);
      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      expect(h.voice.target, const CallVoice('c-team'));
    });

    _voice('the call placed here rings the others until the first answer, then its voice joins', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(outgoing('c-maya'));
      expect(h.voice.call?.phase, CallPhase.calling);
      expect(h.voice.ownCallRinging('c-maya'), isTrue);

      h.gateway.push(accepted('c-maya', maya));
      async.flushMicrotasks();
      expect(h.voice.ownCallRinging('c-maya'), isFalse);
      expect(h.voice.target, const CallVoice('c-maya'));
    });

    _voice('a call ringing here stops when the user answers or declines it on another device', (async, h) {
      h.gateway.push(incoming('c-maya', maya, 'Maya'));
      h.gateway.push(accepted('c-maya', me));
      expect(h.voice.call, isNull);
      // It goes on there.
      expect(h.voice.callsInProgress, {'c-maya'});
      h.gateway.push(ended('c-maya'));

      // A group's goes on after the user declined it there, and can be joined
      // from here still.
      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.gateway.push(declined('c-team', me));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
      // The gateway has the decline: nothing goes from here, nor is told.
      expect(h.gateway.sent, isEmpty);
      expect(h.notices, isEmpty);
      // Neither call was this phone's to keep: the other device answered it.
      expect(h.voice.history.calls.value, isEmpty);

      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
    });

    _voice('READY rings for a call that still rings the user, naming its caller as READY does', (async, h) {
      h.gateway.ready(
        number: 2,
        calls: [listed('c-team', leo, name: 'Leo', avatar: 'av-leo', ringing: true, answered: false)],
      );
      expect(h.voice.call?.phase, CallPhase.ringing);
      expect(h.voice.call?.conversationId, 'c-team');
      expect(h.voice.call?.initiatorName, 'Leo');
      expect(h.voice.call?.initiatorAvatar, 'av-leo');
      expect(h.voice.call?.outgoing, isFalse);

      h.voice.acceptCall();
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      expect(h.voice.target, const CallVoice('c-team'));
    });

    _voice('READY rings for no call answered or declined elsewhere, and one ringing here stops', (async, h) {
      h.gateway.push(incoming('c-maya', maya, 'Maya'));
      // A new session: the user answered on another device meanwhile.
      h.gateway.ready(number: 2, calls: [listed('c-maya', maya, name: 'Maya', ringing: false, answered: true)]);
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-maya'});
      expect(h.voice.history.calls.value, isEmpty);

      h.gateway.ready(number: 3, calls: [listed('c-team', leo, name: 'Leo', ringing: false, answered: true)]);
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
    });

    _voice('someone else\'s call READY lists unanswered can be joined once declined here: it isn\'t the user\'s own', (
      async,
      h,
    ) {
      h.gateway.ready(number: 2, calls: [listed('c-team', leo, name: 'Leo', ringing: true, answered: false)]);
      expect(h.voice.call?.phase, CallPhase.ringing);
      h.voice.declineCall();
      expect(h.voice.callsInProgress, {'c-team'});
      expect(h.voice.ownCallRinging('c-team'), isFalse);

      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_DECLINE', 'CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
    });

    _voice('a call that stopped ringing while the phone was away is kept nowhere; one that stops here is missed', (
      async,
      h,
    ) {
      // Leo's call rang here, then the phone was cut off. Maya answered it,
      // and its ring window ended meanwhile: READY can't tell that from a
      // call the user answered or declined on another device.
      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.gateway.ready(number: 2, calls: [listed('c-team', leo, name: 'Leo', ringing: false, answered: true)]);
      expect(h.voice.call, isNull);
      expect(h.voice.history.calls.value, isEmpty);
      h.gateway.push(ended('c-team'));

      // Its ring window ending while the phone is here (CALL_ONGOING): missed.
      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.gateway.push(ongoing('c-team', leo, [leo, maya]));
      expect(h.voice.call, isNull);
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.missed);
    });

    _voice('READY says whether the user\'s own call was answered: until it is, it can\'t be joined from here', (
      async,
      h,
    ) {
      h.gateway.ready(number: 2, calls: [listed('c-team', me, name: 'Gaby', ringing: false, answered: false)]);
      // Their own call rings none of their devices.
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
      expect(h.voice.ownCallRinging('c-team'), isTrue);
      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.sent, isEmpty);

      h.gateway.ready(number: 3, calls: [listed('c-team', me, name: 'Gaby', ringing: false, answered: true)]);
      expect(h.voice.ownCallRinging('c-team'), isFalse);
    });

    _voice('the call placed here that READY says was answered joins, as the answer it missed would have done', (
      async,
      h,
    ) {
      h.gateway.ready(number: 1);
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(outgoing('c-maya'));
      // Unanswered still: it goes on calling.
      h.gateway.ready(
        number: 2,
        silence: const Duration(seconds: 20),
        calls: [listed('c-maya', me, name: 'Gaby', ringing: false, answered: false)],
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.calling);

      // Maya answered while the socket was down: her CALL_ACCEPTED went to
      // the session that dropped.
      h.now = h.now.add(const Duration(seconds: 40));
      h.gateway.ready(
        number: 3,
        silence: const Duration(seconds: 30),
        calls: [listed('c-maya', me, name: 'Gaby', ringing: false, answered: true)],
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-maya'));
      expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'c-maya');
      // The microphone opened as it was placed.
      expect(h.engine.mics, hasLength(1));
      expect(h.engine.peer.log.first, 'audio mic');
    });

    _voice(
      'after more than 3 minutes without a word from the gateway, it stops calling instead: the call shows, to join',
      (async, h) {
        h.gateway.ready(number: 1);
        h.voice.startCall('c-maya');
        async.flushMicrotasks();
        h.gateway.push(outgoing('c-maya'));
        // The phone slept.
        h.now = h.now.add(const Duration(minutes: 3, seconds: 1));
        h.gateway.ready(
          number: 2,
          silence: const Duration(minutes: 3, seconds: 1),
          calls: [listed('c-maya', me, name: 'Gaby', ringing: false, answered: true)],
        );
        async.flushMicrotasks();
        expect(h.voice.call, isNull);
        expect(h.voice.target, isNull);
        expect(h.gateway.types, isNot(contains('VOICE_JOIN')));
        // What it opened goes with it.
        expect(h.engine.mics.single.stopped, isTrue);
        expect(h.engine.sleeps, 1);
        expect(h.voice.callsInProgress, {'c-maya'});
        expect(h.voice.ownCallRinging('c-maya'), isFalse);
        // It goes on, to join: the history keeps nothing of it.
        expect(h.voice.history.calls.value, isEmpty);

        h.voice.joinCall('c-maya');
        async.flushMicrotasks();
        expect(h.gateway.types.skip(1), ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      },
    );

    // How long the phone was cut off counts from the gateway's last word, or
    // from the call if it was placed later, as voice's own rule does.
    _voice('a call placed just now joins however long the gateway had been silent before', (async, h) {
      h.gateway.ready(number: 1);
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.now = h.now.add(const Duration(seconds: 20));
      h.gateway.ready(
        number: 2,
        silence: const Duration(minutes: 10),
        calls: [listed('c-maya', me, name: 'Gaby', ringing: false, answered: true)],
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-maya'));
    });

    _voice('a call placed long ago joins when the gateway was heard just before', (async, h) {
      h.gateway.ready(number: 1);
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.now = h.now.add(const Duration(minutes: 10));
      h.gateway.ready(
        number: 2,
        silence: const Duration(seconds: 5),
        calls: [listed('c-maya', me, name: 'Gaby', ringing: false, answered: true)],
      );
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-maya'));
    });

    _voice('a gateway from before calls across devices: READY rings nothing, keeps what rings, and any call joins', (
      async,
      h,
    ) {
      h.gateway.ready(number: 1, calls: [listed('c-team', leo)]);
      expect(h.voice.call, isNull);
      expect(h.voice.ownCallRinging('c-team'), isFalse);
      // The user's own call too, as before.
      h.gateway.ready(number: 2, calls: [listed('c-team', me)]);
      expect(h.voice.ownCallRinging('c-team'), isFalse);

      h.gateway.push(incoming('c-maya', maya, 'Maya'));
      h.gateway.ready(number: 3, calls: [listed('c-maya', maya)]);
      expect(h.voice.call?.phase, CallPhase.ringing);
      expect(h.voice.call?.initiatorName, 'Maya');
    });

    _voice('a call whose ring window ended goes on: missed here, who is in it shows, and it can be joined', (async, h) {
      h.gateway.push(incoming('c-team', leo, 'Leo', avatar: 'av-leo'));
      expect(h.voice.call?.initiatorAvatar, 'av-leo');
      // Someone else's answer leaves it ringing here, until its ring window ends.
      h.gateway.push(accepted('c-team', maya));
      expect(h.voice.call?.phase, CallPhase.ringing);

      h.gateway.push(ongoing('c-team', leo, [leo, maya]));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
      expect(h.voice.participants('c-team').map((p) => p.userId), [leo, maya]);
      final missed = h.voice.history.calls.value.single;
      expect((missed.title, missed.outcome, missed.outgoing), ('Design crew', CallOutcome.missed, false));

      h.voice.joinCall('c-team');
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      expect(h.voice.call?.phase, CallPhase.connected);
    });

    _voice('added to a group while its call goes on: it shows, with who is in it, and rings nothing', (async, h) {
      h.gateway.push(ongoing('c-team', leo, [leo]));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, {'c-team'});
      expect(h.voice.participants('c-team').single.userId, leo);
      expect(h.voice.history.calls.value, isEmpty);

      // Nobody in it: none shows.
      h.gateway.push(ongoing('c-team', leo, const []));
      expect(h.voice.participants('c-team'), isEmpty);
    });

    _voice('calls that crossed in a DM connect: the call placed here joins the one that rang', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      // Maya's call reached the gateway first. It rings here, but this phone
      // is calling: it waits for the gateway, which takes its call for an
      // answer.
      h.gateway.push(incoming('c-maya', maya, 'Maya'));
      expect(h.voice.call?.phase, CallPhase.calling);
      h.gateway.push(accepted('c-maya', me));
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-maya'));
      expect(h.gateway.types, ['CALL_INITIATE', 'VOICE_JOIN', 'VOICE_SYNC']);
    });

    _voice('calls that crossed in a group connect too, also when the gateway lets the caller in first', (async, h) {
      h.voice.startCall('c-team');
      async.flushMicrotasks();
      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.gateway.push(accepted('c-team', me));
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.gateway.last('VOICE_JOIN')!['room_id'], 'c-team');
      h.voice.hangUp();
      async.flushMicrotasks();

      // Leo's call began without the user among its members (added just as
      // it began): the gateway lets them in, then takes their call for an
      // answer.
      h.voice.startCall('c-team');
      async.flushMicrotasks();
      h.gateway.push(ongoing('c-team', leo, [leo]));
      expect(h.voice.call?.phase, CallPhase.calling);
      h.gateway.push(accepted('c-team', me));
      async.flushMicrotasks();
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.voice.target, const CallVoice('c-team'));
    });

    _voice('leaving a group during its call hangs up here, or stops its ringing: CALL_ENDED comes to the user alone', (
      async,
      h,
    ) {
      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.voice.acceptCall();
      async.flushMicrotasks();
      h.engine.peer.stateHandler!(PeerState.connected);

      // The user left the group, here or on another device: the gateway
      // takes their voice out of the call, which goes on for the others.
      h.gateway.push(ended('c-team'));
      expect(h.voice.call, isNull);
      expect(h.voice.target, isNull);
      expect(h.voice.callsInProgress, isEmpty);
      expect(h.engine.peer.closed, isTrue);
      expect(h.gateway.types, isNot(contains('CALL_LEAVE')));
      expect(h.gateway.types, isNot(contains('VOICE_LEAVE')));
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.answered);

      h.gateway.push(incoming('c-team', leo, 'Leo'));
      h.gateway.push(ended('c-team'));
      expect(h.voice.call, isNull);
      expect(h.voice.callsInProgress, isEmpty);
    });

    _voice('a cancel after calling back into a call going on takes only the user out: the call shows, to join', (
      async,
      h,
    ) {
      // The user calls into their own call, which Maya answered and they had
      // left: the gateway takes it for their coming back, and its
      // CALL_ACCEPTED of the user is on its way when they cancel.
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_CANCEL']);
      expect(h.voice.callsInProgress, isEmpty);

      // That cancel only took the user's voice out: the call goes on.
      h.gateway.push(accepted('c-maya', me));
      async.flushMicrotasks();
      expect(h.voice.callsInProgress, {'c-maya'});
      expect(h.voice.call, isNull);
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_CANCEL']);
      expect(h.voice.history.calls.value.single.outcome, CallOutcome.cancelled);

      h.voice.joinCall('c-maya');
      async.flushMicrotasks();
      expect(h.gateway.types.skip(2), ['CALL_INITIATE', 'CALL_ACCEPT', 'VOICE_JOIN', 'VOICE_SYNC']);
      h.gateway.push(ended('c-maya'));
      expect(h.voice.callsInProgress, isEmpty);
    });

    _voice('any other cancel of the caller ends the call: it doesn\'t show again before its CALL_ENDED', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      // What the gateway said of the call before the cancel reached it: it
      // had it, and Maya answered it just then.
      h.gateway.push(outgoing('c-maya'));
      h.gateway.push(accepted('c-maya', maya));
      async.flushMicrotasks();
      expect(h.voice.callsInProgress, isEmpty);
      expect(h.voice.ownCallRinging('c-maya'), isFalse);
      expect(h.voice.call, isNull);

      h.gateway.push(ended('c-maya'));
      expect(h.voice.callsInProgress, isEmpty);
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_CANCEL']);
    });

    _voice('a call placed again where one was just cancelled takes what the gateway says of it', (async, h) {
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.gateway.push(outgoing('c-maya'));
      expect(h.voice.ownCallRinging('c-maya'), isTrue);
      expect(h.voice.callsInProgress, {'c-maya'});
      // The gateway has it: a resumed session doesn't place it again.
      h.gateway.resumed(number: 2);
      async.flushMicrotasks();
      expect(h.gateway.types, ['CALL_INITIATE', 'CALL_CANCEL', 'CALL_INITIATE']);
    });

    _voice('the user\'s own call and their cancel are forgotten once the call ends, at READY, and with the account', (
      async,
      h,
    ) {
      h.gateway.push(outgoing('c-team'));
      h.gateway.push(ended('c-team'));
      expect(h.voice.ownCallRinging('c-team'), isFalse);
      // A call placed there from another device after the one cancelled here
      // ended shows.
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      h.gateway.push(ended('c-maya'));
      h.gateway.push(outgoing('c-maya'));
      expect(h.voice.callsInProgress, {'c-maya'});
      expect(h.voice.ownCallRinging('c-maya'), isTrue);
      h.gateway.push(ended('c-maya'));

      // A new session: its READY lists the calls going on.
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      h.gateway.ready(number: 2);
      h.gateway.push(outgoing('c-maya'));
      expect(h.voice.callsInProgress, {'c-maya'});
      h.gateway.push(ended('c-maya'));

      // Another account, or the same again: nothing of the last session's.
      h.gateway.push(outgoing('c-team'));
      h.voice.startCall('c-maya');
      async.flushMicrotasks();
      h.voice.hangUp();
      h.repository.logOut();
      async.flushMicrotasks();
      h.repository.logIn('gaby@duvet.chat', 'secret');
      async.flushMicrotasks();
      expect(h.voice.ownCallRinging('c-team'), isFalse);
      h.gateway.push(outgoing('c-maya'));
      expect(h.voice.callsInProgress, {'c-maya'});
    });
  });

  _voice('the next account starts unmuted, with none of the last one\'s TURN credentials', (async, h) {
    h.gateway.ready(
      number: 1,
      iceServers: const [
        duvet.IceServer(urls: ['turn:turn.duvet.chat:3478'], username: '1:me', credential: 'secret'),
      ],
    );
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    h.voice.toggleDeafen();
    async.flushMicrotasks();

    h.repository.logOut();
    async.flushMicrotasks();
    h.repository.logIn('gaby@duvet.chat', 'secret');
    async.flushMicrotasks();
    h.gateway.socket = 2;
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();
    expect(h.engine.iceServers.last.map((s) => s.urls.first), ['stun:stun.l.google.com:19302']);
    expect((h.voice.muted, h.voice.deafened), (false, false));
    expect(h.gateway.last('VOICE_SYNC'), _sync());
  });

  _voice('signing out leaves voice while the gateway is there to hear it, and forgets the call history', (async, h) {
    h.gateway.push(
      const duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
      ),
    );
    h.voice.declineCall();
    async.flushMicrotasks();
    expect(h.history.data, isNotEmpty);
    // Another account's, left by a session that ended without signing out.
    h.history.data['0a0a0a0a-0000-4000-8000-0000000000ff'] = '[]';
    h.voice.joinRoom(_lounge);
    async.flushMicrotasks();

    h.repository.logOut();
    async.flushMicrotasks();
    expect(h.gateway.types.last, 'VOICE_LEAVE');
    expect(h.voice.target, isNull);
    expect(h.voice.history.calls.value, isEmpty);
    expect(h.history.data, isEmpty);
  });

  _voice('signing out says so to the calls: one ringing declined, one placed cancelled, one going on left', (async, h) {
    duvet.CallIncomingPayloadEvent from(String conversation) => duvet.CallIncomingPayloadEvent(
      duvet.CallIncomingEvent(conversationId: conversation, initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
    );

    h.gateway.push(from('c-leo'));
    h.repository.logOut();
    async.flushMicrotasks();
    expect(h.gateway.last('CALL_DECLINE'), {'conversation_id': 'c-leo'});

    h.repository.logIn('gaby@duvet.chat', 'secret');
    h.gateway.socket = 2;
    async.flushMicrotasks();
    h.voice.startCall('c-maya');
    async.flushMicrotasks();
    h.repository.logOut();
    async.flushMicrotasks();
    expect(h.gateway.last('CALL_CANCEL'), {'conversation_id': 'c-maya'});

    h.repository.logIn('gaby@duvet.chat', 'secret');
    h.gateway.socket = 3;
    async.flushMicrotasks();
    h.gateway.push(from('c-leo'));
    h.voice.acceptCall();
    async.flushMicrotasks();
    h.repository.logOut();
    async.flushMicrotasks();
    expect(h.gateway.types.last, 'CALL_LEAVE');
    expect(h.voice.call, isNull);
    expect(h.history.data, isEmpty);
  });

  group('video', () {
    // In the lounge, its join answered.
    void connected(FakeAsync async, _Harness h) {
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      h.gateway.push(_joined('r-lounge', 'a1'));
      async.flushMicrotasks();
    }

    List<String> offers(_Harness h) => [
      for (final (type, data) in h.gateway.sent)
        if (type == 'WEBRTC_RENEGOTIATE_OFFER') data['offer'] as String,
    ];

    _voice('every VOICE_SYNC carries whose screen share the user watches, until it ends or they leave', (async, h) {
      const maya = FakeRepository.maya;
      const leo = FakeRepository.leo;
      connected(async, h);
      h.gateway.push(_state('r-lounge', maya, 3, screen: true));
      h.gateway.push(_state('r-lounge', leo, 4, screen: true));
      async.flushMicrotasks();

      // Each watch is a sync, in the order they were opened.
      h.voice.watch(maya, on: true);
      expect(h.gateway.last('VOICE_SYNC'), _sync(watching: [maya]));
      h.voice.watch(leo, on: true);
      expect(h.gateway.last('VOICE_SYNC'), _sync(watching: [maya, leo]));
      // Any other sync carries it too: VOICE_SYNC is the whole state.
      h.voice.toggleMute();
      async.flushMicrotasks();
      expect(h.gateway.last('VOICE_SYNC'), _sync(muted: true, watching: [maya, leo]));
      h.voice.toggleMute();
      async.flushMicrotasks();

      // With video off no screen comes in: none, and the list back with it.
      h.voice.setIncomingVideo(false);
      expect(h.gateway.last('VOICE_SYNC'), _sync(videoOff: true));
      h.voice.setIncomingVideo(true);
      expect(h.gateway.last('VOICE_SYNC'), _sync(watching: [maya, leo]));

      // A sharer who stops is watched no more.
      h.gateway.push(_state('r-lounge', maya, 5));
      async.flushMicrotasks();
      expect(h.voice.watching, [leo]);
      expect(h.gateway.last('VOICE_SYNC'), _sync(watching: [leo]));
      h.voice.watch(leo, on: false);
      expect(h.gateway.last('VOICE_SYNC'), _sync());

      // Leaving keeps nothing for the next join.
      h.voice.watch(leo, on: true);
      h.voice.leave();
      async.flushMicrotasks();
      expect(h.voice.watching, isEmpty);
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      expect(h.gateway.last('VOICE_SYNC'), _sync());
    });

    _voice('the camera swaps its track and says so in VOICE_SYNC: it never renegotiates', (async, h) {
      connected(async, h);
      h.voice.toggleCamera();
      async.flushMicrotasks();
      final camera = h.engine.openedCameras.single;
      expect(h.voice.cameraOn, isTrue);
      expect(h.voice.camera, camera);
      expect(h.engine.peer.camera, camera);
      expect(h.gateway.last('VOICE_SYNC'), _sync(camera: true));

      h.voice.switchCamera();
      async.flushMicrotasks();
      expect(camera.switches, 1);

      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.voice.cameraOn, isFalse);
      expect(camera.stopped, isTrue);
      expect(h.engine.peer.log, containsAllInOrder(['camera true', 'camera false']));
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(offers(h), isEmpty);
    });

    _voice('a camera that can\'t open says why: refused, or none at all', (async, h) {
      connected(async, h);
      h.engine.cameraAllowed = false;
      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.notices.last, 'Allow Duvet to use the camera to turn it on');
      h.engine.cameraDevices = const [];
      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.notices.last, 'This phone has no camera');
      expect(h.voice.cameraOn, isFalse);
      expect(h.gateway.types.where((t) => t == 'VOICE_SYNC'), hasLength(1));
    });

    _voice('a camera allowed but busy says only that it couldn\'t turn on', (async, h) {
      connected(async, h);
      h.engine.cameraBusy = true;
      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.notices.last, 'Couldn’t turn on the camera');
      expect(h.voice.cameraOn, isFalse);
    });

    _voice('a tap while the camera opens is the latest word: one camera opens, and off stays off', (async, h) {
      connected(async, h);
      h.engine.holdCamera = Completer<void>();
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.engine.holdCamera!.complete();
      h.engine.holdCamera = null;
      async.flushMicrotasks();
      expect(h.engine.cameraOpens, 1);
      expect(h.engine.openedCameras.single.stopped, isTrue);
      expect(h.voice.cameraOn, isFalse);
      expect(h.engine.peer.camera, isNull);
      expect(h.notices, isEmpty);
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(h.lifecycle.hasListener, isFalse);

      // On, off, on: on, still with one camera opening.
      h.engine.holdCamera = Completer<void>();
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.voice.toggleCamera();
      h.voice.toggleCamera();
      h.engine.holdCamera!.complete();
      h.engine.holdCamera = null;
      async.flushMicrotasks();
      expect(h.engine.cameraOpens, 2);
      expect(h.voice.camera, h.engine.openedCameras.last);
      expect(h.gateway.last('VOICE_SYNC'), _sync(camera: true));
    });

    _voice('the app going to the background while the camera opens leaves it off', (async, h) {
      connected(async, h);
      h.engine.holdCamera = Completer<void>();
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.lifecycle.add(AppLifecycleState.paused);
      h.engine.holdCamera!.complete();
      h.engine.holdCamera = null;
      async.flushMicrotasks();
      expect(h.voice.cameraOn, isFalse);
      expect(h.engine.openedCameras.single.stopped, isTrue);
      expect(h.notices, ['Camera turned off in the background']);
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(h.lifecycle.hasListener, isFalse);
    });

    _voice('the camera picked opens on the next tap, or replaces the one on', (async, h) {
      connected(async, h);
      expect(h.voice.selectedCameraId, isNull);
      h.voice.selectCamera('0');
      expect(h.voice.selectedCameraId, '0');
      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.engine.openedCameras.single.deviceId, '0');

      h.voice.selectCamera('1');
      async.flushMicrotasks();
      final [back, front] = h.engine.openedCameras;
      expect(back.stopped, isTrue);
      expect(front.deviceId, '1');
      expect(h.voice.selectedCameraId, '1');
      expect(h.voice.camera, front);
      expect(h.engine.peer.camera, front);
      expect(offers(h), isEmpty);
    });

    _voice('a camera that ends on its own turns off', (async, h) {
      connected(async, h);
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.engine.openedCameras.single.end();
      async.flushMicrotasks();
      expect(h.voice.cameraOn, isFalse);
      expect(h.gateway.last('VOICE_SYNC'), _sync());
    });

    _voice('sharing the screen is the phone\'s own offer, answered by the gateway, and so is stopping', (async, h) {
      connected(async, h);
      h.voice.startScreenShare();
      async.flushMicrotasks();
      final screen = h.engine.screens.single;
      expect(h.voice.screenSharing, isTrue);
      expect(h.engine.peer.screen, screen);
      expect(h.gateway.last('VOICE_SYNC'), _sync(screen: true));
      expect(h.gateway.last('WEBRTC_RENEGOTIATE_OFFER'), {
        'room_id': 'r-lounge',
        'offer': 'offer-1',
        'tracks': {'1': 'camera'},
      });
      h.gateway.push(_answer('r-lounge', 'b1'));
      async.flushMicrotasks();
      expect(h.engine.peer.log.last, 'remote answer b1');

      h.voice.stopScreenShare();
      async.flushMicrotasks();
      expect(screen.stopped, isTrue);
      expect(h.engine.peer.screen, isNull);
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(offers(h), hasLength(2));
      h.gateway.push(_answer('r-lounge', 'b2'));
      async.flushMicrotasks();
      expect(h.engine.peer.log.last, 'remote answer b2');
    });

    _voice('a second tap while the screen capture starts asks nothing more', (async, h) {
      connected(async, h);
      h.engine.holdScreen = Completer<void>();
      h.voice.startScreenShare();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.engine.holdScreen!.complete();
      h.engine.holdScreen = null;
      async.flushMicrotasks();
      expect(h.engine.screenOpens, 1);
      expect(h.voice.screen, h.engine.screens.single);
      expect(offers(h), hasLength(1));
    });

    _voice('stopping the screen while its offer is out offers again once the answer is in', (async, h) {
      connected(async, h);
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.voice.stopScreenShare();
      async.flushMicrotasks();
      expect(offers(h), hasLength(1));
      h.gateway.push(_answer('r-lounge', 'b1'));
      async.flushMicrotasks();
      expect(offers(h), hasLength(2));
      h.gateway.push(_answer('r-lounge', 'b2'));
      async.flushMicrotasks();
      expect(h.engine.peer.log, containsAllInOrder(['remote answer b1', 'remote answer b2']));
      expect(h.engine.peers, hasLength(1));
    });

    _voice('the second answer to an offer sent again on a resumed socket isn\'t taken for the next one\'s', (async, h) {
      connected(async, h);
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.resumed();
      async.flushMicrotasks();
      h.gateway.push(_answer('r-lounge', 'b1'));
      async.flushMicrotasks();
      h.voice.stopScreenShare();
      async.flushMicrotasks();
      expect(offers(h), hasLength(3));
      h.gateway.push(_answer('r-lounge', 'b1-again'));
      async.flushMicrotasks();
      expect(h.engine.peer.log, isNot(contains('remote answer b1-again')));
      h.gateway.push(_answer('r-lounge', 'b2'));
      async.flushMicrotasks();
      expect(h.engine.peer.log.last, 'remote answer b2');
      async.elapse(const Duration(seconds: 15));
      expect(h.engine.peers, hasLength(1));
    });

    _voice('a screen capture refused, or ended on its own', (async, h) {
      connected(async, h);
      h.engine.screenAllowed = false;
      h.voice.startScreenShare();
      async.flushMicrotasks();
      expect(h.notices.last, 'Duvet can’t share the screen');
      expect(offers(h), isEmpty);

      h.engine.screenAllowed = true;
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.push(_answer('r-lounge', 'b1'));
      h.engine.screens.single.end();
      async.flushMicrotasks();
      expect(h.voice.screenSharing, isFalse);
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(offers(h), hasLength(2));
    });

    _voice('glare: the gateway\'s offer crossing the phone\'s, the phone rolls back, answers, then offers again', (
      async,
      h,
    ) {
      connected(async, h);
      final peer = h.engine.peer;
      h.voice.startScreenShare();
      async.flushMicrotasks();
      expect(offers(h), hasLength(1));
      h.gateway.push(_offer('r-lounge', 'o2'));
      async.flushMicrotasks();
      expect(
        peer.log.skip(5),
        containsAllInOrder(['local offer offer-1', 'local rollback ', 'remote offer o2', 'local offer offer-1']),
      );
      expect(h.gateway.types.where((t) => t.startsWith('WEBRTC_') && t != 'WEBRTC_ICE_CANDIDATE'), [
        'WEBRTC_RENEGOTIATE_OFFER',
        'WEBRTC_ANSWER',
        'WEBRTC_RENEGOTIATE_OFFER',
      ]);
      // The first offer's answer can't come: the gateway failed it.
      h.gateway.push(_answer('r-lounge', 'b1'));
      async.flushMicrotasks();
      expect(peer.log.last, 'remote answer b1');
    });

    _voice('the phone\'s offer waits while the gateway\'s is being answered', (async, h) {
      connected(async, h);
      final peer = h.engine.peer..holdRemote = Completer<void>();
      h.gateway.push(_offer('r-lounge', 'o2'));
      async.flushMicrotasks();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      expect(offers(h), isEmpty);
      peer.holdRemote!.complete();
      peer.holdRemote = null;
      async.flushMicrotasks();
      expect(h.gateway.types.where((t) => t == 'WEBRTC_ANSWER' || t == 'WEBRTC_RENEGOTIATE_OFFER'), [
        'WEBRTC_ANSWER',
        'WEBRTC_RENEGOTIATE_OFFER',
      ]);
      expect(peer.log, isNot(contains('local rollback ')));
    });

    _voice('an offer resumed on a new socket goes again; one never answered starts over without the screen', (
      async,
      h,
    ) {
      connected(async, h);
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.resumed();
      async.flushMicrotasks();
      expect(offers(h), ['offer-1', 'offer-1']);

      async.elapse(const Duration(seconds: 15));
      expect(h.engine.peers, hasLength(2));
      expect(h.engine.screens.single.stopped, isTrue);
      expect(h.voice.screenSharing, isFalse);
      expect(h.notices.last, 'Screen sharing stopped');
      expect(h.gateway.types.where((t) => t == 'VOICE_JOIN'), hasLength(2));
      expect(h.gateway.last('VOICE_SYNC'), _sync());
    });

    _voice('a new session joins again with the camera on, tagged, and the screen stopped', (async, h) {
      connected(async, h);
      h.voice.toggleCamera();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.ready(number: 2);
      async.flushMicrotasks();
      expect(h.engine.peer.log, ['audio mic', 'video', 'camera true', 'sending true', 'local offer offer-2']);
      expect(h.gateway.last('VOICE_JOIN')!['tracks'], {'1': 'camera'});
      expect(h.engine.openedCameras.single.stopped, isFalse);
      expect(h.engine.screens.single.stopped, isTrue);
      expect(h.notices.last, 'Screen sharing stopped');
      expect(h.gateway.last('VOICE_SYNC'), _sync(camera: true));
    });

    _voice('leaving, or the voice taken by another device, stops both; the next join starts with both off', (async, h) {
      connected(async, h);
      h.voice.toggleCamera();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.voice.leave();
      async.flushMicrotasks();
      expect(h.engine.openedCameras.single.stopped, isTrue);
      expect(h.engine.screens.single.stopped, isTrue);
      expect((h.voice.cameraOn, h.voice.screenSharing), (false, false));

      connected(async, h);
      expect(h.engine.peer.log, isNot(contains('camera true')));
      h.voice.toggleCamera();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.push(const duvet.VoiceSessionReplacedPayloadEvent(duvet.VoiceSessionReplacedEvent(roomId: 'r-lounge')));
      async.flushMicrotasks();
      expect(h.engine.openedCameras.last.stopped, isTrue);
      expect(h.engine.screens.last.stopped, isTrue);
      expect((h.voice.cameraOn, h.voice.screenSharing), (false, false));
    });

    _voice('VOICE_VIDEO_REFUSED stops the capture and says why, as the desktop says it', (async, h) {
      connected(async, h);
      for (final (refusal, why) in [
        (_refused('camera', 'limit', limit: 8), 'This room already has 8 cameras on'),
        (_refused('camera', 'limit', limit: 1), 'This room already has 1 camera on'),
        (_refused('camera', 'limit', limit: 0), 'Cameras are turned off in this room'),
        (_refused('camera', 'limit'), 'This room already has as many cameras on as it can'),
        (_refused('camera', 'permission'), 'You can’t use video in this room'),
        (_refused('camera', 'bitrate'), 'Your camera was turned off: it was sending more video than this room allows'),
      ]) {
        h.voice.toggleCamera();
        async.flushMicrotasks();
        h.gateway.push(refusal);
        async.flushMicrotasks();
        expect(h.voice.cameraOn, isFalse);
        expect(h.engine.openedCameras.last.stopped, isTrue);
        expect(h.notices.last, why);
        expect(h.gateway.last('VOICE_SYNC'), _sync());
      }
      // Nothing on: nothing to say.
      final said = h.notices.length;
      h.gateway.push(_refused('camera', 'limit', limit: 8));
      expect(h.notices, hasLength(said));

      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.gateway.push(_refused('screen', 'permission'));
      async.flushMicrotasks();
      expect(h.voice.screenSharing, isFalse);
      expect(h.engine.screens.single.stopped, isTrue);
      expect(h.notices.last, 'You can’t use video in this room');
    });

    _voice('in a call, video is always allowed, and refusals speak of the call', (async, h) {
      h.repository.deniedInRoom['r-lounge'] = Perm.video;
      h.gateway.push(
        const duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
        ),
      );
      h.voice.acceptCall();
      async.flushMicrotasks();
      expect(h.voice.canVideo, isTrue);
      h.voice.toggleCamera();
      async.flushMicrotasks();
      h.gateway.push(_refused('camera', 'limit', limit: 8, room: 'c-leo'));
      async.flushMicrotasks();
      expect(h.notices.last, 'This call already has 8 cameras on');
    });

    _voice('losing Video in the room stops the camera and the screen', (async, h) {
      connected(async, h);
      expect(h.voice.canVideo, isTrue);
      h.voice.toggleCamera();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.repository.deniedInRoom['r-lounge'] = Perm.video;
      h.repository.spaces.value = [...h.repository.spaces.value];
      async.flushMicrotasks();
      expect(h.voice.canVideo, isFalse);
      expect((h.voice.cameraOn, h.voice.screenSharing), (false, false));
      expect(h.engine.openedCameras.single.stopped, isTrue);
      expect(h.engine.screens.single.stopped, isTrue);
      expect(h.notices.last, 'You can’t use video in this room now');
      expect(h.gateway.last('VOICE_SYNC'), _sync());

      h.voice.toggleCamera();
      async.flushMicrotasks();
      expect(h.engine.openedCameras, hasLength(1));
      expect(h.notices.last, 'You can’t use video in this room');
    });

    _voice('the camera turns off in the background; the screen goes on', (async, h) {
      connected(async, h);
      h.voice.toggleCamera();
      h.voice.startScreenShare();
      async.flushMicrotasks();
      h.lifecycle.add(AppLifecycleState.inactive);
      expect(h.voice.cameraOn, isTrue);
      h.lifecycle.add(AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(h.voice.cameraOn, isFalse);
      expect(h.engine.openedCameras.single.stopped, isTrue);
      expect(h.voice.screenSharing, isTrue);
      expect(h.notices.last, 'Camera turned off in the background');
      expect(h.gateway.last('VOICE_SYNC'), _sync(screen: true));
    });

    _voice('incoming video off: VOICE_JOIN and every sync say so, and the others\' videos hide', (async, h) {
      h.voice.setIncomingVideo(false);
      connected(async, h);
      expect(h.gateway.last('VOICE_JOIN')!['video_off'], isTrue);
      expect(h.gateway.last('VOICE_SYNC'), _sync(videoOff: true));
      final maya = VoiceRemoteVideo(userId: FakeRepository.maya, kind: VideoKind.camera, view: (_) => const SizedBox());
      h.engine.peer.remoteVideos.value = [maya];
      expect(h.voice.remoteVideos.value, isEmpty);

      h.voice.setIncomingVideo(true);
      async.flushMicrotasks();
      expect(h.gateway.last('VOICE_SYNC'), _sync());
      expect(h.voice.remoteVideos.value, [maya]);

      h.voice.leave();
      expect(h.voice.remoteVideos.value, isEmpty);
    });

    _voice('noise suppression opens the microphone again with it, still muted', (async, h) {
      connected(async, h);
      h.voice.toggleMute();
      async.flushMicrotasks();
      h.voice.setNoiseSuppression(false);
      async.flushMicrotasks();
      expect(h.engine.noiseSuppression, [true, false]);
      expect(h.engine.mics.first.stopped, isTrue);
      expect(h.engine.mics.last.stopped, isFalse);
      expect(h.engine.peer.log, contains('mic'));
      expect(h.engine.peer.sending, isFalse);

      h.voice.leave();
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      expect(h.engine.noiseSuppression.last, isFalse);
    });

    _voice('noise suppression toggled quickly reopens the microphone one at a time, the last setting winning', (
      async,
      h,
    ) {
      connected(async, h);
      final peer = h.engine.peer;
      h.engine.holdMic = Completer<void>();
      h.voice.setNoiseSuppression(false);
      async.flushMicrotasks();
      h.voice.setNoiseSuppression(true);
      h.voice.setNoiseSuppression(false);
      h.engine.holdMic!.complete();
      h.engine.holdMic = null;
      async.flushMicrotasks();
      expect(h.engine.noiseSuppression, [true, false]);
      expect(peer.log.where((l) => l == 'mic'), hasLength(1));
      expect(h.engine.mics.first.stopped, isTrue);
      expect(h.engine.mics.last.stopped, isFalse);

      h.voice.setNoiseSuppression(true);
      h.voice.setNoiseSuppression(false);
      h.voice.setNoiseSuppression(true);
      async.flushMicrotasks();
      expect(h.engine.noiseSuppression, [true, false, true]);
      expect(h.engine.mics.where((m) => !m.stopped), hasLength(1));
    });

    _voice('the setting changed while joining opens the microphone again with it', (async, h) {
      h.engine.holdMic = Completer<void>();
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      h.voice.setNoiseSuppression(false);
      h.engine.holdMic!.complete();
      h.engine.holdMic = null;
      async.flushMicrotasks();
      expect(h.engine.noiseSuppression, [true, false]);
      expect(h.engine.mics.first.stopped, isTrue);
      expect(h.engine.mics.last.stopped, isFalse);
    });
  });

  group('sounds', () {
    _voice('others joining, leaving and sharing their screen in the user\'s voice', (async, h) {
      // Not in voice: nothing.
      h.gateway.push(_state('r-lounge', FakeRepository.leo, 1));
      h.voice.joinRoom(_lounge);
      async.flushMicrotasks();
      final me = h.repository.profile.value!.id;
      h.gateway.push(_state('r-lounge', me, 1));
      // Leo was there already, as is a catch-up of him.
      h.gateway.push(_state('r-lounge', FakeRepository.leo, 1));
      h.gateway.push(_state('r-studio', FakeRepository.maya, 1));
      async.flushMicrotasks();
      expect(h.player.played, isEmpty);

      h.gateway.push(_state('r-lounge', FakeRepository.maya, 2));
      h.gateway.push(_state('r-lounge', FakeRepository.maya, 3, screen: true));
      h.gateway.push(_state('r-lounge', FakeRepository.maya, 4, muted: true, screen: true));
      h.gateway.push(_state('r-lounge', FakeRepository.maya, 5));
      h.gateway.push(_state('r-lounge', FakeRepository.maya, 6, joined: false));
      async.flushMicrotasks();
      expect(h.player.played.map((p) => p.$1), [
        Sound.voiceJoin,
        Sound.screenShareOn,
        Sound.screenShareOff,
        Sound.voiceLeave,
      ]);
    });

    _voice('the ring goes while a call rings, and stops however it ends', (async, h) {
      const incoming = duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
      );
      h.gateway.push(incoming);
      async.flushMicrotasks();
      expect(h.player.played, [(Sound.incomingCall, true)]);
      h.voice.acceptCall();
      async.flushMicrotasks();
      expect(h.player.stopped, [Sound.incomingCall]);

      h.voice.hangUp();
      h.gateway.push(incoming);
      async.flushMicrotasks();
      h.voice.declineCall();
      async.flushMicrotasks();
      expect(h.player.stopped, hasLength(2));

      h.gateway.push(incoming);
      async.flushMicrotasks();
      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-leo')));
      async.flushMicrotasks();
      expect(h.player.stopped, hasLength(3));
    });

    // Off screen, the call's notification rings (lib/push/notifications.dart), which the app puts up when no push
    // did: the app's own ring would ring with it. On screen, the app rings, and takes the notification away, again
    // every 2 s while it rings, for a push that was on its way; and it goes once the call rings here no more.
    _voice('off screen a call rings through its notification; on screen the app rings it, and takes that away', (
      async,
      h,
    ) {
      const incoming = duvet.CallIncomingPayloadEvent(
        duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
      );
      h.inFront = false;
      h.gateway.push(incoming);
      async.flushMicrotasks();
      expect(h.player.played, isEmpty);
      expect(h.shownAway, ['c-leo']);

      h.inFront = true;
      h.lifecycle.add(AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(h.player.played, [(Sound.incomingCall, true)]);
      expect(h.hidden, ['c-leo']);
      async.elapse(const Duration(seconds: 2));
      expect(h.hidden, ['c-leo', 'c-leo']);

      h.inFront = false;
      h.lifecycle.add(AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(h.player.stopped, [Sound.incomingCall]);
      expect(h.shownAway, ['c-leo', 'c-leo']);
      async.elapse(const Duration(seconds: 4));
      expect(h.hidden, hasLength(2));

      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-leo')));
      async.flushMicrotasks();
      expect(h.hidden, ['c-leo', 'c-leo', 'c-leo']);
    });

    _voice('with notifications off, the app rings a call off screen itself', (async, h) {
      h.notificationsOn = false;
      h.inFront = false;
      h.gateway.push(
        const duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
        ),
      );
      async.flushMicrotasks();
      expect(h.shownAway, ['c-leo']);
      expect(h.player.played, [(Sound.incomingCall, true)]);
    });

    int answers(FakeVoiceSignaling gateway) => gateway.types.where((t) => t == 'CALL_ACCEPT').length;
    const fromLeo = duvet.CallIncomingPayloadEvent(
      duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
    );

    _voice("Answer on a call's notification accepts it once it rings here", (async, h) {
      h.gateway.ready(number: 1);
      async.flushMicrotasks();
      h.voice.answerWhenRinging('c-leo');
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
      expect(h.voice.call?.phase, CallPhase.connected);
    });

    _voice('an Answer for the call ringing here already accepts it at once', (async, h) {
      h.gateway.ready(number: 1);
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      h.voice.answerWhenRinging('c-leo');
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
      expect(h.voice.call?.phase, CallPhase.connected);
    });

    _voice("an Answer while the gateway is out of reach answers once it's back", (async, h) {
      h.gateway.ready(number: 1);
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      h.gateway.socket = null;
      h.voice.answerWhenRinging('c-leo');
      async.flushMicrotasks();
      expect(answers(h.gateway), 0);
      expect(h.voice.call?.phase, CallPhase.ringing);
      h.gateway.resumed();
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
      expect(h.voice.call?.phase, CallPhase.connected);
      expect(h.notices, isEmpty);
    });

    _voice('an Answer for the call a READY lists as ringing answers it', (async, h) {
      h.voice.answerWhenRinging('c-leo');
      h.gateway.ready(
        number: 1,
        calls: const [
          duvet.GatewayReadyActiveCall(
            conversationId: 'c-leo',
            initiatorId: FakeRepository.leo,
            initiatorName: 'Leo',
            ringing: true,
            answered: false,
          ),
        ],
      );
      async.flushMicrotasks();
      expect(answers(h.gateway), 1);
    });

    _voice("an Answer for a call that ended, or that a READY doesn't list, doesn't answer the next one there", (
      async,
      h,
    ) {
      h.gateway.ready(number: 1);
      async.flushMicrotasks();
      h.voice.answerWhenRinging('c-leo');
      h.gateway.push(const duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: 'c-leo')));
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      expect(answers(h.gateway), 0);
      h.voice.declineCall();
      async.flushMicrotasks();

      h.voice.answerWhenRinging('c-leo');
      h.gateway.ready(number: 2);
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      expect(answers(h.gateway), 0);
      expect(h.voice.call?.phase, CallPhase.ringing);
    });

    _voice('an Answer for another call, or older than a ring lasts, accepts nothing', (async, h) {
      h.gateway.ready(number: 1);
      async.flushMicrotasks();
      h.voice.answerWhenRinging('c-maya');
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      expect(answers(h.gateway), 0);
      expect(h.voice.call?.phase, CallPhase.ringing);
      h.voice.declineCall();
      async.flushMicrotasks();

      h.voice.answerWhenRinging('c-leo');
      h.now = h.now.add(const Duration(seconds: 31));
      h.gateway.push(fromLeo);
      async.flushMicrotasks();
      expect(answers(h.gateway), 0);
      expect(h.voice.call?.phase, CallPhase.ringing);
    });
  });

  test('the ring stops when the controller goes', () {
    fakeAsync((async) {
      final repository = FakeRepository()..restore();
      final player = _Player();
      final voice = VoiceController(
        repository: repository,
        engine: FakeVoiceEngine(),
        historyStore: MemoryCallHistoryStore(),
        sounds: Sounds(player: player, ringer: _Ringer()),
        // A ring asks whether Duvet is on screen, which the app's binding says.
        inFront: () => true,
        lifecycle: const Stream.empty(),
      );
      async.flushMicrotasks();
      repository.voiceSignaling.push(
        const duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(conversationId: 'c-leo', initiatorId: FakeRepository.leo, initiatorName: 'Leo'),
        ),
      );
      async.flushMicrotasks();
      expect(player.played, [(Sound.incomingCall, true)]);
      voice.dispose();
      async.flushMicrotasks();
      expect(player.stopped, [Sound.incomingCall]);
      repository.dispose();
      async.flushMicrotasks();
    });
  });

  test('a session refused at launch forgets the call histories kept on the phone', () {
    fakeAsync((async) {
      final repository = FakeRepository(signedIn: false);
      final store = MemoryCallHistoryStore()..data['0a0a0a0a-0000-4000-8000-0000000000ff'] = '[]';
      final voice = VoiceController(repository: repository, engine: FakeVoiceEngine(), historyStore: store);
      repository.restore();
      // No profile ever came: the server refused the saved session.
      repository.endSession();
      async.flushMicrotasks();
      expect(store.data, isEmpty);
      voice.dispose();
      repository.dispose();
      async.flushMicrotasks();
    });
  });
}
