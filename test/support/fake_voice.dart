import 'dart:async';

import 'package:duvet/data/voice_engine.dart';
import 'package:duvet/data/voice_signaling.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

/// A gateway for voice: it keeps what's sent, and tests push what the gateway
/// would send.
class FakeVoiceSignaling implements VoiceSignaling {
  final _events = StreamController<duvet.GatewayEventPayload>.broadcast(sync: true);
  final _resumes = StreamController<void>.broadcast(sync: true);

  /// The open socket's number; null while the gateway is out of reach.
  int? socket = 1;

  @override
  Duration silenceBeforeReady = Duration.zero;

  /// What went out, as `TYPE` and its data.
  final sent = <(String, Map<String, Object?>)>[];

  List<String> get types => [for (final (type, _) in sent) type];

  /// The data of the last [type] sent.
  Map<String, Object?>? last(String type) => sent.lastWhere((s) => s.$1 == type, orElse: () => (type, const {})).$2;

  void push(duvet.GatewayEventPayload event) => _events.add(event);

  /// How many times voice asked for the next socket to start a new session.
  int freshSessionsWanted = 0;

  @override
  void wantFreshSession() => freshSessionsWanted++;

  @override
  Stream<void> get resumes => _resumes.stream;

  /// The gateway resumed the session on socket [number]: it goes on, with no
  /// READY.
  void resumed({int number = 2}) {
    socket = number;
    _resumes.add(null);
  }

  /// A new session: READY, on socket [number].
  void ready({
    int number = 2,
    Duration silence = Duration.zero,
    List<duvet.GatewayReadyActiveCall> calls = const [],
    List<duvet.IceServer> iceServers = const [],
  }) {
    socket = number;
    silenceBeforeReady = silence;
    push(
      duvet.ReadyEvent(
        duvet.GatewayReadyData(
          user: duvet.GatewayUser.fromJson({
            'id': 'me',
            'username': 'gaby',
            'created_at': '2026-10-23T09:00:00Z',
            'updated_at': '2026-10-23T09:00:00Z',
          }),
          sessionToken: 'session-$number',
          activeCalls: calls,
          iceServers: iceServers,
        ),
      ),
    );
  }

  bool _send(String type, Map<String, Object?> data) {
    if (socket == null) return false;
    sent.add((type, data));
    return true;
  }

  @override
  Stream<duvet.GatewayEventPayload> get events => _events.stream;

  @override
  int? get connection => socket;

  @override
  bool joinVoice(String roomId, duvet.SessionDescription offer, {required bool videoOff}) =>
      _send('VOICE_JOIN', {'room_id': roomId, 'offer': offer.sdp, 'video_off': videoOff});

  @override
  bool leaveVoice(String roomId) => _send('VOICE_LEAVE', {'room_id': roomId});

  @override
  bool syncVoice(
    String roomId, {
    required bool muted,
    required bool deafened,
    required bool screenSharing,
    required bool camera,
    required bool videoOff,
  }) => _send('VOICE_SYNC', {
    'room_id': roomId,
    'muted': muted,
    'deafened': deafened,
    'screen_sharing': screenSharing,
    'camera': camera,
    'video_off': videoOff,
  });

  @override
  bool sendIceCandidate(String roomId, duvet.IceCandidateInit candidate) =>
      _send('WEBRTC_ICE_CANDIDATE', {'room_id': roomId, 'candidate': candidate.candidate});

  @override
  bool sendAnswer(String roomId, duvet.SessionDescription answer) =>
      _send('WEBRTC_ANSWER', {'room_id': roomId, 'answer': answer.sdp});

  @override
  bool initiateCall(String conversationId, List<String> memberIds) =>
      _send('CALL_INITIATE', {'conversation_id': conversationId, 'member_ids': memberIds});

  @override
  bool acceptCall(String conversationId) => _send('CALL_ACCEPT', {'conversation_id': conversationId});

  @override
  bool declineCall(String conversationId) => _send('CALL_DECLINE', {'conversation_id': conversationId});

  @override
  bool cancelCall(String conversationId) => _send('CALL_CANCEL', {'conversation_id': conversationId});

  @override
  bool leaveCall(String conversationId) => _send('CALL_LEAVE', {'conversation_id': conversationId});

  void dispose() {
    _events.close();
    _resumes.close();
  }
}

/// A microphone that is only a name.
class FakeMic implements VoiceMic {
  bool stopped = false;

  @override
  Future<void> stop() async => stopped = true;
}

/// A peer connection that keeps what it was told.
class FakePeer implements VoicePeer {
  final int number;
  FakePeer(this.number);

  void Function(duvet.IceCandidateInit candidate)? candidateHandler;
  void Function(PeerState state)? stateHandler;

  @override
  set onIceCandidate(void Function(duvet.IceCandidateInit candidate)? handler) => candidateHandler = handler;

  @override
  set onState(void Function(PeerState state)? handler) => stateHandler = handler;

  /// What happened to it, in order: `audio mic`, `sending true`, `remote answer v1`…
  final log = <String>[];
  final candidates = <String>[];
  bool closed = false;
  bool sending = false;
  bool receiving = true;
  AudioLevels levels = (local: null, remote: const {});

  /// The gateway's offers fail to apply while set.
  bool failOffers = false;

  @override
  Future<void> addAudio(VoiceMic? mic) async => log.add(mic == null ? 'audio none' : 'audio mic');

  @override
  Future<void> useMicrophone(VoiceMic mic) async => log.add('mic');

  @override
  Future<void> setSending(bool sending) async {
    this.sending = sending;
    log.add('sending $sending');
  }

  @override
  Future<void> setReceiving(bool receiving) async => this.receiving = receiving;

  @override
  Future<duvet.SessionDescription> createOffer() async => duvet.SessionDescription(type: 'offer', sdp: 'offer-$number');

  @override
  Future<duvet.SessionDescription> createAnswer() async =>
      duvet.SessionDescription(type: 'answer', sdp: 'answer-$number-${log.length}');

  @override
  Future<void> setLocalDescription(duvet.SessionDescription description) async =>
      log.add('local ${description.type} ${description.sdp}');

  @override
  Future<void> setRemoteDescription(duvet.SessionDescription description) async {
    if (failOffers && description.type == 'offer') throw StateError('can’t apply ${description.sdp}');
    log.add('remote ${description.type} ${description.sdp}');
  }

  @override
  Future<void> addIceCandidate(duvet.IceCandidateInit candidate) async => candidates.add(candidate.candidate);

  /// How many times the levels were read (WebRTC's getStats).
  int reads = 0;

  @override
  Future<AudioLevels> audioLevels() async {
    reads++;
    return levels;
  }

  @override
  Future<void> close() async => closed = true;
}

/// A phone without WebRTC: it hands out [FakePeer]s and [FakeMic]s.
class FakeVoiceEngine implements VoiceEngine {
  /// Whether the user lets the microphone open.
  bool micAllowed = true;
  final mics = <FakeMic>[];
  final peers = <FakePeer>[];
  final iceServers = <List<duvet.IceServer>>[];
  final keptAlive = <String>[];
  int sleeps = 0;
  int prepared = 0;
  final defaults = <bool>[];
  final selected = <AudioRoute>[];

  /// Holds openMicrophone while set: the permission dialog.
  Completer<void>? holdMic;

  /// Holds createPeer while set.
  Completer<void>? holdPeer;

  FakePeer get peer => peers.last;

  @override
  final ValueNotifier<AudioRoutes> routes = ValueNotifier(AudioRoutes.none);

  @override
  Future<void> prepare() async => prepared++;

  @override
  Future<VoiceMic?> openMicrophone() async {
    if (holdMic case final hold?) await hold.future;
    if (!micAllowed) return null;
    final mic = FakeMic();
    mics.add(mic);
    return mic;
  }

  @override
  Future<VoicePeer> createPeer(List<duvet.IceServer> iceServers) async {
    if (holdPeer case final hold?) await hold.future;
    this.iceServers.add(iceServers);
    final peer = FakePeer(peers.length + 1);
    peers.add(peer);
    return peer;
  }

  @override
  Future<void> selectRoute(AudioRoute route) async {
    selected.add(route);
    routes.value = AudioRoutes(available: routes.value.available, current: route);
  }

  @override
  Future<void> useDefaultRoute({required bool speaker}) async => defaults.add(speaker);

  @override
  Future<void> keepAlive(String title) async => keptAlive.add(title);

  @override
  Future<void> letSleep() async => sleeps++;
}
