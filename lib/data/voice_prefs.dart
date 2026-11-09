import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How voice looks and sounds on this device: everyone's animated face in
/// place of their picture, and WebRTC's noise suppression on the microphone.
class VoicePrefs extends ChangeNotifier {
  static const _key = 'duvet.voice_prefs';

  final FlutterSecureStorage _storage;
  VoicePrefs({FlutterSecureStorage storage = const FlutterSecureStorage()}) : _storage = storage;

  bool _facesInVoice = false;
  bool _noiseSuppression = true;

  // Changed before load finished: the user's choice beats what was stored.
  bool _facesSet = false;
  bool _noiseSet = false;

  bool get facesInVoice => _facesInVoice;
  bool get noiseSuppression => _noiseSuppression;

  Future<void> load() async {
    final Map<String, dynamic> json;
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return;
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('voice prefs: $e');
      return;
    }
    if (json['facesInVoice'] case final bool faces when !_facesSet) _facesInVoice = faces;
    if (json['noiseSuppression'] case final bool noise when !_noiseSet) _noiseSuppression = noise;
    notifyListeners();
    // A change made meanwhile was saved with the defaults for the rest.
    if (_facesSet || _noiseSet) await _save();
  }

  Future<void> setFacesInVoice(bool on) {
    _facesSet = true;
    _facesInVoice = on;
    notifyListeners();
    return _save();
  }

  Future<void> setNoiseSuppression(bool on) {
    _noiseSet = true;
    _noiseSuppression = on;
    notifyListeners();
    return _save();
  }

  Future<void> _save() async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({'facesInVoice': _facesInVoice, 'noiseSuppression': _noiseSuppression}),
      );
    } catch (e) {
      debugPrint('voice prefs: $e');
    }
  }
}
