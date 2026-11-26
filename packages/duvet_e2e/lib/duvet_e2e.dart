/// Duvet's end-to-end encryption core: [DuvetE2e.open] opens its database, and
/// [DuvetE2eCore.handle] runs its JSON commands on the core's own threads.
library;

import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/rust/api/core.dart';
import 'src/rust/frb_generated.dart';

/// Opens the core.
abstract final class DuvetE2e {
  static Future<void>? _loaded;

  /// Loads the native library, once. Tests hand it the library they built for the host.
  static Future<void> init({ExternalLibrary? library}) =>
      _loaded ??= RustLib.init(externalLibrary: library);

  /// Opens the database `configJson` names (`{"path"}`) with its raw 32-byte key, or creates it.
  ///
  /// Throws [DuvetE2eException] with the core's error reply: `locked` while another instance,
  /// in this process or another, has the database open; `bad_key` when the key doesn't open it.
  static Future<DuvetE2eCore> open(String configJson, Uint8List dbKey) async {
    await init();
    try {
      return DuvetE2eCore._(await OpenCore.open(configJson: configJson, dbKey: dbKey));
    } on OpenError catch (error) {
      throw DuvetE2eException(error.reply);
    }
  }

  /// Deletes the database `configJson` names (`{"path"}`) and SQLite's files beside it, as the
  /// core's lock is held: once it returns they're gone from the disk, and an open makes a new
  /// database. Its lock file stays, and its key, which the app keeps, is the app's to delete after.
  ///
  /// Throws [DuvetE2eException] with the core's error reply: `locked` while an instance, in this
  /// process or another, has the database open, and nothing is deleted then; `storage` when a file
  /// can't be deleted.
  static Future<void> destroy(String configJson) async {
    await init();
    try {
      await OpenCore.destroy(configJson: configJson);
    } on OpenError catch (error) {
      throw DuvetE2eException(error.reply);
    }
  }
}

/// The core over one open database. Its commands run one at a time.
final class DuvetE2eCore {
  DuvetE2eCore._(this._core);

  final OpenCore _core;

  /// Runs one JSON command (`{"cmd": ...}`) and returns its reply, `{"ok": ...}` or `{"error": ...}`.
  Future<String> handle(String command) => _core.handle(command: command);

  /// Closes the database: another instance may open it, and this one answers `not_found`.
  Future<void> close() => _core.close();
}

/// An `open` or a `destroy` that failed.
final class DuvetE2eException implements Exception {
  DuvetE2eException(this.reply);

  /// The core's error reply, `{"error": {"code", "message", ...}}`.
  final String reply;

  /// The error's stable code: `locked`, `bad_key`, `bad_command`...
  String get code {
    final error = (jsonDecode(reply) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
    return error['code'] as String;
  }

  @override
  String toString() => 'DuvetE2eException: $reply';
}
