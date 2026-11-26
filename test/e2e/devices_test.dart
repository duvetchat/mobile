import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/legacy.dart' show legacyRecords;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/encryption/devices.dart' show rotationStuck;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Devices in Settings (PLAN-E2E-CLIENTES.md, Task 25; decisions 13 and 52): the user's devices, those not seen in 45
// days, another one taken off the list, one lost taken off with new keys, and this one's data deleted, on real cores
// through the fake API. The desktop's devices.test.ts, case for case but the new password's (the web page's), and its
// page's engine cases through the app's own wiring.
const _slow = Timeout(Duration(minutes: 3));
const _list = (method: 'PUT', path: '/api/users/@me/device-list');
const _identity = (method: 'PUT', path: '/api/users/@me/identity');

String _said(http.Request request) => '${request.method} ${request.url.path}';

/// The new recovery key a rotation shows, or null.
String? _rotationKey(EngineState state) => state.rotating ? state.recoveryKey : null;

String _deviceOf(TestDevice device) => device.registered.last;

String _ago(int days) => DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();

Future<Map<String, Object?>> _status(TestDevice device) => device.host.handle<Map<String, Object?>>({'cmd': 'status'});

Future<List<String>> _deviceIds(TestDevice device) async => [for (final d in await device.api.devices()) d.id];

/// What a device notice says, as a test reads it.
(DeviceNoticeKind, String, String) _told(DeviceNotice notice) => (notice.kind, notice.device.id, notice.device.name);

/// A core whose database can't be deleted, as a file the system holds: everything else as the core it wraps.
class _DestroyFails extends WatchedHost {
  _DestroyFails(CoreHost host) : super(host, []);

  @override
  Future<void> destroy(String userId) async => throw CoreError('storage', message: 'a file of the database stays');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'the_list_marks_a_device_not_seen_in_45_days,_and_warns_once_for_it',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final b = await approvedDevice(fake, a);
      await b.engine.stop();
      final phone = _deviceOf(b);

      // The list marks it past 45 days, never this device, and not one seen within them.
      fake
        ..lastSeen(phone, _ago(46))
        ..lastSeen(_deviceOf(a), _ago(46));
      final listed = await a.api.devices();
      expect(inactiveDevice(listed.firstWhere((d) => d.id == phone)), isTrue);
      expect(inactiveDevice(listed.firstWhere((d) => d.current)), isFalse);
      fake.lastSeen(phone, _ago(44));
      expect(inactiveDevice((await a.api.devices()).firstWhere((d) => d.id == phone)), isFalse);
      fake.lastSeen(phone, _ago(46));

      // The app warns once for it: at its next start, not again a day later, nor at the start after.
      await a.engine.stop();
      final notices = <DeviceNotice>[];
      final again = testDevice(fake, ana, host: a.host, store: a.store, token: a.token);
      again.engine.deviceNotices.listen(notices.add);
      await again.engine.start();
      expect(notices.map(_told), [(DeviceNoticeKind.inactive, phone, 'Pixel 8 Pro')]);
      again.clock.advance(const Duration(days: 1));
      await turnEnded(again);
      await again.engine.stop();
      final later = testDevice(fake, ana, host: a.host, store: a.store, token: a.token);
      later.engine.deviceNotices.listen(notices.add);
      await later.engine.start();
      expect(notices, hasLength(1));
      await later.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 11: a list confirmed without its upload lets another list of its version in.
  test(
    'removing_a_device_signs_a_list_without_it,_and_confirms_it_after_its_200',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final client = watchedClient(
        fake,
        seen: (request) {
          if (_said(request) == 'PUT /api/users/@me/device-list') log.add('PUT list');
        },
      );
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log), client: client);
      final b = await approvedDevice(fake, a);
      final c = await approvedDevice(fake, a);
      log.clear();
      List<String> confirmed() => [
        for (final step in log)
          if (step == 'device_list_uploaded') step,
      ];

      // Refused: nothing is confirmed, and the device stays.
      fake.refuse(_list, 500, body: {'error': 'internal server error'});
      await expectLater(
        a.engine.removeDevice(_deviceOf(b)),
        throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 500)),
      );
      expect(log, contains('sign_device_list'));
      expect(confirmed(), isEmpty);
      // Taken or not, the own user is observed before it fails (the core's N3; review 24's rule 2).
      expect(log.last, 'observe_user');
      expect(await _deviceIds(a), contains(_deviceOf(b)));
      // The list the API didn't take stays the core's own, which the next list or key change takes along: named
      // (review 24's M3).
      expect(await a.engine.unsentRemovals(), [_deviceOf(b)]);

      // Again: the list without it goes up, and only its 200 confirms it.
      await a.engine.removeDevice(_deviceOf(b));
      expect(await a.engine.unsentRemovals(), isEmpty);
      expect(confirmed(), hasLength(1));
      expect(log.indexOf('device_list_uploaded'), greaterThan(log.lastIndexOf('PUT list')));
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(c)]));
      await until(() => b.state.stage == EngineStage.removed);
      final served = await a.api.identity(ana);
      expect(listDevices(served.deviceList), unorderedEquals([_deviceOf(a), _deviceOf(c)]));

      // Taken, its answer lost: no 200 came, so nothing is confirmed, and the next try finds it off the list.
      log.clear();
      fake.loseAnswer(_list);
      await expectLater(a.engine.removeDevice(_deviceOf(c)), throwsA(isA<http.ClientException>()));
      expect(confirmed(), isEmpty);
      await a.engine.removeDevice(_deviceOf(c));
      expect(log.where((step) => step == 'PUT list'), hasLength(1));
      expect(await _deviceIds(a), [_deviceOf(a)]);
      expect(a.state, EngineState.ready);
      await Future.wait([a.engine.stop(), b.engine.stop(), c.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 24's rule 4: a confirmation the core answers with nothing kept for an upload (a newer list or identity took
  // its place) counts as done, for a list and for a key change.
  test(
    'a_confirmation_that_finds_nothing_kept_counts_as_done',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      var nothingKept = false;
      final host = WatchedHost(
        TestHost().gate,
        [],
        fail: (command) => nothingKept && command['cmd'] == 'device_list_uploaded'
            ? CoreError('not_found', message: 'no upload waits', what: 'upload')
            : null,
      );
      final a = await firstDevice(fake, ana, host: host);
      final b = await approvedDevice(fake, a);
      nothingKept = true;
      await a.engine.removeDevice(_deviceOf(b));
      expect(await _deviceIds(a), [_deviceOf(a)]);
      expect(a.state, EngineState.ready);
      await a.engine.changeKeys();
      await a.engine.keySaved();
      expect(a.state, EngineState.ready);
      expect((await a.api.identity(ana)).identityKey, (await _status(a))['identity_key']);
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // The core's rule after a list: taken or not, the own user is observed before another is signed (N3).
  test(
    'a_list_that_lost_its_race_is_observed_and_signed_again',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      var puts = 0;
      final log = <String>[];
      final client = watchedClient(
        fake,
        seen: (request) {
          if (_said(request) != 'PUT /api/users/@me/device-list') return;
          puts++;
          log.add('PUT list');
        },
      );
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log), client: client);
      final b = await approvedDevice(fake, a, client: client);
      final c = await approvedDevice(fake, a);
      final d = await approvedDevice(fake, a);
      puts = 0;

      // Two of the user's devices each take another off at once: their lists meet, and one finds the other's first.
      fake.gather(_list, 2);
      await Future.wait([a.engine.removeDevice(_deviceOf(c)), b.engine.removeDevice(_deviceOf(d))]);
      expect(puts, 3);
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      final served = await a.api.identity(ana);
      expect(listDevices(served.deviceList), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      // Both hold the list the API serves.
      for (final device in [a, b]) {
        expect(device.state, EngineState.ready);
        await until(() async => (await _status(device))['device_list'] == served.deviceList);
      }

      // A third lost race is thrown, the own user observed first (the core's N3; review 25's M4).
      log.clear();
      for (var race = 0; race < 3; race++) {
        fake.refuse(
          _list,
          409,
          body: {'error': 'device list changed', 'device_list': served.deviceList, 'version': served.deviceListVersion},
        );
      }
      await expectLater(a.engine.removeDevice(_deviceOf(b)), throwsA(isA<duvet.DuvetDeviceListChangedException>()));
      expect(log.where((step) => step == 'PUT list'), hasLength(3));
      expect(log.last, 'observe_user');
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      await Future.wait([
        for (final device in [a, b, c, d]) device.engine.stop(),
      ]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_device_the_user_never_set_up_goes_by_its_registration',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final fresh = testDevice(fake, ana);
      await fresh.engine.start();
      expect(fresh.state, EngineState.newDevice);
      await a.engine.removeDevice(_deviceOf(fresh));
      expect(await _deviceIds(a), [_deviceOf(a)]);
      await until(() => fresh.state.stage == EngineStage.removed);
      await Future.wait([a.engine.stop(), fresh.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'removing_this_device_deletes_its_database_and_its_registration,_and_stops_its_engine',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final requests = <String>[];
      final a = await firstDevice(fake, ana);
      // A device the user never set up: the API takes its registration away.
      final fresh = testDevice(fake, ana, client: watchedClient(fake, seen: (request) => requests.add(_said(request))));
      await fresh.engine.start();
      await fresh.engine.removeThisDevice();
      expect(await _deviceIds(a), [_deviceOf(a)]);
      expect(fresh.state, EngineState.starting);
      // Its engine does nothing more: no start again, nothing a day later.
      requests.clear();
      fresh.clock.advance(const Duration(days: 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, isEmpty);
      expect(fresh.state, EngineState.starting);
      await fresh.host.open(ana);
      expect((await _status(fresh))['device_id'], isNull);

      // A device on the list: its data goes, and its listing stays for the user's other devices to take off, as the API
      // takes no list without the session's device.
      final b = await approvedDevice(fake, a);
      await b.engine.removeThisDevice();
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      await b.host.open(ana);
      expect((await _status(b))['device_id'], isNull);
      await Future.wait([a.engine.stop(), fresh.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 24's M5: the database goes before the registration, whose deletion ends the session: when the data can't go,
  // the device stays registered and signed in, for the person to try again.
  test(
    "removing_this_device_keeps_its_registration_when_its_data_can't_go",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final fresh = testDevice(fake, ana, host: _DestroyFails(TestHost().gate));
      await fresh.engine.start();
      expect(fresh.state, EngineState.newDevice);
      await expectLater(fresh.engine.removeThisDevice(), throwsA(isA<CoreError>()));
      expect(await _deviceIds(fresh), contains(_deviceOf(fresh)));
      await Future.wait([a.engine.stop(), fresh.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 24's M4 and M6: deleting this device's data clears its record and what it told of the user's devices; the
  // API's external sender it pinned (Ruling 32) and the records of conversations from before the cutover (Ruling 14's
  // anchor) stay, as they're the account's on this phone, which a next device here takes up.
  test(
    'removing_this_device_clears_its_record_and_what_it_told,_and_keeps_the_pin_and_the_legacy_records',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final store = MemoryStore();
      final a = await firstDevice(fake, ana, store: store);
      final b = await approvedDevice(fake, a);
      await until(() => store.read(toldAdded) != null);
      await b.engine.stop();
      fake.lastSeen(_deviceOf(b), _ago(46));
      final again = await restarted(fake, a);
      expect(store.read(toldInactive), [_deviceOf(b)]);
      await store.write(legacyRecords, {'a-conversation': false});

      await again.engine.removeThisDevice();
      for (final key in [...deviceRecord, toldAdded, toldInactive]) {
        expect(store.read(key), isNull, reason: key);
      }
      expect(store.read(externalSender), isNotNull);
      expect(store.read(legacyRecords), {'a-conversation': false});
      await again.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_lost_device_goes_with_new_keys,_and_the_new_recovery_key_must_be_saved',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final requests = <String>[];
      final a = await firstDevice(
        fake,
        ana,
        client: watchedClient(fake, seen: (request) => requests.add(_said(request))),
      );
      final firstKey = a.states.map(shownKey).nonNulls.first;
      final lost = await approvedDevice(fake, a);
      final kept = await approvedDevice(fake, a);
      final before = await a.api.identity(ana);
      requests.clear();

      await a.engine.removeDevice(_deviceOf(lost), changeKeys: true);
      final key = _rotationKey(a.state);
      expect(key, recoveryKeyShape);
      expect(key, isNot(firstKey));
      // Nothing goes up before the person saved it: the API has the identity and the devices it had.
      expect(requests, isNot(contains('PUT /api/users/@me/identity')));
      expect((await a.api.identity(ana)).identityKey, before.identityKey);
      expect(await _deviceIds(a), contains(_deviceOf(lost)));

      await a.engine.keySaved();
      expect(a.state, EngineState.ready);
      // The new identity is the API's, the core keeps no copy for an upload, and the lost device is gone.
      final status = await _status(a);
      expect(status['waiting_upload'], isNull);
      final after = await a.api.identity(ana);
      expect(after.identityKey, status['identity_key']);
      expect(after.identityKey, isNot(before.identityKey));
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(kept)]));
      await until(() => lost.state.stage == EngineStage.removed);
      // The device that stays took the new identity from its transfer.
      await until(() async => (await _status(kept))['identity_key'] == after.identityKey);
      await until(() => kept.state == EngineState.ready);
      await Future.wait([
        for (final device in [a, lost, kept]) device.engine.stop(),
      ]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'changing_the_security_keys_with_no_device_lost_hands_them_to_every_device',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final b = await approvedDevice(fake, a);
      await a.engine.changeKeys();
      expect(_rotationKey(a.state), recoveryKeyShape);
      await a.engine.keySaved();
      final after = await a.api.identity(ana);
      expect(after.identityKey, (await _status(a))['identity_key']);
      expect(await _deviceIds(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      await until(() async => (await _status(b))['identity_key'] == after.identityKey);
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 3: the app dies between the core's command and the API's answer.
  test(
    'a_rotation_cut_before_its_upload_runs_again_as_the_same_rotation',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final sent = <String>[];
      final client = watchedClient(fake, seen: (request) => sent.add(_said(request)));
      final a = await firstDevice(fake, ana, client: client);
      final lost = await approvedDevice(fake, a);
      final kept = await approvedDevice(fake, a);
      sent.clear();

      await a.engine.removeDevice(_deviceOf(lost), changeKeys: true);
      final key = _rotationKey(a.state);
      final made = (await _status(a))['identity_key'];
      // The app closes before the key was saved: nothing went up, and the next start offers to finish.
      final again = await restarted(fake, a, client: client);
      expect(again.state, const EngineState.rotation());
      expect(sent, isNot(contains('PUT /api/users/@me/identity')));

      // Finish: the same rotation, its key and identity, taking off the device it took off.
      await again.engine.changeKeys();
      expect(_rotationKey(again.state), key);
      expect((await _status(again))['identity_key'], made);
      await again.engine.keySaved();
      expect(again.state, EngineState.ready);
      expect((await again.api.identity(ana)).identityKey, made);
      expect(await _deviceIds(again), unorderedEquals([_deviceOf(a), _deviceOf(kept)]));
      await until(() async => (await _status(kept))['identity_key'] == made);

      // Cut after the API took it, its answer lost: the person saved its key before it went, and the next start
      // confirms it, with nothing shown and nothing sent again.
      await again.engine.changeKeys();
      final second = (await _status(again))['identity_key'];
      fake.loseAnswer(_identity);
      await expectLater(again.engine.keySaved(), throwsA(isA<http.ClientException>()));
      expect(_rotationKey(again.state), recoveryKeyShape);
      sent.clear();
      final third = await restarted(fake, again, client: client);
      expect(third.state, EngineState.ready);
      expect(sent, isNot(contains('PUT /api/users/@me/identity')));
      expect((await _status(third))['waiting_upload'], isNull);
      expect((await third.api.identity(ana)).identityKey, second);
      await Future.wait([third.engine.stop(), lost.engine.stop(), kept.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // The brief's rule: no key material reaches a log line or the record, whatever the rotation goes through.
  test(
    "a_rotation's_recovery_key_reaches_no_log_line_and_no_record",
    () async {
      final logged = <String>[];
      final print = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = print);
      final fake = FakeApi();
      final ana = fake.addUser();
      final store = MemoryStore();
      final a = await firstDevice(fake, ana, store: store);
      final b = await approvedDevice(fake, a);
      await a.engine.removeDevice(_deviceOf(b), changeKeys: true);
      final key = _rotationKey(a.state)!;
      // Refused, put off, finished and saved: the engine logs its failure, and the state is printed as a log would.
      fake.refuse(_identity, 500, body: {'error': 'internal server error'});
      await expectLater(a.engine.keySaved(), throwsA(isA<duvet.DuvetApiException>()));
      debugPrint('${a.state}');
      await a.engine.uploadLater();
      await a.engine.changeKeys();
      expect(_rotationKey(a.state), key);
      await a.engine.keySaved();
      expect(a.state, EngineState.ready);
      for (final line in logged) {
        expect(line, isNot(contains(key)));
      }
      expect(store.kept.values.join(), isNot(contains(key)));
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 24's I1: a key change that waits can't finish once another device took off a device it keeps (the core's
  // rotate_again needs a served certificate for each device it keeps). Its Finish says so, with no throw, and so does
  // its upload with the key shown (the API's 400 for a transfer to a removed device).
  test(
    'a_key_change_another_device_made_impossible_says_so',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final b = await approvedDevice(fake, a);
      final c = await approvedDevice(fake, a);
      final d = await approvedDevice(fake, a);

      // Put off, then b takes c off: Finish can't run the same change again.
      await a.engine.changeKeys();
      await a.engine.uploadLater();
      expect(a.state, const EngineState.rotation());
      await b.engine.removeDevice(_deviceOf(c));
      await turnEnded(a);
      await a.engine.changeKeys();
      expect(a.state, const EngineState.rotation(stuck: true));
      await Future.wait([
        for (final device in [a, b, c, d]) device.engine.stop(),
      ]);

      // Its key shown, then b takes d off: the upload can't go.
      final fake2 = FakeApi();
      final bo = fake2.addUser();
      final e = await firstDevice(fake2, bo);
      final f = await approvedDevice(fake2, e);
      final g = await approvedDevice(fake2, e);
      await e.engine.changeKeys();
      expect(_rotationKey(e.state), recoveryKeyShape);
      await f.engine.removeDevice(_deviceOf(g));
      // Not turnEnded: its tap is Later, which would put this change off.
      await pumpEventQueue();
      await e.engine.keySaved();
      expect(e.state, const EngineState.rotation(stuck: true));
      await Future.wait([
        for (final device in [e, f, g]) device.engine.stop(),
      ]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 24's rule 4 and review 25's I1: a key change another device's beat (409 identity changed) reads the inbox,
  // but while this change waits the core checks the winner's transfer against the identity this change made and
  // refuses it (invalid_signature), until duvetchat/e2e#49. The change can never finish, and its words name the one
  // way out: this device's data deleted and set up again.
  test(
    "a_key_change_another_device's_beat_reads_the_inbox",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final requests = <String>[];
      // b hears no DEVICE_MESSAGE: only the 409's own read of the inbox reads it.
      final b = await firstDevice(
        fake,
        ana,
        client: watchedClient(fake, seen: (request) => requests.add(_said(request))),
        hears: (event) => event.type != 'DEVICE_MESSAGE',
      );
      final a = await approvedDevice(fake, b);
      await a.engine.changeKeys();
      await b.engine.changeKeys();
      await a.engine.keySaved();
      requests.clear();

      await b.engine.keySaved();
      expect(
        requests.indexOf('GET /api/users/@me/devices/@me/inbox'),
        greaterThan(requests.indexOf('PUT /api/users/@me/identity')),
      );
      expect(b.state, const EngineState.rotation(stuck: true));
      // Another device's change of keys is no way out: the words name only this device's data deleted.
      expect(rotationStuck, contains("delete this device's data and set it up again"));
      expect(rotationStuck, isNot(contains('on another device')));
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 3's closing review: a new password's remove_devices leaves the signed list naming devices the API took away,
  // which a list naming them again can't go up with (400 `the list names device …`).
  test(
    'a_list_this_device_signs_drops_the_devices_the_API_took_away',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final b = await approvedDevice(fake, a);
      final c = await approvedDevice(fake, a);
      final d = await approvedDevice(fake, a);

      fake.dropDevice(_deviceOf(c));
      await a.engine.removeDevice(_deviceOf(b));
      expect(listDevices((await a.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(d)]));

      // A rotation too: the device it would hand the keys to has no certificate the API serves.
      fake.dropDevice(_deviceOf(d));
      await a.engine.changeKeys();
      await a.engine.keySaved();
      final after = await a.api.identity(ana);
      expect(after.identityKey, (await _status(a))['identity_key']);
      expect(listDevices(after.deviceList), [_deviceOf(a)]);
      await Future.wait([
        for (final device in [a, b, c, d]) device.engine.stop(),
      ]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_new_device_of_the_user's_is_told_once,_never_this_one",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final notices = <DeviceNotice>[];
      final a = testDevice(fake, ana);
      a.engine.deviceNotices.listen(notices.add);
      await a.engine.start();
      await a.engine.makeIdentity();
      await a.engine.keySaved();
      // A new device registers (DEVICE_ADD), then the list takes it (DEVICE_ADD again): told once.
      final b = await approvedDevice(fake, a);
      await until(() => notices.isNotEmpty);
      await turnEnded(a);
      expect(notices.map(_told), [(DeviceNoticeKind.added, _deviceOf(b), 'Pixel 8 Pro')]);
      expect(onlyDevice(await a.api.devices()), isFalse);
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 25's M3: this installation's device is known from its database before the session binds (the desktop's
  // #self), so a start the API refused before it bound still tells of another device of the user's that registers.
  test(
    "a_device_that_registers_while_this_one's_start_is_refused_is_told",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      await a.engine.stop();
      // The app opens again on a new session, whose binding (the device's keys registered again) the API refuses for
      // good: the start fails before it binds.
      fake.refuse((method: 'POST', path: '/api/users/@me/devices'), 403, body: {'error': 'forbidden'});
      final again = testDevice(fake, ana, host: a.host, store: a.store);
      final notices = <DeviceNotice>[];
      again.engine.deviceNotices.listen(notices.add);
      await again.engine.start();
      expect(again.state, const EngineState.failed());

      final b = testDevice(fake, ana);
      await b.engine.start();
      await until(() => again.heard.any((event) => event.type == 'DEVICE_ADD'));
      await turnEnded(again);
      expect(notices.map(_told), [(DeviceNoticeKind.added, _deviceOf(b), 'Pixel 8 Pro')]);
      await Future.wait([again.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test("this_device_is_the_only_one_when_no_other_device_of_the_user's_is_on_the_list", () {
    duvet.Device device(String id, {required bool current, required bool listed}) => duvet.Device(
      id: id,
      name: 'Pixel 8 Pro',
      client: 'android/1.1.0',
      listed: listed,
      current: current,
      createdAt: DateTime.now(),
      lastSeenAt: DateTime.now(),
    );
    expect(onlyDevice([device('a', current: true, listed: true)]), isTrue);
    expect(onlyDevice([device('a', current: true, listed: true), device('b', current: false, listed: false)]), isTrue);
    expect(onlyDevice([device('a', current: true, listed: true), device('b', current: false, listed: true)]), isFalse);
    // Not set up itself, it holds nothing a recovery key would bring back.
    expect(onlyDevice([device('a', current: true, listed: false)]), isFalse);
    expect(onlyDevice(const []), isFalse);
  });

  // The app's own wiring (the desktop's page engine cases): decision 13, deleting a device's data is an act of its
  // own, beside signing out.
  group('the app', () {
    /// The session the app's requests went with, from the first one that had one.
    String sessionOf(TestApp app) =>
        app.seen.map((r) => r.headers['Authorization']).nonNulls.first.replaceFirst('Bearer ', '');

    File databaseOf(TestApp app, String user) => File('${app.support.path}/core/e2e/$user/core.db');

    test(
      'removing_this_device_deletes_its_data_and_signs_out',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final app = await appOn(fake, ana);
        await app.ready();
        final session = sessionOf(app);
        expect(databaseOf(app, ana).existsSync(), isTrue);
        // A decrypted file set aside to share (task 19), which a sign-out leaves for the next start.
        final media = Directory('${app.support.path}/e2e-media');
        File('${media.path}/share/a/shared.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('a decrypted file');

        await app.repository.removeThisDevice();
        // Signed out: the API ended its session.
        expect(app.repository.profile.value, isNull);
        final ended = duvet.E2eApi(
          duvet.RestClient(fake.client, router: fakeRouter, token: session, duvetClient: engineClient),
        ).devices();
        await expectLater(ended, throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 401)));
        // Its data is gone: the database and its key, and every file it decrypted.
        expect(databaseOf(app, ana).existsSync(), isFalse);
        expect(app.keys.keyOf(ana), isNull);
        expect(media.existsSync() ? media.listSync() : const <FileSystemEntity>[], isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'signing_out_leaves_the_device_and_its_database',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final app = await appOn(fake, ana);
        await app.ready();
        final status = await app.core.handle<Map<String, Object?>>({'cmd': 'status'});

        await app.repository.logOut();
        // The session ended, nothing else: the database stays with its key…
        expect(app.repository.profile.value, isNull);
        expect(databaseOf(app, ana).existsSync(), isTrue);
        expect(app.keys.keyOf(ana), isNotNull);
        // …and the API keeps the device on the list: the next sign-in on this phone binds it again, and it's ready.
        await app.repository.logIn('user@duvet.chat', 'secret');
        await until(() => app.repository.encryption.value == EngineState.ready);
        final again = await app.core.handle<Map<String, Object?>>({'cmd': 'status'});
        expect((again['device_id'], again['identity_key']), (status['device_id'], status['identity_key']));
        expect(
          [for (final d in await app.repository.devices()) (d.id, d.listed, d.current)],
          [(status['device_id'], true, true)],
        );
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      "what_the_engine_tells_of_the_user's_devices_shows_in_the_notices'_words",
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final app = await appOn(fake, ana);
        final told = <String>[];
        final heard = app.repository.deviceNotices.listen(told.add);
        addTearDown(heard.cancel);
        await app.ready();

        // Another device of the user's registers.
        final other = testDevice(fake, ana);
        await other.engine.start();
        await other.engine.stop();
        await until(() => told.contains(Notice.deviceAdded.fill({'name': 'Pixel 8 Pro'})));

        // Not seen in 45 days: the app's next engine warns of it.
        fake.lastSeen(other.registered.first, _ago(46));
        await app.repository.logOut();
        await app.repository.logIn('user@duvet.chat', 'secret');
        await until(() => told.contains(Notice.inactiveWarning.fill({'device': 'Pixel 8 Pro'})));
        expect(told, hasLength(2));
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 25's M1: no push tells of a device, so a notice the engine tells while the app is out of sight waits for
    // the app to come to the front.
    test(
      'a_device_notice_heard_out_of_sight_shows_once_the_app_is_in_front',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final app = await appOn(fake, ana);
        final told = <String>[];
        final heard = app.repository.deviceNotices.listen(told.add);
        addTearDown(heard.cancel);
        await app.ready();

        app.repository.wentToBack();
        final other = testDevice(fake, ana);
        await other.engine.start();
        await other.engine.stop();
        // The engine told of it, out of sight: nothing shows.
        final record = File('${app.support.path}/e2e/$ana/client.json');
        await until(() async {
          if (!await record.exists()) return false;
          final added = (jsonDecode(await record.readAsString()) as Map)[toldAdded];
          return added is List && added.contains(other.registered.first);
        });
        await pumpEventQueue();
        expect(told, isEmpty);

        app.repository.cameToFront();
        await until(() => told.isNotEmpty);
        expect(told, [
          Notice.deviceAdded.fill({'name': 'Pixel 8 Pro'}),
        ]);
      },
      skip: noCore,
      timeout: _slow,
    );
  });
}
