// The voice controller against a fake gateway and a fake WebRTC: joining and
// negotiating as desktop's VoiceChat does, the whole state in every
// VOICE_SYNC, a new session (READY) joining again, and calls.
import 'dart:async';

import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/data/voice_engine.dart' show PeerState;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

const _lounge = Room(id: 'r-lounge', spaceId: 's-guild', name: 'lounge', kind: RoomKind.voice, position: 1);
const _studio = Room(id: 'r-studio', spaceId: 's-guild', name: 'studio', kind: RoomKind.voice, position: 2);
const _attic = Room(id: 'r-attic', spaceId: 's-guild', name: 'attic', kind: RoomKind.voice, position: 3);

/// The whole voice state the phone always sends.
Map<String, Object?> _sync({bool muted = false, bool deafened = false, String room = 'r-lounge'}) => {
  'room_id': room,
  'muted': muted,
  'deafened': deafened,
  'screen_sharing': false,
  'camera': false,
  'video_off': true,
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

duvet.VoiceStateUpdatedEvent _state(String room, String user, int version, {bool joined = true, bool muted = false}) =>
    duvet.VoiceStateUpdatedEvent(
      duvet.VoiceStateEvent(roomId: room, userId: user, joined: joined, muted: muted, version: version),
    );

class _Harness {
  final repository = FakeRepository();
  final engine = FakeVoiceEngine();
  final history = MemoryCallHistoryStore();
  late final VoiceController voice;
  final notices = <String>[];
  DateTime now = DateTime(2026, 10, 23, 10);

  /// Duvet on screen, not behind another app or a locked screen.
  bool inFront = true;

  FakeVoiceSignaling get gateway => repository.voiceSignaling;

  _Harness(FakeAsync async) {
    repository.restore();
    voice = VoiceController(
      repository: repository,
      engine: engine,
      historyStore: history,
      clock: () => now,
      inFront: () => inFront,
    );
    voice.notices.listen(notices.add);
    async.flushMicrotasks();
  }

  void dispose() {
    voice.dispose();
    repository.dispose();
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
    expect(h.engine.peer.log, ['audio mic', 'sending true', 'local offer offer-1']);
    expect(h.gateway.types, ['VOICE_JOIN', 'VOICE_SYNC']);
    expect(h.gateway.last('VOICE_JOIN'), {'room_id': 'r-lounge', 'offer': 'offer-1', 'video_off': true});
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
