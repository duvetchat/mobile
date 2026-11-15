import 'package:duvet/data/session_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 15, 12);
  const storage = FlutterSecureStorage();

  // Two isolates write it, the app's and the background renewal's (lib/push/renewal.dart): under one key, a read
  // never finds half of one session and half of another.
  test('a session is written whole, under one key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const store = SecureSessionStore();
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at));
    expect(await storage.readAll(), hasLength(1));
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at));

    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: null));
    expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: null));
  });

  test('a session an older version kept under three keys is read, and written under one', () async {
    FlutterSecureStorage.setMockInitialValues({
      'duvet_session_token': 'access-1',
      'duvet_refresh_token': 'refresh-1',
      'duvet_session_refreshed_at': '${at.millisecondsSinceEpoch}',
    });
    const store = SecureSessionStore();
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at));

    await store.write((token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at));
    expect(await storage.readAll(), hasLength(1));
    expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: at));
  });

  test('cleared, nothing of it is left', () async {
    FlutterSecureStorage.setMockInitialValues({'duvet_session_token': 'access-0', 'duvet_refresh_token': 'refresh-0'});
    const store = SecureSessionStore();
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: at));
    await store.clear();
    expect(await store.read(), isNull);
    expect(await storage.readAll(), isEmpty);
  });
}
