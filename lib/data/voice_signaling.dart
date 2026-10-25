import 'dart:async';

import 'package:duvet_client/duvet.dart' as duvet;

/// What the voice controller needs of the gateway: the events voice and calls
/// follow, the messages that join, negotiate and leave, and whether a socket
/// is open to send them on. [GatewayVoiceSignaling] is the real one; tests
/// pass a fake.
///
/// Every send answers whether the message went out: false while no socket is
/// open, when it would be lost.
abstract interface class VoiceSignaling {
  /// READY, SPACE_CREATE, SPACE_DELETE, ROOM_DELETE and the voice and call
  /// events, as they arrive.
  Stream<duvet.GatewayEventPayload> get events;

  /// The number of the gateway socket open now, or null while none is. A
  /// socket the gateway resumed the session on carries on the one before;
  /// any other gets a READY: a session of its own.
  int? get connection;

  /// How long the gateway had been silent before its last READY: how long
  /// the phone was cut off (asleep, say) before this session.
  Duration get silenceBeforeReady;

  /// Makes the next socket start a new session, with READY, rather than
  /// resume this one, until a READY comes: voice joins on READY, which a
  /// resumed session doesn't send.
  void wantFreshSession();

  /// Fires when the gateway took the session up again on a new socket, with
  /// no READY: what went out on the socket that dropped, still unanswered,
  /// may have been lost with it.
  Stream<void> get resumes;

  bool joinVoice(String roomId, duvet.SessionDescription offer, {required bool videoOff});
  bool leaveVoice(String roomId);

  /// The client's whole voice state: the gateway turns off whatever a sync
  /// leaves out, so every field is required.
  bool syncVoice(
    String roomId, {
    required bool muted,
    required bool deafened,
    required bool screenSharing,
    required bool camera,
    required bool videoOff,
  });
  bool sendIceCandidate(String roomId, duvet.IceCandidateInit candidate);
  bool sendAnswer(String roomId, duvet.SessionDescription answer);

  bool initiateCall(String conversationId, List<String> memberIds);
  bool acceptCall(String conversationId);
  bool declineCall(String conversationId);
  bool cancelCall(String conversationId);
  bool leaveCall(String conversationId);
}

/// [VoiceSignaling] over the session's gateway, which changes as the user
/// signs in and out: the repository [attach]es each one and passes on its
/// events through [deliver].
class GatewayVoiceSignaling implements VoiceSignaling {
  final _events = StreamController<duvet.GatewayEventPayload>.broadcast();
  final _resumes = StreamController<void>.broadcast();
  duvet.GatewayManager? _manager;
  duvet.WebRTCController? _rtc;
  StreamSubscription<duvet.GatewayResume>? _resumed;

  /// The gateway of a new session.
  void attach(duvet.GatewayManager manager) {
    detach();
    _manager = manager;
    _rtc = duvet.WebRTCController(manager);
    _resumed = manager.onResume.listen((_) {
      if (!_resumes.isClosed) _resumes.add(null);
    });
  }

  /// The session ended: nothing goes out until the next one.
  void detach() {
    _resumed?.cancel();
    _resumed = null;
    _rtc?.dispose();
    _rtc = null;
    _manager = null;
  }

  /// Passes on one of the gateway's events, if voice follows it.
  void deliver(duvet.GatewayEventPayload event) {
    if (_events.isClosed || !_follows(event)) return;
    _events.add(event);
  }

  static bool _follows(duvet.GatewayEventPayload event) => switch (event) {
    duvet.ReadyEvent() ||
    duvet.SpaceCreateEvent() ||
    duvet.SpaceDeletedEvent() ||
    duvet.RoomDeletedEvent() ||
    duvet.VoiceStateUpdatedEvent() ||
    duvet.VoiceJoinedPayloadEvent() ||
    duvet.VoiceSessionReplacedPayloadEvent() ||
    duvet.WebRTCIceCandidateEvent() ||
    duvet.WebRTCRenegotiateEvent() ||
    duvet.WebRTCRenegotiateAnswerEvent() ||
    duvet.CallIncomingPayloadEvent() ||
    // The gateway's word that a call the user placed is going on; a gateway
    // from before calls across devices doesn't send it.
    duvet.CallOutgoingPayloadEvent() ||
    duvet.CallAcceptedEvent() ||
    duvet.CallDeclinedEvent() ||
    duvet.CallEndedPayloadEvent() => true,
    _ => false,
  };

  @override
  Stream<duvet.GatewayEventPayload> get events => _events.stream;

  @override
  int? get connection => _manager?.connection;

  @override
  Duration get silenceBeforeReady => _manager?.silenceBeforeReady ?? Duration.zero;

  @override
  void wantFreshSession() => _manager?.wantFreshSession();

  @override
  Stream<void> get resumes => _resumes.stream;

  @override
  bool joinVoice(String roomId, duvet.SessionDescription offer, {required bool videoOff}) =>
      _rtc?.joinVoice(roomId, offer, videoOff: videoOff) ?? false;

  @override
  bool leaveVoice(String roomId) => _rtc?.leaveVoice(roomId) ?? false;

  @override
  bool syncVoice(
    String roomId, {
    required bool muted,
    required bool deafened,
    required bool screenSharing,
    required bool camera,
    required bool videoOff,
  }) =>
      _rtc?.syncVoice(
        roomId,
        muted: muted,
        deafened: deafened,
        screenSharing: screenSharing,
        camera: camera,
        videoOff: videoOff,
      ) ??
      false;

  @override
  bool sendIceCandidate(String roomId, duvet.IceCandidateInit candidate) =>
      _rtc?.sendIceCandidate(roomId, candidate) ?? false;

  @override
  bool sendAnswer(String roomId, duvet.SessionDescription answer) => _rtc?.sendAnswer(roomId, answer) ?? false;

  @override
  bool initiateCall(String conversationId, List<String> memberIds) =>
      _rtc?.initiateCall(conversationId, memberIds) ?? false;

  @override
  bool acceptCall(String conversationId) => _rtc?.acceptCall(conversationId) ?? false;

  @override
  bool declineCall(String conversationId) => _rtc?.declineCall(conversationId) ?? false;

  @override
  bool cancelCall(String conversationId) => _rtc?.cancelCall(conversationId) ?? false;

  @override
  bool leaveCall(String conversationId) => _rtc?.leaveCall(conversationId) ?? false;

  void dispose() {
    detach();
    _events.close();
    _resumes.close();
  }
}
