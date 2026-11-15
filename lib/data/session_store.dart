import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The tokens that resume a session, the access token and the session
/// (refresh) token, and when the API issued them: at the login or the last
/// renewal. Null when that isn't known (saved by an older version of the
/// app).
typedef StoredSession = ({String token, String sessionToken, DateTime? refreshedAt});

abstract interface class SessionStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

/// Keeps the tokens in the platform's keychain / keystore, whole under one key
/// (JSON): two isolates write them, the app's and the background renewal's
/// (lib/push/renewal.dart), and a read must never find half of one session and
/// half of another.
class SecureSessionStore implements SessionStore {
  static const _key = 'duvet_session';

  // Where versions before kept them, a key each: read until the next write.
  static const _tokenKey = 'duvet_session_token';
  static const _sessionKey = 'duvet_refresh_token';
  static const _refreshedKey = 'duvet_session_refreshed_at';

  final FlutterSecureStorage _storage;
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<StoredSession?> read() async {
    if (await _storage.read(key: _key) case final kept?) {
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
      }),
    );
    await _forgetOldKeys();
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
