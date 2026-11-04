import 'dart:async';

/// Runs [check] until it passes; once [timeout] is up, its last failure is the
/// test's. For what the offline cache writes on a timer, a moment after a
/// change: a fixed wait was too short on a loaded runner (#147).
Future<void> eventually(FutureOr<void> Function() check, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await check();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
