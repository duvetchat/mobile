// What the app says it is (PLAN-E2E-CLIENTES.md, Task 36): X-Duvet-Client on each request and an identify's client
// carry android/<pubspec.yaml's version>, the file the build reads it from, and the API takes that version once the
// cutover sets Android's minimum.
import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/e2e/client.dart';
import 'package:duvet_client/http/router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/eventually.dart';
import 'support/fake_api.dart';
import 'support/pubspec.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _at = '2026-11-26T09:00:00Z';

/// Android's lowest version with end-to-end encryption once the cutover sets it: E2E_MIN_CLIENTS's android=1.1.0
/// (PLAN-E2E-CLIENTES.md, «Lo que el paso 6 necesita»). Below it, the API answers 426 on every conversation route.
const _cutoverMinimum = '1.1.0';

/// A gateway on 127.0.0.1 that keeps each identify.
class _Gateway {
  _Gateway._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] == 'identify') identifies.add(message['data'] as Map<String, dynamic>);
      });
    });
  }

  static Future<_Gateway> start() async => _Gateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final identifies = <Map<String, dynamic>>[];

  ApiRouter get router => ApiRouter(api: '127.0.0.1:${_server.port}', ws: '127.0.0.1:${_server.port}', secure: false);

  Future<void> close() => _server.close(force: true);
}

void main() {
  // The binding's HTTP override goes, as the fake gateway is a real socket.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test("each_request_and_identify_say_android_and_pubspec.yaml's_version", () async {
    final gateway = await _Gateway.start();
    addTearDown(gateway.close);
    final requests = <http.BaseRequest>[];
    final api = MockClient((request) async {
      requests.add(request);
      final json = switch (request.url.path) {
        '/api/auth/login' => {'token': 'access-1', 'session_token': 'refresh-1'},
        '/api/users/@me' => {'id': _me, 'username': 'gaby', 'custom': '', 'created_at': _at, 'updated_at': _at},
        '/api/users/@me/conversations' => <Object>[],
        _ => null,
      };
      if (json == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
    });
    final repository = DuvetRepository(
      store: MemorySessionStore(),
      recentsStore: MemoryRecentChatsStore(),
      router: gateway.router,
      httpClient: () => api,
      cacheStore: MemoryChatCacheStore(),
    );
    addTearDown(repository.dispose);

    await repository.logIn('gaby@duvet.chat', 'secret');
    await eventually(() => expect(gateway.identifies, isNotEmpty));
    final client = 'android/${pubspecVersion()}';
    expect(requests, isNotEmpty);
    for (final request in requests) {
      expect(request.headers['X-Duvet-Client'], client, reason: request.url.path);
    }
    for (final identify in gateway.identifies) {
      expect(identify['client'], client);
    }
  });

  test("the_API_takes_it_once_the_cutover_sets_android's_minimum", () async {
    final fake = FakeApi()..minClients = {'android': _cutoverMinimum};
    final token = fake.signIn(fake.addUser()).token;
    final answer = await fake.client.get(
      Uri.parse('$fakeApiUrl/api/users/@me/devices'),
      headers: {'Authorization': 'Bearer $token', 'X-Duvet-Client': ?duvetClient()},
    );
    expect(answer.statusCode, 200, reason: answer.body);
  });
}
