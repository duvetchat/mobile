import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final _random = Random.secure();
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The key of each user's encryption database on this phone (PLAN-E2E-CLIENTES.md, where the database and its key
/// live): 32 random bytes in flutter_secure_storage, which the Keystore encrypts, under `duvet_e2e_db_key.<user_id>`.
/// Nothing else keeps it: the core gets it as it opens the database, and it never goes to a log, a file or the API.
/// flutter_secure_storage reads it in any of the app's engines, the one a push starts included, as it does the session.
class DbKeys {
  const DbKeys([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  /// What the key of [userId]'s database is kept under.
  static String nameOf(String userId) {
    if (!_uuid.hasMatch(userId)) throw ArgumentError.value(userId, 'userId', 'a user ID is a UUID');
    return 'duvet_e2e_db_key.$userId';
  }

  /// The key kept for [userId]'s database, or null when none is. Throws a [FormatException] for one that isn't 32
  /// bytes: whatever it is, no other key opens that database.
  Future<Uint8List?> read(String userId) async {
    final kept = await _storage.read(key: nameOf(userId));
    if (kept == null) return null;
    final key = base64Decode(kept);
    if (key.length != 32) throw const FormatException("the database's key isn't 32 bytes");
    return key;
  }

  /// The key kept for [userId]'s database, made and kept the first time.
  Future<Uint8List> readOrMake(String userId) async {
    if (await read(userId) case final kept?) return kept;
    final key = Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));
    await _storage.write(key: nameOf(userId), value: base64Encode(key));
    return key;
  }

  /// Forgets the key of [userId]'s database, once the database is gone.
  Future<void> delete(String userId) => _storage.delete(key: nameOf(userId));
}
