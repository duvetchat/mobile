import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/push/renewal.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _router = ApiRouter(api: 'api.test', ws: 'ws.test');

void main() {
  final now = DateTime.utc(2026, 11, 14, 12);

  test('renewalDue: tokens of no known age, or 4 hours old, are due; 3 h 59 min old aren\'t', () {
    expect(renewalDue(null, now), isTrue);
    expect(renewalDue(now.subtract(const Duration(hours: 4)), now), isTrue);
    expect(renewalDue(now.subtract(const Duration(hours: 3, minutes: 59)), now), isFalse);
    // A date ahead of the clock says nothing of how old they are.
    expect(renewalDue(now.add(const Duration(minutes: 5)), now), isTrue);
  });

  group('renewStoredSession', () {
    late List<http.Request> requests;
    late int status;
    // How many answers the network loses after the API renewed the session, and what happens meanwhile.
    late int lost;
    late FutureOr<void> Function()? meanwhile;
    http.Client client() => MockClient((request) async {
      requests.add(request);
      await meanwhile?.call();
      if (lost > 0) {
        lost--;
        throw const SocketException('connection reset');
      }
      if (status != 200) return http.Response('{"error":"invalid or expired session"}', status);
      return http.Response(jsonEncode({'token': 'access-2', 'session_token': 'refresh-2'}), 200);
    });
    setUp(() {
      requests = [];
      status = 200;
      lost = 0;
      meanwhile = null;
    });
    final due = (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: now.subtract(const Duration(hours: 5)));

    test('renews a session that\'s due, with its session token, and keeps the new tokens', () async {
      final store = MemorySessionStore((
        token: 'access-1',
        sessionToken: 'refresh-1',
        refreshedAt: now.subtract(const Duration(hours: 5)),
      ));
      await renewStoredSession(store, client(), _router, now);
      expect(
        [for (final r in requests) (r.url.path, r.headers['X-Session-Token'])],
        [('/api/auth/refresh', 'refresh-1')],
      );
      expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: now));
    });

    test('leaves a fresh session alone, and none at all', () async {
      final fresh = (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: now.subtract(const Duration(hours: 1)));
      final store = MemorySessionStore(fresh);
      await renewStoredSession(store, client(), _router, now);
      await renewStoredSession(MemorySessionStore(), client(), _router, now);
      expect(requests, isEmpty);
      expect(await store.read(), fresh);
    });

    test('a session the API refuses stays as it was, for the app to find ended', () async {
      final old = (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: now.subtract(const Duration(hours: 5)));
      final store = MemorySessionStore(old);
      status = 401;
      await renewStoredSession(store, client(), _router, now);
      expect(await store.read(), old);
    });

    // The API may have renewed it and the answer been lost: for 30 seconds it answers the old session token with the
    // same new tokens, which the app's own renewal counts on too (DuvetRepository.renewalRetry).
    test('a renewal that got no answer goes once more 3 s later, with the same session token', () {
      fakeAsync((async) {
        final store = MemorySessionStore(due);
        lost = 1;
        renewStoredSession(store, client(), _router, now).ignore();
        async.flushMicrotasks();
        expect(requests, hasLength(1));
        async.elapse(DuvetRepository.renewalRetry);
        expect([for (final r in requests) r.headers['X-Session-Token']], ['refresh-1', 'refresh-1']);
        StoredSession? kept;
        store.read().then((s) => kept = s);
        async.flushMicrotasks();
        expect(kept, (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: now));
      });
    });

    test("an error the API answered isn't sent again", () async {
      status = 500;
      await expectLater(
        renewStoredSession(MemorySessionStore(due), client(), _router, now),
        throwsA(isA<duvet.DuvetApiException>()),
      );
      expect(requests, hasLength(1));
    });

    test("a session signed out while it was renewed isn't brought back", () async {
      final store = MemorySessionStore(due);
      meanwhile = store.clear;
      await renewStoredSession(store, client(), _router, now);
      expect(await store.read(), isNull);
    });

    test("a session the app renewed meanwhile keeps the app's tokens", () async {
      final store = MemorySessionStore(due);
      final app = (token: 'access-5', sessionToken: 'refresh-5', refreshedAt: now);
      meanwhile = () => store.write(app);
      await renewStoredSession(store, client(), _router, now);
      expect(await store.read(), app);
    });
  });

  // The session has one owner while the app runs: the task asks the app's isolate to renew it, with the client its
  // gateway follows, and renews the stored tokens itself only without one.
  group('askAppToRenew', () {
    tearDown(() => IsolateNameServer.removePortNameMapping(renewalPortName));

    test('with no app running, the task renews by itself', () async {
      expect(await askAppToRenew(), isFalse);
    });

    test("the app renews its own session, and the task waits until it's done", () async {
      final renewing = Completer<void>();
      var asked = 0;
      final app = answerRenewals(() {
        asked++;
        return renewing.future;
      });
      addTearDown(app.close);
      bool? took;
      final asking = askAppToRenew().then((t) => took = t);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((asked, took), (1, null));
      renewing.complete();
      await asking;
      expect(took, isTrue);
    });

    test('an app gone since it registered leaves it to the task', () async {
      // Its isolate ended (the app closed), and its name stayed.
      answerRenewals(() async {}).close();
      expect(await askAppToRenew(ackWait: const Duration(milliseconds: 100)), isFalse);
    });

    test("an app slower than the task can wait keeps it: the task doesn't renew too", () async {
      final app = answerRenewals(() => Completer<void>().future);
      addTearDown(app.close);
      expect(await askAppToRenew(answerWait: const Duration(milliseconds: 100)), isTrue);
    });
  });
}
