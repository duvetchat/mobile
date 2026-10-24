import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
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
  Future<VoiceMic?> openMicrophone() async {
    try {
      final stream = await rtc.navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
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

  _Peer(this._pc) {
    _pc.onTrack = _onTrack;
    _pc.onRemoveTrack = (_, track) => _forget(track.id);
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
    if (track.kind != 'audio' || id == null) return;
    final stream = event.streams.firstOrNull?.id;
    _tracks[id] = track;
    if (stream != null) _owners[id] = stream.split('.').first;
    track.enabled = _receiving;
    track.onEnded = () => _forget(id);
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
  // ignored), and with no map at all it asks for video too.
  @override
  Future<duvet.SessionDescription> createOffer() async => _description(
    await _pc.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
      'optional': [],
    }),
  );

  @override
  Future<duvet.SessionDescription> createAnswer() async => _description(await _pc.createAnswer({}));

  @override
  Future<void> setLocalDescription(duvet.SessionDescription d) =>
      _pc.setLocalDescription(rtc.RTCSessionDescription(d.sdp, d.type));

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
    try {
      await _pc.close();
      await _pc.dispose();
    } catch (e) {
      debugPrint('voice: close: $e');
    }
  }
}
