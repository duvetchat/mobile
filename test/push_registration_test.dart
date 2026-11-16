import 'dart:async';
import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/push/registration.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// A registrar over nothing: the permission as a test sets it, and the FIDs it hands out. [registerFailures] of the
/// next registrations fail, and an unregistering waits for [unregisterHeld]; [log] has both, in order.
class _Registrar implements PushRegistrar {
  bool granted;
  int asked = 0;
  int registers = 0;
  int unregisters = 0;
  int registerFailures = 0;
  Completer<void>? unregisterHeld;
  final log = <String>[];
  final _fids = StreamController<String>.broadcast(sync: true);
  _Registrar({this.granted = true});

  @override
  Future<bool> allowed() async {
    asked++;
    return granted;
  }

  @override
  Future<void> register() async {
    registers++;
    log.add('register');
    if (registerFailures > 0) {
      registerFailures--;
      throw Exception('FCM is unreachable');
    }
  }

  @override
  Stream<String> get registered => _fids.stream;

  @override
  Future<void> unregister() async {
    unregisters++;
    log.add('unregister');
    await unregisterHeld?.future;
    log.add('unregistered');
  }

  /// FCM giving the app a FID.
  void hand(String fid) => _fids.add(fid);
}

void main() {
  late FakeRepository repository;
  late _Registrar registrar;

  setUp(() async {
    repository = FakeRepository();
    await repository.restore();
    // Signed in, its gateway still connecting: the fake's restore says it's up at once.
    repository.status.value = LiveStatus.connecting;
  });

  // The session's first READY.
  Future<void> ready() async {
    repository.status.value = LiveStatus.online;
    await pumpEventQueue();
  }

  PushRegistration start({bool granted = true}) {
    registrar = _Registrar(granted: granted);
    final registration = PushRegistration(repository, registrar);
    addTearDown(registration.dispose);
    return registration;
  }

  test('granted: once the session is up, registers and sends the FID', () async {
    start();
    await pumpEventQueue();
    expect(registrar.asked, 0, reason: 'nothing before READY');
    await ready();
    expect((registrar.asked, registrar.registers), (1, 1));
    registrar.hand('fid-1');
    await pumpEventQueue();
    expect(repository.pushRegistrations, ['fid-1']);
  });

  test('a new FID is sent again', () async {
    start();
    await ready();
    registrar.hand('fid-1');
    registrar.hand('fid-2');
    await pumpEventQueue();
    expect(repository.pushRegistrations, ['fid-1', 'fid-2']);
  });

  test('denied: unregisters, deletes the registration and sends nothing', () async {
    start(granted: false);
    await ready();
    expect((registrar.registers, registrar.unregisters, repository.pushDeletes), (0, 1, 1));
    expect(repository.pushRegistrations, isEmpty);
  });

  test('asks once a session, not again as the gateway reconnects', () async {
    start();
    await ready();
    repository.status.value = LiveStatus.reconnecting;
    await ready();
    expect((registrar.asked, registrar.registers), (1, 1));
  });

  test('sign-out unregisters, sends nothing more, and the next session registers again', () async {
    start();
    await ready();
    registrar.hand('fid-1');
    await repository.endSession();
    repository.status.value = LiveStatus.offline;
    expect(registrar.unregisters, 1);
    registrar.hand('fid-2');
    await pumpEventQueue();
    expect(repository.pushRegistrations, ['fid-1'], reason: 'no session to send it to');

    await repository.restore();
    await ready();
    expect((registrar.asked, registrar.registers), (2, 2));
  });

  // A session found ended at launch signs out before the registration is made (main).
  test('made after a sign-out it was told of, it unregisters, and the next session registers after it', () async {
    await repository.endSession();
    repository.status.value = LiveStatus.offline;
    registrar = _Registrar()..unregisterHeld = Completer();
    final registration = PushRegistration(repository, registrar, signedOut: true);
    addTearDown(registration.dispose);
    expect(registrar.unregisters, 1);

    await repository.restore();
    await ready();
    expect(registrar.registers, 0, reason: 'unregistering after it would leave the phone with no FID');
    registrar.unregisterHeld!.complete();
    await pumpEventQueue();
    expect(registrar.log, ['unregister', 'unregistered', 'register']);
  });

  test('a registration that fails goes again at the next READY', () async {
    start();
    registrar.registerFailures = 1;
    await ready();
    repository.status.value = LiveStatus.reconnecting;
    await ready();
    expect(registrar.registers, 2);
  });

  test("a FID the API didn't take goes again once the next READY registers", () async {
    start();
    repository.pushRegistrationFailures = 1;
    await ready();
    registrar.hand('fid-1');
    await pumpEventQueue();
    expect(repository.pushRegistrations, isEmpty);

    repository.status.value = LiveStatus.reconnecting;
    await ready();
    expect(registrar.registers, 2);
    registrar.hand('fid-1');
    await pumpEventQueue();
    expect(repository.pushRegistrations, ['fid-1']);
  });

  // Done after it, the sign-out's unregistering would leave the phone with no FID.
  test('signed in again right after signing out, it registers once the unregistering is done', () async {
    start();
    await ready();
    registrar.unregisterHeld = Completer();
    await repository.endSession();
    repository.status.value = LiveStatus.offline;
    await repository.restore();
    await ready();
    expect(registrar.registers, 1);

    registrar.unregisterHeld!.complete();
    await pumpEventQueue();
    expect(registrar.log, ['register', 'unregister', 'unregistered', 'register']);
  });

  group('allowedOnce', () {
    late Directory dir;
    late File asked;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('push-asked');
      asked = File('${dir.path}/push/asked');
    });
    tearDown(() => dir.delete(recursive: true));

    test('asks once ever: a refusal stands, until the system allows them', () async {
      var asks = 0;
      Future<bool> refuse() async {
        asks++;
        return false;
      }

      expect(await allowedOnce(granted: () async => false, ask: refuse, asked: asked), isFalse);
      expect(await allowedOnce(granted: () async => false, ask: refuse, asked: asked), isFalse);
      expect(asks, 1);
      expect(await allowedOnce(granted: () async => true, ask: refuse, asked: asked), isTrue);
    });

    // As permission_handler refuses a request while another runs (voice asks for the same permission).
    test("a request that fails isn't an answer: the next one asks", () async {
      var asks = 0;
      await expectLater(
        allowedOnce(
          granted: () async => false,
          ask: () async {
            asks++;
            throw PlatformException(code: 'PermissionHandler.PermissionManager');
          },
          asked: asked,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(
        await allowedOnce(
          granted: () async => false,
          ask: () async {
            asks++;
            return true;
          },
          asked: asked,
        ),
        isTrue,
      );
      expect(asks, 2);
    });
  });
}
