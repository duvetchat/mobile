/// The engine's record (PLAN-E2E-CLIENTES.md, «El motor», its store): small and with no secret, by user, kept in
/// `e2e/<user_id>/client.json` beside the user's database. What it holds is the engine's, and each reader checks what
/// it reads.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'uuid.dart';

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

/// Contacts' changed keys the person isn't done with (contacts.dart), by user: whether the identity replaced was
/// verified, the notice closed, the person's yes, and which change it is. Words alone, never a key.
const keyChanges = 'key_changes';

/// Whom the person verified on this device (contacts.dart), from their tap: user IDs, so a lost change is found again.
const verifiedContacts = 'verified_contacts';

/// Whether a change of keys of this device's left devices out with gone (duvetchat/e2e#49), until a new one starts:
/// the app offers another, as one of them may still hold the keys.
const keysAgain = 'keys_again';

/// Whether another device's change of keys kept a device this device's waiting change takes off, so that the core
/// refused its transfer (`removed_device_listed`, duvetchat/e2e#49): that change can never finish, and a later start,
/// which can't read that transfer again, still says so. Until the change ends.
const keptRelisted = 'relisted';

/// The identity a start over replaces (start_over.dart), from the person's tap until its upload is confirmed: a start
/// that finds the core's new identity waiting for its upload knows it for a start over, not a first device's.
const keptReset = 'reset';

/// The shared histories and catch-ups whose keys this device's core took, by package (history.dart): no key, only
/// what's needed to know a package opens here, kept until it's imported and acknowledged.
const historyKeys = 'history_keys';

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
  keyChanges,
  verifiedContacts,
  keysAgain,
  keptRelisted,
  keptReset,
  historyKeys,
];

/// The API's external sender as this installation first saw it (Ruling 32), which a new device of it keeps.
const externalSender = 'external_sender';

abstract interface class EngineStore {
  /// The JSON value kept under [key], or null.
  Object? read(String key);

  /// Keeps the JSON [value] under [key], null forgetting it: done once it's kept for good.
  Future<void> write(String key, Object? value);

  /// Takes [keys] again as the record holds them for good, once the writes before have landed: on disk, what another
  /// engine of this phone (a push's) wrote there while this one didn't hold the core (contacts.dart). Nothing is
  /// written; a record kept in memory alone has them already, and a key whose change here hasn't landed keeps it.
  Future<void> refresh(List<String> keys);
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The keys both the app's engine and a push's change through the store, each from what it read (a refused
/// generation: recordRefusedGeneration, sync.dart): read as the file holds them, so neither writes back its older copy
/// over the other's change (mobile#345). The contacts' keys are taken again with the core instead (Contacts.reload).
const _readOnDisk = {refusedGenerations};

/// The record as a push's engine opens it, beside the app's engine (review 29's Minor 4): as every record's, its writes
/// change its own keys alone over what's on disk then, as the app's engine may have written the others since.
Future<FileEngineStore> pushRecord(String userId, {Future<Directory> Function()? folder}) =>
    FileEngineStore.open(userId, folder: folder);

/// The record on disk, read once as it opens: a file that doesn't read is an empty record. Each write is the file as it
/// is then with the keys this record changed and the file hasn't taken yet, or the whole record in memory when the file
/// doesn't read, written beside it then renamed, so a cut write leaves the one before and another engine's keys stay.
class FileEngineStore implements EngineStore {
  FileEngineStore._(this._file, this._values) : _next = File('${_file.path}.${uuidv4()}.next');

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

  /// This record's own file beside the record, so two engines writing at once never write one file.
  final File _next;

  /// The keys this record changed and the file hasn't taken yet, each with its change's number: one the file refused
  /// goes again with the next write.
  final _unsaved = <String, int>{};
  var _changes = 0;

  // The writes one at a time, in order: one that failed doesn't hold up the next.
  Future<void> _writing = Future.value();

  @override
  Object? read(String key) {
    if (_readOnDisk.contains(key) && !_unsaved.containsKey(key)) {
      if (_onDiskNow() case final kept?) _take(kept, key);
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _unsaved[key] = ++_changes;
    final whole = jsonEncode(_values);
    // What this write puts over the file, as it is now, should its caller change it after: null forgets.
    final changes = {..._unsaved};
    final changed = jsonEncode({for (final name in changes.keys) name: _values[name]});
    final done = _writing.catchError((Object _) {}).then((_) async {
      // shortcut: another engine's write between this one's read and its rename is lost, one key's; a lock between
      // the isolates would close it, should that ever be seen.
      final kept = await _onDisk();
      if (kept == null) {
        await _save(whole);
      } else {
        for (final MapEntry(key: name, value: now) in (jsonDecode(changed) as Map<String, Object?>).entries) {
          if (now == null) {
            kept.remove(name);
          } else {
            kept[name] = now;
          }
        }
        await _save(jsonEncode(kept));
      }
      // Taken: a key changed again since goes with the next write.
      for (final MapEntry(key: name, value: change) in changes.entries) {
        if (_unsaved[name] == change) _unsaved.remove(name);
      }
    });
    _writing = done;
    return done;
  }

  @override
  Future<void> refresh(List<String> keys) async {
    await _writing.catchError((Object _) {});
    final kept = await _onDisk();
    if (kept == null) return;
    for (final key in keys) {
      if (!_unsaved.containsKey(key)) _take(kept, key);
    }
  }

  void _take(Map<String, Object?> kept, String key) {
    if (kept.containsKey(key)) {
      _values[key] = kept[key];
    } else {
      _values.remove(key);
    }
  }

  /// The record as the file holds it now, or null when there's none or it doesn't read.
  Future<Map<String, Object?>?> _onDisk() async {
    try {
      if (!await _file.exists()) return null;
      return (jsonDecode(await _file.readAsString()) as Map).cast<String, Object?>();
    } catch (error) {
      debugPrint("e2e: the engine's record didn't read again: ${error.runtimeType}");
      return null;
    }
  }

  /// [_onDisk], read at once: what [read] gives of a key another engine changes too.
  Map<String, Object?>? _onDiskNow() {
    try {
      if (!_file.existsSync()) return null;
      return (jsonDecode(_file.readAsStringSync()) as Map).cast<String, Object?>();
    } catch (error) {
      debugPrint("e2e: the engine's record didn't read again: ${error.runtimeType}");
      return null;
    }
  }

  Future<void> _save(String whole) async {
    await _file.parent.create(recursive: true);
    await _next.writeAsString(whole, flush: true);
    await _next.rename(_file.path);
  }
}
