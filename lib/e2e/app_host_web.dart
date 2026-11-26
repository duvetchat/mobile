/// The web build's core: none, as the core's Flutter plugin has no web build here. Its engine says so (unsupported),
/// and the rest of the app goes on.
library;

import 'dart:typed_data';

import 'host.dart';

CoreHost appCoreHost() => const _NoCore();

/// A push's engine's core: none either.
CoreHost pushCoreHost([Duration lockedWait = Duration.zero]) => const _NoCore();

class _NoCore implements CoreHost {
  const _NoCore();

  @override
  Future<Opened> open(String userId) async => (state: HostState.unsupported, keyStorage: null, reason: null);

  @override
  Future<T> handle<T>(Map<String, Object?> command) async => throw CoreError('internal', message: 'no core here');

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) async =>
      throw CoreError('internal', message: 'no core here');

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) async =>
      throw CoreError('internal', message: 'no core here');

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) async =>
      throw CoreError('internal', message: 'no core here');

  @override
  Future<Uint8List> sharePart(String shareId, int n) async => throw CoreError('internal', message: 'no core here');

  @override
  Future<void> dropShare(String shareId) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> destroy(String userId) async {}
}
