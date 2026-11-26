import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart' show ActionFailed, ConversationTarget;
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/push/call_decline.dart';
import 'package:duvet/push/renewal.dart';
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
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<void> close() async => closed++;

  @override
  Future<void> destroy(String userId) async {}
}

/// A core whose open waits for [opens], then opens with a device: an engine whose session ends while its core opens
/// goes on from there.
class _OpeningHost extends _Host {
  final opens = Completer<void>();
  final asked = <String>[];

  @override
  Future<Opened> open(String userId) async {
    opened.add(userId);
    await opens.future;
    return (state: HostState.ready, keyStorage: null, reason: null);
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    asked.add(command['cmd']! as String);
    if (command['cmd'] == 'status') return {'device_id': '01936d4e-8f00-7000-8000-000000000001'} as T;
    throw CoreError('internal', message: 'no core');
  }
}

/// A core with this device set up and listed, whose groups it doesn't hold yet: the engine goes ready on it, and its
/// conversations' commands are noted ([asked]), none of which makes a group.
class _ReadyHost extends _Host {
  static const device = '01936d4e-8f00-7000-8000-000000000002';
  static const identityKey = 'AQID';
  final asked = <Map<String, Object?>>[];

  @override
  Future<Opened> open(String userId) async {
    opened.add(userId);
    return (state: HostState.ready, keyStorage: null, reason: null);
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    asked.add(command);
    final Object ok = switch (command['cmd']) {
      'status' => {'device_id': device, 'identity_key': identityKey, 'has_identity': true},
      'observe_user' => {'state': 'same', 'verified': false},
      'key_packages' => {'key_packages': <Object?>[]},
      'refresh_due' => {'conversations': <Object?>[]},
      'group' => throw CoreError('not_found', what: 'group'),
      _ => throw CoreError('internal', message: 'not in this core'),
    };
    return ok as T;
  }

  /// The commands the engine sent this core of a conversation's, by their names.
  List<String> of(String conversation) => [
    for (final command in asked)
      if (command['conversation_id'] == conversation) command['cmd']! as String,
  ];
}

/// A conversation without a group yet, as the conversations' list gives it: a DM of [_me]'s, or a group of another's.
Map<String, Object?> _conversation(String id, {required bool group}) {
  const other = '00000000-0000-4000-8000-000000000002';
  const at = '2026-11-25T00:00:00Z';
  return {
    'id': id,
    'type': group ? 2 : 1,
    'name': null,
    'owner_id': group ? other : _me,
    'created_at': at,
    'updated_at': at,
    'deleted_at': null,
    'members': [
      for (final (n, user) in [_me, other].indexed)
        {'id': '$id-$n', 'conversation_id': id, 'user_id': user, 'created_at': at, 'updated_at': at},
    ],
    'legacy': false,
    'mls': null,
  };
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
    // What a test answers besides the session's routes (the engine's): null for none.
    late Object? Function(http.Request request) routes;
    // Each sign-in's access token is a new one: access-1, access-2…
    var logins = 0;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      support = Directory.systemTemp.createTempSync('duvet-app-');
      messenger.setMockMethodCallHandler(paths, (_) async => support.path);
      requests = [];
      host = _Host();
      shown = false;
      logins = 0;
      routes = (_) => null;
      final client = MockClient((request) async {
        requests.add(request);
        if (routes(request) case final answer?) {
          return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
        }
        final json = switch ((request.method, request.url.path)) {
          ('POST', '/api/auth/login') => {
            'token': 'access-${++logins}',
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

    // M1 of the review: the requests the app makes from the background say it too: the session's renewal
    // (WorkManager's) and a call's Decline from its notification.
    test("says_what_it_is_from_the_background_too:_the_session's_renewal_and_a_call's_decline", () async {
      final sent = <http.BaseRequest>[];
      final client = MockClient((request) async {
        sent.add(request);
        if (request.url.path == '/api/auth/refresh') {
          return http.Response(jsonEncode({'token': 'access-2', 'session_token': 'refresh-2'}), 200);
        }
        return http.Response('', 204);
      });
      final now = DateTime.utc(2026, 11, 25, 12);
      final store = MemorySessionStore((
        token: 'access-1',
        sessionToken: 'refresh-1',
        refreshedAt: now.subtract(const Duration(hours: 5)),
        userId: _me,
      ));
      await renewStoredSession(store, client, duvetRouter, now);
      const conversation = '00000000-0000-4000-8000-000000000002';
      await declineFromNotification(conversation, startedAt: 0, store: store, client: client);
      expect(
        [for (final request in sent) request.url.path],
        ['/api/auth/refresh', '/api/users/@me/conversations/$conversation/call/decline'],
      );
      for (final request in sent) {
        expect(request.headers['X-Duvet-Client'], 'android/${_version()}', reason: request.url.path);
      }
    });

    // M5 of the review: an engine whose session ended asks nothing more of the API, nor of the next session's client.
    // The reopen keeps its session: gateway_session_test.dart's engine goes on through the new client.
    test('an_engine_whose_session_ended_asks_nothing_of_the_next_one', () async {
      final opening = _OpeningHost();
      host = opening;
      shown = true;
      await repository.logIn('gaby@duvet.chat', 'secret');
      await eventually(() => expect(opening.opened, [_me]));
      // Signed out while its core opens, and in again; the new session's engine waits for the screen.
      await repository.logOut();
      shown = false;
      await repository.logIn('gaby@duvet.chat', 'secret');
      final asked = requests.length;

      opening.opens.complete();
      await eventually(() => expect(opening.closed, 1));
      // It went on from the core's open: its device, then the binding, whose first request never went.
      expect(opening.asked, contains('status'));
      expect([
        for (final request in requests.skip(asked))
          if (request.url.path.startsWith('/api/users/@me/devices')) request.headers['Authorization'],
      ], isEmpty);
    });

    /// The engine's routes for a device set up and listed, with [conversations] listed and no group in them.
    Object? Function(http.Request request) engineRoutes(List<Map<String, Object?>> conversations) => (request) {
      final path = request.url.path;
      return switch (request.method) {
        'GET' when path == '/api/users/@me/devices' => [
          {
            'id': _ReadyHost.device,
            'name': 'Pixel 8 Pro',
            'client': 'android/1.1.0',
            'listed': true,
            'current': true,
            'created_at': '2026-11-25T00:00:00Z',
            'last_seen_at': '2026-11-25T00:00:00Z',
          },
        ],
        'GET' when path == '/api/users/$_me/identity' => {
          'user_id': _me,
          'identity_key': _ReadyHost.identityKey,
          'device_list': 'AQID',
          'device_list_version': 1,
          'certificates': <Object?>[],
          'active': true,
          'changed_at': '2026-11-25T00:00:00Z',
        },
        'GET' when path == '/api/users/@me/devices/@me/inbox' => <Object?>[],
        'GET' when path == '/api/users/@me/conversations' => conversations,
        'PUT' when path == '/api/users/@me/devices/@me/key-packages' => {'handed_out': <Object?>[]},
        'POST' when path.endsWith('/key-packages/claim') => {'key_packages': <Object?>[]},
        _ => null,
      };
    };

    // M3 of the review: the repository's wiring of a conversation's group. A conversation on screen before the engine
    // exists gets its group once the engine is ready, and what each conversation says shows until the session ends.
    test("a_conversation_shown_before_the_engine_exists_gets_its_group_once_it's_ready", () async {
      final ready = _ReadyHost();
      host = ready;
      routes = engineRoutes([
        _conversation('dm-1', group: false),
        _conversation('dm-2', group: false),
        _conversation('group-1', group: true),
      ]);
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.chatShown(const ConversationTarget('dm-1'));
      await pumpEventQueue();
      expect(host.opened, isEmpty);

      shown = true;
      repository.cameToFront();
      await eventually(() => expect(repository.encryption.value, EngineState.ready));
      // The DM's group is made here, as either member may (this core makes none).
      await eventually(() => expect(ready.of('dm-1'), contains('create_group')));
      // Another, shown with the engine ready, gets its group at once.
      expect(ready.of('dm-2'), isNot(contains('create_group')));
      repository.chatShown(const ConversationTarget('dm-2'));
      await eventually(() => expect(ready.of('dm-2'), contains('create_group')));
      // The group of another's waits for its owner, which the app shows; then the session ends, and it goes.
      await eventually(
        () => expect(repository.conversationStates.value, {
          'group-1': const ConversationState.waitOwner('00000000-0000-4000-8000-000000000002'),
        }),
      );
      await repository.logOut();
      expect(repository.conversationStates.value, isEmpty);
    });

    // M1 of the review: a thread shown over its chat, whose own hide the chat reports after, leaves the conversation
    // open in the engine: a view of it is still on screen.
    test('a_thread_over_its_chat_keeps_the_conversation_open', () async {
      final ready = _ReadyHost();
      host = ready;
      routes = engineRoutes([_conversation('dm-1', group: false)]);
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository
        ..chatShown(const ConversationTarget('dm-1'))
        ..chatShown(const ConversationTarget('dm-1'), threadOf: 'message-1')
        ..chatHidden(const ConversationTarget('dm-1'));
      shown = true;
      repository.cameToFront();
      await eventually(() => expect(repository.encryption.value, EngineState.ready));
      await eventually(() => expect(ready.of('dm-1'), contains('create_group')));
      await repository.logOut();
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

    // Review Focus 2 of task 17: only the app's engine on a screen encrypts or reads messages. Off a screen (a push's
    // engine, audio_service's, WorkManager's) the core isn't opened, and a conversation's message goes nowhere.
    test("off_a_screen_a_conversation's_message_is_neither_encrypted_nor_sent", () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      await expectLater(
        repository.send(const ConversationTarget('c-1'), 'not here', nonce: 'n-1'),
        throwsA(isA<ActionFailed>()),
      );
      expect(host.opened, isEmpty);
      expect(requests.where((r) => r.method == 'POST' && r.url.path.contains('/conversations/')), isEmpty);
    });
  });
}
