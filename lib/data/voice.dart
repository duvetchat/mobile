/// Voice rooms and calls: who's in voice where, the user's own voice
/// connection, and the calls that ring.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import 'call_history.dart';
import 'models.dart';
import 'repository.dart';
import 'voice_engine.dart';
import 'voice_signaling.dart';

export 'call_history.dart' show CallHistory, CallOutcome, CallRecord;
export 'voice_engine.dart' show AudioRoute, AudioRouteKind, AudioRoutes;

/// Where the user's voice is: a space's voice room, or a conversation's call.
sealed class VoiceTarget {
  const VoiceTarget();

  /// What the gateway calls its room: the room's ID, or the conversation's.
  String get id;
}

final class RoomVoice extends VoiceTarget {
  final String spaceId;
  final String roomId;
  const RoomVoice({required this.spaceId, required this.roomId});

  @override
  String get id => roomId;

  @override
  bool operator ==(Object other) => other is RoomVoice && other.roomId == roomId;

  @override
  int get hashCode => Object.hash(RoomVoice, roomId);
}

final class CallVoice extends VoiceTarget {
  final String conversationId;
  const CallVoice(this.conversationId);

  @override
  String get id => conversationId;

  @override
  bool operator ==(Object other) => other is CallVoice && other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(CallVoice, conversationId);
}

/// How far the user's voice connection is.
enum VoiceLink {
  /// Opening the microphone.
  starting,

  /// The gateway is out of reach: its next session joins.
  waiting,

  /// Joining: the gateway and the phone negotiate.
  connecting,
  connected,

  /// The connection dropped; the gateway restarts it.
  reconnecting,
}

enum CallPhase {
  /// Ringing here: someone calls.
  ringing,

  /// Called from here; nobody answered yet.
  calling,

  /// Answered: the call's voice joins.
  connected,
}

/// The call this device rings for, places or is in.
class ActiveCall {
  final String conversationId;
  final String initiatorId;
  final String initiatorName;
  final bool outgoing;
  final CallPhase phase;

  /// When it rang, or was placed.
  final DateTime startedAt;

  /// When its voice first connected here: the talk counts from then.
  final DateTime? connectedAt;

  const ActiveCall({
    required this.conversationId,
    required this.initiatorId,
    required this.initiatorName,
    required this.outgoing,
    required this.phase,
    required this.startedAt,
    this.connectedAt,
  });

  ActiveCall _copy({CallPhase? phase, DateTime? connectedAt}) => ActiveCall(
    conversationId: conversationId,
    initiatorId: initiatorId,
    initiatorName: initiatorName,
    outgoing: outgoing,
    phase: phase ?? this.phase,
    startedAt: startedAt,
    connectedAt: connectedAt ?? this.connectedAt,
  );

  ActiveCall answered() => _copy(phase: CallPhase.connected);
}

/// A voice level (0–1, linear) as a face's mouth opens: shut below
/// [speakingLevel], wide open at [speakingLevel] + [mouthRange].
///
/// The desktop app meters a frequency analyser instead; these numbers are
/// for WebRTC's audio levels, and want checking against real voices.
double mouthFor(double level) => level <= speakingLevel ? 0 : math.min(1, (level - speakingLevel) / mouthRange);

/// Quieter than this is silence (about −34 dBFS).
const speakingLevel = 0.02;

/// How much louder than [speakingLevel] opens a mouth wide.
const mouthRange = 0.2;

/// Voice rooms and calls, as desktop's `VoiceChat` and the call parts of its
/// gateway connection do them, through [VoiceSignaling] and [VoiceEngine].
///
/// One voice at a time: a room's or a call's. Joining opens the microphone,
/// starts the foreground service, and sends VOICE_JOIN with the peer
/// connection's offer; the gateway answers with VOICE_JOINED, then its own
/// offers (WEBRTC_RENEGOTIATE) as people's audio comes and goes. Each new
/// gateway session (READY) joins again, unless voice had been out of reach
/// for longer than [rejoinWindow]; a join made while the gateway is out of
/// reach waits for its next session, [rejoinWindow] at most, and one it
/// doesn't answer in [joinTimeout] leaves. Video is out: the phone asks for
/// none (`video_off`) and sends none.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required ChatRepository repository,
    required VoiceEngine engine,
    required CallHistoryStore historyStore,
    this.joinTimeout = const Duration(seconds: 15),
    this.rejoinWindow = const Duration(minutes: 3),
    this.levelInterval = const Duration(milliseconds: 200),
    DateTime Function()? clock,
    @visibleForTesting bool Function()? inFront,
  }) : _repository = repository,
       _signaling = repository.voiceSignaling,
       _engine = engine,
       _now = clock ?? DateTime.now,
       _inFront = inFront ?? _appInFront,
       history = CallHistory(historyStore) {
    _events = _signaling.events.listen(_onEvent);
    _signedOut = _repository.signedOut.listen((_) => _onSignedOut());
    _repository.profile.addListener(_onProfile);
    _repository.spaces.addListener(_checkSpeak);
    _onProfile();
  }

  final ChatRepository _repository;
  final VoiceSignaling _signaling;
  final VoiceEngine _engine;
  final DateTime Function() _now;
  late final StreamSubscription<duvet.GatewayEventPayload> _events;
  late final StreamSubscription<void> _signedOut;

  // Duvet on screen: not behind another app, nor under a locked screen.
  final bool Function() _inFront;
  static bool _appInFront() => switch (SchedulerBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  /// How long the gateway has to answer a join.
  final Duration joinTimeout;

  /// After this long without a word from the gateway (the phone slept, say),
  /// a new session leaves voice rather than join again: the microphone
  /// mustn't open by surprise. A gateway restart takes far less.
  final Duration rejoinWindow;

  /// How often the voices' levels are read, for the faces' mouths.
  final Duration levelInterval;

  /// The calls this device saw.
  final CallHistory history;

  /// Now, by the controller's clock: a call's clock counts from its
  /// [ActiveCall.connectedAt] by it.
  DateTime now() => _now();

  String? _me;

  // ---------------------------------------------------------------------------
  // Who's in voice where
  // ---------------------------------------------------------------------------

  final _states = duvet.VoiceStates();

  /// Who's in the voice of [roomId]: a room, or a call's conversation.
  List<duvet.VoiceParticipant> participants(String roomId) => _states.participantsIn(roomId);

  /// How open each speaker's mouth is (0–1), by user ID; the silent are left
  /// out. Read every [levelInterval] while connected, as long as something
  /// listens (a screen showing the faces) with Duvet in front: WebRTC's stats
  /// cost a call into the platform each time.
  ValueNotifier<Map<String, double>> get levels => _levels;
  final _levels = _Levels();

  /// Conversations with a call going on.
  Set<String> get callsInProgress => _calls;
  Set<String> _calls = const {};

  // ---------------------------------------------------------------------------
  // The user's own voice
  // ---------------------------------------------------------------------------

  VoiceTarget? _target;

  /// Where the user's voice is, or null.
  VoiceTarget? get target => _target;

  VoiceLink? _link;

  /// How far it is, while [target] is set.
  VoiceLink? get link => _link;

  bool _muted = false;
  bool _deafened = false;
  bool _canSpeak = true;

  /// What the gateway shows of the user: muted (or, without a microphone, not
  /// sending), deafened. They outlast a session, as on the desktop, but not
  /// the account.
  bool get muted => _muted;
  bool get deafened => _deafened;

  /// Whether the user may speak where they are (SpeakInVoice in a room).
  bool get canSpeak => _canSpeak;

  /// Where the sound plays.
  ValueListenable<AudioRoutes> get routes => _engine.routes;

  ActiveCall? _call;

  /// The call ringing, placed or going on here.
  ActiveCall? get call => _call;

  /// In a voice room or a call, or placing one: the microphone and the
  /// phone's call audio are voice's.
  bool get inVoice => _target != null || _call?.phase == CallPhase.calling;

  // The gateway socket this phone placed or answered [_call] on.
  int? _callOn;

  // The gateway ends a call nobody answered this long after it rang.
  static const _ringTimeout = Duration(seconds: 30);

  final _notices = StreamController<String>.broadcast();

  /// What to tell the user: a join that failed, voice that moved away.
  Stream<String> get notices => _notices.stream;

  // The connection of the current target, and those it replaced, until it
  // exists (see [_connect]).
  VoicePeer? _peer;
  final _retired = <VoicePeer>[];
  VoiceMic? _mic;
  bool _keptAlive = false;

  // Got as far as joining: from then on each new session (READY) joins again.
  bool _joining = false;

  // The gateway socket the last VOICE_JOIN went out on.
  int? _joinedOn;

  // When the user asked for this voice: a join made offline counts its wait
  // from then, not from the gateway's last word.
  DateTime? _askedAt;

  // Leaves once the gateway has been out of reach for [rejoinWindow].
  Timer? _waitTimer;

  // Counts sessions (each join) and connection attempts, so work for an
  // older one stops when it resumes.
  int _session = 0;
  int _generation = 0;

  bool _negotiationReady = false;
  bool _remoteSet = false;

  // This connection's VOICE_JOINED came.
  bool _answered = false;
  final _pendingCandidates = <duvet.IceCandidateInit>[];
  Future<void> _negotiations = Future.value();

  // The gateway's offers that failed in a row: each starts the connection over.
  int _failedOffers = 0;

  // Completes once VOICE_JOINED was applied: the gateway's offers wait for it.
  Completer<void> _joined = Completer()..complete();
  Timer? _joinTimer;
  Timer? _levelTimer;
  bool _readingLevels = false;

  // READY's STUN and TURN servers (the TURN credentials are the account's);
  // STUN alone until the first READY.
  List<duvet.IceServer> _iceServers = _stun;
  static const _stun = [
    duvet.IceServer(urls: ['stun:stun.l.google.com:19302']),
  ];

  // ---------------------------------------------------------------------------
  // Voice rooms
  // ---------------------------------------------------------------------------

  /// Whether the user may join [room]'s voice: ViewChannels and JoinVoice,
  /// as the gateway checks them.
  bool canJoin(Room room) =>
      _repository.canInRoom(room.spaceId, room.id, Perm.viewChannels) &&
      _repository.canInRoom(room.spaceId, room.id, Perm.joinVoice);

  /// Joins [room]'s voice, leaving any other voice, or call, first.
  Future<void> joinRoom(Room room) async {
    final target = RoomVoice(spaceId: room.spaceId, roomId: room.id);
    if (_target == target) return;
    if (!canJoin(room)) {
      _notice('You can’t join this voice room');
      return;
    }
    _leaveCurrent();
    _canSpeak = _speakAllowed(target);
    if (!_canSpeak) _muted = true;
    await _begin(target, speaker: true);
  }

  /// Leaves the voice room, or hangs up the call (one placed included).
  void leave() {
    switch (_target) {
      case RoomVoice():
        _teardown(sendLeave: true);
        notifyListeners();
      case CallVoice():
        hangUp();
      case null:
        if (_call?.phase == CallPhase.calling) hangUp();
    }
  }

  bool _speakAllowed(RoomVoice t) => _repository.canInRoom(t.spaceId, t.roomId, Perm.speakInVoice);

  // A role or an overwrite changed: without SpeakInVoice the user is muted,
  // as the gateway already shows them.
  void _checkSpeak() {
    final target = _target;
    if (target is! RoomVoice) return;
    final can = _speakAllowed(target);
    if (can == _canSpeak) return;
    _canSpeak = can;
    if (!can && !_muted) {
      _muted = true;
      _sync();
      unawaited(_applyAudio());
      _notice('You can’t speak in this room now');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Microphone and sound
  // ---------------------------------------------------------------------------

  bool get _sending => _mic != null && !_muted && !_deafened;

  /// Mutes, or unmutes: then the microphone opens if it isn't, and a deafened
  /// user hears again.
  Future<void> toggleMute() async {
    final target = _target;
    if (target == null) return;
    if (!_muted) {
      _muted = true;
    } else {
      if (!_canSpeak) {
        _notice('You can’t speak in this room');
        return;
      }
      // While joining, the microphone is opening already.
      if (_mic == null && _link != VoiceLink.starting) {
        final session = _session;
        final mic = await _engine.openMicrophone();
        if (session != _session) {
          await mic?.stop();
          return;
        }
        if (_mic != null) {
          // Another tap opened one meanwhile.
          await mic?.stop();
        } else if (mic == null) {
          _notice('Allow Duvet to use the microphone to talk');
          return;
        } else {
          _mic = mic;
          await _peer?.useMicrophone(mic);
          _keepAlive(target);
        }
      }
      _muted = false;
      _deafened = false;
    }
    _sync();
    notifyListeners();
    await _applyAudio();
  }

  /// Deafens, which mutes too, or hears again (still muted).
  Future<void> toggleDeafen() async {
    if (_target == null) return;
    _deafened = !_deafened;
    if (_deafened) _muted = true;
    _sync();
    notifyListeners();
    await _applyAudio();
  }

  Future<void> selectRoute(AudioRoute route) => _engine.selectRoute(route);

  Future<void> _applyAudio() async {
    final peer = _peer;
    if (peer == null) return;
    try {
      await peer.setSending(_sending);
      await peer.setReceiving(!_deafened);
    } catch (e) {
      debugPrint('voice: $e');
    }
  }

  /// VOICE_SYNC with the whole state: the gateway turns off what a sync
  /// leaves out. No video, ever.
  void _sync() {
    final target = _target;
    if (target == null) return;
    _signaling.syncVoice(
      target.id,
      muted: _muted,
      deafened: _deafened,
      screenSharing: false,
      camera: false,
      videoOff: true,
    );
  }

  void _keepAlive(VoiceTarget target) {
    if (_keptAlive) return;
    _keptAlive = true;
    // Naming nobody: the notification shows on the lock screen, and
    // flutter_background keeps its title in plain SharedPreferences.
    unawaited(
      _engine.keepAlive(switch (target) {
        RoomVoice() => 'In a voice room',
        CallVoice() => 'In a call',
      }),
    );
  }

  String? _conversationTitle(String id) => _repository.conversations.value.where((c) => c.id == id).firstOrNull?.title;

  // ---------------------------------------------------------------------------
  // Joining, as desktop's VoiceChat does
  // ---------------------------------------------------------------------------

  // Opens the microphone (when the user may speak), keeps the app alive, and
  // joins.
  Future<void> _begin(VoiceTarget target, {required bool speaker}) async {
    final session = ++_session;
    _target = target;
    _link = VoiceLink.starting;
    _joining = false;
    _joinedOn = null;
    _askedAt = _now();
    _failedOffers = 0;
    notifyListeners();

    await _engine.prepare();
    if (session != _session) return;
    var refused = false;
    // A call placed from here opened it already (see [startCall]).
    if (_canSpeak && _mic == null) {
      final mic = await _engine.openMicrophone();
      if (session != _session) {
        // Left while the microphone opened.
        await mic?.stop();
        return;
      }
      _mic = mic;
      if (mic == null) {
        _muted = true;
        refused = true;
      }
    }
    if (_mic != null) {
      _keepAlive(target);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      // Android starts a microphone service only with the microphone open:
      // without one, nothing keeps voice going once Duvet is in the background.
      _notice('${refused ? 'Duvet can’t use the microphone. ' : ''}Listening only: keep Duvet open to stay in voice');
    } else if (refused) {
      _notice('Duvet can’t use the microphone: you’re listening only');
    }
    unawaited(_engine.useDefaultRoute(speaker: speaker));
    _joining = true;
    await _connect();
  }

  Future<void> _connect() async {
    final target = _target;
    if (target == null) return;
    final generation = ++_generation;
    _joinTimer?.cancel();
    _negotiationReady = false;
    _remoteSet = false;
    _answered = false;
    _pendingCandidates.clear();
    _negotiations = Future.value();
    if (!_joined.isCompleted) _joined.complete();
    _joined = Completer<void>();

    if (_signaling.connection == null) {
      // The gateway is out of reach, and a VOICE_JOIN now would be lost: its
      // next session's READY joins.
      _setLink(VoiceLink.waiting);
      return;
    }
    _setLink(VoiceLink.connecting);

    // The connections this one replaces close only once it exists: on
    // Android, a moment without any ends the call's audio session, and a new
    // connection doesn't start it again.
    if (_peer case final old?) _retired.add(old);
    _peer = null;
    final VoicePeer peer;
    try {
      peer = await _engine.createPeer(_iceServers);
    } catch (e) {
      debugPrint('voice: $e');
      if (generation == _generation && _target == target) _fail('Couldn’t connect to voice');
      return;
    }
    if (generation != _generation || _target != target) {
      // A newer attempt replaces this one, or the user left.
      if (_target == null) {
        unawaited(peer.close());
      } else {
        _retired.add(peer);
      }
      return;
    }
    _closeRetired();
    _peer = peer;
    peer.onIceCandidate = (c) {
      if (identical(_peer, peer)) _signaling.sendIceCandidate(target.id, c);
    };
    peer.onState = (s) => _onPeerState(peer, s);

    try {
      await peer.addAudio(_mic);
      await peer.setSending(_sending);
      await peer.setReceiving(!_deafened);
      final offer = await peer.createOffer();
      if (!identical(_peer, peer)) return;
      await peer.setLocalDescription(offer);
      if (!identical(_peer, peer)) return;
      // The socket can have closed meanwhile.
      final connection = _signaling.connection;
      if (connection == null) {
        _setLink(VoiceLink.waiting);
        return;
      }
      _signaling.joinVoice(target.id, offer, videoOff: true);
      _joinedOn = connection;
      _sync();
    } catch (e) {
      debugPrint('voice: $e');
      if (identical(_peer, peer)) _fail('Couldn’t connect to voice');
      return;
    }

    // The gateway answers a join it refuses with nothing: one unanswered for
    // long leaves, rather than wait with the microphone open. With the gateway
    // gone by then, its next session joins again.
    _joinTimer = Timer(joinTimeout, () {
      if (generation != _generation || _target != target || _negotiationReady) return;
      if (_signaling.connection == null) {
        _setLink(VoiceLink.waiting);
        return;
      }
      _fail('Couldn’t connect to voice');
    });
  }

  void _onPeerState(VoicePeer peer, PeerState state) {
    if (!identical(_peer, peer)) return;
    switch (state) {
      case PeerState.connected:
        // A call's talk starts.
        if (_call case final call? when _target == CallVoice(call.conversationId) && call.connectedAt == null) {
          _call = call._copy(connectedAt: _now());
        }
        _setLink(VoiceLink.connected);
        _startLevels();
      case PeerState.disconnected:
        _setLink(VoiceLink.reconnecting);
      case PeerState.failed:
        // With the gateway down too, its next session's READY joins again;
        // with it up, it's this connection that can't get through.
        if (_signaling.connection != null) {
          _fail('Lost the connection to voice');
        } else {
          _setLink(VoiceLink.waiting);
        }
      case PeerState.connecting || PeerState.closed:
        break;
    }
  }

  void _setLink(VoiceLink link) {
    if (_link == link) return;
    _link = link;
    _waitTimer?.cancel();
    _waitTimer = null;
    if (link == VoiceLink.waiting) {
      // Not forever: the microphone, the service and the battery stay on
      // while voice waits, and the microphone mustn't go live by surprise.
      _waitTimer = Timer(rejoinWindow, () {
        _notice(_lostForAWhile);
        leave();
      });
    }
    notifyListeners();
  }

  static const _lostForAWhile = 'You left voice: the connection was lost for a while';

  void _closeRetired() {
    final retired = [..._retired];
    _retired.clear();
    for (final p in retired) {
      unawaited(p.close());
    }
  }

  // The connection can't be made: says why, and leaves (a call hangs up).
  void _fail(String why) {
    _notice(why);
    leave();
  }

  // ---------------------------------------------------------------------------
  // Gateway events
  // ---------------------------------------------------------------------------

  void _onEvent(duvet.GatewayEventPayload event) {
    switch (event) {
      case duvet.ReadyEvent(:final data):
        _onReady(data);
      case duvet.SpaceCreateEvent(:final data):
        _states.space(data);
        notifyListeners();
      case duvet.SpaceDeletedEvent(:final data):
        if (_target case RoomVoice(:final spaceId) when spaceId == data.id) {
          _teardown(sendLeave: false);
          _notice('The space was deleted');
          notifyListeners();
        }
      case duvet.RoomDeletedEvent(:final data):
        _states.forget(data.id);
        if (_target case RoomVoice(:final roomId) when roomId == data.id) {
          _teardown(sendLeave: false);
          _notice('The voice room was deleted');
        }
        notifyListeners();
      case duvet.VoiceStateUpdatedEvent(:final data):
        if (_states.apply(data)) {
          if (data.userId == _me && data.roomId == _target?.id) _checkSpeak();
          notifyListeners();
        }
      case duvet.VoiceJoinedPayloadEvent(:final data):
        _onJoined(data);
      case duvet.WebRTCIceCandidateEvent(:final data):
        _onCandidate(data);
      case duvet.WebRTCRenegotiateEvent(:final data):
        _onOffer(data);
      case duvet.WebRTCRenegotiateAnswerEvent(:final data):
        _onAnswer(data);
      case duvet.VoiceSessionReplacedPayloadEvent(:final data):
        _onReplaced(data);
      case duvet.CallIncomingPayloadEvent(:final data):
        _onIncoming(data);
      case duvet.CallAcceptedEvent(:final data):
        _onAccepted(data);
      case duvet.CallDeclinedEvent(:final data):
        _onDeclined(data);
      case duvet.CallEndedPayloadEvent(:final data):
        _onEnded(data.conversationId);
      default:
    }
  }

  // A new gateway session: its ICE servers, its calls, and no voice of this
  // phone's, which joins again.
  void _onReady(duvet.GatewayReadyData data) {
    if (data.iceServers.isNotEmpty) _iceServers = data.iceServers;
    final calls = data.activeCalls ?? const <duvet.GatewayReadyActiveCall>[];
    _states.reset(calls);
    _calls = {for (final c in calls) c.conversationId};

    // The gateway keeps calls in memory: one the new session doesn't list is
    // over (it restarted, or the call ended while the phone was away). But
    // one placed or answered on this session's own socket went out after its
    // identify, and READY was made before it.
    final call = _call;
    if (call != null && !_calls.contains(call.conversationId)) {
      if (_callOn == _signaling.connection) {
        _calls = {..._calls, call.conversationId};
      } else {
        _callOver(call);
      }
    }

    // A call answered here on an older socket, which may have lost the
    // answer, in the 30 s after it rang, when the gateway ends a call nobody
    // answered: the answer again. Only then: each CALL_ACCEPTED makes the
    // desktop app of a member who isn't in the call join it.
    if (_call case final c?
        when c.phase == CallPhase.connected &&
            !c.outgoing &&
            _callOn != _signaling.connection &&
            _now().difference(c.startedAt) < _ringTimeout) {
      _signaling.acceptCall(c.conversationId);
      _callOn = _signaling.connection;
    }

    final target = _target;
    // A join sent on this session's own socket went out after its identify:
    // it's in already.
    if (_joining && target != null && _joinedOn != _signaling.connection) {
      // How long voice was out of reach: since the gateway's last word, or,
      // for a join asked offline, since it was asked.
      final silence = _signaling.silenceBeforeReady;
      final waited = _now().difference(_askedAt ?? _now());
      if ((waited < silence ? waited : silence) > rejoinWindow) {
        _notice(_lostForAWhile);
        leave();
      } else {
        unawaited(_connect());
      }
    }
    notifyListeners();
  }

  void _onJoined(duvet.VoiceJoinedEvent data) {
    final peer = _peer;
    if (peer == null || data.roomId != _target?.id) return;
    if (_answered) {
      // The gateway answers each join once, in order, and its answers carry
      // no tag: a second one means the first was for an older join of this
      // room, left before its answer came. The connection that took it
      // starts over.
      unawaited(_connect());
      return;
    }
    _answered = true;
    final gate = _joined;
    final answer = data.answer;
    // At once, never behind a queued offer.
    unawaited(() async {
      try {
        if (answer == null) return;
        await peer.setRemoteDescription(answer);
        if (!identical(_peer, peer)) return;
        _remoteSet = true;
        _flushCandidates(peer);
        _negotiationReady = true;
      } catch (e) {
        debugPrint('voice: answer: $e');
      } finally {
        // Queued offers may go on.
        if (!gate.isCompleted) gate.complete();
      }
    }());
  }

  void _onCandidate(duvet.IceCandidateEvent data) {
    final peer = _peer;
    if (peer == null || data.roomId != _target?.id) return;
    if (_remoteSet) {
      unawaited(peer.addIceCandidate(data.candidate).catchError((Object e) => debugPrint('voice: candidate: $e')));
    } else {
      _pendingCandidates.add(data.candidate);
    }
  }

  void _flushCandidates(VoicePeer peer) {
    final queued = [..._pendingCandidates];
    _pendingCandidates.clear();
    for (final c in queued) {
      unawaited(peer.addIceCandidate(c).catchError((Object e) => debugPrint('voice: candidate: $e')));
    }
  }

  // The gateway's offer (people's audio came or went, or an ICE restart):
  // answered in turn, never before the join's answer is applied.
  void _onOffer(duvet.RenegotiateOfferEvent data) {
    final target = _target;
    final peer = _peer;
    if (target == null || peer == null || data.roomId != target.id) return;
    final gate = _joined.future;
    _negotiations = _negotiations.then((_) async {
      await gate;
      if (!identical(_peer, peer)) return;
      try {
        await peer.setRemoteDescription(data.offer);
        if (!identical(_peer, peer)) return;
        _remoteSet = true;
        _flushCandidates(peer);
        final answer = await peer.createAnswer();
        if (!identical(_peer, peer)) return;
        await peer.setLocalDescription(answer);
        _signaling.sendAnswer(target.id, answer);
        _failedOffers = 0;
      } catch (e) {
        debugPrint('voice: renegotiation: $e');
        if (!identical(_peer, peer)) return;
        // Unanswered, the gateway's side waits for the answer forever: a new
        // connection, as after a failed one; twice in a row at most.
        if (++_failedOffers > 2) {
          _fail('Lost the connection to voice');
        } else {
          unawaited(_connect());
        }
      }
    });
  }

  void _onAnswer(duvet.RenegotiateAnswerEvent data) {
    final peer = _peer;
    final answer = data.answer;
    if (peer == null || answer == null || data.roomId != _target?.id) return;
    unawaited(peer.setRemoteDescription(answer).catchError((Object e) => debugPrint('voice: answer: $e')));
  }

  // Another device took the voice, or the user lost access to the room.
  void _onReplaced(duvet.VoiceSessionReplacedEvent data) {
    final target = _target;
    if (target == null || data.roomId != target.id) return;
    _teardown(sendLeave: false);
    final call = _call;
    if (target is CallVoice && call?.conversationId == target.id) {
      _record(call!);
      _call = null;
    }
    _notice(
      data.reason == 'permissions' ? 'You can’t be in this voice room anymore' : 'Your voice moved to another device',
    );
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Calls
  // ---------------------------------------------------------------------------

  void _onIncoming(duvet.CallIncomingEvent data) {
    _calls = {..._calls, data.conversationId};
    final current = _call;
    final call = ActiveCall(
      conversationId: data.conversationId,
      initiatorId: data.initiatorId,
      initiatorName: data.initiatorName,
      outgoing: false,
      phase: CallPhase.ringing,
      startedAt: _now(),
    );
    if (current == null) {
      _call = call;
      _callOn = null;
    } else if (current.conversationId != data.conversationId) {
      // One call at a time: another one doesn't ring here, but it's missed.
      _record(call);
      _notice('Missed a call from ${data.initiatorName}');
    }
    notifyListeners();
  }

  void _onAccepted(duvet.CallResponseEvent data) {
    final call = _call;
    if (call == null || call.conversationId != data.conversationId) return;
    if (call.phase == CallPhase.calling) {
      // Someone answered: the caller's voice joins.
      _call = call.answered();
      unawaited(_joinCallVoice(call.conversationId));
    } else if (call.phase == CallPhase.ringing && data.userId == _me) {
      // Answered on another device.
      _call = null;
    } else {
      return;
    }
    notifyListeners();
  }

  void _onDeclined(duvet.CallResponseEvent data) {
    final call = _call;
    if (call == null || call.conversationId != data.conversationId || call.phase != CallPhase.calling) return;
    _notice('${_repository.nameOf(data.userId) ?? 'They'} declined');
  }

  void _onEnded(String conversationId) {
    _calls = {..._calls}..remove(conversationId);
    _states.forget(conversationId);
    final call = _call;
    if (call != null && call.conversationId == conversationId) _callOver(call);
    notifyListeners();
  }

  // The call ended without the user: kept in the history, its voice left.
  void _callOver(ActiveCall call) {
    _record(call);
    // Its voice, or, for one placed that nobody answered, its microphone.
    if (_target == CallVoice(call.conversationId) || _target == null) _teardown(sendLeave: false);
    _call = null;
  }

  void _record(ActiveCall call, [CallOutcome? outcome]) {
    final connectedAt = call.connectedAt;
    final o =
        outcome ??
        switch (call.phase) {
          CallPhase.ringing => CallOutcome.missed,
          CallPhase.calling => CallOutcome.unanswered,
          CallPhase.connected => connectedAt == null ? CallOutcome.failed : CallOutcome.answered,
        };
    history.add(
      CallRecord(
        conversationId: call.conversationId,
        title: _conversationTitle(call.conversationId) ?? (call.outgoing ? 'Call' : call.initiatorName),
        outgoing: call.outgoing,
        outcome: o,
        at: call.startedAt,
        duration: o == CallOutcome.answered && connectedAt != null ? _now().difference(connectedAt) : null,
      ),
    );
  }

  /// Rings [conversationId]'s members. The caller's voice joins once one of
  /// them answers.
  Future<void> startCall(String conversationId) async {
    if (_call != null) {
      _notice('You’re in a call already');
      return;
    }
    final me = _repository.profile.value;
    if (me == null) return;
    const offline = 'You’re offline: call again once you’re back';
    if (_signaling.connection == null) {
      _notice(offline);
      return;
    }
    final ids = await _memberIds(conversationId, me.id);
    if (ids == null || _call != null) return;
    // The permissions before it rings anyone. And the microphone and the
    // foreground service now, with the app in front: once someone answers it
    // may be behind another app, and Android lets neither the microphone
    // open nor a microphone service start from there.
    await _engine.prepare();
    final mic = await _engine.openMicrophone();
    if (_call != null || _repository.profile.value?.id != me.id) {
      await mic?.stop();
      return;
    }
    if (!_signaling.initiateCall(conversationId, ids)) {
      await mic?.stop();
      _notice(offline);
      return;
    }
    // Unlike the desktop, a voice room's voice ends now, not once someone
    // answers.
    if (_target != null) _handOver(() => _teardown(sendLeave: true));
    _call = ActiveCall(
      conversationId: conversationId,
      initiatorId: me.id,
      initiatorName: me.displayName,
      outgoing: true,
      phase: CallPhase.calling,
      startedAt: _now(),
    );
    _callOn = _signaling.connection;
    _calls = {..._calls, conversationId};
    _mic = mic;
    if (mic != null) _keepAlive(CallVoice(conversationId));
    notifyListeners();
  }

  /// Joins the call going on in [conversationId]: one that rang out, or that
  /// the user left.
  Future<void> joinCall(String conversationId) async {
    final current = _call;
    if (current != null && current.conversationId != conversationId) {
      _notice('You’re in a call already');
      return;
    }
    if (current?.phase == CallPhase.ringing) return acceptCall();
    final me = _repository.profile.value;
    if (me == null) return;
    final ids = await _memberIds(conversationId, me.id);
    if (ids == null) return;
    // Makes sure the call is still there (the gateway keeps one going as it
    // is), then answers it.
    _signaling.initiateCall(conversationId, ids);
    if (!_signaling.acceptCall(conversationId)) {
      _notice('You’re offline: join again once you’re back');
      return;
    }
    _callOn = _signaling.connection;
    _call = ActiveCall(
      conversationId: conversationId,
      initiatorId: me.id,
      initiatorName: me.displayName,
      outgoing: false,
      phase: CallPhase.connected,
      startedAt: _now(),
    );
    notifyListeners();
    await _joinCallVoice(conversationId);
  }

  /// Answers the call ringing here.
  Future<void> acceptCall() async {
    final call = _call;
    if (call == null || call.phase != CallPhase.ringing) return;
    if (!_signaling.acceptCall(call.conversationId)) {
      _notice('You’re offline: the call can’t be answered');
      return;
    }
    _callOn = _signaling.connection;
    _call = call.answered();
    notifyListeners();
    await _joinCallVoice(call.conversationId);
  }

  /// Turns down the call ringing here.
  void declineCall() {
    final call = _call;
    if (call == null || call.phase != CallPhase.ringing) return;
    // Sent even offline: the gateway takes a dropped session for a decline.
    _signaling.declineCall(call.conversationId);
    _record(call, CallOutcome.declined);
    _call = null;
    notifyListeners();
  }

  /// Ends the user's part in the call: declines it ringing, cancels it
  /// calling, leaves it answered.
  void hangUp() {
    final call = _call;
    if (call == null) {
      if (_target case CallVoice(:final conversationId)) {
        _signaling.leaveCall(conversationId);
        _teardown(sendLeave: false);
        notifyListeners();
      }
      return;
    }
    switch (call.phase) {
      case CallPhase.ringing:
        declineCall();
        return;
      case CallPhase.calling:
        // The gateway ends a call its caller cancels.
        _signaling.cancelCall(call.conversationId);
        _record(call, CallOutcome.cancelled);
        _calls = {..._calls}..remove(call.conversationId);
        // The microphone opened for it.
        if (_target == null) _teardown(sendLeave: false);
      case CallPhase.connected:
        _signaling.leaveCall(call.conversationId);
        _record(call);
        if (_target == CallVoice(call.conversationId)) _teardown(sendLeave: false);
    }
    _call = null;
    notifyListeners();
  }

  Future<List<String>?> _memberIds(String conversationId, String me) async {
    try {
      final members = await _repository.members(ConversationTarget(conversationId));
      // The caller too: the gateway tells only the call's members how it goes.
      return {me, for (final m in members) m.userId}.toList();
    } catch (e) {
      debugPrint('voice: members: $e');
      _notice('Couldn’t reach Duvet to place the call');
      return null;
    }
  }

  Future<void> _joinCallVoice(String conversationId) async {
    final target = CallVoice(conversationId);
    if (_target == target) return;
    if (_target is RoomVoice) _handOver(() => _teardown(sendLeave: true));
    // Calls ask for no permission.
    _canSpeak = true;
    await _begin(target, speaker: false);
  }

  // Before joining somewhere else: a room's voice is left, a call hung up.
  void _leaveCurrent() => _handOver(_leaveAll);

  // Leaves the voice room or the call, telling the gateway, and declines a
  // call ringing.
  void _leaveAll() {
    if (_call?.phase == CallPhase.ringing) declineCall();
    leave();
  }

  // Leaves ([leave] does) for another voice: its connection closes only once
  // the next one exists (see [_connect]), as on Android the audio session ends
  // with the last one.
  void _handOver(void Function() leave) {
    final old = _peer;
    _peer = null;
    leave();
    if (old != null) _retired.add(old);
  }

  // ---------------------------------------------------------------------------
  // Levels
  // ---------------------------------------------------------------------------

  void _startLevels() {
    _levelTimer ??= Timer.periodic(levelInterval, (_) {
      if (_levels.watched && _inFront()) unawaited(_readLevels());
    });
  }

  Future<void> _readLevels() async {
    final peer = _peer;
    if (peer == null || _readingLevels) return;
    _readingLevels = true;
    try {
      final read = await peer.audioLevels();
      if (!identical(_peer, peer)) return;
      final me = _me;
      final local = read.local;
      final next = <String, double>{
        for (final MapEntry(:key, :value) in read.remote.entries)
          if (mouthFor(value) > 0) key: mouthFor(value),
        if (me != null && _sending && local != null && mouthFor(local) > 0) me: mouthFor(local),
      };
      if (!mapEquals(next, levels.value)) levels.value = next;
    } catch (e) {
      debugPrint('voice: levels: $e');
    } finally {
      _readingLevels = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Leaving
  // ---------------------------------------------------------------------------

  // Ends the voice connection: the peer, the microphone, the foreground
  // service. [sendLeave] tells the gateway (VOICE_LEAVE).
  // Without a target, it releases what a call placed opened.
  void _teardown({required bool sendLeave}) {
    final target = _target;
    if (sendLeave && target != null) _signaling.leaveVoice(target.id);
    _target = null;
    _link = null;
    _joining = false;
    _joinedOn = null;
    _session++;
    _generation++;
    _joinTimer?.cancel();
    _joinTimer = null;
    _waitTimer?.cancel();
    _waitTimer = null;
    _levelTimer?.cancel();
    _levelTimer = null;
    _negotiationReady = false;
    _remoteSet = false;
    _pendingCandidates.clear();
    if (!_joined.isCompleted) _joined.complete();
    final peer = _peer;
    final mic = _mic;
    _peer = null;
    _mic = null;
    _closeRetired();
    unawaited(() async {
      await peer?.close();
      await mic?.stop();
    }());
    if (_keptAlive) {
      _keptAlive = false;
      unawaited(_engine.letSleep());
    }
    levels.value = const {};
  }

  void _notice(String text) {
    if (!_notices.isClosed) _notices.add(text);
  }

  // The session ended for good, its gateway still there: voice and calls tell
  // it they leave, and every call history kept on the phone goes, first, so
  // what ends now isn't kept either.
  void _onSignedOut() {
    unawaited(history.close(forget: true));
    _leaveAll();
  }

  void _onProfile() {
    final me = _repository.profile.value?.id;
    if (me == _me) return;
    final previous = _me;
    _me = me;
    if (previous != null) {
      // Signed out (or in as someone else): voice and calls end here, and
      // nothing of the account's carries over to the next.
      _teardown(sendLeave: true);
      _call = null;
      _calls = const {};
      _states.reset();
      _iceServers = _stun;
      _muted = false;
      _deafened = false;
      unawaited(history.close(forget: me == null));
      notifyListeners();
    }
    if (me != null) unawaited(history.load(me));
  }

  @override
  void dispose() {
    _teardown(sendLeave: true);
    unawaited(_events.cancel());
    unawaited(_signedOut.cancel());
    _repository.profile.removeListener(_onProfile);
    _repository.spaces.removeListener(_checkSpeak);
    unawaited(_notices.close());
    levels.dispose();
    history.dispose();
    super.dispose();
  }
}

/// [VoiceController.levels], which knows whether anything shows them.
class _Levels extends ValueNotifier<Map<String, double>> {
  _Levels() : super(const {});

  bool get watched => hasListeners;
}
