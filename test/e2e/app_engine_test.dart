import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/eventually.dart';

// The engine in the app (PLAN-E2E-CLIENTES.md, Task 13): what the app says it is, the one gateway reopen of Ruling 30,
// and the engine running in the engine with a screen alone, from the session's start to its end.
const _me = '00000000-0000-4000-8000-000000000001';

/// The pubspec's version without its build number, its CRLF made LF first, as a Windows checkout has it.
String _version() {
  final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
  return RegExp(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\+', multiLine: true).firstMatch(pubspec)![1]!;
}

/// A core no build has: its open says so, and the engine asks nothing more of it.
class _Host implements CoreHost {
  final opened = <String>[];
  var closed = 0;

  @override
  Future<Opened> open(String userId) async {
    opened.add(userId);
    return (state: HostState.unsupported, keyStorage: null, reason: null);
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) async => throw CoreError('internal', message: 'no core');

  @override
  Future<void> close() async => closed++;

  @override
  Future<void> destroy(String userId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the_app_is_android_with_its_pubspec's_version,_ios_on_ios,_and_nothing_elsewhere", () {
    expect(duvetClient(), 'android/${_version()}');
    expect(duvetClient(platform: TargetPlatform.iOS, version: '1.1.0'), 'ios/1.1.0');
    expect(duvetClient(web: true), isNull);
    expect(duvetClient(platform: TargetPlatform.linux), isNull);
  });

  // Ruling 30: a gateway session identified without the device starts again, once, as a new one.
  test('a_session_identified_without_the_device_starts_again,_once', () {
    // The first registration, the session identified with none.
    expect(DuvetRepository.reopensFor('d', identified: true), isTrue);
    // Before the gateway's first identify, which names it.
    expect(DuvetRepository.reopensFor('d', identified: false), isFalse);
    // An identify naming it on its way, a new session's: its READY has it.
    expect(DuvetRepository.reopensFor('d', identified: true, sent: 'd'), isFalse);
    // The session has it: a sign-in again, the same device.
    expect(DuvetRepository.reopensFor('d', identified: true, sent: 'd', session: 'd'), isFalse);
    // A device started over: another one.
    expect(DuvetRepository.reopensFor('e', identified: true, sent: 'd', session: 'd'), isTrue);
  });

  group('the app', () {
    late Directory support;
    late List<http.Request> requests;
    late DuvetRepository repository;
    late _Host host;
    var shown = false;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      support = Directory.systemTemp.createTempSync('duvet-app-');
      messenger.setMockMethodCallHandler(paths, (_) async => support.path);
      requests = [];
      host = _Host();
      shown = false;
      final client = MockClient((request) async {
        requests.add(request);
        final json = switch ((request.method, request.url.path)) {
          ('POST', '/api/auth/login') => {
            'token': 'access-1',
            'session_token': 'refresh-1',
            'device_challenge': base64Encode(List.filled(32, 7)),
          },
          ('GET', '/api/users/@me') => {
            'id': _me,
            'username': 'gaby',
            'created_at': '2026-11-25T00:00:00Z',
            'updated_at': '2026-11-25T00:00:00Z',
          },
          ('GET', '/api/e2e') => {
            'external_sender': base64Encode(List.filled(32, 1)),
            'cutover_at': null,
            'paused': false,
            'min_clients': {'android': '0.0.0'},
            'limits': {
              for (final limit in [
                'ciphertext_bytes',
                'key_packages',
                'last_resort_key_packages',
                'key_package_bytes',
                'inbox_message_bytes',
                'history_share_parts',
                'history_share_part_bytes',
                'group_members',
                'listed_devices',
                'commit_bytes',
                'welcome_bytes',
                'group_info_bytes',
                'encrypted_identity_bytes',
                'wrapped_backup_key_bytes',
                'wrapped_previous_backup_keys_bytes',
                'certificate_bytes',
                'device_list_bytes',
                'epochs_behind',
              ])
                limit: 1,
            },
          },
          _ => null,
        };
        if (json == null) return http.Response('not found', 404);
        return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
      });
      repository = DuvetRepository(
        store: MemorySessionStore(),
        recentsStore: MemoryRecentChatsStore(),
        httpClient: () => client,
        connectGateway: false,
        cacheStore: MemoryChatCacheStore(),
        encryptionHost: () => host,
        onScreen: () => shown,
      );
    });

    tearDown(() {
      repository.dispose();
      messenger.setMockMethodCallHandler(paths, null);
      support.deleteSync(recursive: true);
    });

    test('says_what_it_is_on_every_request', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(request.headers['X-Duvet-Client'], 'android/${_version()}', reason: request.url.path);
      }
    });

    // Review Focus 2: main() runs on audio_service's engine too, which may start with no screen.
    test('runs_its_engine_once_on_a_screen,_and_stops_it_with_the_session', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      expect(host.opened, isEmpty);
      expect(repository.encryption.value, EngineState.starting);

      shown = true;
      repository.cameToFront();
      await eventually(() => expect(repository.encryption.value, EngineState.unsupported));
      expect(host.opened, [_me]);
      // Coming to the front again starts no second one.
      repository.cameToFront();
      await pumpEventQueue();
      expect(host.opened, [_me]);

      await repository.logOut();
      expect(repository.encryption.value, EngineState.starting);
      await eventually(() => expect(host.closed, 1));
    });
  });
}
