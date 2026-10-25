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

/// Keeps the tokens in the platform's keychain / keystore.
class SecureSessionStore implements SessionStore {
  static const _tokenKey = 'duvet_session_token';
  static const _sessionKey = 'duvet_refresh_token';
  static const _refreshedKey = 'duvet_session_refreshed_at';

  final FlutterSecureStorage _storage;
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<StoredSession?> read() async {
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
    await _storage.write(key: _tokenKey, value: session.token);
    await _storage.write(key: _sessionKey, value: session.sessionToken);
    if (session.refreshedAt case final at?) {
      await _storage.write(key: _refreshedKey, value: '${at.millisecondsSinceEpoch}');
    } else {
      await _storage.delete(key: _refreshedKey);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _sessionKey);
    await _storage.delete(key: _refreshedKey);
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
