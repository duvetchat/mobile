/// The web build's core: none, as the core's Flutter plugin has no web build here. Its engine says so (unsupported),
/// and the rest of the app goes on.
library;

import 'host.dart';

CoreHost appCoreHost() => const _NoCore();

/// A push's engine's core: none either.
CoreHost pushCoreHost() => const _NoCore();

class _NoCore implements CoreHost {
  const _NoCore();

  @override
  Future<Opened> open(String userId) async => (state: HostState.unsupported, keyStorage: null, reason: null);

  @override
  Future<T> handle<T>(Map<String, Object?> command) async => throw CoreError('internal', message: 'no core here');

  @override
  Future<void> close() async {}

  @override
  Future<void> destroy(String userId) async {}
}
