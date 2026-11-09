import 'package:flutter/widgets.dart';

import 'repository.dart';
import 'sounds.dart';
import 'voice.dart';
import 'voice_prefs.dart';

/// Hands the [ChatRepository] down the tree.
class RepositoryScope extends InheritedWidget {
  final ChatRepository repository;
  const RepositoryScope({required this.repository, required super.child, super.key});

  static ChatRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!.repository;

  @override
  bool updateShouldNotify(RepositoryScope old) => old.repository != repository;
}

/// Hands the [VoiceController] down the tree: widgets listen to it
/// themselves, where they show voice.
class VoiceScope extends InheritedWidget {
  final VoiceController voice;
  const VoiceScope({required this.voice, required super.child, super.key});

  static VoiceController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<VoiceScope>()!.voice;

  @override
  bool updateShouldNotify(VoiceScope old) => old.voice != voice;
}

/// Hands the [VoicePrefs] down the tree: widgets listen to them themselves.
class VoicePrefsScope extends InheritedWidget {
  final VoicePrefs prefs;
  const VoicePrefsScope({required this.prefs, required super.child, super.key});

  static VoicePrefs of(BuildContext context) => maybeOf(context)!;

  /// Null outside the app: a widget pumped alone in a test.
  static VoicePrefs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoicePrefsScope>()?.prefs;

  @override
  bool updateShouldNotify(VoicePrefsScope old) => old.prefs != prefs;
}

/// Hands the [Sounds] down the tree: widgets listen to them themselves.
class SoundsScope extends InheritedWidget {
  final Sounds sounds;
  const SoundsScope({required this.sounds, required super.child, super.key});

  static Sounds of(BuildContext context) => maybeOf(context)!;

  /// Null outside the app: a widget pumped alone in a test.
  static Sounds? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SoundsScope>()?.sounds;

  @override
  bool updateShouldNotify(SoundsScope old) => old.sounds != sounds;
}

extension RepositoryContext on BuildContext {
  ChatRepository get repository => RepositoryScope.of(this);
  VoiceController get voice => VoiceScope.of(this);
}
