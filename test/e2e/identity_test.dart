import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';
import '../support/fake_api.dart';

// The first device of a user (PLAN-E2E-CLIENTES.md, Task 13): its identity made from the person's tap, its recovery
// key shown and saved (decision 23), and only then published and confirmed, on real cores through the fake API. The
// desktop's identity.test.ts, case for case, with its review's rulings.
const _identity = (method: 'PUT', path: '/api/users/@me/identity');

String _said(http.Request request) => '${request.method} ${request.url.path}';

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test("a_first_device_makes_its_identity,_shows_the_key,_and_uploads_it_once_it's_saved", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final requests = <String>[];
    final a = testDevice(fake, ana, client: watchedClient(fake, seen: (request) => requests.add(_said(request))));
    await a.engine.start();
    // The user has no identity: the device waits for the person, its session bound to it.
    expect(a.state, const EngineState.firstDevice());
    final device = a.registered.single;
    expect([for (final d in await a.api.devices()) (d.id, d.name, d.current)], [(device, 'Pixel 8 Pro', true)]);

    await a.engine.makeIdentity();
    final key = shownKey(a.state);
    expect(key, recoveryKeyShape);
    expect(a.state, EngineState.firstDevice(recoveryKey: key));
    // Nothing goes up before the person says they saved it.
    expect(requests, isNot(contains('PUT /api/users/@me/identity')));
    await expectLater(
      a.api.identity(ana),
      throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 404)),
    );

    await a.engine.keySaved();
    expect(a.state, EngineState.ready);
    expect(requests.where((r) => r == 'PUT /api/users/@me/identity'), hasLength(1));
    // Published and confirmed: the API has it with this device listed, and the core keeps no copy for an upload.
    final status = await a.host.handle<Map<String, Object?>>({'cmd': 'status'});
    expect(status['waiting_upload'], isNull);
    expect((await a.api.identity(ana)).identityKey, status['identity_key']);
    expect([for (final d in await a.api.devices()) (d.id, d.listed, d.current)], [(device, true, true)]);
    // Then the device's key packages, at once.
    expect(requests, contains('PUT /api/users/@me/devices/@me/key-packages'));
    await a.engine.stop();
  }, skip: noCore);

  // Review Focus 3: the app dies between the core's command and the API's answer.
  test('an_identity_cut_before_its_upload_goes_up_again', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final sent = <String>[];
    final client = watchedClient(
      fake,
      seen: (request) {
        if (_said(request) == 'PUT /api/users/@me/identity') sent.add(request.body);
      },
    );
    final a = testDevice(fake, ana, client: client);
    await a.engine.start();
    await a.engine.makeIdentity();
    final key = shownKey(a.state);
    fake.loseAnswer(_identity);
    // The API took it, but the answer never came: nothing is confirmed, and the key still shows.
    await expectLater(a.engine.keySaved(), throwsA(isA<http.ClientException>()));
    expect(a.state, EngineState.firstDevice(recoveryKey: key));
    await a.engine.stop();

    // The app starts again on the same database: the core still waits for the upload, so the key comes back.
    final again = testDevice(fake, ana, host: a.host, store: a.store, token: a.token, client: client);
    await again.engine.start();
    expect(again.state, const EngineState.firstDevice(finishing: true));
    await again.engine.makeIdentity();
    expect(shownKey(again.state), key);
    await again.engine.keySaved();
    expect(again.state, EngineState.ready);
    // The same bytes went up again, which the API took as the identity it has.
    expect(sent, hasLength(2));
    expect(sent.last, sent.first);
    expect(again.registered, a.registered);
    await again.engine.stop();
  }, skip: noCore);

  // Review Focus 11: a list confirmed without its upload lets another list of its version in.
  test('a_list_is_confirmed_only_after_its_200', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final log = <String>[];
    final a = testDevice(
      fake,
      ana,
      host: WatchedHost(TestHost().gate, log),
      client: watchedClient(
        fake,
        seen: (request) {
          if (_said(request) == 'PUT /api/users/@me/identity') log.add('PUT identity');
        },
      ),
    );
    await a.engine.start();
    await a.engine.makeIdentity();
    List<String> confirmations() =>
        [for (final step in log) step].where((s) => s == 'identity_uploaded' || s == 'device_list_uploaded').toList();

    // Refused: nothing is confirmed.
    fake.refuse(_identity, 500, body: {'error': 'internal server error'});
    await expectLater(
      a.engine.keySaved(),
      throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 500)),
    );
    // Taken, but its answer lost: the client never saw the 200, so nothing is confirmed either.
    fake.loseAnswer(_identity);
    await expectLater(a.engine.keySaved(), throwsA(isA<http.ClientException>()));
    expect(confirmations(), isEmpty);
    expect((await a.host.handle<Map<String, Object?>>({'cmd': 'status'}))['waiting_upload'], 'create_identity');

    await a.engine.keySaved();
    expect(confirmations(), ['identity_uploaded', 'device_list_uploaded']);
    // Both after the third upload, the one that got its 200.
    expect(log.indexOf('identity_uploaded'), greaterThan(log.lastIndexOf('PUT identity')));
    expect(log.where((step) => step == 'PUT identity'), hasLength(3));
    await a.engine.stop();
  }, skip: noCore);

  // Ruling 26: the core can't undo an identity, so the device that lost starts over as a new one.
  test('two_first_devices_at_once:_the_one_that_loses_starts_over_as_a_new_device', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final (a, b) = (testDevice(fake, ana), testDevice(fake, ana));
    await Future.wait([a.engine.start(), b.engine.start()]);
    await Future.wait([a.engine.makeIdentity(), b.engine.makeIdentity()]);
    expect(shownKey(b.state), recoveryKeyShape);
    await a.engine.keySaved();
    expect(a.state, EngineState.ready);

    await b.engine.keySaved();
    expect(b.state, EngineState.newDevice);
    // A new device, its session bound to it, and its first one's registration deleted.
    expect(b.registered, hasLength(2));
    final [first, now] = b.registered;
    expect(now, isNot(first));
    final devices = {for (final d in await b.api.devices()) d.id: (d.listed, d.current)};
    expect(devices, {a.registered.single: (true, false), now: (false, true)});
    // Its database is a new one: the identity it made is gone with the old one.
    final status = await b.host.handle<Map<String, Object?>>({'cmd': 'status'});
    expect((status['device_id'], status['has_identity']), (now, false));
    await a.engine.stop();
    await b.engine.stop();
  }, skip: noCore);

  // I1 of the desktop's review: every device of a person starts as the first at the cutover; once one publishes, the
  // others' Set up is stale.
  test("a_stale_set_up,_after_another_device_of_the_user_published,_makes_no_key:_it's_a_new_device", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final log = <String>[];
    // It doesn't hear the identity published: its "Set up" is stale when it's tapped.
    final stale = testDevice(
      fake,
      ana,
      host: WatchedHost(TestHost().gate, log),
      hears: (event) => event.type != 'IDENTITY_UPDATE',
    );
    await stale.engine.start();
    expect(stale.state, const EngineState.firstDevice());
    final a = await firstDevice(fake, ana);
    await stale.engine.makeIdentity();
    expect(stale.state, EngineState.newDevice);
    expect(log, isNot(contains('create_identity')));
    expect(stale.states.where((state) => state.recoveryKey != null), isEmpty);
    // Its core made no identity, so nothing is destroyed: the same device, waiting to be given the identity.
    expect(stale.registered, hasLength(1));
    await stale.engine.stop();
    await a.engine.stop();
  }, skip: noCore);

  test("the_user's_identity_published_elsewhere_turns_a_first_device_that_showed_no_key_into_a_new_one", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final waiting = testDevice(fake, ana);
    await waiting.engine.start();
    expect(waiting.state, const EngineState.firstDevice());
    final first = await firstDevice(fake, ana);
    await eventually(() => expect(waiting.state, EngineState.newDevice));
    // One that starts after it is a new device from the start, before any tap.
    final heard = testDevice(fake, ana);
    await heard.engine.start();
    expect(heard.state, EngineState.newDevice);
    for (final device in [waiting, first, heard]) {
      await device.engine.stop();
    }
  }, skip: noCore);

  // I1 too, as the desktop's round 2 has it: an identity the core kept for its upload, once the user's identity is
  // another, is never shown nor uploaded.
  test(
    'an_identity_made_before_the_app_closed,_when_another_was_published_since,_starts_over_with_no_key_shown',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = testDevice(fake, ana);
      await a.engine.start();
      await a.engine.makeIdentity();
      // The app closes before the key is saved; another of Ana's devices publishes hers meanwhile.
      await a.engine.stop();
      final b = await firstDevice(fake, ana);
      final again = testDevice(fake, ana, host: a.host, store: a.store, token: a.token);
      await again.engine.start();
      expect(again.state, const EngineState.firstDevice(finishing: true));
      await again.engine.makeIdentity();
      expect(again.state, EngineState.newDevice);
      expect(again.states.where((state) => state.recoveryKey != null), isEmpty);
      // A new device, its session bound to it, the one whose identity can't be undone deleted.
      expect(again.registered, hasLength(2));
      final status = await again.host.handle<Map<String, Object?>>({'cmd': 'status'});
      expect(
        (status['device_id'], status['has_identity'], status['waiting_upload']),
        (again.registered.last, false, null),
      );
      expect((await again.api.devices()).map((d) => d.id), isNot(contains(again.registered.first)));
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
  );

  // I2 of the desktop's review: once the key is saved, a failed upload doesn't hold the app behind the key.
  test('after_a_failed_upload,_later_closes_the_sheet,_and_finish_brings_the_same_key_back', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = testDevice(fake, ana);
    await a.engine.start();
    await a.engine.makeIdentity();
    final key = shownKey(a.state);
    fake.refuse(_identity, 503);
    await expectLater(a.engine.keySaved(), throwsA(isA<duvet.DuvetApiException>()));
    await a.engine.uploadLater();
    expect(a.state, const EngineState.firstDevice(finishing: true));
    // Finish: the same key, and its upload.
    await a.engine.makeIdentity();
    expect(shownKey(a.state), key);
    await a.engine.keySaved();
    expect(a.state, EngineState.ready);
    await a.engine.stop();
  }, skip: noCore);

  test('an_upload_a_client_too_old_makes_goes_to_update', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = testDevice(fake, ana);
    await a.engine.start();
    await a.engine.makeIdentity();
    fake.refuse(_identity, 426);
    await a.engine.keySaved();
    expect(a.state, const EngineState.update(null));
    await a.engine.stop();
  }, skip: noCore);

  // M5 of the desktop's review: a confirmation cut after identity_uploaded, before the list's.
  test('a_confirmation_cut_halfway_goes_on_at_the_next_continue', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    var cut = true;
    final a = testDevice(
      fake,
      ana,
      host: WatchedHost(
        TestHost().gate,
        [],
        fail: (command) {
          if (command['cmd'] != 'device_list_uploaded' || !cut) return null;
          cut = false;
          return CoreError('internal', message: 'the call was cut');
        },
      ),
    );
    await a.engine.start();
    await a.engine.makeIdentity();
    await expectLater(a.engine.keySaved(), throwsA(isA<CoreError>()));
    await a.engine.keySaved();
    expect(a.state, EngineState.ready);
    await a.engine.stop();
  }, skip: noCore);
}
