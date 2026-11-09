import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Already in the build through just_audio, which takes its attributes but doesn't export them.
// ignore: depend_on_referenced_packages
import 'package:audio_session/audio_session.dart'
    show AndroidAudioAttributes, AndroidAudioContentType, AndroidAudioUsage;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart' as ja;

/// The app's sounds, the desktop's files.
enum Sound {
  mention('message_notification'),
  incomingCall('voice_calling'),
  voiceJoin('join_vc'),
  voiceLeave('leave_vc'),
  screenShareOn('screen_sharing_on'),
  screenShareOff('screen_sharing_off');

  final String file;
  const Sound(this.file);

  String get asset => 'assets/sounds/$file.ogg';
}

/// Plays a [Sound] at a gain from 0 to 1, once or looped until [stop].
abstract interface class SoundPlayer {
  Future<void> play(Sound sound, double gain, {bool loop = false});
  Future<void> stop(Sound sound);
  Future<void> dispose();
}

/// Whether the phone wants quiet: Do not disturb, or the ringer on silent or vibrate.
abstract interface class RingerMode {
  Future<bool> quiet();
}

/// Android's ringer mode and Do not disturb, from MainActivity.
class PlatformRingerMode implements RingerMode {
  const PlatformRingerMode();

  static const _channel = MethodChannel('chat.duvet/ringer');

  @override
  Future<bool> quiet() async {
    if (!Platform.isAndroid) return false;
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('state');
      return state?['dnd'] == true || state?['mode'] != 'normal';
    } catch (e) {
      // Can't tell: sound as the desktop does rather than go mute.
      debugPrint('sounds: $e');
      return false;
    }
  }
}

/// just_audio, kept off the shared audio session: no activation means no audio
/// focus request (ExoPlayer's own focus handling is off in just_audio), so a
/// sound never pauses a voice note or ducks the call, and its own attributes
/// (notification, the ring as a ringtone) put it on the notification volume.
/// SoundPool would do the same but cuts samples past about 1 MB decoded, and
/// the ring is 10 s of stereo.
///
/// Android only: iOS's AVPlayer doesn't decode .ogg, so it plays nothing there.
class JustAudioSoundPlayer implements SoundPlayer {
  final _players = <Sound, Future<ja.AudioPlayer>>{};

  Future<ja.AudioPlayer> _load(Sound sound) => _players[sound] ??= () async {
    final player = ja.AudioPlayer(
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
      handleAudioSessionActivation: false,
    );
    await player.setAndroidAudioAttributes(
      AndroidAudioAttributes(
        contentType: AndroidAudioContentType.sonification,
        usage: sound == Sound.incomingCall ? AndroidAudioUsage.notificationRingtone : AndroidAudioUsage.notification,
      ),
    );
    await player.setAsset(sound.asset);
    return player;
  }();

  @override
  Future<void> play(Sound sound, double gain, {bool loop = false}) async {
    if (!Platform.isAndroid) return;
    final player = await _load(sound);
    await player.setVolume(gain);
    await player.setLoopMode(loop ? ja.LoopMode.one : ja.LoopMode.off);
    await player.seek(Duration.zero);
    // Its future ends with the playback, never for a loop.
    unawaited(player.play());
  }

  @override
  Future<void> stop(Sound sound) async => (await _players[sound])?.pause();

  @override
  Future<void> dispose() async {
    for (final player in _players.values) {
      (await player).dispose();
    }
    _players.clear();
  }
}

/// The volume of each sound and of all of them, 0 to 200 as on the desktop (100
/// by default, 0 is off), kept on the device, and the sounds played at them.
class Sounds extends ChangeNotifier {
  static const _key = 'duvet.sounds';

  final SoundPlayer _player;
  final RingerMode _ringer;
  final FlutterSecureStorage _storage;

  Sounds({SoundPlayer? player, RingerMode? ringer, FlutterSecureStorage storage = const FlutterSecureStorage()})
    : _player = player ?? JustAudioSoundPlayer(),
      _ringer = ringer ?? const PlatformRingerMode(),
      _storage = storage;

  int _master = 100;
  final _volumes = {for (final s in Sound.values) s: 100};

  /// The ring playing or about to: a stop while it waits on the ringer cancels it.
  Object? _ring;

  int get master => _master;
  int volume(Sound sound) => _volumes[sound]!;

  /// As the desktop: each half of the 0–200 range scales the other, so 100 and 100 play at a quarter.
  double gain(Sound sound) => ((_master / 200) * (volume(sound) / 200)).clamp(0, 1).toDouble();

  static int _clamp(Object? v) => v is num ? v.round().clamp(0, 200) : 100;

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _master = _clamp(json['master']);
      for (final s in Sound.values) {
        _volumes[s] = _clamp(json[s.name]);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('sounds: $e');
    }
  }

  Future<void> setMaster(int value) => _set(() => _master = value.clamp(0, 200));

  Future<void> setVolume(Sound sound, int value) => _set(() => _volumes[sound] = value.clamp(0, 200));

  Future<void> _set(void Function() change) async {
    change();
    notifyListeners();
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({'master': _master, for (final s in Sound.values) s.name: _volumes[s]}),
      );
    } catch (e) {
      debugPrint('sounds: $e');
    }
  }

  /// Plays [sound] once, unless it's off or the phone wants quiet.
  Future<void> play(Sound sound) async {
    final gain = this.gain(sound);
    if (gain == 0 || await _ringer.quiet()) return;
    await _guard(() => _player.play(sound, gain));
  }

  /// Plays [sound] once even when the phone wants quiet: the user asked to hear it.
  Future<void> preview(Sound sound) => _guard(() => _player.play(sound, gain(sound)));

  /// Rings until [stopRing]; a ring already going goes on alone.
  Future<void> startRing() async {
    if (_ring != null) return;
    final ring = _ring = Object();
    final gain = this.gain(Sound.incomingCall);
    if (gain == 0 || await _ringer.quiet()) {
      if (identical(_ring, ring)) _ring = null;
      return;
    }
    if (!identical(_ring, ring)) return;
    await _guard(() => _player.play(Sound.incomingCall, gain, loop: true));
    // Stopped while it started.
    if (!identical(_ring, ring)) await _guard(() => _player.stop(Sound.incomingCall));
  }

  Future<void> stopRing() async {
    if (_ring == null) return;
    _ring = null;
    await _guard(() => _player.stop(Sound.incomingCall));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('sounds: $e');
    }
  }

  @override
  void dispose() {
    _ring = null;
    unawaited(_player.dispose());
    super.dispose();
  }
}
