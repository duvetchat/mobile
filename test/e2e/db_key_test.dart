import 'dart:convert';

import 'package:duvet/e2e/db_key.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/keychain.dart';

// The key of a user's encryption database on this phone (PLAN-E2E-CLIENTES.md, where the database and its key live):
// 32 random bytes in flutter_secure_storage, which the Keystore encrypts, under duvet_e2e_db_key.<user_id>.
const ana = '0193a4b2-0000-7000-8000-000000000001';
const bo = '0193a4b2-0000-7000-8000-000000000002';

void main() {
  const storage = FlutterSecureStorage();
  const keys = DbKeys();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('the_key_is_made_once_and_kept', () async {
    expect(await keys.read(ana), isNull);
    final made = await keys.readOrMake(ana);
    expect(made, hasLength(32));
    expect(await keys.readOrMake(ana), made);
    expect(await keys.read(ana), made);
    // Under its name, in base64, and nothing else.
    expect(await storage.readAll(), {'duvet_e2e_db_key.$ana': base64Encode(made)});

    // Another user's database has a key of its own.
    final bos = await keys.readOrMake(bo);
    expect(bos, isNot(made));
    expect((await storage.readAll()).keys.toSet(), {'duvet_e2e_db_key.$ana', 'duvet_e2e_db_key.$bo'});

    await keys.delete(ana);
    expect(await keys.read(ana), isNull);
    expect(await keys.read(bo), bos);
  });

  // A database whose key reads wrong can't open with another: what's kept stays for whoever looks.
  test("a kept key that isn't 32 bytes is refused, and never replaced", () async {
    FlutterSecureStorage.setMockInitialValues({'duvet_e2e_db_key.$ana': base64Encode(List.filled(31, 7))});
    await expectLater(keys.read(ana), throwsFormatException);
    await expectLater(keys.readOrMake(ana), throwsFormatException);
    FlutterSecureStorage.setMockInitialValues({'duvet_e2e_db_key.$ana': 'not base64!'});
    await expectLater(keys.readOrMake(ana), throwsFormatException);
    expect(await storage.read(key: 'duvet_e2e_db_key.$ana'), 'not base64!');
  });

  test('a user ID that is no UUID names no key', () async {
    await expectLater(keys.readOrMake('../$ana'), throwsArgumentError);
    expect(await storage.readAll(), isEmpty);
  });

  // PLAN-E2E-PLATAFORMAS.md, where the database and its key live (Review Focus 8): an engine with no screen reads the
  // key with the phone locked, once it was unlocked after starting, and the key stays on this phone, in neither
  // iCloud's Keychain nor a backup restored to another one. Android's Keystore is asked as before.
  test('on iOS the key is kept for this device only, readable after the first unlock', () async {
    final keychain = KeychainCalls.install();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final made = await keys.readOrMake(ana);
    expect(await keys.read(ana), made);
    await keys.delete(ana);
    expect(keychain.options, isNotEmpty);
    expect(
      keychain.options,
      everyElement(
        allOf(containsPair('accessibility', 'first_unlock_this_device'), containsPair('synchronizable', 'false')),
      ),
    );

    keychain.options.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await keys.readOrMake(bo);
    expect(keychain.options, isNotEmpty);
    expect(keychain.options, everyElement(AndroidOptions.defaultOptions.params));
  });
}
