import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

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
  /// refused it or there is none.
  Future<VoiceMic?> openMicrophone();

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

/// The peer connection of a voice room or call: one audio transceiver that
/// sends the microphone, and the others' audio coming in, each user's in a
/// stream named after them.
abstract interface class VoicePeer {
  set onIceCandidate(void Function(duvet.IceCandidateInit candidate)? handler);
  set onState(void Function(PeerState state)? handler);

  /// Adds the audio transceiver, sending and receiving: [mic]'s track, or
  /// nothing yet (it can be given later with [useMicrophone]).
  Future<void> addAudio(VoiceMic? mic);

  /// The microphone to send from now on: one opened after joining.
  Future<void> useMicrophone(VoiceMic mic);

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
