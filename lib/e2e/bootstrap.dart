/// «Arranque» (PLAN-E2E-CLIENTES.md, «El motor»), its steps 2 and 3: this installation's device in the user's
/// database, made the first time, and the session bound to it with a proof over the session's challenge (decision 13).
library;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'conventions.dart' show maxDeviceName;
import 'engine.dart';
import 'host.dart';
import 'store.dart';
import 'uuid.dart';

/// What `status` answers (the core's contract): this device, the identity it holds, and what waits for its upload.
class CoreStatus {
  CoreStatus.of(Map<String, Object?> status)
    : deviceId = status['device_id'] as String?,
      identityKey = status['identity_key'] as String?,
      certificate = status['certificate'] as String?,
      deviceList = status['device_list'] as String?,
      waitingUpload = status['waiting_upload'] as String?,
      waitingRemove = switch (status['waiting_remove']) {
        final List<Object?> ids => ids.whereType<String>().toList(),
        _ => null,
      },
      hasIdentity = status['has_identity'] == true;

  final String? deviceId;
  final String? identityKey;

  /// This device's certificate, as the last identity command (or an approval's transfer) answered it.
  final String? certificate;

  /// The user's list as this device holds it: the last an identity command or a list answered, or observing gave.
  final String? deviceList;

  /// The identity command whose upload the core waits for: `create_identity` or `rotate_keys`.
  final String? waitingUpload;

  /// What a change of keys that waits takes off the list, in its order (duvetchat/e2e#49): what it runs again with.
  final List<String>? waitingRemove;
  final bool hasIdentity;
}

Future<CoreStatus> coreStatus(CoreHost host) async =>
    CoreStatus.of(await host.handle<Map<String, Object?>>({'cmd': 'status'}));

/// A device's public keys, as create_device gives them: kept with its ID, as a sign-in registers them again.
typedef DeviceKeys = ({String signatureKey, String hpkeKey});

/// The keys the record kept for this device: never another device's, which would sign a proof they don't match.
DeviceKeys? _keysOf(Object? kept, String deviceId) => switch (kept) {
  {'device_id': final String id, 'signature_key': final String signatureKey, 'hpke_key': final String hpkeKey}
      when id == deviceId =>
    (signatureKey: signatureKey, hpkeKey: hpkeKey),
  _ => null,
};

/// The user's database's device, made the first time with an ID of the client's (a UUIDv7), and its keys: kept in
/// the record with its ID, or just made (a record that refused them still registers the new device). Keys that don't
/// read leave the record none, as the desktop's does: an older record's are another device's.
Future<({CoreStatus status, DeviceKeys? keys})> ownDevice(E2EEngine engine) async {
  final status = await coreStatus(engine.host);
  if (status.deviceId case final id?) return (status: status, keys: _keysOf(engine.store.read(deviceKeys), id));
  final id = uuidv7();
  final made = await engine.host.handle<Map<String, Object?>>({
    'cmd': 'create_device',
    'user_id': engine.user,
    'device_id': id,
  });
  final keys = _keysOf({...made, 'device_id': id}, id);
  await engine.store
      .write(
        deviceKeys,
        keys == null ? null : {'device_id': id, 'signature_key': keys.signatureKey, 'hpke_key': keys.hpkeKey},
      )
      .catchError((Object error) => debugPrint("e2e: the device's keys: $error"));
  return (status: await coreStatus(engine.host), keys: keys);
}

/// Binds the session to the device: at once when the API says it is (`current`), else over a challenge (the login's,
/// once, then a new one each time), by registering its keys again, which binds a device the API has (200) and
/// registers one it hasn't (201). Without its keys, or with its ID refused (409: a device of the user's deleted, the
/// same ID with other keys, or another user's), by the bind route, whose 404 alone says the API took the device away:
/// false. Any other refusal is thrown.
Future<bool> bindSession(E2EEngine engine, String deviceId, DeviceKeys? keys) async {
  final api = engine.api;
  if ((await api.devices()).any((device) => device.current && device.id == deviceId)) return true;
  final challenge = engine.takeChallenge() ?? await api.deviceChallenge();
  final proof =
      (await engine.host.handle<Map<String, Object?>>({'cmd': 'bind_proof', 'challenge': challenge}))['proof']!
          as String;
  try {
    if (keys != null) {
      try {
        await api.registerDevice(
          duvet.DeviceRegistration(
            deviceId: deviceId,
            name: engine.deviceName,
            signatureKey: keys.signatureKey,
            hpkeKey: keys.hpkeKey,
            proof: proof,
          ),
        );
        return true;
      } on duvet.DuvetApiException catch (error) {
        // A refused registration spends no challenge: the same proof binds.
        if (error.statusCode != 409) rethrow;
      }
    }
    await api.bindDevice(deviceId, proof);
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 404) return false;
    rethrow;
  }
  return true;
}

/// The channel MainActivity.kt answers the phone's model on.
const deviceChannel = MethodChannel('chat.duvet/device');

/// What a phone whose model can't be read is called.
const unknownPhone = 'Duvet for Android';

/// The name this installation registers its device with, which the user's other devices show (PLAN-E2E-CLIENTES.md,
/// its conventions; Ruling 27): the phone's model, as Android has it (Build.MODEL), cut to the API's 64 characters.
Future<String> phoneName([MethodChannel channel = deviceChannel]) async {
  String? model;
  try {
    model = (await channel.invokeMethod<String>('model'))?.trim();
  } catch (error) {
    debugPrint("e2e: the phone's model: ${error.runtimeType}");
  }
  if (model == null || model.isEmpty) return unknownPhone;
  return String.fromCharCodes(model.runes.take(maxDeviceName)).trim();
}
