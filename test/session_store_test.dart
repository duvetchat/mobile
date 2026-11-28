import 'package:duvet/data/session_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/keychain.dart';

void main() {
  final at = DateTime.utc(2026, 11, 15, 12);
  const storage = FlutterSecureStorage();

  // Two isolates write it, the app's and the background renewal's (lib/push/renewal.dart): under one key, a read
  // never finds half of one session and half of another.
  test('a session is written whole, under one key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = SecureSessionStore();
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: null));
    expect(await storage.readAll(), hasLength(1));
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: null));

    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: null, userId: null));
    expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: null, userId: null));
  });

  test('a session an older version kept under three keys is read, and written under one', () async {
    FlutterSecureStorage.setMockInitialValues({
      'duvet_session_token': 'access-1',
      'duvet_refresh_token': 'refresh-1',
      'duvet_session_refreshed_at': '${at.millisecondsSinceEpoch}',
    });
    const store = SecureSessionStore();
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: null));

    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at, userId: null));
    expect(await storage.readAll(), hasLength(1));
    expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at, userId: null));
  });

  test('whose session it is is kept with it, and none in one saved without', () async {
    FlutterSecureStorage.setMockInitialValues({'duvet_session': '{"token":"access-1","session_token":"refresh-1"}'});
    const store = SecureSessionStore();
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null, userId: null));

    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: 'u-1'));
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: 'u-1'));
    expect(await storage.readAll(), hasLength(1));
  });

  // Three more round trips to the keychain at each renewal otherwise, for keys that aren't there.
  test('a write after a read that found the session under its one key leaves the old keys alone', () async {
    FlutterSecureStorage.setMockInitialValues({'duvet_session': '{"token":"access-1","session_token":"refresh-1"}'});
    const store = SecureSessionStore();
    await store.read();
    // Not there in the app: only so the test sees whether they were deleted.
    await storage.write(key: 'duvet_session_token', value: 'old');
    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at, userId: null));
    expect((await storage.readAll()).keys, containsAll(['duvet_session', 'duvet_session_token']));
    expect((await store.read())!.token, 'access-2');

    // A read that finds none under it doesn't know them gone: the next write deletes them.
    await storage.delete(key: 'duvet_session');
    expect((await store.read())!.token, 'old');
    await store.write((token: 'access-3', sessionToken: 'refresh-3', refreshedAt: at, userId: null));
    expect((await storage.readAll()).keys, ['duvet_session']);

    // Clearing always does.
    await storage.write(key: 'duvet_refresh_token', value: 'old');
    await store.clear();
    expect(await storage.readAll(), isEmpty);
  });

  // PLAN-E2E-PLATAFORMAS.md, where the database and its key live (Review Focus 8): the background renewal reads the
  // session with the phone locked, once it was unlocked after starting, and the session stays on this phone, in
  // neither iCloud's Keychain nor a backup restored to another one. Android's Keystore is asked as before.
  test('on iOS the session is kept for this device only, readable after the first unlock', () async {
    final keychain = KeychainCalls.install();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const store = SecureSessionStore();
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: 'u-1'));
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: 'u-1'));
    await store.clear();
    expect(keychain.options, isNotEmpty);
    expect(
      keychain.options,
      everyElement(
        allOf(containsPair('accessibility', 'first_unlock_this_device'), containsPair('synchronizable', 'false')),
      ),
    );

    keychain.options.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at, userId: null));
    expect(await store.read(), isNotNull);
    expect(keychain.options, isNotEmpty);
    expect(keychain.options, everyElement(AndroidOptions.defaultOptions.params));
  });

  test('cleared, nothing of it is left', () async {
    FlutterSecureStorage.setMockInitialValues({'duvet_session_token': 'access-0', 'duvet_refresh_token': 'refresh-0'});
    const store = SecureSessionStore();
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at, userId: null));
    await store.clear();
    expect(await store.read(), isNull);
    expect(await storage.readAll(), isEmpty);
  });
}
