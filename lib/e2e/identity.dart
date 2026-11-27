/// The user's identity (PLAN-E2E-CLIENTES.md, «El motor»: «Arranque» step 5, and «Qué se manda», its identity's row):
/// a first device publishes the one it made, once the person saved its recovery key (decision 23), and confirms it
/// only after the API took it; every device holds itself to the one the API serves.
library;

import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
import 'cbor.dart';
import 'engine.dart';
import 'host.dart';
import 'store.dart';

/// What create_identity answers: what goes up, and the recovery key the person saves first.
class IdentityMade {
  IdentityMade.of(Map<String, Object?> made)
    : identityKey = made['identity_key']! as String,
      certificate = made['certificate']! as String,
      deviceList = made['device_list']! as String,
      recoveryKey = made['recovery_key']! as String,
      wrappedBackupKey = made['wrapped_backup_key']! as String,
      encryptedIdentity = made['encrypted_identity']! as String;

  final String identityKey;
  final String certificate;
  final String deviceList;
  final String recoveryKey;
  final String wrappedBackupKey;
  final String encryptedIdentity;
}

/// The user's identity as the API serves it today, or null without one (404).
Future<duvet.Identity?> servedIdentity(E2EEngine engine) async {
  try {
    return await engine.api.identity(engine.user);
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 404) return null;
    rethrow;
  }
}

/// What an observation made of an identity the API served: the core's answer ([observeOn]'s `seen`).
typedef Observed = Future<void> Function(duvet.Identity identity, Map<String, Object?> answer);

/// observe_user of each user, as the API serves their identities, 50 at a time: one it doesn't serve stays as it was.
Future<void> observeUsers(E2EEngine engine, List<String> users) =>
    observeOn(engine.host, engine.api, users, seen: _ownSeen(engine));

/// [observeUsers] on a core and a session of their own: a push's engine's, which runs no engine. [seen] is told what
/// the core answered of each.
Future<void> observeOn(CoreHost host, duvet.E2eApi api, List<String> users, {Observed? seen}) async {
  for (var at = 0; at < users.length; at += 50) {
    for (final identity in await api.identities(users.sublist(at, min(at + 50, users.length)))) {
      final answer = await host.handle<Map<String, Object?>>({
        'cmd': 'observe_user',
        'user_id': identity.userId,
        'identity_key': identity.identityKey,
        'device_list': identity.deviceList,
        'certificates': identity.certificates,
      });
      await seen?.call(identity, answer);
    }
  }
}

/// A command that may first ask for users' identities (`needs_identities`): they're observed, and it runs again.
/// Three rounds at most: the core asks once for what it knows of each user, and goes on with that the next time.
Future<T> withIdentities<T>(E2EEngine engine, Future<T> Function() run) =>
    withIdentitiesOn(engine.host, engine.api, run, seen: _ownSeen(engine));

/// [withIdentities] on a core and a session of their own: a push's engine's.
Future<T> withIdentitiesOn<T>(CoreHost host, duvet.E2eApi api, Future<T> Function() run, {Observed? seen}) async {
  for (var round = 1; ; round++) {
    try {
      return await run();
    } on CoreError catch (error) {
      final asked = error.code == 'needs_identities' ? error.users : null;
      if (asked == null || asked.isEmpty || round >= 3) rethrow;
      await observeOn(host, api, asked, seen: seen);
    }
  }
}

/// observe_user of the user's own identity, as served: what the core made of it (`not_own_identity`, an identity this
/// device doesn't hold). A list it took finishes the approvals of this device's it names (mobile#352).
Future<String?> observeOwn(E2EEngine engine, duvet.Identity served) async {
  final seen = await engine.host.handle<Map<String, Object?>>({
    'cmd': 'observe_user',
    'user_id': engine.user,
    'identity_key': served.identityKey,
    'device_list': served.deviceList,
    'certificates': served.certificates,
  });
  await _ownListSeen(engine.store, served.deviceList, seen);
  return seen['reason'] as String?;
}

/// The own user's observations among an engine's: each list the core took finishes the approvals it names.
Observed _ownSeen(E2EEngine engine) => (identity, answer) async {
  if (identity.userId == engine.user) await _ownListSeen(engine.store, identity.deviceList, answer);
};

/// The own user's [deviceList], as the core just answered of it: one it took (not `rejected`) names the devices this
/// one approved that set up since.
Future<void> _ownListSeen(EngineStore store, String deviceList, Map<String, Object?> answer) async {
  if (answer['state'] != 'rejected') await forgetApproved(store, listDevices(deviceList) ?? const []);
}

/// The most approvals the record keeps: the newest.
const _approvedKept = 20;

/// The approvals the record keeps, as it keeps them.
List<Map<String, Object?>> _approvedIn(EngineStore store) => [
  for (final one in switch (store.read(approvedHere)) {
    final List<Object?> list => list,
    _ => const <Object?>[],
  })
    if (one case final Map<Object?, Object?> kept when kept['device'] is String && kept['at'] is int)
      kept.cast<String, Object?>(),
];

/// The devices this one approved that no list the core took has named since: approvals of its own that didn't
/// finish (mobile#352). This device's word alone: neither the list the API serves nor the devices it registers.
Set<String> approvedHereIn(EngineStore store) => {for (final one in _approvedIn(store)) one['device']! as String};

/// This device approved [device] (approval_confirm, approval_from_qr) [at]: kept until a list the core took names it.
Future<void> noteApproved(EngineStore store, String device, DateTime at) {
  final kept = [
    for (final one in _approvedIn(store))
      if (one['device'] != device) one,
    {'device': device, 'at': at.millisecondsSinceEpoch},
  ];
  return store
      .write(approvedHere, kept.sublist(max(0, kept.length - _approvedKept)))
      .catchError((Object error) => debugPrint("e2e: the record's approvals here: ${error.runtimeType}"));
}

/// These devices are no approvals of this device's left to finish: on a list the core took, or signed off.
Future<void> forgetApproved(EngineStore store, Iterable<String> devices) async {
  final kept = _approvedIn(store);
  final left = [
    for (final one in kept)
      if (!devices.contains(one['device'])) one,
  ];
  if (left.length == kept.length) return;
  await store
      .write(approvedHere, left.isEmpty ? null : left)
      .catchError((Object error) => debugPrint("e2e: the record's approvals here: ${error.runtimeType}"));
}

/// Whether this device took the identity the API serves (recovered, or approved: Tasks 26 and 27) and the API's list
/// doesn't name it yet: its first list, with its certificate, is what's left of its setup (recover.dart). A list that
/// doesn't read says nothing of it: the core's observe_user decides. Never once the API listed it ([listedDevice]): a
/// list without it then is older than the one it holds, or a newer one that leaves it out, which the core's observation
/// tells apart, and a first list put up on top of an older one would lose its race (step 5).
bool firstListWaits(duvet.Identity served, CoreStatus status, EngineStore store) =>
    status.hasIdentity &&
    status.deviceId != null &&
    store.read(listedDevice) != status.deviceId &&
    served.identityKey == status.identityKey &&
    listDevices(served.deviceList)?.contains(status.deviceId) == false;

/// What this device is by the list its core holds of its user: removed once that list leaves the device out, else
/// ready. A list that doesn't read says nothing of it, as in [firstListWaits].
EngineState _byHeldList(CoreStatus status) =>
    listDevices(status.deviceList ?? '')?.contains(status.deviceId) == false ? EngineState.removed : EngineState.ready;

/// What the user's identity, as served, makes of this device (step 5): none yet, a first device; one this device
/// doesn't hold, or holds without being on its list yet (its first list still to go up), a new device; its own,
/// ready. Served one this device doesn't hold while it holds another, a rotation's transfer for it may wait in the
/// inbox ([takeInbox]): without one, the user's devices went on without this one, which is off the list (removed; a
/// rotation off it removes it, and starting over leaves it unlisted). Of the identity this device holds, the list its
/// core keeps once it observed the served one decides: a list the server rolls back changes nothing.
Future<EngineState> identityState(E2EEngine engine, Future<Object?> Function() takeInbox) async {
  var served = await servedIdentity(engine);
  if (served == null) return const EngineState.firstDevice();
  final status = await coreStatus(engine.host);
  if (!status.hasIdentity) return EngineState.newDevice;
  // A rotation of this device's own, cut before its upload's answer (Review Focus 3). The API serving the identity it
  // made took it: confirmed now, nothing shown or sent again, as its key was saved before it went. Else the core holds
  // the new identity the API doesn't serve: it goes up again as the same rotation once the person finishes it, never
  // read as this device being off the list.
  if (status.waitingUpload == 'rotate_keys') {
    if (served.identityKey != status.identityKey) return const EngineState.rotation();
    await confirmIdentity(engine, served.deviceList == status.deviceList ? served.deviceListVersion : null);
  }
  if (firstListWaits(served, status, engine.store)) return EngineState.newDevice;
  if (await observeOwn(engine, served) != 'not_own_identity') return _byHeldList(await coreStatus(engine.host));
  await takeInbox();
  served = await servedIdentity(engine) ?? served;
  if (await observeOwn(engine, served) == 'not_own_identity') return EngineState.removed;
  return _byHeldList(await coreStatus(engine.host));
}

/// The first device's identity goes up (PUT …/identity) with the list naming this device alone, or a start over's in
/// the place of the identity it [replaces] (`reset`, decision 47). Only after the API's 200 is it confirmed:
/// identity_uploaded, device_list_uploaded with the version the API answered, then the own user observed (the core's
/// rules after an upload, N2 and N3). False on a 409: another identity is there now (another first device published
/// first, or the one a start over replaces changed).
Future<bool> publishIdentity(E2EEngine engine, IdentityMade made, {String? replaces}) async {
  final int version;
  try {
    final published = await engine.api.putIdentity(
      duvet.IdentityUpload(
        identityKey: made.identityKey,
        deviceList: made.deviceList,
        certificate: made.certificate,
        encryptedIdentity: made.encryptedIdentity,
        wrappedBackupKey: made.wrappedBackupKey,
        replaces: replaces,
        reset: replaces != null,
      ),
    );
    version = published.deviceListVersion;
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 409) return false;
    rethrow;
  }
  await confirmIdentity(engine, version);
  return true;
}

/// device_list_uploaded of the [version] the API took. The core keeping nothing of it (`not_found` `upload`: a newer
/// list or identity took its place) is done, as nothing's left to confirm (review 24's rule 4).
Future<void> listUploaded(E2EEngine engine, int version) async {
  try {
    await engine.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': version});
  } on CoreError catch (error) {
    if (error.code != 'not_found' || error.what != 'upload') rethrow;
  }
}

/// What the API took of an identity command (create_identity, reset_identity, rotate_keys), confirmed only after its
/// 200: identity_uploaded, device_list_uploaded with the [version] the API answered (none when the list it serves is
/// another), then the own user observed (the core's rules after an upload, N2 and N3). A rotation's devices the record
/// kept for its run again go with it.
Future<void> confirmIdentity(E2EEngine engine, int? version) async {
  try {
    await engine.host.handle<Object?>({'cmd': 'identity_uploaded'});
  } on CoreError catch (error) {
    // Nothing kept for an upload: a confirmation cut after it took this one, before the list's (M5 of the desktop's
    // review).
    if (error.code != 'not_found' || error.what != 'upload') rethrow;
  }
  if (version != null) await listUploaded(engine, version);
  await engine.store
      .write(rotationRemove, null)
      .catchError((Object error) => debugPrint("e2e: the rotation's devices: ${error.runtimeType}"));
  if (await servedIdentity(engine) case final served?) await observeOwn(engine, served);
}
