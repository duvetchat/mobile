// The repository's gateway session against a fake gateway on 127.0.0.1 that
// keeps sessions as the real one does: a dropped socket resumes the session
// (no READY, nothing fetched again), one the gateway can't resume gets READY,
// and a 4004 asks the API about the session.
import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet_client/http/router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _at = '2026-10-23T09:00:00Z';

/// A gateway with one socket at a time. An identify naming its session with
/// a sequence number resumes it, while [resumes]: nothing is sent but the
/// heartbeats' acks. Any other starts a session, with READY.
class _Gateway {
  _Gateway._(this._server) {
    _server.listen(_handle);
  }

  static Future<_Gateway> start() async => _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  WebSocket? _socket;
  int _seq = 0;
  int _sessions = 0;

  /// Whether it takes up the sessions it's asked to resume.
  bool resumes = true;

  /// The identifies, in order.
  final identified = <Map<String, dynamic>>[];

  ApiRouter get router => ApiRouter(api: '127.0.0.1:${_server.port}', ws: '127.0.0.1:${_server.port}', secure: false);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/gateway' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = _socket = await WebSocketTransformer.upgrade(request);
    socket.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (message['type']) {
        case 'identify':
          final data = message['data'] as Map<String, dynamic>;
          identified.add(data);
          final resumed = resumes && data['session_token'] == 'gw-$_sessions' && data['last_seq'] == _seq;
          if (!resumed) {
            _seq = 0;
            _send('READY', {
              'user': {'id': _me, 'username': 'gaby', 'created_at': _at, 'updated_at': _at},
              'sessionToken': 'gw-${++_sessions}',
            });
          }
        case 'heartbeat':
          socket.add(jsonEncode({'event': 'heartbeat_ack'}));
      }
    });
  }

  void _send(String type, Map<String, dynamic> data) => _socket?.add(
    jsonEncode({
      'event': 'payload',
      'op': 1,
      'd': {'type': type, 'data': data},
      's': ++_seq,
    }),
  );

  /// The socket drops, as when the phone changes networks.
  Future<void> drop() async => _socket?.close();

  /// Refuses the session's token, as when it ended: 4004, then the socket
  /// closes.
  Future<void> refuse() async {
    _socket?.add(jsonEncode({'event': 'close-with-reason', 'code': 4004, 'reason': 'session ended'}));
    await _socket?.close(4004);
  }

  Future<void> close() => _server.close(force: true);
}

/// Waits for [done], on the real clock: sockets take their time.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(done(), isTrue);
}

void main() {
  late _Gateway gateway;
  late DuvetRepository repository;
  late List<String> requests;
  late bool sessionDead;

  setUp(() async {
    gateway = await _Gateway.start();
    requests = [];
    sessionDead = false;
    final api = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (sessionDead && request.url.path != '/api/auth/login') return http.Response('', 401);
      final json = switch (request.url.path) {
        '/api/auth/login' => {'token': 'access-1', 'session_token': 'refresh-1'},
        '/api/users/@me' => {'id': _me, 'username': 'gaby', 'custom': '', 'created_at': _at, 'updated_at': _at},
        '/api/users/@me/conversations' || '/api/users/@me/friends' => <Object>[],
        '/api/users/@me/friends/requests' || '/api/users/@me/friends/requests/sent' => <Object>[],
        '/api/users/@me/mentions/counts' => <String, Object>{},
        _ => null,
      };
      if (json == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
    });
    repository = DuvetRepository(
      store: MemorySessionStore(),
      recentsStore: MemoryRecentChatsStore(),
      router: gateway.router,
      httpClient: () => api,
      cacheStore: MemoryChatCacheStore(),
    );
  });

  tearDown(() async {
    repository.dispose();
    await gateway.close();
  });

  Future<void> signIn() async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await _until(() => repository.status.value == LiveStatus.online);
    // What READY fetches.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  test('a dropped socket resumes the session: no READY, and nothing fetched again', () async {
    var caughtUp = 0;
    repository.resumed.listen((_) => caughtUp++);
    await signIn();
    expect(gateway.identified.single.containsKey('session_token'), isFalse);
    final fetched = requests.length;

    await gateway.drop();
    await _until(() => repository.status.value == LiveStatus.reconnecting);
    await _until(() => repository.status.value == LiveStatus.online);
    expect(gateway.identified, hasLength(2));
    expect(gateway.identified.last, containsPair('session_token', 'gw-1'));
    expect(gateway.identified.last, containsPair('last_seq', 1));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(caughtUp, 0);
    expect(requests, hasLength(fetched));
  });

  test('a session the gateway can\'t resume gets READY, after which chats catch up', () async {
    var caughtUp = 0;
    repository.resumed.listen((_) => caughtUp++);
    await signIn();

    gateway.resumes = false;
    await gateway.drop();
    await _until(() => repository.status.value == LiveStatus.reconnecting);
    await _until(() => repository.status.value == LiveStatus.online);
    expect(gateway.identified.last, containsPair('session_token', 'gw-1'));
    await _until(() => caughtUp == 1);
  });

  test('a 4004 asks the API about the session, and a dead one ends', () async {
    var ended = 0;
    repository.signedOut.listen((_) => ended++);
    await signIn();
    final asked = requests.length;

    sessionDead = true;
    await gateway.refuse();
    await _until(() => repository.profile.value == null);
    expect(requests.skip(asked).first, 'GET /api/users/@me');
    expect(ended, 1);
  });
}
