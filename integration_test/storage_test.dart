import 'dart:io';

import 'package:duvet/e2e/bootstrap.dart' show phoneName;
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/db_key.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// The encryption database, its key and this device's name in the iOS app itself (PLAN-E2E-PLATAFORMAS.md, Task 13),
// which CI's ios job runs on a simulator: the app's gate, on the app's support folder and the Keychain, as on a phone.
// Each test has a user of its own, whose database goes with its key once the test is done.
const ready = (state: HostState.ready, keyStorage: 'provided', reason: null);

/// What ios/Runner/Storage.swift answers on.
const storage = MethodChannel('chat.duvet/storage');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late String user;
  late CoreGate app;
  Future<Directory> folder() async => Directory('${(await getApplicationSupportDirectory()).path}/e2e');
  Future<String?> deviceOf(CoreGate gate) async =>
      (await gate.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id'] as String?;

  setUp(() {
    user = uuidv7();
    app = CoreGate(serves: true);
  });
  tearDown(() async {
    if (File('${(await folder()).path}/$user/core.db').existsSync()) await app.destroy(user);
    await app.close();
  });

  test("the database's folder is excluded from backups", () async {
    // As on a phone that never had one: the folder is the app's first open's.
    final e2e = await folder();
    if (e2e.existsSync()) e2e.deleteSync(recursive: true);
    expect(await app.open(user), ready);
    expect(File('${e2e.path}/$user/core.db').existsSync(), isTrue);
    expect(await storage.invokeMethod<bool>('excluded', e2e.path), isTrue);
  });

  test('the key survives a restart of the app', () async {
    expect(await app.open(user), ready);
    final device = uuidv7();
    await app.handle<Object?>({'cmd': 'create_device', 'user_id': user, 'device_id': device});
    await app.close();
    // The Keychain has it, and the next start's gate, which knows nothing of this one, opens the database with it.
    expect(await const DbKeys().read(user), hasLength(32));
    app = CoreGate(serves: true);
    expect(await app.open(user), ready);
    expect(await deviceOf(app), device);
  });

  test('a database whose key is gone starts over as a new device', () async {
    expect(await app.open(user), ready);
    await app.handle<Object?>({'cmd': 'create_device', 'user_id': user, 'device_id': uuidv7()});
    await app.close();
    // As a backup restored to another iPhone would leave the database, if one held it: no key opens it.
    await const DbKeys().delete(user);
    expect(await app.open(user), (state: HostState.failed, keyStorage: null, reason: 'bad_key'));
    // Starting over destroys it with its key, and the next open makes a new one, with a new key and no device yet.
    await app.destroy(user);
    expect(await app.open(user), ready);
    expect(await deviceOf(app), isNull);
    expect(await const DbKeys().read(user), hasLength(32));
  });

  test("this phone's device is named by its model", () async {
    expect(await phoneName(), anyOf('iPhone', 'iPad'));
  });
}
