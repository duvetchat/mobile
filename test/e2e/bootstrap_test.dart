import 'dart:convert';

import 'package:duvet/e2e/bootstrap.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';
import '../support/fake_api.dart';

// The engine's start (PLAN-E2E-CLIENTES.md, «El motor», «Arranque»): the API's configuration, the user's database,
// this installation's device and the session bound to it, and what the user's identity makes of the device. The
// desktop's bootstrap.test.ts, case for case, with its review's rulings.
const _minute = Duration(minutes: 1);

/// A host whose open answers [opened], as a build without the core's library does: nothing else is asked of it.
class _ClosedHost implements CoreHost {
  _ClosedHost(this.opened);
  final Opened opened;
  final asked = <String>[];

  @override
  Future<Opened> open(String userId) async => opened;

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    asked.add(command['cmd']! as String);
    throw CoreError('internal', message: 'no core');
  }

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) async =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<Uint8List> sharePart(String shareId, int n) async => throw CoreError('internal', message: 'no core');

  @override
  Future<void> dropShare(String shareId) async {}

  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) async =>
      throw CoreError('internal', message: 'no core');

  @override
  Future<void> close() async {}

  @override
  Future<void> destroy(String userId) async {}
}

/// A core whose create_device answers keys that don't read, the device made all the same.
class _KeysUnread implements CoreHost {
  _KeysUnread(this._core);
  final CoreHost _core;

  @override
  Future<Opened> open(String userId) => _core.open(userId);

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    final answer = await _core.handle<T>(command);
    return command['cmd'] == 'create_device' ? <String, Object?>{} as T : answer;
  }

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      _core.sealFile(key, attachmentId, plain, progress: progress);

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      _core.openFile(key, attachmentId, sealed, progress: progress);

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) => _core.share(command);

  @override
  Future<Uint8List> sharePart(String shareId, int n) => _core.sharePart(shareId, n);

  @override
  Future<void> dropShare(String shareId) => _core.dropShare(shareId);

  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) => _core.importShare(shareId, parts);

  @override
  Future<void> close() => _core.close();

  @override
  Future<void> destroy(String userId) => _core.destroy(userId);
}

String _said(http.Request request) => '${request.method} ${request.url.path}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test('the_same_installation_signs_in_again_and_is_the_same_device', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = await firstDevice(fake, ana);
    await a.engine.stop();

    // A new sign-in: a session the device isn't bound to yet, on the same database and record.
    final again = testDevice(fake, ana, host: a.host, store: a.store);
    await again.engine.start();
    expect(again.state, EngineState.ready);
    // Its keys registered again: the same device, now this session's, and no new one announced.
    expect(again.registered, a.registered);
    expect(
      [for (final d in await again.api.devices()) (d.id, d.name, d.listed, d.current)],
      [(a.registered.single, 'Pixel 8 Pro', true, true)],
    );
    expect(again.heard.where((event) => event.type == 'DEVICE_ADD'), isEmpty);
    // The record keeps the device the identify names before the core opens (Ruling 30).
    expect(again.store.read(keptDevice), a.registered.single);
    await again.engine.stop();
  }, skip: noCore);

  test('a_record_that_keeps_nothing_still_registers_a_new_device', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    // A record that refuses every write: the keys the device was just made with register it all the same.
    final a = testDevice(fake, ana, store: RefusingStore());
    await a.engine.start();
    expect(a.state, const EngineState.firstDevice());
    expect([for (final d in await a.api.devices()) (d.id, d.current)], [(a.registered.single, true)]);
    await a.engine.stop();
  }, skip: noCore);

  test('a_device_taken_off_its_list_says_so', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = await firstDevice(fake, ana);
    final b = testDevice(fake, ana);
    await b.engine.start();
    expect(b.state, EngineState.newDevice);

    // Another of Ana's devices starts over (Task 27 does it from the app): a new identity, listing that device alone.
    final made = await b.host.handle<Map<String, Object?>>({'cmd': 'reset_identity'});
    final replaces = (await b.api.identity(ana)).identityKey;
    final published = await b.api.putIdentity(
      duvet.IdentityUpload(
        identityKey: made['identity_key']! as String,
        deviceList: made['device_list']! as String,
        certificate: made['certificate']! as String,
        encryptedIdentity: made['encrypted_identity']! as String,
        wrappedBackupKey: made['wrapped_backup_key']! as String,
        replaces: replaces,
        reset: true,
      ),
    );
    await b.host.handle<Object?>({'cmd': 'identity_uploaded'});
    await b.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': published.deviceListVersion});

    // The first device hears its user's identity changed, and finds no transfer for itself: it's off the list.
    await eventually(() => expect(a.state, EngineState.removed));
    await a.engine.stop();
    // And so says its next start.
    final again = testDevice(fake, ana, host: a.host, store: a.store, token: a.token);
    await again.engine.start();
    expect(again.state, EngineState.removed);
    await again.engine.stop();

    // Taken away for good (its sessions end with it), a sign-in again finds its ID refused.
    await b.api.deleteDevice(a.registered.single);
    final later = testDevice(fake, ana, host: a.host, store: a.store);
    await later.engine.start();
    expect(later.state, EngineState.removed);
    // Set up again: a new device of Ana's, which waits for her key or another device.
    await later.engine.startOver();
    expect(later.state, EngineState.newDevice);
    // Its first device was refused, so the new one is the first it registered.
    expect(later.registered, hasLength(1));
    expect(later.registered.single, isNot(a.registered.single));
    expect((await later.api.devices()).where((d) => d.current).single.id, later.registered.single);
    await b.engine.stop();
    await later.engine.stop();
  }, skip: noCore);

  // M10 of the desktop's review: DEVICE_REMOVE, with no IDENTITY_UPDATE before it.
  test('a_device_taken_away_while_it_runs_hears_so', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = await firstDevice(fake, ana);
    await a.engine.stop();
    final heard = testDevice(
      fake,
      ana,
      host: a.host,
      store: a.store,
      token: a.token,
      hears: (event) => event.type != 'IDENTITY_UPDATE',
    );
    await heard.engine.start();
    expect(heard.state, EngineState.ready);
    final b = testDevice(fake, ana);
    await b.engine.start();
    final made = await b.host.handle<Map<String, Object?>>({'cmd': 'reset_identity'});
    await b.api.putIdentity(
      duvet.IdentityUpload(
        identityKey: made['identity_key']! as String,
        deviceList: made['device_list']! as String,
        certificate: made['certificate']! as String,
        encryptedIdentity: made['encrypted_identity']! as String,
        wrappedBackupKey: made['wrapped_backup_key']! as String,
        replaces: (await b.api.identity(ana)).identityKey,
        reset: true,
      ),
    );
    expect(heard.state, EngineState.ready);
    await b.api.deleteDevice(heard.registered.single);
    await eventually(() => expect(heard.state, EngineState.removed));
    await heard.engine.stop();
    await b.engine.stop();
  }, skip: noCore);

  test('a_database_another_engine_holds_is_locked_until_it_lets_go', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final host = TestHost();
    final a = await firstDevice(fake, ana, host: host.gate);
    final second = testDevice(
      fake,
      ana,
      host: TestHost(folder: host.folder, keys: host.keys).gate,
      store: a.store,
      token: a.token,
    );
    await second.engine.start();
    expect(second.state, EngineState.locked);
    await a.engine.stop();
    // It tries again later, and opens once the first let go.
    second.clock.advance(_minute);
    await eventually(() => expect(second.state, EngineState.ready));
    expect(second.registered, a.registered);
    await second.engine.stop();
  }, skip: noCore);

  test("a_database_whose_key_is_lost_can't_open_again_and_the_device_starts_over_as_a_new_one", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final host = TestHost();
    final a = await firstDevice(fake, ana, host: host.gate);
    await a.engine.stop();
    final log = <String>[];
    final lost = WatchedHost(TestHost(folder: host.folder, keys: MemoryKeys({ana: Uint8List(32)})).gate, log);
    final again = testDevice(fake, ana, host: lost, store: a.store, token: a.token);
    await again.engine.start();
    expect(again.state, const EngineState.failed(lostKey: true));
    // Not a passing failure: nothing tries again by itself, and no tap of another state reaches the core.
    again.clock.advance(const Duration(minutes: 10));
    await again.engine.makeIdentity();
    await again.engine.keySaved();
    expect(again.state, const EngineState.failed(lostKey: true));
    expect(log, isEmpty);

    // Its data deleted on the person's word, a new device: the user has an identity, which it waits to be given.
    await again.engine.startOver();
    expect(again.state, EngineState.newDevice);
    expect(again.registered, hasLength(1));
    expect(again.registered.single, isNot(a.registered.single));
    await again.engine.stop();
  }, skip: noCore);

  test("a_failure_on_the_way_is_tried_again;_a_host_without_the_core,_or_a_client_too_old,_isn't", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    fake.refuse((method: 'GET', path: '/api/e2e'), 502, body: {'error': 'bad gateway'});
    final a = testDevice(fake, ana);
    await a.engine.start();
    expect(a.state, EngineState.starting);
    a.clock.advance(_minute);
    await eventually(() => expect(a.state, const EngineState.firstDevice()));
    await a.engine.stop();

    // A build without the core (iOS, say): the host says so, and nothing more is asked.
    final none = _ClosedHost((state: HostState.unsupported, keyStorage: null, reason: null));
    final bare = testDevice(fake, ana, host: none);
    await bare.engine.start();
    expect(bare.state, EngineState.unsupported);
    bare.clock.advance(const Duration(minutes: 10));
    expect(none.asked, isEmpty);
    await bare.engine.stop();

    // A client below its platform's minimum: the API says which version, or none where the platform has none.
    fake.minClients = {'desktop-windows': '1.2.0', 'android': '99.0.0'};
    final old = testDevice(fake, ana);
    await old.engine.start();
    expect(old.state, const EngineState.update('99.0.0'));
    await old.engine.stop();
    fake.minClients = {'desktop-windows': '1.2.0'};
    final elsewhere = testDevice(fake, ana);
    await elsewhere.engine.start();
    expect(elsewhere.state, const EngineState.update(null));
    await elsewhere.engine.stop();
  }, skip: noCore);

  // I3 of the desktop's review: a stale tap (a bar from before) never destroys a database in use.
  test('starting_over_is_only_for_a_removed_device_or_a_lost_key', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = await firstDevice(fake, ana);
    final b = testDevice(fake, ana);
    await b.engine.start();
    for (final device in [a, b]) {
      final before = await device.host.handle<Map<String, Object?>>({'cmd': 'status'});
      final state = device.state;
      await device.engine.startOver();
      expect(device.state, state);
      expect(device.registered, hasLength(1));
      expect(await device.host.handle<Map<String, Object?>>({'cmd': 'status'}), before);
    }
    await a.engine.stop();
    await b.engine.stop();
  }, skip: noCore);

  // M7 of the desktop's review: the record's keys are a device's, by its ID; a registration's 409 is no answer about
  // the device yet (a device of the user's deleted, the same ID with other keys, or another user's).
  test(
    "keys_the_record_kept_for_another_device_aren't_sent,_and_a_refused_registration_binds_by_the_bind_route",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      await a.engine.stop();
      final b = testDevice(fake, ana);
      await b.engine.start();
      final others = (b.store.read(deviceKeys)! as Map).cast<String, Object?>();
      final device = a.registered.single;
      final requests = <String>[];
      http.Client watched() => watchedClient(fake, seen: (request) => requests.add(_said(request)));
      List<String> registrations() => [
        for (final request in requests)
          if (request.startsWith('POST /api/users/@me/devices') && !request.endsWith('challenge')) request,
      ];

      // The record holds another device's keys, as when the database was made again and the record wasn't: none goes,
      // and the bind route binds the device.
      await a.store.write(deviceKeys, others);
      final again = testDevice(fake, ana, host: a.host, store: a.store, client: watched());
      await again.engine.start();
      expect(again.state, EngineState.ready);
      expect(again.registered, a.registered);
      expect(registrations(), ['POST /api/users/@me/devices/$device/bind']);
      await again.engine.stop();

      // Under this device's ID, keys that aren't its own (a key changed): the API refuses them, and the bind binds it.
      requests.clear();
      await a.store.write(deviceKeys, {...others, 'device_id': device});
      final later = testDevice(fake, ana, host: a.host, store: a.store, client: watched());
      await later.engine.start();
      expect(later.state, EngineState.ready);
      expect(later.registered, a.registered);
      expect(registrations(), ['POST /api/users/@me/devices', 'POST /api/users/@me/devices/$device/bind']);
      await later.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
  );

  // M6 of the review: a new device whose keys don't read keeps none of an older record's, as the desktop writes none.
  test("a_new_device_whose_keys_don't_read_keeps_none_of_the_record's_older_ones", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final store = MemoryStore();
    await store.write(deviceKeys, {
      'device_id': '01936d4e-8f00-7000-8000-00000000000f',
      'signature_key': base64Encode(Uint8List(32)),
      'hpke_key': base64Encode(Uint8List(32)),
    });
    final a = testDevice(fake, ana, host: _KeysUnread(TestHost().gate), store: store);
    await a.engine.start();
    expect(store.read(deviceKeys), isNull);
    await a.engine.stop();
  }, skip: noCore);

  // M7: a refusal no try changes ends the tries, with the failed state.
  test('a_binding_the_api_refuses_for_good_ends_the_tries_with_the_failed_bar', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final requests = <String>[];
    final a = testDevice(
      fake,
      ana,
      client: watchedClient(
        fake,
        seen: (request) => requests.add(_said(request)),
        answer: (request) async => _said(request) == 'POST /api/users/@me/devices'
            ? http.Response(jsonEncode({'error': "the proof doesn't verify"}), 403)
            : null,
      ),
    );
    await a.engine.start();
    expect(a.state, const EngineState.failed());
    final asked = requests.length;
    a.clock.advance(const Duration(minutes: 10));
    await pumpEventQueue();
    expect(requests, hasLength(asked));
    await a.engine.stop();
  }, skip: noCore);

  // The app's sign-in is in the app: the login's challenge binds its session, and a later binding asks for one.
  test("the_login's_challenge_binds_its_first_session,_and_another_binding_asks_for_one", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final requests = <String>[];
    final client = watchedClient(fake, seen: (request) => requests.add(_said(request)));
    final a = await firstDevice(fake, ana, client: client);
    expect(requests, isNot(contains('POST /api/users/@me/devices/challenge')));
    await a.engine.stop();
    // The same session, bound already: no binding.
    final same = testDevice(fake, ana, host: a.host, store: a.store, token: a.token, client: client);
    await same.engine.start();
    expect(requests, isNot(contains('POST /api/users/@me/devices/challenge')));
    await same.engine.stop();
    // Another session with no login's challenge in memory (the app started again): it asks for one.
    final other = fake.signIn(ana).token;
    final next = testDevice(fake, ana, host: a.host, store: a.store, token: other, client: client);
    await next.engine.start();
    expect(next.state, EngineState.ready);
    expect(requests.where((r) => r == 'POST /api/users/@me/devices/challenge'), hasLength(1));
    await next.engine.stop();
    // A login's challenge past the API's 10 minutes (the app came to the front late) isn't taken: a proof over it would
    // be refused, for good. The binding asks for one.
    final late = testDevice(
      fake,
      ana,
      client: client,
      challengedAt: DateTime.now().subtract(const Duration(minutes: 10)),
    );
    await late.engine.start();
    expect(late.state, EngineState.newDevice);
    expect(requests.where((r) => r == 'POST /api/users/@me/devices/challenge'), hasLength(2));
    await late.engine.stop();
  }, skip: noCore);

  group("the phone's name", () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(deviceChannel, null));

    test("is_its_model,_cut_to_the_API's_64_characters", () async {
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => call.method == 'model' ? 'Pixel 8 Pro' : null);
      expect(await phoneName(), 'Pixel 8 Pro');
      // Counted by code point, as the API counts it: an emoji outside the BMP is one.
      final long = '${String.fromCharCode(0x1F4F1)}${'x' * 70}';
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => long);
      expect((await phoneName()).runes, hasLength(64));
      expect(await phoneName(), startsWith(String.fromCharCode(0x1F4F1)));
    });

    test('without_the_channel,_or_with_no_model,_is_the_app_on_android', () async {
      expect(await phoneName(), unknownPhone);
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => '   ');
      expect(await phoneName(), unknownPhone);
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => throw PlatformException(code: 'gone'));
      expect(await phoneName(), unknownPhone);
    });

    // ios/Runner answers the channel with the phone's model, «iPhone» or «iPad» (PLAN-E2E-PLATAFORMAS.md, Task 13).
    test('on iOS, without the channel or with no model, is the app on iOS', () async {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await phoneName(), unknownIPhone);
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => '');
      expect(await phoneName(), unknownIPhone);
      messenger.setMockMethodCallHandler(deviceChannel, (call) async => 'iPhone');
      expect(await phoneName(), 'iPhone');
    });
  });
}
