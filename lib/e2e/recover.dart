/// A new device of a user who has an identity, set up with the recovery key (PLAN-E2E-CLIENTES.md, Tasks 26 and 27;
/// decisions 22 and 24): the key checked as the core reads it before anything is asked of the API, then what the API
/// keeps for recovery opened with it (GET …/identity/backup, recover). Then the device puts up its first list, with
/// itself on it and its certificate, as a device another one approved does too (approval.dart). The desktop's
/// recover.ts in Dart.
library;

import 'package:duvet_client/duvet.dart' as duvet;

import 'bootstrap.dart';
import 'cbor.dart';
import 'devices.dart' show takenAway;
import 'engine.dart';
import 'host.dart';
import 'identity.dart';

/// The recovery key as the core reads one (decision 22): its 48 characters, spaces and dashes aside, and their check.
/// The core reads the key before what it opens, so `recover` with nothing to open throws a mistyped key's
/// `bad_command` (`recovery_key`) before the API is asked for anything, and leaves the device as it was; a key that
/// reads gets as far as the nothing it was given to open.
Future<void> checkRecoveryKey(E2EEngine engine, String recoveryKey) async {
  try {
    await engine.host.handle<Object?>({
      'cmd': 'recover',
      'recovery_key': recoveryKey,
      'wrapped_backup_key': '',
      'encrypted_identity': '',
      'device_list': '',
    });
  } on CoreError catch (error) {
    if (error.code == 'bad_command' && error.field == 'recovery_key') rethrow;
  }
}

/// A command given the backup keys from before a change of keys, which the API keeps, when it keeps some: run again
/// without them when they don't open with the backup key (the core's rule), as only the backup reads them (Task 33).
Future<T> withPreviousKeys<T>(String? previous, Future<T> Function(String? previous) run) async {
  if (previous == null || previous.isEmpty) return run(null);
  try {
    return await run(previous);
  } on CoreError catch (error) {
    if (error.code != 'decrypt_failed' || error.kind != 'previous_backup_keys') rethrow;
    return run(null);
  }
}

/// This device takes the user's identity: what the API keeps for recovery, opened with the recovery key.
Future<void> recoverIdentity(E2EEngine engine, String recoveryKey) async {
  final backup = await engine.api.identityBackup();
  await withPreviousKeys(
    backup.wrappedPreviousBackupKeys,
    (previous) => engine.host.handle<Object?>({
      'cmd': 'recover',
      'recovery_key': recoveryKey,
      'device_list': backup.deviceList,
      'encrypted_identity': backup.encryptedIdentity,
      'wrapped_backup_key': backup.wrappedBackupKey,
      'wrapped_previous_backup_keys': ?previous,
    }),
  );
}

/// How a device's first list went: up, [lost] to another list there first, or waiting for the person's Finish to
/// leave out the devices [leavingOut] names.
typedef FirstList = ({bool lost, List<String> leavingOut});

/// This device's first list, once it holds the identity (recovered, or approved) and the API doesn't list it yet: the
/// list it holds, with itself on it, signed again without the devices the API took away (a new password's
/// remove_devices: the API refuses a list that names them, step 3's ruling 23), goes up with this device's certificate
/// on top of the version served, and is confirmed only after its 200 (Review Focus 11), the own user observed after.
/// Leaving devices out is the person's act: the app names them first, and only their Finish signs ([signOff]; Android
/// has no box of the system's, and a start waits for that tap too, as the desktop's does). Another list there first
/// (409) leaves this device off for good ([FirstList.lost]): no command adds a device to a list.
Future<FirstList> putFirstList(E2EEngine engine, {required bool signOff}) async {
  final served = await servedIdentity(engine) ?? (throw StateError('this user has no identity to list this device on'));
  var status = await coreStatus(engine.host);
  final off = await takenAway(engine, status.deviceList ?? '');
  if (off.isNotEmpty) {
    if (!signOff) return (lost: false, leavingOut: off);
    await engine.host.handle<Object?>({'cmd': 'sign_device_list', 'remove': off});
    status = await coreStatus(engine.host);
  }
  final (list, certificate) = (status.deviceList, status.certificate);
  if (list == null || certificate == null || listDevices(list) == null) {
    throw StateError("this device holds no list or certificate of its user's");
  }
  final int version;
  try {
    version = await engine.api.putDeviceList(
      duvet.DeviceListUpload(deviceList: list, baseVersion: served.deviceListVersion, certificate: certificate),
    );
  } on duvet.DuvetDeviceListChangedException {
    return (lost: true, leavingOut: const <String>[]);
  }
  await listUploaded(engine, version);
  await observeOwn(engine, await servedIdentity(engine) ?? served);
  return (lost: false, leavingOut: const <String>[]);
}
