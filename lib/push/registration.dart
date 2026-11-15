/// The phone's registration for the signed-in user's pushes.
library;

import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/models.dart';
import '../data/repository.dart';

/// Where the phone's registration comes from: the notifications permission, and FCM's installation ID (FID).
abstract interface class PushRegistrar {
  /// Whether notifications are allowed, asking the user if they were never asked.
  Future<bool> allowed();

  /// Registers the app with FCM: [registered] then gives its FID.
  Future<void> register();

  /// Each FID FCM gives the app: as it registers, and whenever it changes.
  Stream<String> get registered;

  /// Unregisters the app from FCM: its FID gets nothing any more.
  Future<void> unregister();
}

/// FCM's registration (firebase_messaging's `register()`, `onRegistered` and `unregister()`), and the notifications
/// permission through permission_handler, which asks for every permission the app takes. Android 13 and later ask the
/// user, once; older ones allow it.
class FirebasePushRegistrar implements PushRegistrar {
  const FirebasePushRegistrar();

  @override
  Future<bool> allowed() async => allowedOnce(
    granted: () => Permission.notification.isGranted,
    ask: () async => (await Permission.notification.request()).isGranted,
    asked: File('${(await getApplicationSupportDirectory()).path}/push/asked'),
  );

  @override
  Future<void> register() => FirebaseMessaging.instance.register();

  @override
  Stream<String> get registered => FirebaseMessaging.instance.onRegistered;

  @override
  Future<void> unregister() => FirebaseMessaging.instance.unregister();
}

/// Whether notifications are allowed: [granted] already, or the user's answer to [ask], asked once ever ([asked] marks
/// it once answered): a refusal stands until the user turns them on in the system's settings. A request that fails
/// isn't an answer, as when another one runs (voice asks for the same permission): the next one asks.
Future<bool> allowedOnce({
  required Future<bool> Function() granted,
  required Future<bool> Function() ask,
  required File asked,
}) async {
  if (await granted()) return true;
  if (await asked.exists()) return false;
  final answer = await ask();
  await asked.create(recursive: true);
  return answer;
}

/// Keeps the phone registered for the signed-in user's pushes. Once a session is up (its first READY) it asks for the
/// notifications permission ([PushRegistrar.allowed]): allowed, it registers with FCM and hands the API each FID;
/// refused, it tells FCM and the API to forget the phone. Signing out unregisters from FCM, as the API deleted the
/// session's registration with it.
class PushRegistration {
  final ChatRepository repository;
  final PushRegistrar registrar;
  StreamSubscription<String>? _fids;
  late final StreamSubscription<void> _signedOut;

  // Whose session registered: once a session, not again as the gateway reconnects. A registration that fails forgets
  // it, so the next READY tries again.
  String? _session;

  // A sign-out's unregistering, which a registration waits for: done after it, it would leave the phone with no FID.
  Future<void>? _unregistering;

  PushRegistration(this.repository, this.registrar) {
    try {
      _fids = registrar.registered.listen(_sendFid, onError: (Object e) => debugPrint('push: FIDs: $e'));
    } catch (e) {
      // FCM isn't set up: nothing to register with.
      debugPrint('push: FIDs: $e');
    }
    _signedOut = repository.signedOut.listen((_) => _signOut());
    repository.status.addListener(_follow);
    _follow();
  }

  void _follow() {
    final me = repository.profile.value?.id;
    if (repository.status.value != LiveStatus.online || me == null || me == _session) return;
    _session = me;
    unawaited(_register());
  }

  Future<void> _register() async {
    try {
      await _unregistering;
      if (await registrar.allowed()) {
        await registrar.register();
      } else {
        await registrar.unregister();
        await repository.deletePushRegistration();
      }
    } catch (e) {
      debugPrint('push: registering: $e');
      _session = null;
    }
  }

  Future<void> _sendFid(String fid) async {
    // Signed out: the next session's registration sends it.
    if (_session == null) return;
    try {
      await repository.setPushRegistration(fid);
    } catch (e) {
      debugPrint('push: the FID: $e');
      // The next READY registers again, which hands it again.
      _session = null;
    }
  }

  void _signOut() {
    _session = null;
    _unregistering = registrar.unregister().catchError((Object e) => debugPrint('push: unregistering: $e'));
  }

  void dispose() {
    repository.status.removeListener(_follow);
    unawaited(_fids?.cancel());
    unawaited(_signedOut.cancel());
  }
}
