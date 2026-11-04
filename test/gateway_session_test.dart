// The repository's gateway session against a fake gateway on 127.0.0.1 that
// keeps sessions as the real one does: a dropped socket resumes the session
// (no READY, nothing fetched again), one the gateway can't resume gets READY,
// and a 4004 asks the API about the session.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:duvet/data/cache.dart';
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _at = '2026-10-23T09:00:00Z';

/// A Space the user owns, with a voice room.
const _space = {
  'space': {'id': 's-1', 'name': 'Design Guild', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
  'rooms': {
    'r-voice': {
      'id': 'r-voice',
      'space_id': 's-1',
      'type': 2,
      'name': 'lounge',
      'position': 0,
      'created_at': _at,
      'updated_at': _at,
    },
  },
  'roles_permissions': <String, dynamic>{},
  'owner_id': _me,
};

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

  /// While set, it refuses the socket's upgrade with this status, as the
  /// gateway does a token it doesn't know (401) or while it can't check one
  /// (503); and how many it refused.
  int? refuseWith;
  int refused = 0;

  /// The access tokens it no longer knows, which it refuses at the upgrade
  /// with a 401: the API revoked them as it renewed the session.
  final revoked = <String>{};

  /// The access token each upgrade carried, refused or not.
  final upgrades = <String?>[];

  /// The identifies, in order, and every message by the socket it came on
  /// (counted from 1) and its type.
  final identified = <Map<String, dynamic>>[];
  final received = <(int, String)>[];
  int _sockets = 0;

  /// A Space the user owns, with a voice room, that each READY is followed by.
  bool sendsSpace = false;

  /// Whether it says it has a call the user placed (CALL_OUTGOING), as a
  /// gateway from after the calls across devices does.
  bool tellsOutgoing = false;

  ApiRouter get router => ApiRouter(api: '127.0.0.1:${_server.port}', ws: '127.0.0.1:${_server.port}', secure: false);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/gateway' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final token = request.uri.queryParameters['token'];
    upgrades.add(token);
    if (revoked.contains(token) ? HttpStatus.unauthorized : refuseWith case final status?) {
      refused++;
      request.response.statusCode = status;
      await request.response.close();
      return;
    }
    final socket = _socket = await WebSocketTransformer.upgrade(request);
    final number = ++_sockets;
    socket.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      received.add((number, message['type'] as String));
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
            if (sendsSpace) _send('SPACE_CREATE', _space);
          }
        case 'heartbeat':
          socket.add(jsonEncode({'event': 'heartbeat_ack'}));
        case 'CALL_INITIATE' when tellsOutgoing:
          final call = message['data'] as Map<String, dynamic>;
          _send('CALL_OUTGOING', {'conversation_id': call['conversation_id']});
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

/// Waits for [done], on the real clock, [within] at most: sockets take their
/// time.
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 5)}) async {
  final until = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(until)) {
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
      if (request.url.path == '/api/auth/refresh') {
        // The session's renewed at once, which revokes the old access token;
        // the answer takes a moment.
        gateway.revoked.add('access-1');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response(jsonEncode({'token': 'access-2', 'session_token': 'refresh-2'}), 200);
      }
      if (gateway.revoked.contains(request.headers['Authorization']?.replaceFirst('Bearer ', ''))) {
        return http.Response('', 401);
      }
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

  // Others see a phone for someone whose every connection says it's the mobile app (#84).
  test('each identify says the app runs on mobile, a resume\'s too', () async {
    await signIn();
    expect(gateway.identified.single, containsPair('platform', 'mobile'));

    await gateway.drop();
    await _until(() => gateway.identified.length == 2 && repository.status.value == LiveStatus.online);
    expect(gateway.identified.last, containsPair('session_token', 'gw-1'));
    expect(gateway.identified.last, containsPair('platform', 'mobile'));
  });

  test('on a computer, the identify says desktop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await signIn();
    expect(gateway.identified.single, containsPair('platform', 'desktop'));
  });

  test('what the app says it runs on: mobile on Android and iOS, web in a browser, desktop anywhere else', () {
    expect(
      {for (final target in TargetPlatform.values) target: DuvetRepository.platformOf(target: target)},
      {
        TargetPlatform.android: duvet.ClientPlatform.mobile,
        TargetPlatform.iOS: duvet.ClientPlatform.mobile,
        TargetPlatform.windows: duvet.ClientPlatform.desktop,
        TargetPlatform.macOS: duvet.ClientPlatform.desktop,
        TargetPlatform.linux: duvet.ClientPlatform.desktop,
        TargetPlatform.fuchsia: duvet.ClientPlatform.desktop,
      },
    );
    // A browser on a phone too: it isn't the mobile app.
    for (final target in TargetPlatform.values) {
      expect(DuvetRepository.platformOf(web: true, target: target), duvet.ClientPlatform.web, reason: '$target');
    }
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

  test('a session that ended while the socket was down, refused at the upgrade, asks the API and ends', () async {
    var ended = 0;
    repository.signedOut.listen((_) => ended++);
    await signIn();

    sessionDead = true;
    gateway.refuseWith = 401;
    await gateway.drop();
    await _until(() => repository.profile.value == null);
    expect(ended, 1);
    expect(gateway.refused, 1);
  });

  test('back in front while reconnecting, the next attempt goes at once', () async {
    await signIn();
    int asked() => requests.where((r) => r == 'GET /api/users/@me').length;
    final before = asked();
    gateway.refuseWith = 503;
    await gateway.drop();
    // The first failure asks the API about the session, once the client waits
    // to try again.
    await _until(() => gateway.refused == 1 && asked() > before);

    repository.cameToFront();
    // Not after the 2 seconds and more the next wait takes.
    await _until(() => gateway.refused == 2, within: const Duration(milliseconds: 600));
  });

  test('back in front while reconnecting with tokens an hour old, the attempt waits for their renewal', () async {
    await signIn();
    gateway.refuseWith = 503;
    await gateway.drop();
    await _until(() => gateway.refused == 1);
    gateway.refuseWith = null;
    final attempts = gateway.upgrades.length;

    withClock(Clock.fixed(DateTime.now().add(const Duration(hours: 2))), repository.cameToFront);
    await _until(() => repository.status.value == LiveStatus.online);
    // With the new token: the old one, which the renewal revokes as it goes,
    // would be refused, and the next wait take longer.
    expect(gateway.upgrades.skip(attempts), ['access-2']);
  });

  test(
    'a voice join the gateway hadn\'t answered when the socket dropped goes again once the session resumes',
    () async {
      gateway.sendsSpace = true;
      await signIn();
      final voice = VoiceController(
        repository: repository,
        engine: FakeVoiceEngine(),
        historyStore: MemoryCallHistoryStore(),
        inFront: () => true,
      );
      addTearDown(voice.dispose);
      await voice.joinRoom(
        const Room(id: 'r-voice', spaceId: 's-1', name: 'lounge', kind: RoomKind.voice, position: 0),
      );
      await _until(() => gateway.received.contains((1, 'VOICE_JOIN')));

      // Dropped before its answer.
      await gateway.drop();
      await _until(() => gateway.received.contains((2, 'VOICE_JOIN')));
      expect(gateway.identified.last, containsPair('session_token', 'gw-1'));
      expect(gateway.received.where((r) => r.$2 == 'VOICE_JOIN'), hasLength(2));
    },
  );

  test(
    'a call placed just as the socket dropped is placed again once the session resumes, unless the gateway had it',
    () async {
      await signIn();
      final voice = VoiceController(
        repository: repository,
        engine: FakeVoiceEngine(),
        historyStore: MemoryCallHistoryStore(),
        inFront: () => true,
      );
      addTearDown(voice.dispose);
      int placed() => gateway.received.where((r) => r.$2 == 'CALL_INITIATE').length;

      // Nothing came back for it: placed again on the session resumed.
      await voice.startCall('c-1');
      await _until(() => gateway.received.contains((1, 'CALL_INITIATE')));
      await gateway.drop();
      await _until(() => gateway.received.contains((2, 'CALL_INITIATE')));
      expect(placed(), 2);
      voice.hangUp();

      // The gateway said it had it: not again.
      gateway.tellsOutgoing = true;
      await voice.startCall('c-1');
      await _until(() => placed() == 3);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await gateway.drop();
      await _until(() => gateway.identified.length == 3 && repository.status.value == LiveStatus.online);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(placed(), 3);
    },
  );
}
