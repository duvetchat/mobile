/// Voice rooms and calls: who's in voice where, the user's own voice
/// connection, and the calls that ring.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:permission_handler/permission_handler.dart' show Permission, PermissionActions, PermissionStatusGetters;

import 'call_history.dart';
import 'models.dart';
import 'repository.dart';
import 'sounds.dart';
import 'voice_engine.dart';
import 'voice_signaling.dart';

export 'call_history.dart' show CallHistory, CallOutcome, CallRecord;
export 'voice_engine.dart'
    show
        AudioRoute,
        AudioRouteKind,
        AudioRoutes,
        CameraFacing,
        VideoKind,
        VoiceCamera,
        VoiceCameraDevice,
        VoiceRemoteVideo,
        VoiceScreen;

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

/// What the app does with a call's notification (lib/push) while a call rings here: [show] puts it up as Duvet leaves
/// the screen, and answers whether it shows; [hide] takes it away.
typedef CallNotices = ({Future<bool> Function(ActiveCall call) show, void Function(String conversationId) hide});

/// The call this device rings for, places or is in.
class ActiveCall {
  final String conversationId;
  final String initiatorId;
  final String initiatorName;

  /// The caller's avatar, an attachment ID, as CALL_INCOMING and READY give
  /// it: the incoming call screen shows it.
  final String? initiatorAvatar;
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
    this.initiatorAvatar,
    required this.outgoing,
    required this.phase,
    required this.startedAt,
    this.connectedAt,
  });

  ActiveCall _copy({CallPhase? phase, DateTime? connectedAt}) => ActiveCall(
    conversationId: conversationId,
    initiatorId: initiatorId,
    initiatorName: initiatorName,
    initiatorAvatar: initiatorAvatar,
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
/// for longer than [rejoinWindow], and a session the gateway resumes on a new
/// socket keeps its voice as it was; a join made while the gateway is out of
/// reach waits for its next session (a new one: it asks for it), and
/// [rejoinWindow] at most, and one it doesn't answer in [joinTimeout] leaves.
///
/// Video: the camera's transceiver is in every join's offer, tagged, so
/// turning the camera on or off only swaps its track and says so in
/// VOICE_SYNC. Sharing the screen adds a sender, the phone's only own offer
/// (WEBRTC_RENEGOTIATE_OFFER), ordered with the gateway's offers.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required ChatRepository repository,
    required VoiceEngine engine,
    required CallHistoryStore historyStore,
    this.joinTimeout = const Duration(seconds: 15),
    this.rejoinWindow = const Duration(minutes: 3),
    this.levelInterval = const Duration(milliseconds: 200),
    this.pingInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
    @visibleForTesting bool Function()? inFront,
    @visibleForTesting Stream<AppLifecycleState>? lifecycle,
    @visibleForTesting Future<bool> Function()? cameraRefused,
    Sounds? sounds,
    CallNotices? callNotices,
  }) : _repository = repository,
       _signaling = repository.voiceSignaling,
       _engine = engine,
       _now = clock ?? DateTime.now,
       _inFront = inFront ?? _appInFront,
       _lifecycle = lifecycle ?? _appLifecycle(),
       _cameraRefused = cameraRefused ?? _cameraPermissionRefused,
       _sounds = sounds,
       _callNotices = callNotices,
       history = CallHistory(historyStore) {
    _events = _signaling.events.listen(_onEvent);
    _resumes = _signaling.resumes.listen((_) => _onResume());
    _signedOut = _repository.signedOut.listen((_) => _onSignedOut());
    _repository.profile.addListener(_onProfile);
    _repository.spaces.addListener(_checkPerms);
    addListener(_followRing);
    _onProfile();
  }

  /// How long an Answer from a call's notification waits for the call to ring here, as the app starts and connects:
  /// a call rings 30 s at most.
  static const answerWait = Duration(seconds: 30);

  final CallNotices? _callNotices;

  // While a call rings here, whether Duvet comes on screen or leaves it, which decides where it rings.
  StreamSubscription<AppLifecycleState>? _ringFollowsScreen;

  // The conversation whose call rings here, which its notification is of; whether the app put that notification up
  // since Duvet left the screen, and whether it could; and, on screen, the timer that takes it away again.
  String? _ringingIn;
  bool _shownAway = false;
  bool _noNotice = false;
  Timer? _hideAgain;

  // An Answer from a call's notification, for the call of that conversation once it rings here, until then.
  ({String conversationId, DateTime until})? _answerFor;

  final ChatRepository _repository;
  final VoiceSignaling _signaling;
  final VoiceEngine _engine;
  final DateTime Function() _now;
  late final StreamSubscription<duvet.GatewayEventPayload> _events;
  late final StreamSubscription<void> _resumes;
  late final StreamSubscription<void> _signedOut;

  // Duvet on screen: not behind another app, nor under a locked screen. Before Flutter says, it isn't: a start with no
  // screen (audio_service's engine) has said nothing yet.
  final bool Function() _inFront;
  static bool _appInFront() => switch (SchedulerBinding.instance.lifecycleState) {
    AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  // The app's lifecycle, followed only while the camera is on: a controller
  // made without Flutter running (some tests) never touches its binding.
  final Stream<AppLifecycleState> _lifecycle;
  static Stream<AppLifecycleState> _appLifecycle() {
    AppLifecycleListener? listener;
    late final StreamController<AppLifecycleState> states;
    states = StreamController.broadcast(
      onListen: () => listener = AppLifecycleListener(onStateChange: states.add),
      onCancel: () {
        listener?.dispose();
        listener = null;
      },
    );
    return states.stream;
  }

  // Whether the user refused the camera, as far as the phone tells: a camera
  // that doesn't open may be busy instead (another app has it).
  final Future<bool> Function() _cameraRefused;
  static Future<bool> _cameraPermissionRefused() async {
    // iOS: flutter_webrtc asks itself, and can't say.
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final status = await Permission.camera.status;
      return status.isDenied || status.isPermanentlyDenied;
    } catch (e) {
      debugPrint('voice: camera permission: $e');
      return false;
    }
  }

  final Sounds? _sounds;

  /// How long the gateway has to answer a join.
  final Duration joinTimeout;

  /// After this long without a word from the gateway (the phone slept, say),
  /// a new session leaves voice rather than join again: the microphone
  /// mustn't open by surprise. A gateway restart takes far less.
  final Duration rejoinWindow;

  /// How often the voices' levels are read, for the faces' mouths.
  final Duration levelInterval;

  /// How often the connection's round trip is measured, as desktop's status bar does.
  final Duration pingInterval;

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

  /// The voice connection's round trip in milliseconds, measured every
  /// [pingInterval] while connected; null out of voice and until measured.
  final ping = ValueNotifier<int?>(null);

  /// Conversations with a call going on.
  Set<String> get callsInProgress => _calls;
  Set<String> _calls = const {};

  /// Whether [conversationId]'s call is the user's own, placed from this
  /// phone or another of their devices, and still rings the others: nobody
  /// has answered it yet. Until someone does, it can't be joined from here:
  /// the user's voice would be in it alone, and the device that placed it
  /// joins at the first answer. A gateway from before calls across devices
  /// doesn't say, and its calls can be joined as before.
  bool ownCallRinging(String conversationId) => _unanswered.contains(conversationId);
  Set<String> _unanswered = const {};

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

  bool _canVideo = true;

  /// Whether the user may turn on a camera or share the screen where they
  /// are: Video in a room; always in a call.
  bool get canVideo => _canVideo;

  VoiceCamera? _camera;
  VoiceScreen? _screen;
  StreamSubscription<void>? _cameraEnded;
  StreamSubscription<void>? _screenEnded;
  StreamSubscription<AppLifecycleState>? _background;

  /// The camera while it's on, for its preview.
  VoiceCamera? get camera => _camera;
  bool get cameraOn => _camera != null;

  /// The screen while it's shared.
  VoiceScreen? get screen => _screen;
  bool get screenSharing => _screen != null;

  // The camera picked for this session; the front one until then.
  String? _cameraDevice;

  bool _incomingVideo = true;

  /// Whether the others' cameras and screens come in (`video_off` is its
  /// opposite).
  bool get incomingVideo => _incomingVideo;

  /// The others' cameras and screens: none while [incomingVideo] is off or
  /// out of voice.
  ValueListenable<List<VoiceRemoteVideo>> get remoteVideos => _remoteVideos;
  final _remoteVideos = ValueNotifier<List<VoiceRemoteVideo>>(const []);

  // The peer whose videos [remoteVideos] shows.
  VoicePeer? _watched;

  List<String> _watching = const [];

  /// Whose screen share the user watches in their voice, by user ID, in the
  /// order they opened them: VOICE_SYNC's `watching`, none while
  /// [incomingVideo] is off.
  List<String> get watching => _watching;

  /// Watches [userId]'s screen share in the user's voice, or stops.
  void watch(String userId, {required bool on}) {
    if (_target == null || on == _watching.contains(userId)) return;
    _watching = on ? [..._watching, userId] : [..._watching.where((id) => id != userId)];
    _sync();
    notifyListeners();
  }

  /// Watches no screen share, as when the voice screen closes. It doesn't
  /// notify: a widget calls it as it's disposed.
  void stopWatching() {
    if (_watching.isEmpty) return;
    _watching = const [];
    _sync();
  }

  // A sharer who stopped sharing, or left the user's voice, is watched no more.
  void _keepWatching() {
    final target = _target;
    if (target == null || _watching.isEmpty) return;
    final sharing = {
      for (final p in _states.participantsIn(target.id))
        if (p.screenSharing) p.userId,
    };
    final kept = [..._watching.where(sharing.contains)];
    if (kept.length == _watching.length) return;
    _watching = kept;
    _sync();
  }

  bool _noiseSuppression = true;

  /// Where the sound plays.
  ValueListenable<AudioRoutes> get routes => _engine.routes;

  ActiveCall? _call;

  /// The call ringing, placed or going on here.
  ActiveCall? get call => _call;

  /// In a voice room or a call, or placing one: the microphone and the
  /// phone's call audio are voice's.
  bool get inVoice => _target != null || _call?.phase == CallPhase.calling;

  // The gateway socket this phone placed or answered [_call] on, and whether
  // the gateway heard its answer: its CALL_ACCEPTED came back.
  int? _callOn;
  bool _answerHeard = false;

  // Whom a call placed here rang, and whether the gateway has the call: its
  // CALL_OUTGOING came, someone answered or declined, or READY listed it.
  List<String> _placedWith = const [];
  bool _placeHeard = false;

  // The conversation whose call placed here was cancelled, until its
  // CALL_ENDED, or until a call is placed there again: a call placed into
  // one going on (calls that crossed, or its caller back by calling it)
  // joins it, and its cancel may then take only the user out, the call
  // going on for the others.
  String? _cancelledIn;

  /// The gateway ends a call nobody answered this long after it rang.
  static const ringWindow = Duration(seconds: 30);

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
  Timer? _pingTimer;

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
    _canVideo = _videoAllowed(target);
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
  bool _videoAllowed(RoomVoice t) => _repository.canInRoom(t.spaceId, t.roomId, Perm.video);

  bool _inSpaces(RoomVoice t) =>
      _repository.spaces.value.any((s) => s.id == t.spaceId && s.rooms.any((r) => r.id == t.roomId));

  // A role or an overwrite changed: without SpeakInVoice the user is muted,
  // as the gateway already shows them, and without Video their camera and
  // screen stop. Not in a room the user no longer has, deleted or no longer
  // one they can view: its ROOM_DELETE took its overwrites, and what they
  // gave, before the gateway ends its voice, and a mute set then would stay
  // for the next room.
  void _checkPerms() {
    final target = _target;
    if (target is! RoomVoice || !_inSpaces(target)) return;
    final can = _speakAllowed(target);
    final video = _videoAllowed(target);
    if (can == _canSpeak && video == _canVideo) return;
    _canSpeak = can;
    _canVideo = video;
    if (!can && !_muted) {
      _muted = true;
      _sync();
      unawaited(_applyAudio());
      _notice('You can’t speak in this room now');
    }
    if (!video && (_camera != null || _screen != null)) {
      _cameraOff();
      _screenOff();
      _sync();
      _notice('You can’t use video in this room now');
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
        final suppressing = _noiseSuppression;
        final mic = await _engine.openMicrophone(noiseSuppression: suppressing);
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
          _micSuppressing = suppressing;
          await _peer?.useMicrophone(mic);
          _keepAlive(target);
          _matchNoiseSuppression();
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

  /// Uses WebRTC's noise suppression on the microphone, or not: the one open
  /// in voice opens again with it.
  void setNoiseSuppression(bool on) {
    if (on == _noiseSuppression) return;
    _noiseSuppression = on;
    _matchNoiseSuppression();
  }

  // What the microphone open was opened with.
  bool _micSuppressing = true;

  // The microphone's reopenings, one at a time: two at once could attach a
  // microphone the other one stopped.
  Future<void> _micSwaps = Future.value();

  // Opens the microphone again if it was opened with another setting than the
  // one set now; once the reopenings before are done, so the last one wins.
  void _matchNoiseSuppression() {
    _micSwaps = _micSwaps.then((_) => _reopenMic()).catchError((Object e) => debugPrint('voice: microphone: $e'));
  }

  Future<void> _reopenMic() async {
    final session = _session;
    final old = _mic;
    final suppressing = _noiseSuppression;
    if (old == null || _target == null || suppressing == _micSuppressing) return;
    final mic = await _engine.openMicrophone(noiseSuppression: suppressing);
    if (session != _session || !identical(_mic, old)) {
      await mic?.stop();
      return;
    }
    // Refused now: the one open goes on as it was.
    if (mic == null) return;
    _mic = mic;
    _micSuppressing = suppressing;
    try {
      await _peer?.useMicrophone(mic);
    } catch (e) {
      debugPrint('voice: $e');
    }
    await old.stop();
    // The new track sends only if the user does: muted stays muted.
    await _applyAudio();
  }

  /// VOICE_SYNC with the whole state: the gateway turns off what a sync
  /// leaves out.
  void _sync() {
    final target = _target;
    if (target == null) return;
    _signaling.syncVoice(
      target.id,
      muted: _muted,
      deafened: _deafened,
      screenSharing: _screen != null,
      camera: _camera != null,
      videoOff: !_incomingVideo,
      // The gateway sends no screen while video is off: the list stays for when it's back.
      watching: _incomingVideo ? _watching : const [],
    );
  }

  // ---------------------------------------------------------------------------
  // Camera and screen
  // ---------------------------------------------------------------------------

  /// Turns the camera on or off: only ever from the user's tap. It swaps the
  /// camera transceiver's track, so nothing renegotiates.
  ///
  /// One camera opens at a time: a tap while it opens is the user's latest
  /// word on it, and a camera that arrives no longer wanted stops at once
  /// (many phones can't open two cameras at once, either).
  Future<void> toggleCamera() async {
    final target = _target;
    if (target == null) return;
    if (_cameraOpening == _session) {
      _cameraWanted = !_cameraWanted;
      return;
    }
    if (_camera != null) {
      _cameraOff();
      _sync();
      notifyListeners();
      return;
    }
    if (!_canVideo) {
      _notice(_noVideo(target));
      return;
    }
    final session = _cameraOpening = _session;
    _cameraWanted = true;
    // From now: a camera that opens with the app gone to the background
    // would be blocked there.
    _followBackground();
    final VoiceCamera? camera;
    try {
      camera = await _openCamera();
    } finally {
      if (_cameraOpening == session) _cameraOpening = null;
    }
    if (camera == null || session != _session || _camera != null || !_canVideo || !_cameraWanted) {
      await camera?.stop();
      // Unless another camera opens meanwhile (a new session's).
      if (_camera == null && _cameraOpening != _session) _stopFollowingBackground();
      return;
    }
    _useCamera(camera);
    _sync();
    notifyListeners();
  }

  // The session whose camera is opening, and whether the user still wants it.
  int? _cameraOpening;
  bool _cameraWanted = false;

  /// Flips the camera between front and back, in place.
  Future<void> switchCamera() async {
    await _camera?.switchFacing();
    notifyListeners();
  }

  /// The phone's cameras, to pick one.
  Future<List<VoiceCameraDevice>> cameras() => _engine.cameras();

  /// The camera picked with [selectCamera], for the picker's check; null for
  /// the phone's default. A flip doesn't change it.
  String? get selectedCameraId => _cameraDevice;

  /// Picks the camera [deviceId]: it replaces the one on, or the next tap
  /// opens it. Kept for this session only.
  Future<void> selectCamera(String deviceId) async {
    _cameraDevice = deviceId;
    final old = _camera;
    if (old == null) return;
    final session = _session;
    // Many phones can't open two cameras at once: the old one goes first.
    _cameraEnded?.cancel();
    _cameraEnded = null;
    await old.stop();
    final camera = await _openCamera();
    if (session != _session || !identical(_camera, old)) {
      await camera?.stop();
      return;
    }
    if (camera == null) {
      _cameraOff();
      _sync();
    } else {
      _useCamera(camera);
    }
    notifyListeners();
  }

  // Opens the camera picked, or says why it can't.
  Future<VoiceCamera?> _openCamera() async {
    final camera = await _engine.openCamera(deviceId: _cameraDevice);
    if (camera == null) {
      final none = (await _engine.cameras()).isEmpty;
      final refused = !none && await _cameraRefused();
      _notice(
        none
            ? 'This phone has no camera'
            : refused
            ? 'Allow Duvet to use the camera to turn it on'
            : 'Couldn’t turn on the camera',
      );
    }
    return camera;
  }

  void _useCamera(VoiceCamera camera) {
    _camera = camera;
    _cameraEnded = camera.onEnded.listen((_) {
      if (!identical(_camera, camera)) return;
      _cameraOff();
      _sync();
      notifyListeners();
    });
    _followBackground();
    _onPeer((peer) => peer.setCamera(camera));
  }

  // Android blocks the camera of an app in the background: it turns off, or,
  // still opening, stays off once it opens.
  void _followBackground() {
    _background ??= _lifecycle.listen((state) {
      if (state != AppLifecycleState.paused && state != AppLifecycleState.hidden) return;
      if (_cameraOpening == _session && _cameraWanted) {
        _cameraWanted = false;
        _notice('Camera turned off in the background');
      }
      if (_camera == null) return;
      _cameraOff();
      _sync();
      _notice('Camera turned off in the background');
      notifyListeners();
    });
  }

  void _stopFollowingBackground() {
    _background?.cancel();
    _background = null;
  }

  // The camera goes off: no track on its transceiver, the device released.
  void _cameraOff() {
    final camera = _camera;
    if (camera == null) return;
    _camera = null;
    _cameraEnded?.cancel();
    _cameraEnded = null;
    _stopFollowingBackground();
    _onPeer((peer) => peer.setCamera(null));
    unawaited(camera.stop());
  }

  /// Shares the screen: the phone offers its new sender to the gateway.
  Future<void> startScreenShare() async {
    final target = _target;
    // Only on a connection that's joined: a join's offer must carry no
    // untagged video (see [_connect]).
    // One at a time: a second tap would ask the user's consent twice.
    if (target == null || _screen != null || !_negotiationReady || _screenStarting == _session) return;
    if (!_canVideo) {
      _notice(_noVideo(target));
      return;
    }
    final session = _screenStarting = _session;
    final VoiceScreen? screen;
    try {
      screen = await _engine.openScreen();
    } finally {
      if (_screenStarting == session) _screenStarting = null;
    }
    if (screen == null) {
      if (session == _session) _notice('Duvet can’t share the screen');
      return;
    }
    if (session != _session || _screen != null || !_canVideo || !_negotiationReady) {
      await screen.stop();
      return;
    }
    _screen = screen;
    _screenEnded = screen.onEnded.listen((_) {
      if (identical(_screen, screen)) unawaited(stopScreenShare());
    });
    _onPeer((peer) => peer.setScreen(screen));
    _sync();
    notifyListeners();
  }

  // The session whose screen capture is starting.
  int? _screenStarting;

  /// Stops sharing the screen: the phone offers its sender's removal.
  Future<void> stopScreenShare() async {
    if (_screen == null) return;
    _screenOff();
    _sync();
    notifyListeners();
  }

  // The screen stops: its sender goes, if there's a connection, and the
  // capture with it.
  void _screenOff() {
    final screen = _screen;
    if (screen == null) return;
    _screen = null;
    _screenEnded?.cancel();
    _screenEnded = null;
    _onPeer((peer) => peer.setScreen(null));
    unawaited(screen.stop());
  }

  // Does [change] to the connection, if there is one now.
  void _onPeer(Future<void> Function(VoicePeer peer) change) {
    final peer = _peer;
    if (peer == null) return;
    unawaited(change(peer).catchError((Object e) => debugPrint('voice: $e')));
  }

  static String _noVideo(VoiceTarget target) => 'You can’t use video in this ${_place(target)}';
  static String _place(VoiceTarget target) => target is RoomVoice ? 'room' : 'call';

  /// Lets the others' cameras and screens come in, or not.
  Future<void> setIncomingVideo(bool on) async {
    if (on == _incomingVideo) return;
    _incomingVideo = on;
    _showVideos();
    _sync();
    notifyListeners();
  }

  void _watchVideos(VoicePeer? peer) {
    _watched?.remoteVideos.removeListener(_showVideos);
    _watched = peer;
    peer?.remoteVideos.addListener(_showVideos);
    _showVideos();
  }

  void _showVideos() {
    final peer = _watched;
    _remoteVideos.value = peer != null && _incomingVideo ? peer.remoteVideos.value : const [];
  }

  // VOICE_VIDEO_REFUSED: the gateway turned down, or stopped, the camera or
  // the screen. Said as desktop's videoRefusedMessage says it.
  void _onVideoRefused(duvet.VoiceVideoRefusedEvent data) {
    final target = _target;
    if (target == null || data.roomId != target.id) return;
    switch (data.kind) {
      case 'camera' when _camera != null:
        _cameraOff();
      case 'screen' when _screen != null:
        _screenOff();
      default:
        return;
    }
    _sync();
    final place = _place(target);
    _notice(switch (data.reason) {
      'limit' => switch (data.limit) {
        // The gateway can be set to allow no cameras at all.
        0 => 'Cameras are turned off in this $place',
        null => 'This $place already has as many cameras on as it can',
        1 => 'This $place already has 1 camera on',
        final n => 'This $place already has $n cameras on',
      },
      'permission' => 'You can’t use video in this $place',
      'bitrate' => 'Your camera was turned off: it was sending more video than this $place allows',
      _ => 'Your camera was turned off',
    });
    notifyListeners();
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
    if (target != _target) _watching = const [];
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
      final suppressing = _noiseSuppression;
      final mic = await _engine.openMicrophone(noiseSuppression: suppressing);
      if (session != _session) {
        // Left while the microphone opened.
        await mic?.stop();
        return;
      }
      _mic = mic;
      _micSuppressing = suppressing;
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
    // The setting changed while the microphone opened (here, or for a call
    // placed): it opens again with it.
    _matchNoiseSuppression();
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
    _dropOwnOffer();
    if (!_joined.isCompleted) _joined.complete();
    _joined = Completer<void>();

    if (_signaling.connection == null) {
      // The gateway is out of reach, and a VOICE_JOIN now would be lost: its
      // next session's READY joins.
      _waitForSession();
      return;
    }
    _setLink(VoiceLink.connecting);

    // The connections this one replaces close only once it exists: on
    // Android, a moment without any ends the call's audio session, and a new
    // connection doesn't start it again.
    if (_peer case final old?) _retired.add(old);
    _peer = null;
    _watchVideos(null);
    // A join's offer can't carry the screen: the gateway would take its
    // untagged video for a new share. The camera's transceiver is tagged,
    // and stays on.
    if (_screen != null) {
      _screenOff();
      _notice('Screen sharing stopped');
    }
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
    _watchVideos(peer);
    peer.onIceCandidate = (c) {
      if (identical(_peer, peer)) _signaling.sendIceCandidate(target.id, c);
    };
    peer.onState = (s) => _onPeerState(peer, s);
    peer.onNegotiationNeeded = () {
      if (identical(_peer, peer)) _offerOwn(peer, target);
    };

    try {
      await peer.addAudio(_mic);
      // Before the first offer, so the camera never renegotiates.
      await peer.addVideo();
      if (_camera case final camera?) await peer.setCamera(camera);
      await peer.setSending(_sending);
      await peer.setReceiving(!_deafened);
      final offer = await peer.createOffer();
      if (!identical(_peer, peer)) return;
      await peer.setLocalDescription(offer);
      if (!identical(_peer, peer)) return;
      // The socket can have closed meanwhile.
      final connection = _signaling.connection;
      if (connection == null) {
        _waitForSession();
        return;
      }
      _signaling.joinVoice(target.id, offer, tracks: peer.trackLabels, videoOff: !_incomingVideo);
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
        _waitForSession();
        return;
      }
      _fail('Couldn’t connect to voice');
    });
  }

  // Joins on the gateway's next session, as desktop's VoiceChat does: a new
  // one, whose READY joins. A resumed one would send no READY, and could
  // replay what the gateway sent the last socket.
  void _waitForSession() {
    _signaling.wantFreshSession();
    _setLink(VoiceLink.waiting);
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
        _startPing();
      case PeerState.disconnected:
        _setLink(VoiceLink.reconnecting);
      case PeerState.failed:
        // With the gateway down too, its next session's READY joins again;
        // with it up, it's this connection that can't get through.
        if (_signaling.connection != null) {
          _fail('Lost the connection to voice');
        } else {
          _waitForSession();
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
        _keepWatching();
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
        final before = _states.participantsIn(data.roomId).where((p) => p.userId == data.userId).firstOrNull;
        if (_states.apply(data)) {
          if (data.userId == _me && data.roomId == _target?.id) _checkPerms();
          if (data.userId != _me && data.roomId == _target?.id) _cue(before, data);
          _keepWatching();
          notifyListeners();
        }
      case duvet.VoiceVideoRefusedPayloadEvent(:final data):
        _onVideoRefused(data);
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
      case duvet.CallOutgoingPayloadEvent(:final data):
        _onOutgoing(data.conversationId);
      case duvet.CallOngoingPayloadEvent(:final data):
        _onOngoing(data);
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
    _unanswered = {
      for (final c in calls)
        if (c.initiatorId == _me && c.answered == false) c.conversationId,
    };
    _cancelledIn = null;

    // The gateway keeps calls in memory: one the new session doesn't list is
    // over (it restarted, or the call ended while the phone was away). But
    // one placed or answered on this session's own socket went out after its
    // identify, and READY was made before it.
    final call = _call;
    final listed = call == null ? null : calls.where((c) => c.conversationId == call.conversationId).firstOrNull;
    if (call != null && call.outgoing && listed != null) _placeHeard = true;
    if (call != null && listed == null) {
      if (_callOn == _signaling.connection) {
        _calls = {..._calls, call.conversationId};
      } else {
        _callOver(call);
      }
    } else if (call != null && listed != null) {
      if (call.phase == CallPhase.ringing && listed.ringing == false) {
        // Answered or declined on another device while this one was away, or
        // its ring window ended: it rings here no more.
        _call = null;
      } else if (call.phase == CallPhase.calling && listed.answered == true) {
        // Answered while this phone was away: its CALL_ACCEPTED went to the
        // session that dropped. The call's voice joins, as it would have
        // then, unless the gateway had been out of reach for long (the phone
        // slept, say), as voice doesn't join again either: the microphone
        // mustn't go live by surprise. Then it shows going on, to join.
        final silence = _signaling.silenceBeforeReady;
        final waited = _now().difference(call.startedAt);
        if ((waited < silence ? waited : silence) > rejoinWindow) {
          _call = null;
          // The microphone opened for it.
          if (_target == null) _teardown(sendLeave: false);
        } else {
          _call = call.answered();
          unawaited(_joinCallVoice(call.conversationId));
        }
      }
    }
    // A call that rings the user from before this session (it rang while the
    // phone was away, or began as it came back), its caller as READY names
    // them. A gateway from before calls across devices doesn't say whether a
    // call rings, and none rings here then.
    if (_call == null) {
      if (calls.where((c) => c.ringing == true).firstOrNull case final c?) {
        _call = ActiveCall(
          conversationId: c.conversationId,
          initiatorId: c.initiatorId,
          initiatorName: c.initiatorName ?? _repository.nameOf(c.initiatorId) ?? 'Someone',
          initiatorAvatar: c.initiatorAvatar,
          outgoing: false,
          phase: CallPhase.ringing,
          startedAt: _now(),
        );
        _callOn = null;
        _answerHeard = false;
      }
    }

    // An answer the gateway may have lost with the socket it went on.
    _answerAgain();
    // An Answer from a notification of a call this session doesn't ring: it ended meanwhile.
    if (_answerFor case final wanted?
        when !calls.any((c) => c.conversationId == wanted.conversationId && c.ringing == true)) {
      _answerFor = null;
    }

    final target = _target;
    // A join sent on this session's own socket went out after its identify:
    // it's in already.
    if (_joining && target != null && _joinedOn != _signaling.connection) {
      // How long voice was out of reach: for a join never sent, since it was
      // asked (a new gateway client's first READY reports no silence at all);
      // else since the gateway's last word, or the join if it came later.
      final silence = _signaling.silenceBeforeReady;
      final waited = _now().difference(_askedAt ?? _now());
      final lost = _joinedOn == null || waited < silence ? waited : silence;
      if (lost > rejoinWindow) {
        _notice(_lostForAWhile);
        leave();
      } else {
        unawaited(_connect());
      }
    }
    notifyListeners();
    _answerIfWanted();
  }

  // A call answered here on an older socket, whose answer the gateway hasn't
  // confirmed, in the 30 s after it rang, when the gateway ends a call nobody
  // answered: the answer again. Only then: each CALL_ACCEPTED makes the
  // desktop app of a member who isn't in the call join it.
  void _answerAgain() {
    if (_call case final c?
        when c.phase == CallPhase.connected &&
            !c.outgoing &&
            !_answerHeard &&
            _callOn != _signaling.connection &&
            _now().difference(c.startedAt) < ringWindow) {
      _signaling.acceptCall(c.conversationId);
      _callOn = _signaling.connection;
    }
  }

  // The gateway took the session up again on a new socket, with no READY:
  // voice and the call go on as they were. But a join or an answer that went
  // out on the socket that dropped, still unanswered, may have been lost with
  // it: it goes again on this one, as READY sends them again on a new
  // session. A join answered meanwhile came replayed before this.
  void _onResume() {
    final connection = _signaling.connection;
    // A call placed on an older socket whose CALL_INITIATE may never have
    // reached the gateway, which would leave the caller calling no one: placed
    // again. The gateway takes another one for a call it has as nothing.
    if (_call case final c? when c.phase == CallPhase.calling && !_placeHeard && _callOn != connection) {
      _signaling.initiateCall(c.conversationId, _placedWith);
      _callOn = connection;
    }
    _answerAgain();
    _answerIfWanted();
    if (_joining && _target != null && _joinedOn != null && _joinedOn != connection && !_answered) {
      unawaited(_connect());
      return;
    }
    // The phone's own offer, still unanswered, may have been lost too.
    if ((_target, _peer, _ownOffer, _ownAnswer) case (
      final target?,
      final peer?,
      final offer?,
      final pending?,
    ) when !pending.isCompleted) {
      _signaling.sendRenegotiateOffer(target.id, offer, tracks: peer.trackLabels);
      _ownSends++;
    }
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
    // It crossed the phone's own offer, which the gateway, with an offer
    // out, fails: the phone gives way (see [_offerOwn]).
    _gatewayWaiting++;
    if (_ownAnswer case final pending? when !pending.isCompleted) pending.complete(null);
    final gate = _joined.future;
    _negotiations = _negotiations.then((_) async {
      await gate;
      if (!identical(_peer, peer)) return;
      _gatewayWaiting--;
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
        // Unanswered, the gateway's side waits for the answer forever.
        _negotiationFailed();
      }
    });
  }

  // A negotiation that can't finish: a new connection, as after a failed
  // one; twice in a row at most.
  void _negotiationFailed() {
    if (++_failedOffers > 2) {
      _fail('Lost the connection to voice');
    } else {
      unawaited(_connect());
    }
  }

  // The phone's own offer, out and waiting for the gateway's answer: null
  // when the gateway's offer crossed it. Sent again on a resumed socket.
  Completer<duvet.SessionDescription?>? _ownAnswer;
  duvet.SessionDescription? _ownOffer;

  // How many times the offer out went (again on a resumed socket), and the
  // gateway's answers to it still to come once one was applied: stale, they
  // mustn't be taken for the next offer's.
  int _ownSends = 0;
  int _staleAnswers = 0;
  Timer? _staleTimer;
  bool _ownQueued = false;

  // The gateway's offers queued and not yet taken up: the phone's own goes
  // after them.
  int _gatewayWaiting = 0;

  // The screen's sender came or went: the phone offers it, in turn with the
  // gateway's offers, one negotiation at a time. Glare: the gateway, with its
  // own offer out, fails the phone's, so the phone gives way (rolls its offer
  // back), answers the gateway's, then offers again. Waiting for an answer
  // that never comes instead would hold every offer behind it.
  void _offerOwn(VoicePeer peer, VoiceTarget target) {
    if (_ownQueued) return;
    _ownQueued = true;
    final gate = _joined.future;
    _negotiations = _negotiations.then((_) async {
      await gate;
      _ownQueued = false;
      if (!identical(_peer, peer)) return;
      if (_gatewayWaiting > 0) {
        _offerOwn(peer, target);
        return;
      }
      try {
        final offer = await peer.createOffer();
        if (!identical(_peer, peer)) return;
        await peer.setLocalDescription(offer);
        if (!identical(_peer, peer)) return;
        duvet.SessionDescription? answer;
        if (_gatewayWaiting == 0) {
          final pending = _ownAnswer = Completer();
          _ownOffer = offer;
          _ownSends = 1;
          _signaling.sendRenegotiateOffer(target.id, offer, tracks: peer.trackLabels);
          answer = await pending.future.timeout(joinTimeout);
          if (identical(_ownAnswer, pending)) {
            _ownAnswer = null;
            _ownOffer = null;
          }
          if (!identical(_peer, peer)) return;
        }
        if (answer == null) {
          await peer.setLocalDescription(const duvet.SessionDescription(type: 'rollback', sdp: ''));
          _offerOwn(peer, target);
          return;
        }
        await peer.setRemoteDescription(answer);
        _failedOffers = 0;
      } catch (e) {
        debugPrint('voice: own offer: $e');
        if (!identical(_peer, peer)) return;
        _negotiationFailed();
      }
    });
  }

  // Forgets the negotiations of a connection that's gone.
  void _dropOwnOffer() {
    final pending = _ownAnswer;
    _ownAnswer = null;
    _ownOffer = null;
    _ownQueued = false;
    _gatewayWaiting = 0;
    _staleAnswers = 0;
    _staleTimer?.cancel();
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  void _onAnswer(duvet.RenegotiateAnswerEvent data) {
    final answer = data.answer;
    if (answer == null || data.roomId != _target?.id) return;
    // shortcut: answers carry no tag and VoicePeer shows no signaling state,
    // so an offer sent twice counts on two answers, the second dropped for
    // joinTimeout at most; if only one came, an offer answered within that
    // loses its answer and voice connects again. A tag on the gateway's
    // answers would tell for sure.
    if (_staleAnswers > 0) {
      _staleAnswers--;
      return;
    }
    if (_ownAnswer case final pending? when !pending.isCompleted) {
      pending.complete(answer);
      _staleAnswers = _ownSends - 1;
      _staleTimer?.cancel();
      if (_staleAnswers > 0) _staleTimer = Timer(joinTimeout, () => _staleAnswers = 0);
    }
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
      initiatorAvatar: data.initiatorAvatar,
      outgoing: false,
      phase: CallPhase.ringing,
      startedAt: _now(),
    );
    if (current == null) {
      _call = call;
      _callOn = null;
      _answerHeard = false;
    } else if (current.conversationId != data.conversationId) {
      // One call at a time: another one doesn't ring here, but it's missed.
      _record(call);
      _notice('Missed a call from ${data.initiatorName}');
    }
    notifyListeners();
    _answerIfWanted();
  }

  // Every member's sessions get it, whoever answered: the user themselves on
  // another device (or the caller back by calling), or anyone else.
  void _onAccepted(duvet.CallResponseEvent data) {
    final id = data.conversationId;
    var changed = false;
    if (data.userId != _me && _unanswered.contains(id)) {
      // Someone answered the user's own call: it can be joined from here.
      _unanswered = {..._unanswered}..remove(id);
      changed = true;
    }
    if (data.userId == _me && id == _cancelledIn && !_calls.contains(id)) {
      // The call cancelled here had joined one going on, which its cancel
      // left going on for the others.
      _calls = {..._calls, id};
      changed = true;
    }
    final call = _call;
    if (call != null && call.conversationId == id) {
      if (call.phase == CallPhase.calling) {
        // Someone answered, or the call placed here joined one going on:
        // the caller's voice joins.
        _call = call.answered();
        unawaited(_joinCallVoice(id));
        changed = true;
      } else if (call.phase == CallPhase.ringing && data.userId == _me) {
        // Answered on another device.
        _call = null;
        changed = true;
      } else if (call.phase == CallPhase.connected && data.userId == _me) {
        // The gateway heard this phone's answer.
        _answerHeard = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _onDeclined(duvet.CallResponseEvent data) {
    final call = _call;
    if (call == null || call.conversationId != data.conversationId) return;
    if (data.userId == _me) {
      // Declined on another device: it rings here no more.
      if (call.phase == CallPhase.ringing) {
        _call = null;
        notifyListeners();
      }
      return;
    }
    if (call.phase != CallPhase.calling) return;
    _placeHeard = true;
    _notice('${_repository.nameOf(data.userId) ?? 'They'} declined');
  }

  // A call the user started, from this phone or another of their devices: it
  // rings none of them, and goes on in that conversation, unanswered.
  void _onOutgoing(String conversationId) {
    // The one placed here and cancelled since: its cancel ends it.
    if (conversationId == _cancelledIn) return;
    _calls = {..._calls, conversationId};
    _unanswered = {..._unanswered, conversationId};
    // The gateway has the call this phone placed.
    if (_call case final c? when c.outgoing && c.conversationId == conversationId) _placeHeard = true;
    notifyListeners();
  }

  // A call goes on without ringing the user: its ring window ended before
  // they answered it, someone else having answered, or they became one of
  // its members while it went on (added to the group). It rings here no
  // more, and who is in it shows, to join it with [joinCall].
  void _onOngoing(duvet.CallOngoingEvent data) {
    _calls = {..._calls, data.conversationId};
    _states.ongoing(data);
    _keepWatching();
    if (_call case final c? when c.phase == CallPhase.ringing && c.conversationId == data.conversationId) {
      // Answered on none of the user's devices: missed.
      _record(c);
      _call = null;
    }
    notifyListeners();
  }

  void _onEnded(String conversationId) {
    if (_answerFor?.conversationId == conversationId) _answerFor = null;
    _calls = {..._calls}..remove(conversationId);
    _unanswered = {..._unanswered}..remove(conversationId);
    if (conversationId == _cancelledIn) _cancelledIn = null;
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
    final suppressing = _noiseSuppression;
    final mic = await _engine.openMicrophone(noiseSuppression: suppressing);
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
    _placedWith = ids;
    _placeHeard = false;
    // What the gateway says of this conversation's call is this one's now.
    if (_cancelledIn == conversationId) _cancelledIn = null;
    _calls = {..._calls, conversationId};
    _mic = mic;
    _micSuppressing = suppressing;
    if (mic != null) _keepAlive(CallVoice(conversationId));
    notifyListeners();
  }

  /// Joins the call going on in [conversationId]: one that rang out, or that
  /// the user left. Not the user's own while it still rings the others (see
  /// [ownCallRinging]).
  Future<void> joinCall(String conversationId) async {
    if (ownCallRinging(conversationId)) return;
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
    _answerHeard = false;
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

  /// Answers the call of [conversationId] from its notification's Answer, which
  /// opened the app: at once when it rings here already, else as it does
  /// (READY or CALL_INCOMING, once the app connects), within [answerWait].
  void answerWhenRinging(String conversationId) {
    _answerFor = (conversationId: conversationId, until: _now().add(answerWait));
    _answerIfWanted();
  }

  // Answers the call ringing here when the notification's Answer was for it. Kept until the answer goes: the gateway may
  // be out of reach yet (READY and resumes try it again); a call of that conversation that ends, or that a READY doesn't
  // list as ringing, drops it.
  void _answerIfWanted() {
    final wanted = _answerFor;
    if (wanted == null) return;
    if (!_now().isBefore(wanted.until)) {
      _answerFor = null;
      return;
    }
    final call = _call;
    if (call == null || call.phase != CallPhase.ringing || call.conversationId != wanted.conversationId) return;
    final answered = _sendAnswer(offlineNotice: false);
    if (answered == null) return;
    _answerFor = null;
    unawaited(_joinCallVoice(answered));
  }

  /// Answers the call ringing here.
  Future<void> acceptCall() async {
    final answered = _sendAnswer(offlineNotice: true);
    if (answered != null) await _joinCallVoice(answered);
  }

  // Sends the answer to the call ringing here, whose conversation it returns: null when none rings, or the gateway is
  // out of reach, which [offlineNotice] tells the user.
  String? _sendAnswer({required bool offlineNotice}) {
    final call = _call;
    if (call == null || call.phase != CallPhase.ringing) return null;
    if (!_signaling.acceptCall(call.conversationId)) {
      if (offlineNotice) _notice('You’re offline: the call can’t be answered');
      return null;
    }
    _callOn = _signaling.connection;
    _answerHeard = false;
    _call = call.answered();
    notifyListeners();
    return call.conversationId;
  }

  /// Turns down the call ringing here.
  void declineCall() {
    final call = _call;
    if (call == null || call.phase != CallPhase.ringing) return;
    // Offline it goes nowhere: the call rings out on the user's other devices, as the gateway takes a dropped session
    // for no answer while the call rings it (it may ring the phone through its notification).
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
        // The gateway ends a call its caller cancels. Not always one placed
        // into a call going on, which joined it: then the CALL_ACCEPTED of
        // this user that follows shows it again (see [_onAccepted]).
        if (_signaling.cancelCall(call.conversationId)) _cancelledIn = call.conversationId;
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
    _canVideo = true;
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

  // Leaves ([leave] does) for another voice: its connection, and any that
  // still wait for a newer one to exist, close only once the next one exists
  // (see [_connect]), as on Android the audio session ends with the last one.
  void _handOver(void Function() leave) {
    final kept = [..._retired, ?_peer];
    _retired.clear();
    _peer = null;
    leave();
    _retired.addAll(kept);
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

  void _startPing() {
    if (_pingTimer != null) return;
    unawaited(_readPing());
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (_inFront()) unawaited(_readPing());
    });
  }

  Future<void> _readPing() async {
    final peer = _peer;
    if (peer == null) return;
    try {
      final rtt = await peer.roundTrip();
      if (identical(_peer, peer) && rtt != null) ping.value = rtt.inMilliseconds;
    } catch (e) {
      debugPrint('voice: ping: $e');
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
    _watching = const [];
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
    _pingTimer?.cancel();
    _pingTimer = null;
    _negotiationReady = false;
    _remoteSet = false;
    _pendingCandidates.clear();
    _dropOwnOffer();
    if (!_joined.isCompleted) _joined.complete();
    final peer = _peer;
    final mic = _mic;
    _peer = null;
    _mic = null;
    // The connection closes: the captures only stop, releasing the camera.
    _cameraOff();
    _screenOff();
    _watchVideos(null);
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
    ping.value = null;
  }

  void _notice(String text) {
    if (!_notices.isClosed) _notices.add(text);
  }

  // ---------------------------------------------------------------------------
  // Sounds
  // ---------------------------------------------------------------------------

  // Someone else in the user's voice joined, left, or started or stopped
  // sharing their screen; [before] is what was known of them. Snapshots
  // (READY, SPACE_CREATE, CALL_ONGOING) aren't updates, and a catch-up
  // update of someone known changes nothing, so joining makes no sound.
  void _cue(duvet.VoiceParticipant? before, duvet.VoiceStateEvent now) {
    final sounds = _sounds;
    if (sounds == null) return;
    final sound = switch ((before, now.joined)) {
      (null, true) => Sound.voiceJoin,
      (_?, false) => Sound.voiceLeave,
      (final b?, true) when b.screenSharing != now.screenSharing =>
        now.screenSharing ? Sound.screenShareOn : Sound.screenShareOff,
      _ => null,
    };
    if (sound != null) unawaited(sounds.play(sound));
  }

  bool _ringing = false;

  // Rings while a call rings here, and stops the moment it doesn't:
  // answered, declined, cancelled, ended, replaced. Off screen the call's
  // notification rings it (lib/push), unless the phone shows none of Duvet's.
  void _followRing() {
    final call = _call;
    final rings = call != null && call.phase == CallPhase.ringing;
    if (rings) {
      _ringFollowsScreen ??= _lifecycle.listen((_) => _followRing());
    } else if (_ringFollowsScreen case final screen?) {
      _ringFollowsScreen = null;
      unawaited(screen.cancel());
    }
    final onScreen = rings && _inFront();
    _followCallNotice(rings ? call : null, onScreen: onScreen);
    final ringing = rings && (onScreen || _callNotices == null || _noNotice);
    if (ringing == _ringing) return;
    _ringing = ringing;
    final sounds = _sounds;
    if (sounds != null) unawaited(ringing ? sounds.startRing() : sounds.stopRing());
  }

  // The notification of the call [ringing] here: on screen the app rings the
  // call, and takes the notification away, now and every 2 s, for a push that
  // was on its way; off screen the notification rings it, which the app puts
  // up as Duvet leaves the screen; and it goes once the call rings here no
  // more.
  void _followCallNotice(ActiveCall? ringing, {required bool onScreen}) {
    final notices = _callNotices;
    if (notices == null) return;
    final conversationId = ringing?.conversationId;
    if (_ringingIn case final was? when was != conversationId) {
      notices.hide(was);
      _shownAway = _noNotice = false;
    }
    _ringingIn = conversationId;
    if (ringing == null || !onScreen) {
      _hideAgain?.cancel();
      _hideAgain = null;
    }
    if (ringing == null) return;
    if (onScreen) {
      _shownAway = false;
      if (_hideAgain == null) {
        notices.hide(ringing.conversationId);
        _hideAgain = Timer.periodic(const Duration(seconds: 2), (_) => notices.hide(ringing.conversationId));
      }
    } else if (!_shownAway) {
      _shownAway = true;
      unawaited(
        notices.show(ringing).then((shown) {
          if (_ringingIn != ringing.conversationId || _noNotice != shown) return;
          // Without the notification, the app rings on itself.
          _noNotice = !shown;
          _followRing();
        }),
      );
    }
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
      _unanswered = const {};
      _cancelledIn = null;
      _states.reset();
      _iceServers = _stun;
      _muted = false;
      _deafened = false;
      _incomingVideo = true;
      _cameraDevice = null;
      unawaited(history.close(forget: me == null));
      notifyListeners();
    }
    if (me != null) unawaited(history.load(me));
  }

  @override
  void dispose() {
    _teardown(sendLeave: true);
    unawaited(_events.cancel());
    unawaited(_resumes.cancel());
    unawaited(_signedOut.cancel());
    _repository.profile.removeListener(_onProfile);
    _repository.spaces.removeListener(_checkPerms);
    unawaited(_ringFollowsScreen?.cancel());
    _hideAgain?.cancel();
    if (_ringing) unawaited(_sounds?.stopRing());
    unawaited(_notices.close());
    levels.dispose();
    ping.dispose();
    _remoteVideos.dispose();
    history.dispose();
    super.dispose();
  }
}

/// [VoiceController.levels], which knows whether anything shows them.
class _Levels extends ValueNotifier<Map<String, double>> {
  _Levels() : super(const {});

  bool get watched => hasListeners;
}
