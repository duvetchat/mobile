import 'dart:convert';

import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A new device set up with the recovery key (PLAN-E2E-CLIENTES.md, Task 27; decisions 22 and 24): the key as the
// person types it, a mistyped one caught before the API is asked, then what the API keeps for recovery opened, and
// this device listed with its certificate, confirmed only after the API took its list, on real cores through the fake
// API. The desktop's recover.test.ts, but Bun's box: Android has none, so a list that leaves devices out waits for the
// person's Finish, at a start too.
const _slow = Timeout(Duration(minutes: 3));
const _list = (method: 'PUT', path: '/api/users/@me/device-list');
const _backup = 'GET /api/users/@me/identity/backup';

String _said(http.Request request) => '${request.method} ${request.url.path}';

String _deviceOf(TestDevice device) => device.registered.last;

/// The key as a person may type it: in its groups of four, spaces and dashes between them.
String _typed(String key) => [for (var at = 0; at < key.length; at += 4) key.substring(at, at + 4)].join(' - ');

Future<Map<String, Object?>> _status(TestDevice device) => device.host.handle<Map<String, Object?>>({'cmd': 'status'});

List<Object?> _signed(WatchedHost host) => [
  for (final command in host.commands)
    if (command['cmd'] == 'sign_device_list') command['remove'],
];

/// A first device of the user's, and the recovery key it showed before it was saved.
Future<(TestDevice, String)> _withKey(FakeApi fake, String user) async {
  final device = testDevice(fake, user);
  await device.engine.start();
  await device.engine.makeIdentity();
  final key = shownKey(device.state)!;
  await device.engine.keySaved();
  return (device, key);
}

/// Another device of the user's, on a session of its own: a new device, as its start leaves it.
Future<TestDevice> _newDevice(
  FakeApi fake,
  String user, {
  CoreHost? host,
  http.Client? client,
  MemoryStore? store,
}) async {
  final device = testDevice(fake, user, host: host, client: client, store: store);
  await device.engine.start();
  expect(device.state, EngineState.newDevice);
  return device;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'the_recovery_key_is_read_with_spaces_and_dashes,_and_a_mistyped_one_is_caught_before_the_server_is_asked',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final requests = <String>[];
      final client = watchedClient(fake, seen: (request) => requests.add(_said(request)));
      final (a, key) = await _withKey(fake, ana);
      final b = await _newDevice(fake, ana, client: client);
      // One character off: the core's check catches it, and the API is asked for nothing.
      const at = 17;
      final mistyped = key.substring(0, at) + (key[at] == '2' ? '3' : '2') + key.substring(at + 1);
      await expectLater(
        b.engine.recover(_typed(mistyped)),
        throwsA(isA<CoreError>().having((e) => (e.code, e.field), 'refusal', ('bad_command', 'recovery_key'))),
      );
      expect(requests, isNot(contains(_backup)));
      expect(b.state, EngineState.newDevice);

      // As the person types it, in groups with spaces and dashes: it opens the identity, and this device is set up.
      await b.engine.recover(_typed(key));
      expect(requests.where((request) => request == _backup), hasLength(1));
      expect(b.state, EngineState.ready);
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 11: a list confirmed without its upload lets another list of its version in.
  test(
    'recovering_lists_this_device,_uploads_its_certificate_with_the_list,_and_confirms_it',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final timeline = <String>[];
      final lists = <Object?>[];
      final client = watchedClient(
        fake,
        seen: (request) {
          timeline.add(_said(request));
          if (_said(request) == 'PUT ${_list.path}') lists.add(jsonDecode(request.body));
        },
      );
      final (a, key) = await _withKey(fake, ana);
      final b = await _newDevice(fake, ana, client: client, host: WatchedHost(TestHost().gate, timeline));
      await b.engine.recover(key);
      expect(b.state, EngineState.ready);

      // One list, this device's own with its certificate, on top of the version it read.
      final status = await _status(b);
      expect(lists, [
        {'device_list': status['device_list'], 'base_version': 1, 'certificate': status['certificate']},
      ]);
      final served = await b.api.identity(ana);
      expect(listDevices(served.deviceList), unorderedEquals([_deviceOf(a), status['device_id']]));
      expect(served.certificates, contains(status['certificate']));
      expect(
        [
          for (final d in await b.api.devices())
            if (d.current) (d.id, d.listed),
        ],
        [(status['device_id'], true)],
      );
      // Confirmed once the API answered, never before; then this device's key packages.
      final put = timeline.indexOf('PUT ${_list.path}');
      expect(timeline.indexOf('recover'), lessThan(put));
      expect(timeline.indexOf('device_list_uploaded'), greaterThan(put));
      expect(timeline.lastIndexOf('PUT /api/users/@me/devices/@me/key-packages'), greaterThan(put));
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 3: the app dies between the core's recover and the API's answer to the list.
  test(
    "a_recovery_cut_before_its_list's_answer_is_finished_by_the_next_start,_and_confirmed_only_after_a_200",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final (a, key) = await _withKey(fake, ana);
      final log = <String>[];
      final b = await _newDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      // The list never reaches the API: nothing is confirmed, and the device waits to finish.
      fake.cutRequest(_list);
      await expectLater(b.engine.recover(key), throwsA(isA<http.ClientException>()));
      expect(log, isNot(contains('device_list_uploaded')));
      expect(b.state, const EngineState.settingUp(DeviceSetup.finishing()));
      // The app starts again: the same list goes up at the start, with no tap (nothing to ask), and it's set up.
      final again = await restarted(fake, b);
      expect(again.state, EngineState.ready);
      expect(listDevices((await again.api.identity(ana)).deviceList), contains(_deviceOf(again)));

      // Its answer lost this time: the API took it, so the next start finds the device listed and sends nothing.
      final c = await _newDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      fake.loseAnswer(_list);
      log.clear();
      await expectLater(c.engine.recover(key), throwsA(isA<http.ClientException>()));
      expect(log, isNot(contains('device_list_uploaded')));
      final back = await restarted(fake, c);
      expect(back.state, EngineState.ready);
      await Future.wait([a.engine.stop(), again.engine.stop(), back.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 3's closing review: a new password's remove_devices leaves the signed list naming devices the API took away,
  // which a list naming them can't go up with (400 `the list names device …`).
  test(
    "a_recovered_device's_first_list_leaves_out_the_devices_the_API_took_away",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final (a, key) = await _withKey(fake, ana);
      final b = await approvedDevice(fake, a);
      await Future.wait([a.engine.stop(), b.engine.stop()]);
      // A new password, its devices removed: both are gone from the API, and still on the signed list.
      fake
        ..dropDevice(_deviceOf(a))
        ..dropDevice(_deviceOf(b));
      final host = WatchedHost(TestHost().gate, []);
      final c = await _newDevice(fake, ana, host: host);
      await c.engine.recover(key);
      // The app says first which devices go, by what the person can place: their IDs' start, as Settings names them.
      final leavingOut = [
        for (final d in [a, b]) _deviceOf(d).substring(0, 8),
      ]..sort();
      expect(c.state, EngineState.settingUp(DeviceSetup.finishing(leavingOut)));
      expect(_signed(host), isEmpty);
      // Their Finish signs, on top of recover's list, a list without them.
      await c.engine.finishSetup();
      expect(c.state, EngineState.ready);
      expect(_signed(host), [
        unorderedEquals([_deviceOf(a), _deviceOf(b)]),
      ]);
      final served = await c.api.identity(ana);
      expect(listDevices(served.deviceList), [_deviceOf(c)]);
      expect(served.certificates, [(await _status(c))['certificate']]);
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Ruled for Android: with no box of the system's, a first list that leaves devices out waits for the person's tap,
  // at a start too, as the desktop's does.
  test(
    "a_first_list_that_leaves_devices_out_waits_for_the_person's_Finish,_at_a_start_too",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final (a, key) = await _withKey(fake, ana);
      await a.engine.stop();
      fake.dropDevice(_deviceOf(a));
      final log = <String>[];
      final b = await _newDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      await b.engine.recover(key);
      final waiting = EngineState.settingUp(DeviceSetup.finishing([_deviceOf(a).substring(0, 8)]));
      expect(b.state, waiting);
      expect(log, isNot(contains('sign_device_list')));
      // The app starts again: nothing signs by itself, and the list still waits.
      final again = await restarted(fake, b);
      expect(again.state, waiting);
      expect(log, isNot(contains('sign_device_list')));
      // Their Finish signs, and the device is set up.
      await again.engine.finishSetup();
      expect(again.state, EngineState.ready);
      expect(listDevices((await again.api.identity(ana)).deviceList), [_deviceOf(again)]);
      await again.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'the_recovery_key_reaches_no_record,_log_or_request:_only_the_core',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final bodies = <String>[];
      final client = watchedClient(fake, seen: (request) => bodies.add('${request.url} ${request.body}'));
      final (a, key) = await _withKey(fake, ana);
      final logged = <String>[];
      final print = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = print);
      final store = MemoryStore();
      final host = WatchedHost(TestHost().gate, []);
      final b = await _newDevice(fake, ana, host: host, client: client, store: store);
      bodies.clear();
      final mistyped = '${key.substring(0, 47)}${key.endsWith('2') ? '3' : '2'}';
      await expectLater(b.engine.recover(_typed(mistyped)), throwsA(isA<CoreError>()));
      await b.engine.recover(_typed(key));
      await turnEnded(b);
      expect(b.state, EngineState.ready);
      debugPrint('${b.state}');
      for (final form in [key, _typed(key), mistyped, _typed(mistyped)]) {
        for (final where in [bodies, logged, store.kept.values]) {
          expect(where.join('\n'), isNot(contains(form)));
        }
      }
      // Where it goes: recover's commands alone.
      final carrying = [
        for (final command in host.commands)
          if (jsonEncode(command).contains(_typed(key))) command['cmd'],
      ];
      expect(carrying, isNotEmpty);
      expect(carrying.toSet(), {'recover'});
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );
}
