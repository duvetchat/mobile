/// The user's identity (PLAN-E2E-CLIENTES.md, «El motor»: «Arranque» step 5, and «Qué se manda», its identity's row):
/// a first device publishes the one it made, once the person saved its recovery key (decision 23), and confirms it
/// only after the API took it; every device holds itself to the one the API serves.
library;

import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
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

/// observe_user of each user, as the API serves their identities, 50 at a time: one it doesn't serve stays as it was.
Future<void> observeUsers(E2EEngine engine, List<String> users) => observeOn(engine.host, engine.api, users);

/// [observeUsers] on a core and a session of their own: a push's engine's, which runs no engine.
Future<void> observeOn(CoreHost host, duvet.E2eApi api, List<String> users) async {
  for (var at = 0; at < users.length; at += 50) {
    for (final identity in await api.identities(users.sublist(at, min(at + 50, users.length)))) {
      await host.handle<Object?>({
        'cmd': 'observe_user',
        'user_id': identity.userId,
        'identity_key': identity.identityKey,
        'device_list': identity.deviceList,
        'certificates': identity.certificates,
      });
    }
  }
}

/// A command that may first ask for users' identities (`needs_identities`): they're observed, and it runs again.
/// Three rounds at most: the core asks once for what it knows of each user, and goes on with that the next time.
Future<T> withIdentities<T>(E2EEngine engine, Future<T> Function() run) =>
    withIdentitiesOn(engine.host, engine.api, run);

/// [withIdentities] on a core and a session of their own: a push's engine's.
Future<T> withIdentitiesOn<T>(CoreHost host, duvet.E2eApi api, Future<T> Function() run) async {
  for (var round = 1; ; round++) {
    try {
      return await run();
    } on CoreError catch (error) {
      final asked = error.code == 'needs_identities' ? error.users : null;
      if (asked == null || asked.isEmpty || round >= 3) rethrow;
      await observeOn(host, api, asked);
    }
  }
}

/// observe_user of the user's own identity, as served: what the core made of it (`not_own_identity`, an identity this
/// device doesn't hold).
Future<String?> observeOwn(E2EEngine engine, duvet.Identity served) async {
  final seen = await engine.host.handle<Map<String, Object?>>({
    'cmd': 'observe_user',
    'user_id': engine.user,
    'identity_key': served.identityKey,
    'device_list': served.deviceList,
    'certificates': served.certificates,
  });
  return seen['reason'] as String?;
}

/// What the user's identity, as served, makes of this device (step 5): none yet, a first device; one this device
/// doesn't hold, a new device; its own, ready. Served one this device doesn't hold while it holds another, a
/// rotation's transfer for it may wait in the inbox ([takeInbox]): without one, the user's devices went on without
/// this one, which is off the list (removed; a rotation off it removes it, and starting over leaves it unlisted).
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
  if (await observeOwn(engine, served) != 'not_own_identity') return EngineState.ready;
  await takeInbox();
  served = await servedIdentity(engine) ?? served;
  return await observeOwn(engine, served) == 'not_own_identity' ? EngineState.removed : EngineState.ready;
}

/// The first device's identity goes up (PUT …/identity) with the list naming this device alone. Only after the API's
/// 200 is it confirmed: identity_uploaded, device_list_uploaded with the version the API answered, then the own user
/// observed (the core's rules after an upload, N2 and N3). False on a 409: another first device published first.
Future<bool> publishIdentity(E2EEngine engine, IdentityMade made) async {
  final int version;
  try {
    final published = await engine.api.putIdentity(
      duvet.IdentityUpload(
        identityKey: made.identityKey,
        deviceList: made.deviceList,
        certificate: made.certificate,
        encryptedIdentity: made.encryptedIdentity,
        wrappedBackupKey: made.wrappedBackupKey,
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
