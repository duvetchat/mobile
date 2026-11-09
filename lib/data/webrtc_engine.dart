import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:permission_handler/permission_handler.dart';

import 'voice_engine.dart';

/// [VoiceEngine] over flutter_webrtc, with flutter_background's foreground
/// service on Android.
///
/// Nothing touches a plugin until a voice session starts: the app builds one
/// at launch, and widget tests build it without the plugins.
///
/// On Android, flutter_webrtc routes audio with Twilio's AudioSwitch, which
/// it starts when the microphone opens (in-communication mode, audio focus)
/// and stops when the last peer connection is disposed; it sees a Bluetooth
/// headset only with BLUETOOTH_CONNECT granted before it starts.
class WebRtcVoiceEngine implements VoiceEngine {
  WebRtcVoiceEngine({@visibleForTesting bool? android}) : _android = android ?? Platform.isAndroid;

  final bool _android;
  bool _prepared = false;
  bool _askedNotifications = false;
  final _routes = ValueNotifier(AudioRoutes.none);
  bool _listening = false;

  // The route picked last, by the user or as a session's default: the
  // platform doesn't tell which one plays.
  AudioRoute? _chosen;
  bool _speakerDefault = true;

  @override
  ValueListenable<AudioRoutes> get routes => _routes;

  @override
  Future<void> prepare() async {
    if (_prepared) return;
    _prepared = true;
    if (!_android) return;
    try {
      // Once: after a refusal Android shows the rationale flag, and the answer
      // stands. (Granted below Android 12, where the permission doesn't exist.)
      final status = await Permission.bluetoothConnect.status;
      if (status.isDenied && !await Permission.bluetoothConnect.shouldShowRequestRationale) {
        await Permission.bluetoothConnect.request();
      }
    } catch (e) {
      debugPrint('voice: Bluetooth permission: $e');
    }
  }

  @override
  Future<VoiceMic?> openMicrophone({bool noiseSuppression = true}) async {
    try {
      final stream = await rtc.navigator.mediaDevices.getUserMedia(
        microphoneConstraints(noiseSuppression: noiseSuppression),
      );
      final tracks = stream.getAudioTracks();
      if (tracks.isEmpty) {
        await stream.dispose();
        return null;
      }
      _listenForDevices();
      return _Mic(stream, tracks.first);
    } catch (e) {
      // Refused, or no microphone.
      debugPrint('voice: microphone: $e');
      return null;
    }
  }

  @override
  Future<List<VoiceCameraDevice>> cameras() async {
    try {
      return [
        for (final d in await rtc.navigator.mediaDevices.enumerateDevices())
          if (d.kind == 'videoinput') VoiceCameraDevice(id: d.deviceId, label: d.label, facing: cameraFacing(d.label)),
      ];
    } catch (e) {
      debugPrint('voice: cameras: $e');
      return const [];
    }
  }

  @override
  Future<VoiceCamera?> openCamera({String? deviceId}) async {
    try {
      // iOS: flutter_webrtc asks itself (permission_handler's camera is
      // compiled out there).
      if (_android && !await Permission.camera.request().isGranted) return null;
      final stream = await rtc.navigator.mediaDevices.getUserMedia(cameraConstraints(deviceId));
      final tracks = stream.getVideoTracks();
      if (tracks.isEmpty) {
        await stream.dispose();
        return null;
      }
      // The camera that opened, by the id its track reports: asked for the
      // front one, a phone with only a back one opens that.
      final opened = tracks.first.getSettings()['deviceId'] as String? ?? deviceId;
      final facing =
          (await cameras()).where((d) => d.id == opened).firstOrNull?.facing ??
          (deviceId == null ? CameraFacing.front : CameraFacing.external);
      return _Camera(stream, tracks.first, facing);
    } catch (e) {
      // Refused, or no camera.
      debugPrint('voice: camera: $e');
      return null;
    }
  }

  /// The app's own foreground service of the screen capture type (MainActivity,
  /// ScreenCaptureService): Android 10 and later capture the screen only under
  /// one, and flutter_background's carries only the microphone type (it starts
  /// with every type it has, and on Android 14 a screen capture type fails to
  /// start before the consent).
  static const _screenService = MethodChannel('chat.duvet/screen');

  // shortcut: flutter_webrtc 1.6.3 ignores MediaProjection's onStop, so a
  // share stopped from the system's UI never ends the track (onEnded stays
  // silent); the user stops it in the app.
  @override
  Future<VoiceScreen?> openScreen() async {
    if (!_android) return null;
    var serviceStarted = false;
    rtc.MediaStream? stream;
    try {
      // The consent, then the service, then the capture: Android 14 lets a
      // screen capture service start only after the consent, and the capture
      // only under that service. Helper.requestCapturePermission asks the
      // same, behind a platform check a test can't pass.
      final granted = await rtc.WebRTC.invokeMethod<bool, dynamic>('requestCapturePermission', {
        'fullScreenOnly': false,
      });
      if (granted != true) return null;
      await _screenService.invokeMethod<void>('start');
      serviceStarted = true;
      stream = await rtc.navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final tracks = stream.getVideoTracks();
      if (tracks.isEmpty) throw StateError('no screen track');
      return _Screen(stream, tracks.first, _stopScreenService);
    } catch (e) {
      debugPrint('voice: screen: $e');
      try {
        await stream?.dispose();
      } catch (e) {
        debugPrint('voice: screen: $e');
      }
      if (serviceStarted) await _stopScreenService();
      return null;
    }
  }

  static Future<void> _stopScreenService() async {
    try {
      await _screenService.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('voice: screen: $e');
    }
  }

  @override
  Future<VoicePeer> createPeer(List<duvet.IceServer> iceServers) async {
    final pc = await rtc.createPeerConnection({
      'iceServers': [for (final s in iceServers) s.toJson()],
      'sdpSemantics': 'unified-plan',
    });
    return _Peer(pc);
  }

  void _listenForDevices() {
    if (_listening) return;
    _listening = true;
    rtc.navigator.mediaDevices.ondevicechange = (_) => unawaited(_refreshRoutes());
  }

  @override
  Future<void> useDefaultRoute({required bool speaker}) async {
    _speakerDefault = speaker;
    _chosen = null;
    try {
      if (speaker) {
        // A headset if there is one, else the loudspeaker.
        await rtc.Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        // A headset if there is one, else the earpiece.
        await rtc.Helper.setSpeakerphoneOn(false);
      }
    } catch (e) {
      debugPrint('voice: route: $e');
    }
    await _refreshRoutes();
  }

  @override
  Future<void> selectRoute(AudioRoute route) async {
    try {
      if (Platform.isIOS && route.kind != AudioRouteKind.speaker) {
        // iOS switches between the loudspeaker and the route it prefers.
        await rtc.Helper.setSpeakerphoneOn(false);
      } else {
        await rtc.Helper.selectAudioOutput(route.id);
      }
      _chosen = route;
    } catch (e) {
      debugPrint('voice: route: $e');
    }
    await _refreshRoutes();
  }

  Future<void> _refreshRoutes() async {
    try {
      final devices = await rtc.navigator.mediaDevices.enumerateDevices();
      final available = <AudioRoute>[
        for (final d in devices)
          if (d.kind == 'audiooutput')
            AudioRoute(id: d.deviceId, kind: routeKind(d.deviceId, d.groupId), label: d.label),
      ];
      _routes.value = AudioRoutes(available: available, current: currentRoute(available, _chosen, _speakerDefault));
    } catch (e) {
      debugPrint('voice: routes: $e');
    }
  }

  // Starts and stops of the service, one after another: a session that
  // ends as the next one starts (a call placed from a voice room) stops it
  // before starting it again, never after.
  Future<void> _service = Future.value();

  Future<void> _inTurn(Future<void> Function() change) =>
      _service = _service.then((_) => change()).catchError((Object e) {
        debugPrint('voice: keep alive: $e');
      });

  @override
  Future<void> keepAlive(String title) {
    if (!_android) return Future.value();
    return _inTurn(() async {
      if (!_askedNotifications) {
        _askedNotifications = true;
        // Android 13 and later: the call's notification shows only with it.
        await Permission.notification.request();
      }
      final ready = await FlutterBackground.initialize(
        androidConfig: FlutterBackgroundAndroidConfig(
          notificationTitle: title,
          notificationText: 'Tap to return to Duvet',
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          // Battery optimizations stay as they are: the service and its wake
          // lock carry a call.
          shouldRequestBatteryOptimizationsOff: false,
        ),
      );
      if (ready && !FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
    });
  }

  @override
  Future<void> letSleep() {
    _routes.value = AudioRoutes.none;
    _chosen = null;
    if (!_android) return Future.value();
    return _inTurn(() async {
      if (FlutterBackground.isBackgroundExecutionEnabled) await FlutterBackground.disableBackgroundExecution();
    });
  }
}

/// What kind of output a device is, from what flutter_webrtc calls it:
/// Android's `speaker`, `earpiece`, `bluetooth` and `wired-headset`, or iOS's
/// port types.
@visibleForTesting
AudioRouteKind routeKind(String id, String? group) {
  final name = '$id ${group ?? ''}'.toLowerCase();
  if (name.contains('bluetooth')) return AudioRouteKind.bluetooth;
  if (name.contains('wired') || name.contains('headphone') || name.contains('headset')) return AudioRouteKind.wired;
  if (name.contains('speaker')) return AudioRouteKind.speaker;
  return AudioRouteKind.earpiece;
}

/// The route that plays now, as Android's AudioSwitch picks it: the one
/// chosen while it's there, else a headset (Bluetooth first), else the
/// loudspeaker or the earpiece, as the session prefers.
@visibleForTesting
AudioRoute? currentRoute(List<AudioRoute> available, AudioRoute? chosen, bool speaker) {
  if (chosen != null && available.contains(chosen)) return chosen;
  AudioRoute? of(AudioRouteKind kind) => available.where((r) => r.kind == kind).firstOrNull;
  return of(AudioRouteKind.bluetooth) ??
      of(AudioRouteKind.wired) ??
      (speaker
          ? of(AudioRouteKind.speaker) ?? of(AudioRouteKind.earpiece)
          : of(AudioRouteKind.earpiece) ?? of(AudioRouteKind.speaker));
}

/// getUserMedia's microphone. flutter_webrtc passes audio constraints to
/// WebRTC only as `mandatory` and `optional`, under WebRTC's own names, as
/// strings.
@visibleForTesting
Map<String, Object> microphoneConstraints({required bool noiseSuppression}) => {
  'audio': {
    'mandatory': {
      'googNoiseSuppression': '$noiseSuppression',
      'googEchoCancellation': 'true',
      'googAutoGainControl': 'true',
    },
    'optional': <Object>[],
  },
  'video': false,
};

/// getUserMedia's camera: [deviceId], else the front one, at 640x360 and up
/// to 30 fps.
@visibleForTesting
Map<String, Object> cameraConstraints(String? deviceId) => {
  'audio': false,
  'video': {
    'deviceId': ?deviceId,
    if (deviceId == null) 'facingMode': 'user',
    'width': 640,
    'height': 360,
    'frameRate': 30,
  },
};

/// Which way a camera faces, from its name: flutter_webrtc drops Android's
/// facing and keeps it in the label ("Camera 1, Facing front, Orientation
/// 270"), and iOS names its cameras "Front Camera", "Back Camera"…
@visibleForTesting
CameraFacing cameraFacing(String label) {
  final name = label.toLowerCase();
  if (name.contains('front')) return CameraFacing.front;
  if (name.contains('back') || name.contains('rear')) return CameraFacing.back;
  return CameraFacing.external;
}

/// Whose video a remote stream is: the gateway sends a user's camera as
/// `<user_id>.camera` and their screen in `<user_id>` (with their audio).
/// Anything else is no one's.
@visibleForTesting
({String userId, VideoKind kind})? videoOwner(String streamId) {
  final parts = streamId.split('.');
  return switch (parts) {
    [final id] when id.isNotEmpty => (userId: id, kind: VideoKind.screen),
    [final id, 'camera'] when id.isNotEmpty => (userId: id, kind: VideoKind.camera),
    _ => null,
  };
}

/// [codecs] with VP8 first, the rest as they were: the gateway forwards video
/// as it comes, and every client decodes VP8.
@visibleForTesting
List<rtc.RTCRtpCodecCapability> vp8First(List<rtc.RTCRtpCodecCapability> codecs) {
  bool vp8(rtc.RTCRtpCodecCapability c) => c.mimeType.toLowerCase() == 'video/vp8';
  return [...codecs.where(vp8), ...codecs.where((c) => !vp8(c))];
}

/// A renderer that is released only once it's ready: flutter_webrtc leaks the
/// texture of one disposed while it initializes.
class _Renderer {
  final renderer = rtc.RTCVideoRenderer();
  late final Future<void> _ready = renderer.initialize();
  bool _released = false;

  /// Shows [stream] once ready.
  void show(rtc.MediaStream stream) => unawaited(
    _ready
        .then((_) {
          if (!_released) renderer.srcObject = stream;
        })
        .catchError((Object e) => debugPrint('voice: video: $e')),
  );

  void release() {
    if (_released) return;
    _released = true;
    unawaited(_ready.then((_) => renderer.dispose()).catchError((Object e) => debugPrint('voice: video: $e')));
  }
}

/// A local capture's view, with its own renderer.
class _Preview extends StatefulWidget {
  final rtc.MediaStream stream;
  final bool mirror;
  const _Preview(this.stream, this.mirror);

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final _renderer = _Renderer();

  @override
  void initState() {
    super.initState();
    _renderer.show(widget.stream);
  }

  // Another capture in the same place (a new camera picked): show it, not the stopped one.
  @override
  void didUpdateWidget(_Preview old) {
    super.didUpdateWidget(old);
    if (old.stream != widget.stream) _renderer.show(widget.stream);
  }

  @override
  void dispose() {
    _renderer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => rtc.RTCVideoView(
    _renderer.renderer,
    mirror: widget.mirror,
    objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );
}

class _Capture implements VoiceVideoSource {
  final rtc.MediaStream stream;
  final rtc.MediaStreamTrack track;
  final _ended = StreamController<void>.broadcast();
  bool _stopped = false;

  _Capture(this.stream, this.track) {
    track.onEnded = () {
      if (!_stopped) _ended.add(null);
    };
  }

  @override
  Widget preview({bool mirror = false}) => _Preview(stream, mirror);

  @override
  Stream<void> get onEnded => _ended.stream;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    unawaited(_ended.close());
    try {
      await track.stop();
      await stream.dispose();
    } catch (e) {
      debugPrint('voice: video: $e');
    }
  }
}

class _Camera extends _Capture implements VoiceCamera {
  @override
  CameraFacing facing;

  _Camera(super.stream, super.track, this.facing);

  @override
  Future<void> switchFacing() async {
    try {
      // It answers whether the camera now is the front one.
      final front = await rtc.Helper.switchCamera(track);
      facing = front ? CameraFacing.front : CameraFacing.back;
    } catch (e) {
      debugPrint('voice: camera: $e');
    }
  }
}

class _Screen extends _Capture implements VoiceScreen {
  // Stops the screen capture service once the capture is over.
  final Future<void> Function() _release;

  _Screen(super.stream, super.track, this._release);

  @override
  Future<void> stop() async {
    if (_stopped) return;
    await super.stop();
    await _release();
  }
}

class _Mic implements VoiceMic {
  final rtc.MediaStream stream;
  final rtc.MediaStreamTrack track;
  _Mic(this.stream, this.track);

  @override
  Future<void> stop() async {
    try {
      await track.stop();
      await stream.dispose();
    } catch (e) {
      debugPrint('voice: microphone: $e');
    }
  }
}

class _Peer implements VoicePeer {
  final rtc.RTCPeerConnection _pc;
  rtc.RTCRtpSender? _sender;
  rtc.MediaStreamTrack? _micTrack;
  bool _sending = false;
  bool _receiving = true;

  // The others' audio, by track ID, and whose each is: the gateway names a
  // user's stream after them (`<user_id>`, or `<user_id>.camera`).
  final _tracks = <String, rtc.MediaStreamTrack>{};
  final _owners = <String, String>{};

  // What the last stats read said, per track (and 'local'): the energy and
  // duration totals, to average the level between two reads.
  final _totals = <String, ({double energy, double duration})>{};

  // The camera transceiver's sender, the screen's while shared, and the
  // camera's mid once the local description has one.
  rtc.RTCRtpSender? _cameraSender;
  rtc.RTCRtpSender? _screenSender;
  var _labels = const <String, String>{};
  void Function()? _negotiationNeeded;

  // The others' cameras and screens, by track ID.
  final _videos = <String, ({VoiceRemoteVideo video, _Renderer renderer})>{};
  final _remoteVideos = ValueNotifier<List<VoiceRemoteVideo>>(const []);

  _Peer(this._pc) {
    _pc.onTrack = _onTrack;
    _pc.onRemoveTrack = (_, track) {
      _forget(track.id);
      _dropVideo(track.id);
    };
  }

  void _forget(String? trackId) {
    _tracks.remove(trackId);
    _owners.remove(trackId);
    _totals.remove(trackId);
  }

  @override
  set onIceCandidate(void Function(duvet.IceCandidateInit candidate)? handler) => _pc.onIceCandidate = handler == null
      ? null
      : (c) {
          final line = c.candidate;
          if (line == null || line.isEmpty) return;
          handler(duvet.IceCandidateInit(candidate: line, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex));
        };

  @override
  set onState(void Function(PeerState state)? handler) => _pc.onConnectionState = handler == null
      ? null
      : (s) => handler(switch (s) {
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected => PeerState.connected,
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => PeerState.disconnected,
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed => PeerState.failed,
          rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed => PeerState.closed,
          _ => PeerState.connecting,
        });

  void _onTrack(rtc.RTCTrackEvent event) {
    final track = event.track;
    final id = track.id;
    if (id == null) return;
    if (track.kind == 'video') return _showVideo(id, track, event.streams.firstOrNull);
    if (track.kind != 'audio') return;
    final stream = event.streams.firstOrNull?.id;
    _tracks[id] = track;
    if (stream != null) _owners[id] = stream.split('.').first;
    track.enabled = _receiving;
    track.onEnded = () => _forget(id);
  }

  void _showVideo(String id, rtc.MediaStreamTrack track, rtc.MediaStream? stream) {
    final owner = stream == null ? null : videoOwner(stream.id);
    if (stream == null || owner == null) return;
    final renderer = _Renderer()..show(stream);
    final kind = owner.kind;
    final video = VoiceRemoteVideo(
      userId: owner.userId,
      kind: kind,
      view: (mirror) => rtc.RTCVideoView(
        renderer.renderer,
        mirror: mirror,
        // A screen whole, a face filling its tile.
        objectFit: kind == VideoKind.camera
            ? rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
            : rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      ),
    );
    // One per user and kind, and per track: a new one replaces the old.
    for (final old in [
      for (final e in _videos.entries)
        if (e.key == id || e.value.video == video) e.key,
    ]) {
      _dropVideo(old, publish: false);
    }
    _videos[id] = (video: video, renderer: renderer);
    track.onEnded = () => _dropVideo(id);
    _publishVideos();
  }

  void _dropVideo(String? id, {bool publish = true}) {
    final entry = _videos.remove(id);
    if (entry == null) return;
    entry.renderer.release();
    if (publish) _publishVideos();
  }

  void _publishVideos() => _remoteVideos.value = [for (final v in _videos.values) v.video];

  @override
  ValueListenable<List<VoiceRemoteVideo>> get remoteVideos => _remoteVideos;

  @override
  set onNegotiationNeeded(void Function()? handler) => _negotiationNeeded = handler;

  @override
  Map<String, String> get trackLabels => _labels;

  @override
  Future<void> addVideo() async {
    if (_cameraSender != null) return;
    final transceiver = await _pc.addTransceiver(
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.SendRecv,
        sendEncodings: [rtc.RTCRtpEncoding(maxBitrate: 500000, maxFramerate: 30)],
      ),
    );
    _cameraSender = transceiver.sender;
    try {
      final codecs = (await rtc.getRtpReceiverCapabilities('video')).codecs ?? const [];
      await transceiver.setCodecPreferences(vp8First(codecs));
    } catch (e) {
      // WebRTC's own order then: the gateway still picks one both sides have.
      debugPrint('voice: codecs: $e');
    }
  }

  @override
  Future<void> setCamera(VoiceCamera? camera) async =>
      _cameraSender?.replaceTrack(camera is _Camera ? camera.track : null);

  @override
  Future<void> setScreen(VoiceScreen? screen) async {
    final track = screen is _Screen ? screen.track : null;
    final sender = _screenSender;
    if (track == null && sender == null) return;
    if (track != null && sender != null) {
      // Another screen on the same sender: nothing to negotiate.
      await sender.replaceTrack(track);
      return;
    }
    if (sender != null) {
      await _pc.removeTrack(sender);
      _screenSender = null;
    } else {
      _screenSender = await _pc.addTrack(track!, (screen as _Screen).stream);
    }
    _negotiationNeeded?.call();
  }

  @override
  Future<void> addAudio(VoiceMic? mic) async {
    if (mic is _Mic) {
      _micTrack = mic.track;
      _sender = await _pc.addTrack(mic.track, mic.stream);
      _sending = true;
    } else {
      // Sends nothing until a microphone comes: no renegotiation then.
      final transceiver = await _pc.addTransceiver(
        kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.SendRecv),
      );
      _sender = transceiver.sender;
    }
  }

  @override
  Future<void> useMicrophone(VoiceMic mic) async {
    if (mic is! _Mic) return;
    _micTrack = mic.track;
    if (_sending) await _sender?.replaceTrack(mic.track);
  }

  @override
  Future<void> setSending(bool sending) async {
    _sending = sending;
    await _sender?.replaceTrack(sending ? _micTrack : null);
  }

  @override
  Future<void> setReceiving(bool receiving) async {
    _receiving = receiving;
    for (final track in _tracks.values) {
      track.enabled = receiving;
    }
  }

  static duvet.SessionDescription _description(rtc.RTCSessionDescription d) =>
      duvet.SessionDescription(type: d.type ?? '', sdp: d.sdp ?? '');

  // flutter_webrtc reads only `mandatory` and `optional` (a flat map was
  // ignored), and with no map at all it asks for video too. Video isn't
  // named: false would take receiving off every video transceiver, the
  // others' cameras and screens with them.
  @override
  Future<duvet.SessionDescription> createOffer() async => _description(
    await _pc.createOffer({
      'mandatory': {'OfferToReceiveAudio': true},
      'optional': [],
    }),
  );

  @override
  Future<duvet.SessionDescription> createAnswer() async => _description(await _pc.createAnswer({}));

  @override
  Future<void> setLocalDescription(duvet.SessionDescription d) async {
    await _pc.setLocalDescription(rtc.RTCSessionDescription(d.sdp, d.type));
    final camera = _cameraSender;
    if (camera == null) return;
    // flutter_webrtc's transceivers keep the mid they had when read: a fresh
    // read has the one the description gave it.
    final transceivers = await _pc.getTransceivers();
    final mid = transceivers.where((t) => t.sender.senderId == camera.senderId).firstOrNull?.mid;
    _labels = mid == null || mid.isEmpty ? const {} : {mid: 'camera'};
  }

  @override
  Future<void> setRemoteDescription(duvet.SessionDescription d) =>
      _pc.setRemoteDescription(rtc.RTCSessionDescription(d.sdp, d.type));

  @override
  Future<void> addIceCandidate(duvet.IceCandidateInit c) =>
      _pc.addCandidate(rtc.RTCIceCandidate(c.candidate, c.sdpMid, c.sdpMLineIndex));

  @override
  Future<AudioLevels> audioLevels() async {
    final reports = await _pc.getStats();
    double? local;
    final remote = <String, double>{};
    for (final report in reports) {
      final v = report.values;
      if (v['kind'] != 'audio') continue;
      if (report.type == 'inbound-rtp') {
        final track = v['trackIdentifier'];
        final owner = track is String ? _owners[track] : null;
        if (owner == null) continue;
        final level = _level(track as String, v);
        if (level != null) remote[owner] = math.max(remote[owner] ?? 0, level);
      } else if (report.type == 'media-source') {
        local = _level('local', v) ?? local;
      }
    }
    return (local: local, remote: remote);
  }

  @override
  Future<Duration?> roundTrip() async {
    final reports = await _pc.getStats();
    final pairs = {
      for (final r in reports)
        if (r.type == 'candidate-pair') r.id: r.values,
    };
    final selected = reports.where((r) => r.type == 'transport').firstOrNull?.values['selectedCandidatePairId'];
    // Not every platform names the selected pair: the nominated one that works is it.
    final pair =
        pairs[selected] ?? pairs.values.where((v) => v['nominated'] == true && v['state'] == 'succeeded').firstOrNull;
    final seconds = (pair?['currentRoundTripTime'] as num?)?.toDouble();
    return seconds == null ? null : Duration(microseconds: (seconds * 1e6).round());
  }

  // The average level since the last read: the square root of the energy
  // over the time (both totals grow as audio comes), else the instant level.
  double? _level(String key, Map<dynamic, dynamic> v) {
    final energy = (v['totalAudioEnergy'] as num?)?.toDouble();
    final duration = (v['totalSamplesDuration'] as num?)?.toDouble();
    if (energy != null && duration != null) {
      final last = _totals[key];
      _totals[key] = (energy: energy, duration: duration);
      if (last != null && duration > last.duration) {
        return math.sqrt(math.max(0, energy - last.energy) / (duration - last.duration));
      }
    }
    return (v['audioLevel'] as num?)?.toDouble();
  }

  @override
  Future<void> close() async {
    for (final id in [..._videos.keys]) {
      _dropVideo(id, publish: false);
    }
    _publishVideos();
    try {
      await _pc.close();
      await _pc.dispose();
    } catch (e) {
      debugPrint('voice: close: $e');
    }
  }
}
