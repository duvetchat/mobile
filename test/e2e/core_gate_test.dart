import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/db_key.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_e2e/duvet_e2e.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_lib.dart';

// The core in the app (PLAN-E2E-CLIENTES.md, Android: the engine that has the core): the app's engine opens a user's
// database with the key the phone keeps and answers the other engines through the duvet-e2e-core port; another engine
// asks through it, and opens the database itself only when no engine answers there.
const ana = '0193a4b2-0000-7000-8000-000000000001';
const bo = '0193a4b2-0000-7000-8000-000000000002';
const storage = FlutterSecureStorage();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    support = Directory.systemTemp.createTempSync('duvet-gate-');
  });
  tearDown(() {
    IsolateNameServer.removePortNameMapping(corePortName);
    support.deleteSync(recursive: true);
  });

  /// An engine's gate, the app's or another's, on this phone's support folder.
  CoreGate gate({required bool app, Duration? lockedWait, Duration? answerWait}) => CoreGate(
    serves: app,
    folder: () async => support,
    lockedWait: lockedWait ?? const Duration(seconds: 10),
    answerWait: answerWait ?? const Duration(seconds: 5),
  );
  String database(String user) => '${support.path}/e2e/$user/core.db';
  const ready = (state: HostState.ready, keyStorage: 'provided', reason: null);

  /// The app's engine, its database made and a device in it, open and answering on the port: its device's ID.
  Future<(CoreGate, String)> appWithDevice() async {
    final app = gate(app: true);
    expect(await app.open(ana), ready);
    final device = uuidv7();
    await app.handle<Object?>({'cmd': 'create_device', 'user_id': ana, 'device_id': device});
    return (app, device);
  }

  Future<String?> deviceOf(CoreGate gate) async =>
      (await gate.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id'] as String?;

  /// The read another engine makes, a push's: a page of a conversation's messages, which none has here. Only the app's
  /// engine reads its device's status (inBackground).
  Future<Object?> pageOn(CoreGate gate) async =>
      (await gate.handle<Map<String, Object?>>({'cmd': 'messages', 'conversation_id': ana, 'limit': 1}))['messages'];

  test('opens_with_the_stored_key', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i * 7));
    FlutterSecureStorage.setMockInitialValues({DbKeys.nameOf(ana): base64Encode(key)});
    final app = gate(app: true);
    expect(await app.open(ana), ready);
    expect((await app.handle<Map<String, Object?>>({'cmd': 'status'}))['key_storage'], 'provided');
    await app.close();

    // The database is where the plan puts it, and the stored key is the one that opens it.
    final config = jsonEncode({'path': database(ana)});
    await (await DuvetE2e.open(config, Uint8List.fromList(key))).close();
    await expectLater(
      DuvetE2e.open(config, Uint8List(32)),
      throwsA(isA<DuvetE2eException>().having((error) => error.code, 'code', 'bad_key')),
    );
    expect(await storage.readAll(), {DbKeys.nameOf(ana): base64Encode(key)});
  }, skip: noCore);

  test("the app's engine makes the key with the database, once; no other engine makes one", () async {
    // Another engine, with no database here, makes neither.
    expect((await gate(app: false).open(ana)).state, HostState.failed);
    expect(await storage.readAll(), isEmpty);
    expect(File(database(ana)).existsSync(), isFalse);

    final app = gate(app: true);
    expect(await app.open(ana), ready);
    final kept = await storage.readAll();
    expect(kept.keys, [DbKeys.nameOf(ana)]);
    await app.close();
    expect(await app.open(ana), ready);
    expect(await storage.readAll(), kept);
    await app.close();

    // A database whose key is gone is never given another: no key opens it, which the open says (bad_key), so the
    // engine doesn't try it again.
    FlutterSecureStorage.setMockInitialValues({});
    expect(await gate(app: true).open(ana), (state: HostState.failed, keyStorage: null, reason: 'bad_key'));
    expect(await storage.readAll(), isEmpty);
    // One the kept key doesn't open, the same.
    FlutterSecureStorage.setMockInitialValues({DbKeys.nameOf(ana): base64Encode(Uint8List(32))});
    expect(await gate(app: true).open(ana), (state: HostState.failed, keyStorage: null, reason: 'bad_key'));
  }, skip: noCore);

  test('second_engine_asks_the_first', () async {
    final (app, device) = await appWithDevice();
    final key = (await app.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
    // Another engine: an isolate with neither the core's library nor the phone's storage, which would fail to open
    // the database. It opens, reads a page of messages and seals a file through the port, then closes, which leaves
    // the app's core open.
    final answers = ReceivePort();
    await Isolate.spawn(_secondEngine, (answers.sendPort, ana, key));
    final answer = await answers.first.timeout(const Duration(seconds: 30));
    expect(answer, {
      'opened': 'ready',
      'page': <Object?>[],
      'sealed_back': 'a file of the second engine',
      'progress': ['a file of the second engine'.length],
      'refused': 'bad_command',
    });
    expect(await deviceOf(app), device);
    await app.close();
  }, skip: noCore);

  // Review Focus 2 and 3 (Task 27; step 5's review, Minor 2, mobile#366): another engine runs only what a push sends,
  // by a list of it: every other command the app sends its core runs only in the app's engine, the one with a screen.
  // Another engine refuses it before it asks the app's engine or runs it itself, so no change in a background path
  // makes a commit or an upload it never sends, in an engine with 15 s.
  test(
    "another engine runs only what a push sends: it refuses every other command, with the app's engine or alone",
    () async {
      final refused = isA<CoreError>()
          .having((e) => (e.code, e.field), 'refusal', ('bad_command', 'cmd'))
          .having((e) => e.message, 'message', endsWith('runs only in the app with a screen'));
      final (app, _) = await appWithDevice();
      final other = gate(app: false);
      expect(await other.open(ana), ready);
      for (final cmd in _withAScreen) {
        await expectLater(other.handle<Object?>({'cmd': cmd}), throwsA(refused), reason: cmd);
      }
      // What a push sends reaches the app's core, which answers it.
      final page = await other.handle<Map<String, Object?>>({
        'cmd': 'messages',
        'conversation_id': uuidv7(),
        'limit': 1,
      });
      expect(page['messages'], isEmpty);
      for (final cmd in ['apply', 'observe_user']) {
        await expectLater(other.handle<Object?>({'cmd': cmd}), throwsA(isNot(refused)), reason: cmd);
      }
      await other.close();
      await app.close();
      final alone = gate(app: false);
      expect(await alone.open(ana), ready);
      for (final cmd in _withAScreen) {
        await expectLater(alone.handle<Object?>({'cmd': cmd}), throwsA(refused), reason: cmd);
      }
      await alone.close();
    },
    skip: noCore,
  );

  test('without_a_port_it_opens_and_closes', () async {
    final (app, device) = await appWithDevice();
    await app.close();
    expect(IsolateNameServer.lookupPortByName(corePortName), isNull);

    // No engine answers on the port: this one opens the database itself, and answers nobody.
    final other = gate(app: false);
    expect(await other.open(ana), ready);
    expect(IsolateNameServer.lookupPortByName(corePortName), isNull);
    expect(await pageOn(other), isEmpty);
    await other.close();

    // Closed once its work is done: the next engine opens it.
    final next = gate(app: true);
    expect(await next.open(ana), ready);
    expect(await deviceOf(next), device);
    await next.close();
  }, skip: noCore);

  test('a_locked_open_waits_for_the_port', () async {
    final (app, device) = await appWithDevice();
    // The moment between the app's open and its port: the database is taken, and nothing answers on the port yet.
    final port = IsolateNameServer.lookupPortByName(corePortName)!;
    IsolateNameServer.removePortNameMapping(corePortName);
    final other = gate(app: false);
    final opening = other.open(ana);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    IsolateNameServer.registerPortWithName(port, corePortName);
    expect(await opening, ready);
    expect(await pageOn(other), isEmpty);
    await other.close();
    expect(await deviceOf(app), device);
    await app.close();
  }, skip: noCore);

  test('a locked open with no port to ask is locked once its wait is over', () async {
    final (app, _) = await appWithDevice();
    IsolateNameServer.removePortNameMapping(corePortName);
    final waited = Stopwatch()..start();
    expect((await gate(app: false, lockedWait: const Duration(milliseconds: 500)).open(ana)).state, HostState.locked);
    expect(waited.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
    await app.close();
  }, skip: noCore);

  test("a call whose engine went away is internal, and the next one opens the database again", () async {
    final (app, _) = await appWithDevice();
    final other = gate(app: false, answerWait: const Duration(milliseconds: 300));
    expect(await other.open(ana), ready);
    // The app's engine went away without a word: its port answers nothing.
    final port = IsolateNameServer.lookupPortByName(corePortName)!;
    await app.close();
    IsolateNameServer.registerPortWithName(port, corePortName);
    await expectLater(pageOn(other), throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')));
    // Its name stayed, and still answers nothing: the next call opens the database here.
    expect(await pageOn(other), isEmpty);
    expect(IsolateNameServer.lookupPortByName(corePortName), port);
    await other.close();
  }, skip: noCore);

  test("handle refuses the commands with ways of their own, and a gate with nothing open is internal", () async {
    final (app, _) = await appWithDevice();
    for (final cmd in ['attachment_encrypt', 'attachment_decrypt', 'history_share', 'catch_up', 'history_import']) {
      await expectLater(
        app.handle<Object?>({'cmd': cmd}),
        throwsA(isA<CoreError>().having((e) => (e.code, e.field), 'code', ('bad_command', 'cmd'))),
      );
    }
    await app.close();
    await expectLater(
      app.handle<Object?>({'cmd': 'status'}),
      throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')),
    );
  }, skip: noCore);

  test('a file goes through the core part by part, and back', () async {
    final (app, _) = await appWithDevice();
    final key = (await app.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
    final id = uuidv7();
    // Two whole parts and a bit of a third.
    final plain = Uint8List.fromList(List.generate(2 * attachmentPart + 5, (i) => i % 251));
    final done = <int>[];
    final sealed = await app.sealFile(key, id, plain, progress: done.add);
    expect(done, [attachmentPart, 2 * attachmentPart, plain.length]);
    expect(sealed.length, plain.length + 3 * partTag);
    expect(await app.openFile(key, id, sealed), plain);
    await expectLater(
      app.openFile(key, uuidv7(), sealed),
      throwsA(isA<CoreError>().having((error) => error.code, 'code', 'decrypt_failed')),
    );
    await app.close();
  }, skip: noCore);

  test('destroy leaves nothing to open: a new open makes a new database with a new key', () async {
    final (app, _) = await appWithDevice();
    final key = await storage.read(key: DbKeys.nameOf(ana));
    await app.destroy(ana);
    expect(await storage.readAll(), isEmpty);
    expect(File(database(ana)).existsSync(), isFalse);
    // The core's lock stays, empty: an open racing the deletion takes the same one.
    expect(File('${database(ana)}.lock').existsSync(), isTrue);
    expect(IsolateNameServer.lookupPortByName(corePortName), isNull);

    expect(await app.open(ana), ready);
    expect(await deviceOf(app), isNull);
    expect(await storage.read(key: DbKeys.nameOf(ana)), isNot(key));
    await app.close();
  }, skip: noCore);

  // PLAN-E2E-PLATAFORMAS.md, where the database and its key live (Review Focus 8): iOS backs up the app's support
  // folder, and a database restored from a backup is a cloned device, or one behind its groups. The app's engine takes
  // e2e/ out of the phone's backups before the core makes anything there, and again at every start. Android's manifest
  // keeps the app's files out of its backups, and nothing is asked there.
  test('the folder leaves the backups before the database is made', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final asked = <(String, {bool folder, bool database})>[];
    Future<Object?> exclude(MethodCall call) async {
      final path = call.arguments as String;
      if (call.method == 'exclude') {
        asked.add((path, folder: Directory(path).existsSync(), database: File(database(ana)).existsSync()));
      }
      return null;
    }

    messenger.setMockMethodCallHandler(storageChannel, exclude);
    addTearDown(() {
      messenger.setMockMethodCallHandler(storageChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final e2e = '${support.path}/e2e';
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final app = gate(app: true);
    expect(await app.open(ana), ready);
    expect(asked, [(e2e, folder: true, database: false)]);
    await app.close();
    expect(await app.open(ana), ready);
    expect(asked, [(e2e, folder: true, database: false), (e2e, folder: true, database: true)]);
    await app.close();
    // Another engine opens only a database there is, in the folder the app's engine took out.
    final other = gate(app: false);
    expect(await other.open(ana), ready);
    await other.close();
    expect(asked, hasLength(2));

    // A folder that can't leave the backups gets no database, nor a key, and the next start tries again.
    messenger.setMockMethodCallHandler(storageChannel, (call) async => throw PlatformException(code: 'storage'));
    expect(await gate(app: true).open(bo), (state: HostState.failed, keyStorage: null, reason: null));
    expect(File(database(bo)).existsSync(), isFalse);
    expect(await storage.read(key: DbKeys.nameOf(bo)), isNull);

    messenger.setMockMethodCallHandler(storageChannel, exclude);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    asked.clear();
    final android = gate(app: true);
    expect(await android.open(bo), ready);
    await android.close();
    expect(asked, isEmpty);
  }, skip: noCore);

  test('two opens at once make one key, the one the database opens with again', () async {
    final app = gate(app: true);
    final both = await Future.wait([app.open(ana), app.open(ana)]);
    expect([for (final opened in both) opened.state], [HostState.ready, HostState.ready]);
    final device = uuidv7();
    await app.handle<Object?>({'cmd': 'create_device', 'user_id': ana, 'device_id': device});
    await app.close();
    expect(await storage.readAll(), hasLength(1));
    final next = gate(app: true);
    expect(await next.open(ana), ready);
    expect(await deviceOf(next), device);
    await next.close();
  }, skip: noCore);

  test("a call whose core closed under it is internal, not the core's not_found", () async {
    final (app, _) = await appWithDevice();
    final making = expectLater(
      app.handle<Object?>({'cmd': 'key_packages'}),
      throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')),
    );
    await app.close();
    await making;
  }, skip: noCore);

  test('bytes cross between engines as TransferableTypedData, which the SDK promises between isolate groups', () async {
    final (app, _) = await appWithDevice();
    final key = (await app.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
    final answers = ReceivePort();
    IsolateNameServer.lookupPortByName(corePortName)!.send([
      answers.sendPort,
      'sealFile',
      ana,
      [
        key,
        uuidv7(),
        TransferableTypedData.fromList([
          Uint8List.fromList([1, 2, 3]),
        ]),
      ],
    ]);
    final answer = await answers.firstWhere((reply) => (reply as List).first != 'taken' && reply.first != 'progress');
    answers.close();
    expect(answer, ['ok', isA<TransferableTypedData>()]);
    await app.close();
  }, skip: noCore);

  test('a call whose engine ends after it took the call is internal at once, not after its wait', () async {
    final started = ReceivePort();
    await Isolate.spawn(_endingEngine, started.sendPort);
    await started.first;
    final other = gate(app: false, answerWait: const Duration(seconds: 20));
    expect(await other.open(ana), ready);
    final asked = Stopwatch()..start();
    await expectLater(pageOn(other), throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')));
    expect(asked.elapsed, lessThan(const Duration(seconds: 10)));
  });

  // M1 of step 4's closing review: the app's engine holds what it answers on the port to the same list the asking side
  // holds (inBackground), whoever sends, and deletes nothing at another engine's request.
  test("the port answers only what a push sends, and deletes no database for another engine", () async {
    final (app, _) = await appWithDevice();
    final port = IsolateNameServer.lookupPortByName(corePortName)!;
    Future<List<Object?>> answer(String op, [List<Object?> args = const []]) async {
      final replies = ReceivePort();
      port.send([replies.sendPort, op, ana, args]);
      final [_, last] = await replies.take(2).toList();
      replies.close();
      return last! as List<Object?>;
    }

    Object? codeOf(List<Object?> reply) => reply.first == 'error' ? jsonDecode(reply[1]! as String)['code'] : reply;
    expect(
      codeOf(
        await answer('handle', [
          jsonEncode({'cmd': 'status'}),
        ]),
      ),
      'bad_command',
    );
    expect(codeOf(await answer('destroy')), 'bad_command');
    final other = gate(app: false);
    expect(await other.open(ana), ready);
    await expectLater(other.destroy(ana), throwsA(isA<CoreError>()));
    expect(File(database(ana)).existsSync(), isTrue);
    expect(await storage.readAll(), isNotEmpty);
    expect((await app.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id'], isNotNull);
    // What a push sends is answered.
    expect(await pageOn(other), isEmpty);
  }, skip: noCore);

  test("a user's ID is a UUID, as it names a folder", () async {
    await expectLater(gate(app: true).open('../$ana'), throwsA(isA<CoreError>()));
    expect(support.listSync(), isEmpty);
  });

  group('CoreError', () {
    test("is the core's error with its code and the fields beside it", () {
      final error = CoreError.of({
        'code': 'needs_identities',
        'message': 'observe these users first',
        'users': [ana],
      });
      expect((error.code, error.message), ('needs_identities', 'observe these users first'));
      expect(error.users, [ana]);
      expect(CoreError.of({'code': 'gap', 'message': '', 'from': 7}).from, 7);
      expect(CoreError.of({'code': 'too_large', 'message': '', 'limit': 32768}).limit, 32768);
      expect(CoreError.of({'code': 'rule_violation', 'message': '', 'rule': 'stale_message'}).rule, 'stale_message');
      expect(CoreError.of({'code': 'bad_command', 'message': '', 'field': 'nonce'}).field, 'nonce');
      expect(CoreError.of({'code': 'not_found', 'message': '', 'what': 'group'}).what, 'group');
      expect(CoreError.of({'code': 'decrypt_failed', 'message': '', 'kind': 'envelope'}).kind, 'envelope');
    });

    test("takes no field the core didn't name as it writes it, and one without a message says its code", () {
      final error = CoreError.of({'code': 'storage', 'from': 'seven', 'users': 'ana', 'extra': 1});
      expect((error.message, error.from, error.users), ('storage', null, null));
    });

    test("a reply's ok is its value, an error reply throws its CoreError, and anything else is internal", () {
      expect(
        replyOk({
          'ok': {'handle': 3},
        }),
        {'handle': 3},
      );
      expect(
        () => replyOk({
          'error': {'code': 'locked', 'message': 'another instance has the database open'},
        }),
        throwsA(isA<CoreError>().having((error) => error.code, 'code', 'locked')),
      );
      for (final reply in [
        null,
        3,
        <String, Object?>{},
        {
          'ok': 1,
          'error': {'code': 'locked'},
        },
        {'error': 'locked'},
        {'error': <String, Object?>{}},
      ]) {
        expect(() => replyOk(reply), throwsA(isA<CoreError>().having((e) => e.code, 'code', 'internal')));
      }
    });
  });
}

/// Every command the app sends its core (lib/e2e) but the three a push sends, and those that go their own way.
const _withAScreen = [
  'add_members',
  'approval_accept',
  'approval_begin',
  'approval_check',
  'approval_confirm',
  'approval_from_qr',
  'approval_offer',
  'approval_receive',
  'approval_reveal',
  'attachment_key',
  'backup_due',
  'backup_import',
  'backup_reencrypt',
  'backup_segment',
  'backup_uploaded',
  'bind_proof',
  'catch_up_delivered',
  'commit_pending',
  'commit_result',
  'create_device',
  'create_group',
  'create_identity',
  'delete',
  'device_list_uploaded',
  'discard',
  'edit',
  'encrypt',
  'group',
  'identity_uploaded',
  'join_external',
  'key_packages',
  'leave',
  'receive_direct',
  'recover',
  'refresh',
  'refresh_due',
  'remove_members',
  'reset_group',
  'reset_identity',
  'rotate_keys',
  'safety_number',
  'search',
  'sent',
  'sign_device_list',
  'status',
  'verify_user',
  'without_devices',
];

/// The second engine of second_engine_asks_the_first, in an isolate of its own: no core library is loaded here, and
/// neither the phone's storage nor its folders answer.
Future<void> _secondEngine((SendPort, String, String) start) async {
  final (answer, user, key) = start;
  final gate = CoreGate(serves: false, folder: () => throw StateError("this engine can't reach the database"));
  final opened = await gate.open(user);
  final page = await gate.handle<Map<String, Object?>>({'cmd': 'messages', 'conversation_id': user, 'limit': 1});
  final id = uuidv7();
  final progress = <int>[];
  final plain = Uint8List.fromList(utf8.encode('a file of the second engine'));
  final sealed = await gate.sealFile(key, id, plain, progress: progress.add);
  final back = await gate.openFile(key, id, sealed);
  String? refused;
  try {
    await gate.handle<Object?>({'cmd': 'messages', 'conversation_id': user});
  } on CoreError catch (error) {
    refused = error.code;
  }
  await gate.close();
  answer.send({
    'opened': opened.state.name,
    'page': page['messages'],
    'sealed_back': utf8.decode(back),
    'progress': progress,
    'refused': refused,
  });
}

/// An app's engine that answers an open, then takes the next request and ends without answering it.
Future<void> _endingEngine(SendPort started) async {
  final port = ReceivePort();
  IsolateNameServer.registerPortWithName(port.sendPort, corePortName);
  started.send(null);
  await for (final request in port) {
    final [SendPort reply, String op, ...] = request as List;
    reply.send(['taken', Isolate.current.controlPort]);
    if (op != 'open') Isolate.exit();
    reply.send([
      'ok',
      jsonEncode({'state': 'ready'}),
    ]);
  }
}
