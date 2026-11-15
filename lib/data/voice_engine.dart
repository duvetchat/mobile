import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The phone's side of voice: the microphone, the peer connection to the
/// gateway, where the sound plays, and what keeps a call going in the
/// background. [WebRtcVoiceEngine] is flutter_webrtc's; tests pass a fake, so
/// nothing here touches a plugin.
abstract interface class VoiceEngine {
  /// Asks, once, for what routing needs before the first call: Bluetooth's
  /// permission on Android 12 and later, without which a headset can't carry
  /// the call.
  Future<void> prepare();

  /// Opens the microphone, asking for it the first time; null when the user
  /// refused it or there is none. [noiseSuppression] is WebRTC's own; echo
  /// cancellation and gain control stay on either way.
  Future<VoiceMic?> openMicrophone({bool noiseSuppression = true});

  /// The phone's cameras; empty when it has none.
  Future<List<VoiceCameraDevice>> cameras();

  /// Opens a camera ([deviceId], else the front one) at 640x360 and up to 30
  /// fps, asking for it the first time; null when the user refused it or there
  /// is none.
  Future<VoiceCamera?> openCamera({String? deviceId});

  /// Captures the screen (Android's screen capture, which asks every time);
  /// null when the user refused it or the phone can't (iOS).
  Future<VoiceScreen?> openScreen();

  /// A peer connection to the gateway over [iceServers] (READY's STUN and
  /// TURN servers).
  Future<VoicePeer> createPeer(List<duvet.IceServer> iceServers);

  /// Where the sound can play now, and where it plays.
  ValueListenable<AudioRoutes> get routes;

  /// Plays the sound on [route].
  Future<void> selectRoute(AudioRoute route);

  /// The route a session starts on: the loudspeaker for a voice room, the
  /// earpiece for a call; a headset first, either way.
  Future<void> useDefaultRoute({required bool speaker});

  /// Keeps the app running while in voice with the phone locked or another
  /// app open: Android's foreground service, its notification titled [title].
  /// It needs the microphone, already granted.
  Future<void> keepAlive(String title);

  /// The session is over: the app may sleep again.
  Future<void> letSleep();
}

/// The open microphone.
abstract interface class VoiceMic {
  /// Releases it, and with it the system's microphone indicator.
  Future<void> stop();
}

/// A camera the user can pick.
class VoiceCameraDevice {
  final String id;
  final String label;
  final CameraFacing facing;
  const VoiceCameraDevice({required this.id, required this.label, required this.facing});
}

enum CameraFacing { front, back, external }

/// A local video capture: the camera or the screen.
abstract interface class VoiceVideoSource {
  /// What it captures, cover-fit; the view owns its renderer.
  Widget preview({bool mirror = false});

  /// The capture ended without [stop]: permission revoked, screen capture
  /// stopped, the camera taken by another app.
  Stream<void> get onEnded;

  /// Stops the capture and releases the device; once is enough.
  Future<void> stop();
}

abstract interface class VoiceCamera implements VoiceVideoSource {
  CameraFacing get facing;

  /// Flips front and back in place: the same track, so no renegotiation.
  Future<void> switchFacing();
}

abstract interface class VoiceScreen implements VoiceVideoSource {}

enum VideoKind { camera, screen }

/// Someone's camera or screen coming in. One per user and kind, so two are
/// equal by those alone.
class VoiceRemoteVideo {
  final String userId;
  final VideoKind kind;

  /// A view of it.
  final Widget Function(bool mirror) view;

  const VoiceRemoteVideo({required this.userId, required this.kind, required this.view});

  @override
  bool operator ==(Object other) => other is VoiceRemoteVideo && other.userId == userId && other.kind == kind;

  @override
  int get hashCode => Object.hash(userId, kind);
}

/// The peer connection of a voice room or call: one audio transceiver that
/// sends the microphone, and the others' audio coming in, each user's in a
/// stream named after them; with video, a camera transceiver, the screen's
/// sender while shared, and the others' cameras and screens.
abstract interface class VoicePeer {
  set onIceCandidate(void Function(duvet.IceCandidateInit candidate)? handler);
  set onState(void Function(PeerState state)? handler);

  /// Adds the audio transceiver, sending and receiving: [mic]'s track, or
  /// nothing yet (it can be given later with [useMicrophone]).
  Future<void> addAudio(VoiceMic? mic);

  /// The microphone to send from now on: one opened after joining.
  Future<void> useMicrophone(VoiceMic mic);

  /// Adds the camera transceiver, sending and receiving, with no track yet:
  /// once, before the first offer, so turning the camera on never
  /// renegotiates.
  Future<void> addVideo();

  /// `{mid: "camera"}` for the camera transceiver, for the gateway to tell it
  /// from the screen; set by [setLocalDescription].
  Map<String, String> get trackLabels;

  /// Sends [camera] on the camera transceiver, or nothing: never renegotiates.
  Future<void> setCamera(VoiceCamera? camera);

  /// Adds or removes the screen's sender, then calls [onNegotiationNeeded]:
  /// the client offers it.
  Future<void> setScreen(VoiceScreen? screen);

  /// The others' cameras and screens now.
  ValueListenable<List<VoiceRemoteVideo>> get remoteVideos;

  set onNegotiationNeeded(void Function()? handler);

  /// Sends the microphone, or nothing (muted or deafened).
  Future<void> setSending(bool sending);

  /// Plays the others, or not (deafened).
  Future<void> setReceiving(bool receiving);

  Future<duvet.SessionDescription> createOffer();
  Future<duvet.SessionDescription> createAnswer();
  Future<void> setLocalDescription(duvet.SessionDescription description);
  Future<void> setRemoteDescription(duvet.SessionDescription description);
  Future<void> addIceCandidate(duvet.IceCandidateInit candidate);

  /// How loud each user's audio was since the last call (0–1, by user ID),
  /// and the microphone's ([AudioLevels.local]).
  Future<AudioLevels> audioLevels();

  /// The connection's round trip to the gateway, from the selected ICE
  /// candidate pair; null until it is measured.
  Future<Duration?> roundTrip();

  Future<void> close();
}

/// Audio levels, linear (1 is full scale).
typedef AudioLevels = ({double? local, Map<String, double> remote});

/// A peer connection's state, as voice reads it.
enum PeerState { connecting, connected, disconnected, failed, closed }

enum AudioRouteKind { speaker, earpiece, bluetooth, wired }

/// Somewhere the sound can play.
class AudioRoute {
  /// What the platform calls it, to select it.
  final String id;
  final AudioRouteKind kind;

  /// Its name, e.g. a headset's.
  final String label;

  const AudioRoute({required this.id, required this.kind, required this.label});

  @override
  bool operator ==(Object other) => other is AudioRoute && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);
}

/// The routes available and the one in use.
class AudioRoutes {
  final List<AudioRoute> available;
  final AudioRoute? current;
  const AudioRoutes({this.available = const [], this.current});

  static const none = AudioRoutes();
}
