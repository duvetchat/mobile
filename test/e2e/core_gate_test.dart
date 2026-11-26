import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/db_key.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_e2e/duvet_e2e.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_lib.dart';

// The core in the app (PLAN-E2E-CLIENTES.md, Android: the engine that has the core): the app's engine opens a user's
// database with the key the phone keeps and answers the other engines through the duvet-e2e-core port; another engine
// asks through it, and opens the database itself only when no engine answers there.
const ana = '0193a4b2-0000-7000-8000-000000000001';
const storage = FlutterSecureStorage();

void main() {
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
    // Another engine: an isolate with neither the core's library nor the phone's storage, which would fail to open
    // the database. It opens, reads its status and seals a file through the port, then closes, which leaves the app's
    // core open.
    final answers = ReceivePort();
    await Isolate.spawn(_secondEngine, (answers.sendPort, ana));
    final answer = await answers.first.timeout(const Duration(seconds: 30));
    expect(answer, {
      'opened': 'ready',
      'device_id': device,
      'sealed_back': 'a file of the second engine',
      'progress': ['a file of the second engine'.length],
      'refused': 'bad_command',
    });
    expect(await deviceOf(app), device);
    await app.close();
  }, skip: noCore);

  // Review Focus 2 (Task 27): only the engine with a screen recovers, approves or starts over.
  test(
    "a device's setup runs only in the app's engine: another engine refuses it, with the app's engine or alone",
    () async {
      final refused = isA<CoreError>().having((e) => (e.code, e.field), 'refusal', ('bad_command', 'cmd'));
      final (app, _) = await appWithDevice();
      final other = gate(app: false);
      expect(await other.open(ana), ready);
      for (final cmd in screenOnly) {
        await expectLater(other.handle<Object?>({'cmd': cmd}), throwsA(refused));
      }
      await other.close();
      await app.close();
      final alone = gate(app: false);
      expect(await alone.open(ana), ready);
      await expectLater(alone.handle<Object?>({'cmd': 'recover'}), throwsA(refused));
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
    expect(await deviceOf(other), device);
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
    expect(await deviceOf(other), device);
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
    final (app, device) = await appWithDevice();
    final other = gate(app: false, answerWait: const Duration(milliseconds: 300));
    expect(await other.open(ana), ready);
    // The app's engine went away without a word: its port answers nothing.
    final port = IsolateNameServer.lookupPortByName(corePortName)!;
    await app.close();
    IsolateNameServer.registerPortWithName(port, corePortName);
    await expectLater(deviceOf(other), throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')));
    // Its name stayed, and still answers nothing: the next call opens the database here.
    expect(await deviceOf(other), device);
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
    await expectLater(
      other.handle<Object?>({'cmd': 'status'}),
      throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')),
    );
    expect(asked.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('destroy through the port: the app\'s engine deletes the database it has open, and its key', () async {
    final (app, _) = await appWithDevice();
    final other = gate(app: false);
    expect(await other.open(ana), ready);
    await other.destroy(ana);
    expect(File(database(ana)).existsSync(), isFalse);
    expect(await storage.readAll(), isEmpty);
    expect(IsolateNameServer.lookupPortByName(corePortName), isNull);
    await expectLater(
      app.handle<Object?>({'cmd': 'status'}),
      throwsA(isA<CoreError>().having((error) => error.code, 'code', 'internal')),
    );
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

/// The second engine of second_engine_asks_the_first, in an isolate of its own: no core library is loaded here, and
/// neither the phone's storage nor its folders answer.
Future<void> _secondEngine((SendPort, String) start) async {
  final (answer, user) = start;
  final gate = CoreGate(serves: false, folder: () => throw StateError("this engine can't reach the database"));
  final opened = await gate.open(user);
  final device = (await gate.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id'];
  final key = (await gate.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
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
    'device_id': device,
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
