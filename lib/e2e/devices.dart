/// Devices in Settings (PLAN-E2E-CLIENTES.md, Task 25; decisions 13 and 52): the user's devices, those not seen in 45
/// days, another one taken off the list (sign_device_list, its upload and its confirmation), one lost taken off with
/// new keys (rotate_keys, its upload with its transfers, its confirmation and the new recovery key), and this one's
/// registration given up as its data goes. The desktop's devices.ts in Dart; the engine keeps the state and the turn.
library;

import 'package:clock/clock.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
import 'cbor.dart';
import 'engine.dart';
import 'host.dart' show CoreError;
import 'identity.dart';
import 'store.dart';

/// How long a device goes unseen before Settings marks it, and the app warns of it once (decisions 13 and 52).
const inactiveAfter = Duration(days: 45);

/// Whether [device] wasn't seen in over 45 days: never this one, which is seen as it asks.
bool inactiveDevice(duvet.Device device, [DateTime? now]) =>
    !device.current && (now ?? clock.now()).difference(device.lastSeenAt) > inactiveAfter;

/// Whether this device is its user's only one on the list: set up itself, and no other listed. Deleting its data then
/// loses the encrypted history, unless the person has their recovery key.
bool onlyDevice(List<duvet.Device> devices) =>
    devices.any((d) => d.current && d.listed) && !devices.any((d) => !d.current && d.listed);

/// What the engine tells of the user's other devices: one added (DEVICE_ADD), one not seen in 45 days.
enum DeviceNoticeKind { added, inactive }

typedef DeviceNotice = ({DeviceNoticeKind kind, duvet.UserDevice device});

/// The own user's identity as the API serves it, observed: the core then holds the list the API serves, or its own
/// newer one the API didn't take (the core's rule before a list is signed, N3).
Future<duvet.Identity> _observedOwn(E2EEngine engine) async {
  final served = await servedIdentity(engine) ?? (throw StateError('the user has no identity'));
  await observeOwn(engine, served);
  return served;
}

/// The devices [list] names whose registration the API took away (a new password's remove_devices, step 3's ruling
/// 23): no list or rotation may name them again. A device it still registers stays though it has no certificate yet
/// (one this device approved, whose own list hasn't gone up: task 24's review, M2).
Future<List<String>> takenAway(E2EEngine engine, String list) async {
  final registered = {for (final device in await engine.api.devices()) device.id};
  return [
    for (final id in listDevices(list) ?? const <String>[])
      if (!registered.contains(id)) id,
  ];
}

/// What a removal or a change of keys takes off the list beside the device asked for, never this device: those an
/// earlier removal of this device's took off that the API didn't take ([unsentRemovals]), and those the list names
/// that `GET …/devices` doesn't return ([takenAway]), which a new password's removal and a server's short listing
/// look alike in. Its confirmation names each, and a list goes without one only once it was named (I2 of step 4's
/// closing review).
typedef DevicesAlong = ({List<String> unsent, List<String> unregistered});

/// What a removal of [asked] (none: a change of keys) takes along ([DevicesAlong]).
Future<DevicesAlong> devicesAlong(E2EEngine engine, String? asked) async {
  final status = await coreStatus(engine.host);
  final held = status.deviceList ?? (await servedIdentity(engine))?.deviceList;
  bool along(String id) => id != asked && id != status.deviceId;
  return (
    unsent: (await unsentRemovals(engine)).where(along).toList(),
    unregistered: held == null ? const <String>[] : (await takenAway(engine, held)).where(along).toList(),
  );
}

/// A list that would leave out a device the person wasn't told of ([named]), beside those they asked to take off:
/// nothing is signed, and the person is asked again.
void _onlyNamed(Iterable<String> off, Iterable<String> asked, List<String> named) {
  if (off.any((id) => !asked.contains(id) && !named.contains(id))) {
    throw CoreError('devices_changed', message: 'the list would leave out a device the person was not told of');
  }
}

/// [deviceId] off the user's devices. One never set up goes by its registration (DELETE, which ends its sessions); a
/// listed one by a list without it ([unlist]), and the devices its confirmation [named]. Done at once when the API has
/// it no more.
Future<void> removeDevice(E2EEngine engine, String deviceId, {List<String> named = const []}) async {
  final device = (await engine.api.devices()).where((d) => d.id == deviceId).firstOrNull;
  if (device == null) return;
  if (!device.listed) {
    try {
      return await engine.api.deleteDevice(deviceId);
    } on duvet.DuvetApiException catch (error) {
      if (error.statusCode == 404) return;
      // Listed meanwhile: a list takes it off.
      if (error.statusCode != 409) rethrow;
    }
  }
  await unlist(engine, deviceId, named: named);
}

/// A list without [deviceId], and without the devices the API took away: signed on the list this device holds once
/// the API's is observed, and uploaded on the version the API serves. Only the API's 200 confirms it (Review Focus 11),
/// and the own user is observed after; a list that lost its race (409) is observed and signed again, three rounds at
/// most, and any other failure is observed, then thrown (the core's N3). Done once neither the API's list nor the one
/// this device holds names it: on this device's alone, it's a device this one approved that never took its transfer,
/// which a list without it lets this device approve again (task 26's I1, the core's way out). A list of this device's
/// that the API never took (its upload refused) stays the core's own, newer than the API's (`older_list`), and goes up
/// again as it is when it leaves the device out: the core signs no list without a device its own doesn't name. [alone]
/// signs off that device and no other: an approval's way out, which takes nothing off on the API's word (mobile#352).
/// Otherwise the devices the API took away, and those the list it's signed on left out, go only when the person's
/// confirmation [named] them.
Future<void> unlist(E2EEngine engine, String deviceId, {bool alone = false, List<String> named = const []}) async {
  for (var round = 1; ; round++) {
    final served = await _observedOwn(engine);
    final held = (await coreStatus(engine.host)).deviceList ?? served.deviceList;
    final onHeld = (listDevices(held) ?? const <String>[]).contains(deviceId);
    // Off both: a list that went up before its answer was lost, or another device's.
    if (!onHeld && !(listDevices(served.deviceList) ?? const <String>[]).contains(deviceId)) return;
    final remove = {if (onHeld) deviceId, if (!alone) ...await takenAway(engine, held)};
    // And what the list it's signed on already leaves out, an earlier removal's that the API didn't take (N-M8 of step
    // 4's closing re-review), as the question named both.
    if (!alone) _onlyNamed({...remove, ...await unsentRemovals(engine)}, [deviceId], named);
    final list = remove.isEmpty
        ? held
        : (await engine.host.handle<Map<String, Object?>>({
                'cmd': 'sign_device_list',
                'remove': remove.toList(),
              }))['device_list']!
              as String;
    final int version;
    try {
      version = await engine.api.putDeviceList(
        duvet.DeviceListUpload(deviceList: list, baseVersion: served.deviceListVersion),
      );
    } catch (error) {
      if (error is duvet.DuvetDeviceListChangedException && round < 3) continue;
      // Taken or not, the own user is observed before another list is signed, a third lost race's too (review 25's
      // M4): what it can't reach, the next one does.
      await _observedOwn(engine).then<void>((_) {}, onError: (Object own) => debugPrint('e2e: the own user: $own'));
      rethrow;
    }
    await listUploaded(engine, version);
    await _observedOwn(engine);
    return;
  }
}

/// The devices a list of this device's took off that the API didn't take (its upload refused, or lost unanswered and
/// not taken): the core keeps that list (`older_list`), and the next list or key change, signed on top of it, takes
/// them off too (review 24's M3). The served list minus the held one, while the held is this device's newer one.
Future<List<String>> unsentRemovals(E2EEngine engine) async {
  final served = await servedIdentity(engine);
  final status = await coreStatus(engine.host);
  final held = status.deviceList == null ? null : deviceListOf(status.deviceList!);
  final theirs = served == null ? null : deviceListOf(served.deviceList);
  if (held == null || theirs == null || status.identityKey != served?.identityKey) return const [];
  if (held.version <= theirs.version) return const [];
  return [
    for (final id in theirs.devices)
      if (!held.devices.contains(id)) id,
  ];
}

/// What rotate_keys made: what goes up, with a transfer for each device that stays, over the identity it replaces;
/// and the new recovery key the person saves first.
class Rotation {
  Rotation._(Map<String, Object?> made, this.replaces)
    : identityKey = made['identity_key']! as String,
      recoveryKey = made['recovery_key']! as String,
      _made = made;

  final String identityKey;
  final String recoveryKey;

  /// The identity key it replaces: the one the API served as it was made.
  final String replaces;
  final Map<String, Object?> _made;

  duvet.IdentityUpload get upload => duvet.IdentityUpload(
    identityKey: identityKey,
    deviceList: _made['device_list']! as String,
    certificate: _made['certificate']! as String,
    encryptedIdentity: _made['encrypted_identity']! as String,
    wrappedBackupKey: _made['wrapped_backup_key']! as String,
    wrappedPreviousBackupKeys: _made['wrapped_previous_backup_keys'] as String?,
    replaces: replaces,
    transfers: [
      for (final transfer in (_made['transfers']! as List).cast<Map<Object?, Object?>>())
        duvet.IdentityTransfer(
          deviceId: transfer['device_id']! as String,
          certificate: transfer['certificate']! as String,
          message: transfer['transfer']! as String,
        ),
    ],
  );
}

/// rotate_keys (a lost device, decision 13): new keys, sealed to every device that stays, [remove] taken off with the
/// devices the API took away. Run again before its upload it's the same rotation, which the core takes only with the
/// same remove: the record keeps it, and without the record the core says it (`status`'s waiting_remove, its client
/// rule: never read back from the lists, which name too much once the rotation was signed on a list of this device's
/// that never went up, e2e#49). The served certificates go as each device uploaded them. Run again with [gone], the
/// devices it keeps that the API's list no longer names ([goneDevices]), on the person's yes, it signs its list again
/// without them, the served list its proof (e2e#49). A new one takes the devices the API took away, and those the list
/// it's signed on left out, only when the person's confirmation [named] them.
Future<Rotation> rotateKeys(
  E2EEngine engine,
  List<String> remove, {
  List<String> gone = const [],
  List<String> named = const [],
}) async {
  final status = await coreStatus(engine.host);
  final again = status.waitingUpload == 'rotate_keys';
  // Before its upload the core holds the new identity: the API's, the one it replaces, isn't observed then.
  final served = again
      ? await servedIdentity(engine) ?? (throw StateError('the user has no identity'))
      : await _observedOwn(engine);
  final List<String> off;
  if (again) {
    off = switch (engine.store.read(rotationRemove)) {
      final List<Object?> ids => ids.whereType<String>().toList(),
      _ => [...?status.waitingRemove],
    };
  } else {
    final held = (await coreStatus(engine.host)).deviceList ?? served.deviceList;
    // The core takes off only devices its own list names.
    final listed = listDevices(held) ?? const <String>[];
    off = {...remove.where(listed.contains), ...await takenAway(engine, held)}.toList()..sort();
    // And what the list it's signed on already leaves out (N-M8 of step 4's closing re-review).
    _onlyNamed({...off, ...await unsentRemovals(engine)}, remove, named);
    // Kept before the command, so a rotation cut right after it runs again with it.
    await engine.store
        .write(rotationRemove, off)
        .catchError((Object error) => debugPrint("e2e: the rotation's devices: ${error.runtimeType}"));
  }
  final made = await engine.host.handle<Map<String, Object?>>({
    'cmd': 'rotate_keys',
    'remove': off..sort(),
    'certificates': served.certificates,
    if (again && gone.isNotEmpty) ...{'gone': gone, 'served_list': served.deviceList},
  });
  return Rotation._(made, served.identityKey);
}

/// The devices a change of keys that waits keeps and the API's list no longer names, never this one: another device
/// took them off with a list of the identity this change replaces, which the API took and whose certificates it no
/// longer serves, so the change can't run again with them (its `bad_command` `certificates`). Its run again leaves
/// them out with `gone`, on the person's yes (e2e#49). None when nothing waits.
Future<List<String>> goneDevices(E2EEngine engine) async {
  final status = await coreStatus(engine.host);
  final served = await servedIdentity(engine);
  if (status.waitingUpload != 'rotate_keys' || served == null) return const [];
  final listed = listDevices(served.deviceList) ?? const <String>[];
  return [
    for (final id in listDevices(status.deviceList ?? '') ?? const <String>[])
      if (id != status.deviceId && !listed.contains(id)) id,
  ];
}

/// The rotation goes up with its transfers, confirmed only after the API's 200 ([confirmIdentity]). A refusal or a lost
/// answer throws, the key still shown, and the same rotation goes next time.
Future<void> publishRotation(E2EEngine engine, Rotation rotation) async =>
    confirmIdentity(engine, (await engine.api.putIdentity(rotation.upload)).deviceListVersion);

/// This device's registration, given up as its data goes: one never set up is deleted, which ends its sessions; a
/// listed one stays, as the API takes no list without the session's device, for the user's other devices to take off.
/// Best effort: the person asked for the data to go, which a failure here doesn't hold up.
Future<void> giveUpRegistration(E2EEngine engine, String deviceId) async {
  try {
    final device = (await engine.api.devices()).where((d) => d.id == deviceId).firstOrNull;
    if (device != null && !device.listed) await engine.api.deleteDevice(deviceId);
  } catch (error) {
    debugPrint("e2e: this device's registration stays: $error");
  }
}

/// The devices the record says the app told of under [key].
Set<String> _told(EngineStore store, String key) => switch (store.read(key)) {
  final List<Object?> ids => ids.whereType<String>().toSet(),
  _ => <String>{},
};

Future<void> _keepTold(EngineStore store, String key, List<String> ids) =>
    store.write(key, ids).catchError((Object error) => debugPrint('e2e: the devices told of: ${error.runtimeType}'));

/// The user's devices not seen in 45 days that the app hasn't told of, now kept as told with those before, of the
/// devices the API still has (a removed device's ID never comes back), so the record doesn't grow.
Future<List<duvet.Device>> inactiveToTell(E2EEngine engine) async {
  final devices = await engine.api.devices();
  final told = _told(engine.store, toldInactive);
  final due = [
    for (final device in devices)
      if (inactiveDevice(device) && !told.contains(device.id)) device,
  ];
  if (due.isNotEmpty) {
    await _keepTold(engine.store, toldInactive, [
      for (final device in devices)
        if (told.contains(device.id) || due.contains(device)) device.id,
    ]);
  }
  return due;
}

/// Whether to tell of a device added to the user's account: once each, as its registration and then its listing
/// come, the record keeping the newest 50 told.
Future<bool> addedToTell(EngineStore store, duvet.UserDevice device) async {
  final told = _told(store, toldAdded);
  if (told.contains(device.id)) return false;
  final kept = [...told, device.id];
  await _keepTold(store, toldAdded, kept.sublist(kept.length > 50 ? kept.length - 50 : 0));
  return true;
}
