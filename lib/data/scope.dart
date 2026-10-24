import 'package:flutter/widgets.dart';

import 'repository.dart';
import 'voice.dart';

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

extension RepositoryContext on BuildContext {
  ChatRepository get repository => RepositoryScope.of(this);
  VoiceController get voice => VoiceScope.of(this);
}
