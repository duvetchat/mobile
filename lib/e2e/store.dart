/// The engine's record (PLAN-E2E-CLIENTES.md, «El motor», its store): small and with no secret, by user, kept in
/// `e2e/<user_id>/client.json` beside the user's database. What it holds is the engine's, and each reader checks what
/// it reads.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The device this installation registered for the user, which each identify names (Ruling 30): kept so the app
/// identifies before its core opens.
const keptDevice = 'device';

/// This installation's device's public keys, with its ID, which each sign-in registers again (bootstrap.dart).
const deviceKeys = 'device_keys';

/// The inbox's approval frames waiting for their flow (Task 27), the transfers kept for later, and the messages whose
/// type a later task takes (a history or catch-up key: Tasks 23 and 31), as inbox.dart keeps them.
const keptApprovals = 'approvals';
const keptTransfers = 'transfers';
const keptLater = 'later';

/// What goes in the clear with each message of the person's still being sent, by its nonce (send.dart): never its
/// text, which the core keeps.
const pendingSends = 'pending_sends';

/// The person's edits and deletions not answered yet, in their order: each one's conversation, message and kind, never
/// its text (send.dart), made again at the next start.
const pendingChanges = 'pending_changes';

/// What a rotation of this device's takes off the list, kept before it runs: run again before its upload, it must
/// take the same devices off (devices.dart).
const rotationRemove = 'rotation_remove';

/// The user's devices the app told of once, as added and as not seen in 45 days (decision 13): it doesn't again.
const toldAdded = 'told_added';
const toldInactive = 'told_inactive';

/// The generation of each conversation whose members a welcome or a join was refused for, until the person's yes or a
/// later generation (sync.dart; the core's #46, kept across restarts).
const refusedGenerations = 'refused_generations';

/// Whether a change of keys of this device's left devices out with gone (duvetchat/e2e#49), until a new one starts:
/// the app offers another, as one of them may still hold the keys.
const keysAgain = 'keys_again';

/// The identity a start over replaces (start_over.dart), from the person's tap until its upload is confirmed: a start
/// that finds the core's new identity waiting for its upload knows it for a start over, not a first device's.
const keptReset = 'reset';

/// What a new device of this installation starts without.
const deviceRecord = [
  keptDevice,
  deviceKeys,
  keptApprovals,
  keptTransfers,
  keptLater,
  pendingSends,
  pendingChanges,
  rotationRemove,
  refusedGenerations,
  keysAgain,
  keptReset,
];

/// The API's external sender as this installation first saw it (Ruling 32), which a new device of it keeps.
const externalSender = 'external_sender';

abstract interface class EngineStore {
  /// The JSON value kept under [key], or null.
  Object? read(String key);

  /// Keeps the JSON [value] under [key], null forgetting it: done once it's kept for good.
  Future<void> write(String key, Object? value);
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The record on disk, read once as it opens: a file that doesn't read is an empty record. Each write replaces the
/// whole file, written beside it then renamed, so a cut write leaves the one before.
class FileEngineStore implements EngineStore {
  FileEngineStore._(this._file, this._values);

  /// [userId]'s record, in the app's support folder (or [folder], a test's).
  static Future<FileEngineStore> open(String userId, {Future<Directory> Function()? folder}) async {
    if (!_uuid.hasMatch(userId)) throw ArgumentError.value(userId, 'userId', 'a user ID is a UUID');
    final file = File('${(await (folder ?? getApplicationSupportDirectory)()).path}/e2e/$userId/client.json');
    var values = <String, Object?>{};
    try {
      if (await file.exists()) values = (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } catch (error) {
      debugPrint("e2e: the engine's record didn't read: ${error.runtimeType}");
    }
    return FileEngineStore._(file, values);
  }

  final File _file;
  final Map<String, Object?> _values;

  // The writes one at a time, in order: one that failed doesn't hold up the next.
  Future<void> _writing = Future.value();

  @override
  Object? read(String key) => _values[key];

  @override
  Future<void> write(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    final whole = jsonEncode(_values);
    final done = _writing.catchError((Object _) {}).then((_) => _save(whole));
    _writing = done;
    return done;
  }

  Future<void> _save(String whole) async {
    await _file.parent.create(recursive: true);
    final next = File('${_file.path}.next');
    await next.writeAsString(whole, flush: true);
    await next.rename(_file.path);
  }
}
