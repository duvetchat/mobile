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

/// The inbox's approval frames waiting for their flow (Task 27), the transfers kept for later, and the messages the
/// core can't take yet (a history or catch-up key: Tasks 23 and 31), which each round gives it again, as inbox.dart
/// keeps them.
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

/// The devices this device approved (approval_confirm, or approval_from_qr after a scan), each with when, until a list
/// the core took names it (identity.dart): one still kept is an approval of this device's that didn't finish, whose
/// way out is to sign it off (approval.dart). This device's own word, never the API's (mobile#352).
const approvedHere = 'approved_here';

/// What this device knows of its user's devices, by ID: each one's name, client and when it was added, as `GET
/// …/devices` and DEVICE_ADD last gave them (devices.dart), the newest 50. What names one the API no longer lists.
const knownDevices = 'known_devices';

/// The user's devices the app told of once, as added and as not seen in 45 days (decision 13): it doesn't again.
const toldAdded = 'told_added';
const toldInactive = 'told_inactive';

/// The generation of each conversation whose members a welcome or a join was refused for, until the person's yes or a
/// later generation (sync.dart; the core's #46, kept across restarts).
const refusedGenerations = 'refused_generations';

/// The conversations whose welcome an apply refused as another group's (`another_group`, mobile#369): the API's group
/// at the generation this device holds another one of, kept by conversation with that welcome's generation
/// (mobile#383). Either engine notes one, a push's too, as the welcome that says so is spent; the app's engine forgets
/// its own group at that generation, then lets the note go, as any forget does (sync.dart).
const anotherGroups = 'another_groups';

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

/// This installation's device, once its user's list named it on the API (its first list went up, or it was ready):
/// from then on no list the API serves makes its first list wait again (identity.dart's firstListWaits). Its ID,
/// nothing secret.
const listedDevice = 'listed';

/// The shared histories and catch-ups whose keys this device's core took, by package (history.dart): no key, only
/// what's needed to know a package opens here, kept until it's imported and acknowledged.
const historyKeys = 'history_keys';

/// The encrypted backup's (backup.dart): IDs, times and counts alone. A restore that's due, with the conversations it
/// went through and whether only what it set aside is left (`{done, waiting}`); the key this device last saw itself
/// seal with and how far the move of other keys' segments went, the last segment it moved, in one write (`{key,
/// after}`, `after` gone once the move is over), as two writes of the file aren't atomic; since when a full storage
/// paused it (`{at}`); and what failed, by conversation and day, by conversation or by segment, with how many passes in
/// a row did and since when it's set aside.
const backupRestore = 'backup_restore';
const backupMove = 'backup_move';
const backupPaused = 'backup_paused';
const backupSetAside = 'backup_set_aside';

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
  approvedHere,
  knownDevices,
  refusedGenerations,
  anotherGroups,
  keyChanges,
  verifiedContacts,
  keysAgain,
  keptRelisted,
  keptReset,
  listedDevice,
  historyKeys,
  backupRestore,
  backupMove,
  backupPaused,
  backupSetAside,
];

/// The API's external sender as this installation first saw it (Ruling 32), which a new device of it keeps.
const externalSender = 'external_sender';

abstract interface class EngineStore {
  /// The JSON value kept under [key], or null.
  Object? read(String key);

  /// Keeps the JSON [value] under [key], null forgetting it: done once it's kept for good.
  Future<void> write(String key, Object? value);

  /// Keeps under [key] what [change] makes of the value the record holds for good as it runs, another engine's change
  /// included, null forgetting it: a key more than one engine changes (a refused generation). Done once it's kept.
  Future<void> update(String key, Object? Function(Object? kept) change);

  /// Takes [keys] again as the record holds them for good, once the writes before have landed: on disk, what another
  /// engine of this phone (a push's) wrote there while this one didn't hold the core (contacts.dart). Nothing is
  /// written; a record kept in memory alone has them already, and a key whose change here hasn't landed keeps it.
  Future<void> refresh(List<String> keys);
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The keys both the app's engine and a push's change through the store ([EngineStore.update]: a refused generation,
/// recordRefusedGeneration in sync.dart): read as the file holds them, unless a change of the record's own is on its
/// way (mobile#345). The contacts' keys are taken again with the core instead (Contacts.reload).
const _readOnDisk = {refusedGenerations};

/// How long a write waits for the record's lock at most, how often it looks again, and how old a lock is that a write
/// left as it ended holding it (its process killed): a write holds it for milliseconds.
const _lockWait = Duration(seconds: 30);
const _lockAgain = Duration(milliseconds: 10);
const _lockLeft = Duration(seconds: 5);

/// The record as a push's engine opens it, beside the app's engine (review 29's Minor 4): as every record's, its writes
/// change its own keys alone over what's on disk then, one engine at a time.
Future<FileEngineStore> pushRecord(String userId, {Future<Directory> Function()? folder}) =>
    FileEngineStore.open(userId, folder: folder);

/// The value as it is now, should its caller change it after: the JSON it's kept as.
Object? _copy(Object? value) => value == null ? null : jsonDecode(jsonEncode(value));

/// The record on disk, read once as it opens: a file that doesn't read is an empty record. A write holds the record's
/// lock while it reads the file as it is then, puts over it the keys this record changed and the file hasn't taken yet
/// (its whole copy, when the file doesn't read), writes that beside the record and renames it over it: a cut write
/// leaves the one before, and another engine's keys stay.
class FileEngineStore implements EngineStore {
  FileEngineStore._(this._file, this._values) : _next = File('${_file.path}.${uuidv4()}.next');

  /// [userId]'s record, in the app's support folder (or [folder], a test's). What killed writes left beside it goes
  /// first, under the lock, which every write holds while its file is beside the record.
  static Future<FileEngineStore> open(String userId, {Future<Directory> Function()? folder}) async {
    if (!_uuid.hasMatch(userId)) throw ArgumentError.value(userId, 'userId', 'a user ID is a UUID');
    final file = File('${(await (folder ?? getApplicationSupportDirectory)()).path}/e2e/$userId/client.json');
    try {
      if (await file.parent.exists()) await _locked(file, () => _dropLeftovers(file));
    } catch (error) {
      debugPrint("e2e: what a write left beside the engine's record stays: ${error.runtimeType}");
    }
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
    _set(key, _copy(value));
    return _land();
  }

  @override
  Future<void> update(String key, Object? Function(Object? kept) change) {
    final at = _changes;
    return _land((kept) {
      // A write of the key asked for after this one replaces what this one makes.
      if ((_unsaved[key] ?? 0) > at) return;
      _set(key, _copy(change(_unsaved.containsKey(key) || kept == null ? _values[key] : kept[key])));
    });
  }

  @override
  Future<void> refresh(List<String> keys) async {
    await _writing.catchError((Object _) {});
    await _locked(_file, () async {
      final kept = await _onDisk();
      if (kept == null) return;
      for (final key in keys) {
        if (!_unsaved.containsKey(key)) _take(kept, key);
      }
    });
  }

  void _set(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _unsaved[key] = ++_changes;
  }

  /// One write of the record, after this record's writes before it, holding the lock: the file as it is then, [first]
  /// (an update's change) made from it, then every key this record changed and the file hasn't taken yet put over it,
  /// or the whole record in memory when the file doesn't read.
  Future<void> _land([void Function(Map<String, Object?>? kept)? first]) {
    final done = _writing
        .catchError((Object _) {})
        .then(
          (_) => _locked(_file, () async {
            final kept = await _onDisk();
            first?.call(kept);
            final changes = {..._unsaved};
            if (kept == null) {
              await _save(jsonEncode(_values));
            } else {
              for (final name in changes.keys) {
                if (_values.containsKey(name)) {
                  kept[name] = _values[name];
                } else {
                  kept.remove(name);
                }
              }
              await _save(jsonEncode(kept));
            }
            // Taken: a key changed again since goes with the next write.
            for (final MapEntry(key: name, value: change) in changes.entries) {
              if (_unsaved[name] == change) _unsaved.remove(name);
            }
          }),
        );
    _writing = done;
    return done;
  }

  /// [work] while this engine holds the record's lock, `client.json.lock`, which each write, refresh and open takes: an
  /// exclusive create, which one engine of the phone makes at a time, in any isolate or process, where
  /// RandomAccessFile.lock is the process's, which every isolate of one process takes at once. A lock a write left as
  /// it ended holding it goes once it's [_lockLeft] old, or as far ahead of the clock; past [_lockWait], the work
  /// fails.
  static Future<T> _locked<T>(File record, Future<T> Function() work) async {
    final lock = File('${record.path}.lock');
    final waited = Stopwatch()..start();
    while (true) {
      try {
        await lock.create(recursive: true, exclusive: true);
        break;
      } on PathExistsException {
        if (waited.elapsed > _lockWait) rethrow;
        await _dropIfLeft(lock);
        await Future<void>.delayed(_lockAgain);
      }
    }
    try {
      return await work();
    } finally {
      try {
        await lock.delete();
      } on FileSystemException catch (error) {
        debugPrint("e2e: the engine's record's lock wasn't let go: ${error.runtimeType}");
      }
    }
  }

  /// A lock [_lockLeft] old, which a write left as it ended holding it, or as far ahead of the clock, which was set
  /// back since (mobile#366): moved away, by one engine alone, then deleted. A lock a moment ahead is a write's.
  static Future<void> _dropIfLeft(File lock) async {
    try {
      if (DateTime.now().difference(await lock.lastModified()).abs() < _lockLeft) return;
      await (await lock.rename('${lock.path}.${uuidv4()}.left')).delete();
    } on FileSystemException {
      // Let go or moved away meanwhile: the next try takes the lock as it is then.
    }
  }

  /// What killed writes left beside [record]: their files beside it and the locks moved away from them, never another
  /// file of its folder. Run under the lock, which a write holds while its file is there.
  static Future<void> _dropLeftovers(File record) async {
    final name = record.uri.pathSegments.last;
    await for (final entry in record.parent.list()) {
      final left = entry.uri.pathSegments.last;
      if (entry is File && left.startsWith('$name.') && (left.endsWith('.next') || left.endsWith('.left'))) {
        await entry.delete();
      }
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
