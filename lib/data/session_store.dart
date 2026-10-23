import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The tokens that resume a session: the access token and the session
/// (refresh) token.
typedef StoredSession = ({String token, String sessionToken});

abstract interface class SessionStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

/// Keeps the tokens in the platform's keychain / keystore.
class SecureSessionStore implements SessionStore {
  static const _tokenKey = 'duvet_session_token';
  static const _sessionKey = 'duvet_refresh_token';

  final FlutterSecureStorage _storage;
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<StoredSession?> read() async {
    final token = await _storage.read(key: _tokenKey);
    final sessionToken = await _storage.read(key: _sessionKey);
    if (token == null || token.isEmpty) return null;
    return (token: token, sessionToken: sessionToken ?? '');
  }

  @override
  Future<void> write(StoredSession session) async {
    await _storage.write(key: _tokenKey, value: session.token);
    await _storage.write(key: _sessionKey, value: session.sessionToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _sessionKey);
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
