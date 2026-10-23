import 'package:flutter/widgets.dart';

import 'repository.dart';

/// Hands the [ChatRepository] down the tree.
class RepositoryScope extends InheritedWidget {
  final ChatRepository repository;
  const RepositoryScope({required this.repository, required super.child, super.key});

  static ChatRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!.repository;

  @override
  bool updateShouldNotify(RepositoryScope old) => old.repository != repository;
}

extension RepositoryContext on BuildContext {
  ChatRepository get repository => RepositoryScope.of(this);
}
