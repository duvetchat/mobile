import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../e2e/db_key.dart' show phoneKeychain;

/// The tokens that resume a session, the access token and the session
/// (refresh) token, and when the API issued them: at the login or the last
/// renewal. Null when that isn't known (saved by an older version of the
/// app). And whose session it is, once the API said: null until then, and in
/// one an older version saved.
typedef StoredSession = ({String token, String sessionToken, DateTime? refreshedAt, String? userId});

abstract interface class SessionStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

/// Keeps the tokens in the platform's keychain / keystore, whole under one key
/// (JSON): two isolates write them, the app's and the background renewal's
/// (lib/push/renewal.dart), and a read must never find half of one session and
/// half of another. On iOS the renewal reads them with the phone locked, and
/// they stay on this phone ([phoneKeychain]).
class SecureSessionStore implements SessionStore {
  static const _key = 'duvet_session';

  // Where versions before kept them, a key each: read until the next write.
  static const _tokenKey = 'duvet_session_token';
  static const _sessionKey = 'duvet_refresh_token';
  static const _refreshedKey = 'duvet_session_refreshed_at';

  // The old keys are known to be gone: a write needn't delete them again, three
  // round trips to the keychain each time. Static, as the store is const, so
  // each isolate finds out for itself. A read that finds no session under
  // [_key] forgets it.
  static bool _oldKeysGone = false;

  final FlutterSecureStorage _storage;
  const SecureSessionStore([this._storage = phoneKeychain]);

  @override
  Future<StoredSession?> read() async {
    final kept = await _storage.read(key: _key);
    // Under the one key, so a write since then took the old ones away. One that
    // died before it did leaves them until the session is cleared: nothing
    // reads them, as this key wins.
    _oldKeysGone = kept != null;
    if (kept != null) {
      try {
        final session = jsonDecode(kept);
        if (session case {
          'token': final String token,
          'session_token': final String sessionToken,
        } when token.isNotEmpty) {
          return (
            token: token,
            sessionToken: sessionToken,
            refreshedAt: switch (session['refreshed_at']) {
              final int at => DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
              _ => null,
            },
            userId: switch (session['user_id']) {
              final String id when id.isNotEmpty => id,
              _ => null,
            },
          );
        }
      } on FormatException {
        // Unreadable: no session.
      }
      return null;
    }
    final token = await _storage.read(key: _tokenKey);
    final sessionToken = await _storage.read(key: _sessionKey);
    if (token == null || token.isEmpty) return null;
    final refreshed = int.tryParse(await _storage.read(key: _refreshedKey) ?? '');
    return (
      token: token,
      sessionToken: sessionToken ?? '',
      refreshedAt: refreshed == null ? null : DateTime.fromMillisecondsSinceEpoch(refreshed, isUtc: true),
      userId: null,
    );
  }

  @override
  Future<void> write(StoredSession session) async {
    await _storage.write(
      key: _key,
      value: jsonEncode({
        'token': session.token,
        'session_token': session.sessionToken,
        if (session.refreshedAt case final at?) 'refreshed_at': at.millisecondsSinceEpoch,
        'user_id': ?session.userId,
      }),
    );
    if (!_oldKeysGone) await _forgetOldKeys();
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _forgetOldKeys();
  }

  Future<void> _forgetOldKeys() async {
    for (final key in [_tokenKey, _sessionKey, _refreshedKey]) {
      await _storage.delete(key: key);
    }
    _oldKeysGone = true;
  }
}

/// Keeps the tokens until the app exits.
class MemorySessionStore implements SessionStore {
  StoredSession? _session;
  MemorySessionStore([this._session]);

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
