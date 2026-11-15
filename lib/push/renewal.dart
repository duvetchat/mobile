/// The session's renewal while the app sits closed: a session lasts a day from its last renewal, so a phone left alone
/// longer would stop getting its pushes. Android's WorkManager runs it every [renewalEvery], with a network.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

import '../data/duvet_repository.dart' show DuvetRepository, duvetRouter;
import '../data/session_store.dart';

/// The background task's name, which registering again keeps.
const renewalTask = 'renew-session';

/// How often WorkManager runs the renewal, and how old the tokens get before it renews them.
const renewalEvery = Duration(hours: 4);

/// Whether tokens renewed at [refreshedAt] are due by [now]: [renewalEvery] old, or of no known age (no date, or one
/// ahead of the clock, which says nothing of how old they are).
bool renewalDue(DateTime? refreshedAt, DateTime now) =>
    refreshedAt == null || refreshedAt.isAfter(now) || now.difference(refreshedAt) >= renewalEvery;

/// Renews the stored session when it's due, and keeps the new tokens: the app takes them up on its next 401
/// (DuvetRepository). A session the API refuses stays as it was, for the app to find ended. A try that got no answer
/// goes once more [DuvetRepository.renewalRetry] later, with the same session token, as the app's own renewal does:
/// the API may have renewed it and the answer been lost. The new tokens are kept only while the store still holds the
/// session they renew: one signed out meanwhile stays out, and one the app renewed keeps the app's tokens.
Future<void> renewStoredSession(SessionStore store, http.Client client, ApiRouter router, DateTime now) async {
  final saved = await store.read();
  if (saved == null || saved.sessionToken.isEmpty || !renewalDue(saved.refreshedAt, now)) return;
  final api = duvet.RestClient(client, router: router, token: saved.token, sessionToken: saved.sessionToken);
  try {
    try {
      await api.refreshSession();
    } on duvet.DuvetApiException {
      rethrow;
    } catch (_) {
      await Future<void>.delayed(DuvetRepository.renewalRetry);
      await api.refreshSession();
    }
  } on duvet.DuvetAuthException {
    return;
  }
  if (!api.isAuthenticated || (await store.read())?.sessionToken != saved.sessionToken) return;
  await store.write((token: api.token, sessionToken: api.sessionToken, refreshedAt: now));
}

/// The name the app's isolate answers the background task under ([answerRenewals]).
const renewalPortName = 'duvet-session-renewal';

/// In the app's isolate: renews the session with [renew] when the background task asks ([askAppToRenew]). The app's
/// own client renews it, so the session keeps one owner while the app runs, and its gateway follows the renewal
/// rather than starting over with tokens the task stored. The port stays open as long as the app runs.
ReceivePort answerRenewals(Future<void> Function() renew) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(renewalPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, renewalPortName);
  port.listen((asker) async {
    if (asker is! SendPort) return;
    asker.send('taken');
    try {
      await renew();
    } catch (e) {
      debugPrint('session: the renewal the background asked for: $e');
    }
    asker.send('done');
  });
  return port;
}

/// In the background task: asks the app's isolate, if one runs in this process, to renew its session, and waits until
/// it's done, [answerWait] at most, so the phone stays awake for it. True once the app took it; false when no app
/// answered within [ackWait] (none runs, or its isolate ended since it registered): the task renews the stored tokens
/// itself then.
Future<bool> askAppToRenew({
  Duration ackWait = const Duration(seconds: 5),
  Duration answerWait = const Duration(seconds: 60),
}) async {
  final app = IsolateNameServer.lookupPortByName(renewalPortName);
  if (app == null) return false;
  final answers = ReceivePort();
  final replies = StreamIterator<Object?>(answers);
  try {
    app.send(answers.sendPort);
    if (!await replies.moveNext().timeout(ackWait, onTimeout: () => false)) return false;
    await replies.moveNext().timeout(answerWait, onTimeout: () => false);
    return true;
  } finally {
    answers.close();
  }
}

/// WorkManager's entry point, in an isolate of its own.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    if (task != renewalTask) return true;
    final client = http.Client();
    try {
      // The app's own isolate renews it when one runs.
      if (await askAppToRenew()) return true;
      await renewStoredSession(const SecureSessionStore(), client, duvetRouter, DateTime.now().toUtc());
    } catch (e) {
      debugPrint('session: the background renewal: $e');
    } finally {
      client.close();
    }
    return true;
  });
}
