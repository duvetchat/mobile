// An app on the fake (PLAN-E2E-CLIENTES.md's tests over the app's own wiring): a user's DuvetRepository with its engine
// and its core in a support folder of its own, which path_provider gives, signed in and connected to the gateway. Every
// request it makes goes to the fake, and is noted. One app a test: path_provider's answer is the test's.
import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'engines.dart';
import 'fake_api.dart';

class TestApp {
  TestApp._(this.repository, this.seen, this.support, this._core, this.end);

  final DuvetRepository repository;

  /// Every request the app made, with its body.
  final List<http.Request> seen;

  /// The app's support folder: the engine's record, the core's database and the notifications' history.
  final Directory support;
  final CoreGate Function() _core;

  /// Its connection to the gateway closed.
  final void Function() end;

  /// The app's core, once its engine made it.
  CoreGate get core => _core();

  /// Its device set up, as a first device: its identity made and its key saved, the engine ready.
  Future<void> ready() async {
    await until(() => repository.encryption.value.stage == EngineStage.firstDevice);
    await repository.makeIdentity();
    await repository.keySaved();
    await until(() => repository.encryption.value == EngineState.ready);
  }

  /// The requests made since [from] (an index into [seen]) of this method and path.
  int count(String method, String path, {int from = 0}) =>
      seen.skip(from).where((r) => r.method == method && r.url.path == path).length;
}

/// [user]'s app on [fake], signed in and connected, its engine starting: [TestApp.ready] sets its device up. Its
/// connection hands on only what [hears] lets through, and [answers] answer routes the fake lacks, by `METHOD path`.
Future<TestApp> appOn(
  FakeApi fake,
  String user, {
  RecentChatsStore? recents,
  ChatCacheStore? cache,
  bool Function(GatewayEvent event)? hears,
  void Function(Directory support)? prepare,
  Map<String, Object?> answers = const {},
}) async {
  final support = Directory.systemTemp.createTempSync('duvet-app-');
  // What a run before this one left in the app's folders.
  prepare?.call(support);
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(paths, (_) async => support.path);
  addTearDown(() {
    messenger.setMockMethodCallHandler(paths, null);
    if (support.existsSync()) support.deleteSync(recursive: true);
  });
  final seen = <http.Request>[];
  final session = fake.signIn(user);
  final client = MockClient((request) async {
    seen.add(request);
    final at = DateTime.now().toUtc().toIso8601String();
    final Object? own = switch ((request.method, request.url.path)) {
      ('POST', '/api/auth/login') => {
        'token': session.token,
        'session_token': 'refresh',
        'device_challenge': session.deviceChallenge,
      },
      ('GET', '/api/users/@me') => {'id': user, 'username': 'user', 'created_at': at, 'updated_at': at},
      _ => answers['${request.method} ${request.url.path}'],
    };
    if (own != null) return http.Response(jsonEncode(own), 200, headers: {'content-type': 'application/json'});
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return http.Response.fromStream(await fake.client.send(copy));
  });
  late CoreGate core;
  final repository = DuvetRepository(
    store: MemorySessionStore(),
    recentsStore: recents ?? MemoryRecentChatsStore(),
    httpClient: () => client,
    connectGateway: false,
    cacheStore: cache ?? MemoryChatCacheStore(),
    encryptionHost: () => core = TestHost(folder: Directory('${support.path}/core')..createSync()).gate,
    onScreen: () => true,
  );
  await repository.logIn('user@duvet.chat', 'secret');
  final end = fake.connect(session.token, null, (event) {
    if (hears != null && !hears(event)) return;
    if (payloadOf(event, user) case final payload?) repository.handleEvent(payload);
  });
  addTearDown(() {
    end();
    repository.dispose();
  });
  return TestApp._(repository, seen, support, () => core, end);
}
