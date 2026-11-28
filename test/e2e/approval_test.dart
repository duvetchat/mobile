import 'dart:convert';

import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/devices.dart' show takenAway;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/encryption/approval.dart' show deviceUnfinished;
import 'package:duvet/encryption/devices.dart' show devicesRefusal;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A new device approved by another of the user's (PLAN-E2E-CLIENTES.md, Task 27; decision 24), on real cores through
// the fake API: the new device's QR, which a phone of the user's scans, or its commitment and the code the approving
// device shows, which the person types into the new one; the approving device offers only on the person's tap and
// confirms only on their Confirm. The desktop's approval.test.ts, case for case, and the scan the desktop doesn't have.
const _slow = Timeout(Duration(minutes: 3));
final _fingerprint = matches(RegExp(r'^[0-9a-f]{4}( [0-9a-f]{4}){3}$'));

String _deviceOf(TestDevice device) => device.registered.last;

DeviceSetup? _setupOf(EngineState state) => state.stage == EngineStage.newDevice ? state.setup : null;

DeviceApproval? _approvalOf(EngineState state) => state.stage == EngineStage.ready ? state.approval : null;

/// The question an approving device shows, which the person's yes answers.
String _questionOf(TestDevice device) => _approvalOf(device.state)?.question ?? '';

/// The new device's code's way, once an approving device's offer was taken.
bool _offered(TestDevice device) {
  final setup = _setupOf(device.state);
  return setup?.way == SetupWay.code && setup!.offered;
}

String? _qrOf(TestDevice device) {
  final setup = _setupOf(device.state);
  return setup?.way == SetupWay.qr ? setup!.qr : null;
}

/// The approval frames the device's record keeps, by their step.
List<ApprovalStep?> _keptSteps(TestDevice device) => [
  for (final kept in switch (device.store.read(keptApprovals)) {
    final List<Object?> list => list,
    _ => const <Object?>[],
  })
    readApprovalFrame((kept! as Map)['message'] as String)?.step,
];

/// The commands of a kind a device's host was asked, in order.
List<Map<String, Object?>> _asked(WatchedHost host, String cmd) => [
  for (final command in host.commands)
    if (command['cmd'] == cmd) command,
];

Future<List<String>> _heldList(TestDevice device) async =>
    listDevices((await device.host.handle<Map<String, Object?>>({'cmd': 'status'}))['device_list']! as String)!;

/// Another device of the user's, on a session of its own: a new device, as its start leaves it.
Future<TestDevice> _newDevice(
  FakeApi fake,
  String user, {
  CoreHost? host,
  bool Function(GatewayEvent event)? hears,
}) async {
  final device = testDevice(fake, user, host: host, hears: hears);
  await device.engine.start();
  expect(device.state, EngineState.newDevice);
  return device;
}

/// The new device asks by its code, and the approving device, on the person's yes, shows the code: what it shows.
Future<String> _toTheCode(TestDevice approver, TestDevice fresh) async {
  await fresh.engine.beginApproval();
  await fresh.engine.useCode();
  final fingerprint = _setupOf(fresh.state)!.fingerprint;
  await until(() => _approvalOf(approver.state)?.fingerprint == fingerprint);
  await approver.engine.approveDevice(_deviceOf(fresh), _questionOf(approver));
  await until(() => _approvalOf(approver.state)?.phase == ApprovalPhase.code);
  await until(() => _offered(fresh));
  return _approvalOf(approver.state)!.code!;
}

/// Another six digits than these.
String _otherThan(String code) => ((int.parse(code) + 1) % 1000000).toString().padLeft(6, '0');

final _waits = isA<CoreError>().having((e) => e.code, 'code', 'approval_waits');

/// The bodies of what a device's client sent to the inbox of the device [to] names (none until it names one), in
/// order, those cut on their way included.
http.Client _inboxOf(FakeApi fake, String? Function() to, List<String> bodies) => watchedClient(
  fake,
  seen: (request) {
    if (to() case final device? when request.method == 'POST' && request.url.path == '/api/devices/$device/inbox') {
      bodies.add(request.body);
    }
  },
);

/// A server that lies to one device (its [client]) once [lying]: the user's identity as it served it at [freeze] (a
/// list from before), when frozen, and the user's devices without [hidden].
class _Lies {
  _Lies(FakeApi fake) {
    client = watchedClient(
      fake,
      change: (request, answered) async {
        final path = request.url.path;
        if (request.method != 'GET') return answered;
        if (RegExp(r'^/api/users/[^/@]+/identity$').hasMatch(path)) {
          if (lying && frozen != null) return frozen!;
          latest = answered;
        }
        if (lying && path == '/api/users/@me/devices') {
          final devices = [
            for (final device in jsonDecode(answered.body) as List<Object?>)
              if (!hidden.contains((device! as Map)['id'])) device,
          ];
          return http.Response(jsonEncode(devices), 200, headers: answered.headers);
        }
        return answered;
      },
    );
  }

  late final http.Client client;
  http.Response? latest;
  http.Response? frozen;
  var lying = false;
  var hidden = <String>{};

  /// The identity as it was served last, served from now on while lying.
  void freeze() => frozen = latest;
}

/// A core whose approval_confirm names another device than the one it approved ([other], once set): the device the
/// transfer goes to is the core's word, not the inbox's.
class _ConfirmsAnother extends WatchedHost {
  _ConfirmsAnother(CoreHost host) : super(host, []);

  String? other;

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    final answer = await super.handle<T>(command);
    final named = other;
    if (command['cmd'] != 'approval_confirm' || named == null) return answer;
    return {...(answer! as Map<String, Object?>), 'device_id': named} as T;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "approval_by_code:_the_new_device_takes_only_the_approver's_code,_and_the_approver_confirms_after",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      // The new device shows its QR first; the code is the other way, an attempt of its own.
      await n.engine.beginApproval();
      expect(_qrOf(n), isA<String>());
      await n.engine.useCode();
      final setup = _setupOf(n.state)!;
      expect((setup.way, setup.offered, setup.accepted), (SetupWay.code, false, false));
      expect(setup.fingerprint, _fingerprint);

      // The approving device asks the person, naming the new device and showing the same fingerprint, about the
      // commitment's inbox message, which the yes answers.
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      expect(_questionOf(a), isNotEmpty);
      expect(
        _approvalOf(a.state),
        DeviceApproval(
          device: _deviceOf(n),
          name: 'Pixel 8 Pro',
          fingerprint: setup.fingerprint!,
          phase: ApprovalPhase.asked,
          question: _questionOf(a),
        ),
      );
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.code);
      final code = _approvalOf(a.state)!.code!;
      expect(code, matches(RegExp(r'^\d{6}$')));
      await until(() => _offered(n));

      // Any other code is refused, and the attempt goes on; the approver's is accepted.
      await expectLater(
        n.engine.acceptCode(_otherThan(code)),
        throwsA(isA<CoreError>().having((e) => (e.code, e.rule), 'refusal', ('rule_violation', 'code_mismatch'))),
      );
      expect(_setupOf(n.state), DeviceSetup.code(setup.fingerprint!, offered: true));
      await n.engine.acceptCode(code);
      expect(_setupOf(n.state), DeviceSetup.code(setup.fingerprint!, offered: true, accepted: true));

      // The approver confirms after: the new device takes the transfer, and goes on as with the recovery key.
      await a.engine.confirmApproval(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      final served = await n.api.identity(ana);
      expect(listDevices(served.deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      expect(served.certificates, hasLength(2));
      // Its list up, the approving device lets go of the approval.
      await until(() => _approvalOf(a.state) == null);
      expect(a.state, EngineState.ready);
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "an_offer_is_made_only_on_the_person's_tap",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      await turnEnded(a);
      expect(log, isNot(contains('approval_offer')));
      // The person's no: nothing is offered, and the question goes.
      await a.engine.declineDevice(_deviceOf(n));
      expect(_approvalOf(a.state), isNull);
      expect(log, isNot(contains('approval_offer')));

      // The new device asks again, and the app starts again before the person answers: still nothing offered.
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      final again = await restarted(fake, a);
      await until(() => _approvalOf(again.state)?.phase == ApprovalPhase.asked);
      expect(log, isNot(contains('approval_offer')));
      await again.engine.approveDevice(_deviceOf(n), _questionOf(again));
      expect(log.where((cmd) => cmd == 'approval_offer'), hasLength(1));

      // Confirm too runs on the person's tap alone: Android has no box of the system's, and the app's Confirm, beside
      // the fingerprint, is the person's act.
      await until(() => _approvalOf(again.state)?.phase == ApprovalPhase.code);
      final code = _approvalOf(again.state)!.code!;
      await n.engine.acceptCode(code);
      await turnEnded(again);
      expect(log, isNot(contains('approval_confirm')));
      await again.engine.confirmApproval(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      expect(log.where((cmd) => cmd == 'approval_confirm'), hasLength(1));
      await Future.wait([again.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "the_code's_field_is_never_filled_in",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final store = MemoryStore();
      final n = testDevice(fake, ana, store: store);
      await n.engine.start();
      final code = await _toTheCode(a, n);
      await turnEnded(n);
      // The new device keeps its own code in its core alone: nothing it shows or keeps holds the approver's.
      expect('${n.state}', isNot(contains(code)));
      expect(store.kept.values.join(), isNot(contains(code)));
      final setup = _setupOf(n.state)!;
      expect(setup, DeviceSetup.code(setup.fingerprint!, offered: true));
      expect(setup.fingerprint, _fingerprint);
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_transfer_that_came_before_the_code_is_kept,_and_taken_after_it',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      final code = await _toTheCode(a, n);
      // The person confirms on the approving device before they type the code into the new one.
      await a.engine.confirmApproval(_deviceOf(n));
      await until(() => _keptSteps(n).contains(ApprovalStep.transfer));
      await turnEnded(n);
      expect(n.state.stage, EngineStage.newDevice);
      expect((_setupOf(n.state)?.way, _setupOf(n.state)?.accepted), (SetupWay.code, false));
      // Their code, typed: the kept transfer is taken, and the device is set up.
      await n.engine.acceptCode(code);
      await until(() => n.state == EngineState.ready);
      expect(listDevices((await n.api.identity(ana)).deviceList), contains(_deviceOf(n)));
      expect(_keptSteps(n), isNot(contains(ApprovalStep.transfer)));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'an_attempt_past_ten_minutes_starts_over',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      // The QR is made again before its attempt's ten minutes end.
      await n.engine.beginApproval();
      final first = _qrOf(n);
      n.clock.advance(const Duration(minutes: 9));
      await turnEnded(n);
      final renewed = _qrOf(n);
      expect(renewed, isA<String>());
      expect(renewed, isNot(first));

      // By the code, an attempt not done in its ten minutes starts over, with a new QR.
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      n.clock.advance(attemptLife);
      await turnEnded(n);
      final over = _qrOf(n);
      expect(over, isA<String>());
      expect([first, renewed], isNot(contains(over)));

      // The approving device's own attempt ends ten minutes after its offer: its question says so (M1).
      await n.engine.useCode();
      final fingerprint = _setupOf(n.state)!.fingerprint;
      await until(() => _approvalOf(a.state)?.fingerprint == fingerprint);
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(_approvalOf(a.state)?.phase, isNot(ApprovalPhase.asked));
      a.clock.advance(attemptLife);
      await turnEnded(a);
      expect((_approvalOf(a.state)?.phase, _approvalOf(a.state)?.ended), (ApprovalPhase.ended, ApprovalEnd.over));
      await a.engine.declineDevice(_deviceOf(n));
      expect(_approvalOf(a.state), isNull);
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'approval_by_QR_needs_no_code',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final qr = _qrOf(n)!;
      // A device that approves from the QR sends its transfer to the new device, which takes it with no code.
      final approved = await a.host.handle<Map<String, Object?>>({'cmd': 'approval_from_qr', 'qr': qr});
      expect(approved['device_id'], _deviceOf(n));
      await a.api.sendToDevice(
        _deviceOf(n),
        approvalFrameMessage((step: ApprovalStep.transfer, data: approved['transfer']! as String, name: null)),
      );
      await until(() => n.state == EngineState.ready);
      expect(listDevices((await n.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // The phone's scan (Ruling 21; review 26's rules for task 27): the QR names the device, which the person is asked
  // about before anything is approved; then the text as it was scanned goes to approval_from_qr, its transfer to the
  // device its reply names (e2e#52), and this device's lists wait for that device's.
  test(
    'a_scanned_qr_approves_without_a_code',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final host = WatchedHost(TestHost().gate, []);
      final a = await firstDevice(fake, ana, host: host);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final qr = _qrOf(n)!;
      expect(qrDevice(qr), _deviceOf(n));

      // What the scan names, before anything is approved: the new device, by its name among the user's devices.
      final scanned = await a.engine.scannedDevice(qr);
      expect(scanned, (id: _deviceOf(n), name: 'Pixel 8 Pro', listed: false, unfinished: false));
      expect(_asked(host, 'approval_from_qr'), isEmpty);
      // A text that isn't an approval's QR names none.
      expect(await a.engine.scannedDevice('not a code'), isNull);

      // The person's yes: approved from the text as it was scanned, the transfer to that device, which needs no code.
      expect(await a.engine.approveScanned(qr, scanned!), isTrue);
      expect(_asked(host, 'approval_from_qr').map((command) => command['qr']), [qr]);
      expect(_asked(host, 'approval_offer'), isEmpty);
      await until(() => n.state == EngineState.ready);
      expect(listDevices((await n.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      // Its list up, the approving device's changes go on; scanned again, the device is set up already.
      await until(() => _approvalOf(a.state) == null);
      expect((await a.engine.scannedDevice(qr))?.listed, isTrue);
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 24's review, M2: until the new device's list goes up, it has no certificate of the identity, so it's no device
  // the API took away (GET …/devices still has it), and a list or a change of keys made meanwhile would leave it out.
  test(
    "a_device_this_one_approved_isn't_taken_for_one_the_API_took_away,_and_list_and_key_changes_wait_for_its_list",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final b = await approvedDevice(fake, a);
      var reading = true;
      final n = await _newDevice(fake, ana, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      final code = await _toTheCode(a, n);
      await n.engine.acceptCode(code);
      // The new device doesn't read its inbox for now: its transfer waits there.
      reading = false;
      await a.engine.confirmApproval(_deviceOf(n));
      expect((_approvalOf(a.state)?.device, _approvalOf(a.state)?.phase), (_deviceOf(n), ApprovalPhase.confirmed));
      final status = await a.host.handle<Map<String, Object?>>({'cmd': 'status'});
      expect(listDevices(status['device_list']! as String), contains(_deviceOf(n)));
      expect(await takenAway(a.engine, status['device_list']! as String), isEmpty);
      final waits = isA<CoreError>().having((e) => e.code, 'code', 'approval_waits');
      await expectLater(a.engine.removeDevice(_deviceOf(b)), throwsA(waits));
      await expectLater(a.engine.changeKeys(), throwsA(waits));

      // The new device reads its inbox at its next READY: its list goes up, and the approving device's changes go on.
      reading = true;
      n.connect(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      await until(() => _approvalOf(a.state) == null);
      await a.engine.removeDevice(_deviceOf(b));
      expect(listDevices((await a.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      await Future.wait([a.engine.stop(), b.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 24's round 2: a change of keys under way makes the identity a new one the API doesn't have yet.
  test(
    "a_device_whose_change_of_keys_waits_approves_no_device_until_it's_done",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      await a.engine.changeKeys();
      expect(a.state.rotating, isTrue);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      await n.engine.useCode();
      await until(() => _keptSteps(a).contains(ApprovalStep.commitment));
      expect(_approvalOf(a.state), isNull);
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(log, isNot(contains('approval_offer')));
      // The change done, the new device's question shows.
      await a.engine.keySaved();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 26's I1: approval_confirm put the new device on this device's list, and its transfer was never taken (the
  // setup opened again, a Cancel after a failed send, the new device's restart): the core's way out is to take it off
  // this list and approve it again.
  test(
    "a_confirmed_approval_whose_transfer_isn't_taken:_the_device_comes_off_the_list,_and_a_fresh_approval_completes",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final host = WatchedHost(TestHost().gate, []);
      final a = await firstDevice(fake, ana, host: host);
      var reading = true;
      final n = await _newDevice(fake, ana, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      await _toTheCode(a, n);
      // Confirmed before the code was typed, and the setup opened again: the new attempt can't take that transfer.
      reading = false;
      await a.engine.confirmApproval(_deviceOf(n));
      await n.engine.useCode();
      // The new attempt's question says the device comes off this device's list first.
      final fingerprint = _setupOf(n.state)!.fingerprint;
      await until(() => _approvalOf(a.state)?.fingerprint == fingerprint);
      expect((_approvalOf(a.state)?.device, _approvalOf(a.state)?.unfinished), (_deviceOf(n), true));
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(_asked(host, 'sign_device_list').map((command) => command['remove']), [
        [_deviceOf(n)],
      ]);
      expect(await _heldList(a), [_deviceOf(a)]);

      // Its changes no longer wait for it, and the fresh approval completes.
      reading = true;
      n.connect(_deviceOf(n));
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.code);
      await until(() => _offered(n));
      await n.engine.acceptCode(_approvalOf(a.state)!.code!);
      await a.engine.confirmApproval(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      expect(listDevices((await n.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 5's review, I1 (mobile#352): what didn't finish is this device's own record, never the API's word. A listed
  // device's request, replayed while the server serves a list from before that device, and its devices without it,
  // asks only «Is this device yours?», and the yes changes no list: by the code, and by the scan.
  test(
    "a_listed_device's_request,_while_the_served_list_and_the_devices_leave_it_out,_changes_no_list_on_the_yes",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final lies = _Lies(fake);
      final host = WatchedHost(TestHost().gate, []);
      final a = await firstDevice(fake, ana, host: host, client: lies.client);
      // The list naming this device alone, kept to serve later.
      lies.freeze();
      // B, approved here by the code: its list up, which this device observed.
      final b = await _newDevice(fake, ana);
      await b.engine.beginApproval();
      final qr = _qrOf(b)!;
      await b.engine.acceptCode(await _toTheCode(a, b));
      await a.engine.confirmApproval(_deviceOf(b));
      await until(() => b.state == EngineState.ready);
      await until(() => _approvalOf(a.state) == null);
      await turnEnded(a);
      expect(await _heldList(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));

      // The server lies from now on, and replays the request B was set up by.
      lies
        ..lying = true
        ..hidden = {_deviceOf(b)};
      fake.replayInbox(_deviceOf(a));
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      expect((_approvalOf(a.state)?.device, _approvalOf(a.state)?.unfinished), (_deviceOf(b), false));
      await a.engine.approveDevice(_deviceOf(b), _questionOf(a));
      expect(_asked(host, 'sign_device_list'), isEmpty);
      expect(await _heldList(a), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      // The core approves no device on its list.
      expect((_approvalOf(a.state)?.phase, _approvalOf(a.state)?.ended), (ApprovalPhase.ended, ApprovalEnd.listed));
      await a.engine.declineDevice(_deviceOf(b));

      // B's QR from before it was set up, scanned while only the served list leaves it out: the same.
      lies.hidden = {};
      final scanned = await a.engine.scannedDevice(qr);
      expect((scanned?.id, scanned?.unfinished), (_deviceOf(b), false));
      await expectLater(
        a.engine.approveScanned(qr, scanned!),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'exists')),
      );
      expect(_asked(host, 'sign_device_list'), isEmpty);
      expect(listDevices((await b.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(b)]));
      await Future.wait([a.engine.stop(), b.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // mobile#352 too: the way out of an approval that didn't finish signs off that device and no other, whatever the
  // API says of the user's other devices.
  test(
    "an_unfinished_approval's_way_out_signs_off_that_device_alone",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final lies = _Lies(fake);
      final host = WatchedHost(TestHost().gate, []);
      final a = await firstDevice(fake, ana, host: host, client: lies.client);
      final c = await approvedDevice(fake, a);
      var reading = true;
      final n = await _newDevice(fake, ana, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      await _toTheCode(a, n);
      reading = false;
      await a.engine.confirmApproval(_deviceOf(n));
      await n.engine.useCode();
      final fingerprint = _setupOf(n.state)!.fingerprint;
      await until(() => _approvalOf(a.state)?.fingerprint == fingerprint);
      expect(_approvalOf(a.state)?.unfinished, isTrue);

      // The API's devices leave C out as the yes runs: C stays on the list all the same.
      lies
        ..lying = true
        ..hidden = {_deviceOf(c)};
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(_asked(host, 'sign_device_list').map((command) => command['remove']), [
        [_deviceOf(n)],
      ]);
      expect(listDevices((await c.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(c)]));
      await Future.wait([a.engine.stop(), c.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 5's review, M1 (mobile#355): the yes offered to the question's commitment while a newer attempt of the
  // device's waited in the record, before the take that keeps the newest alone; the new device then dropped the offer.
  test(
    'a_yes_to_a_question_a_newer_attempt_replaced_offers_nothing,_and_the_newer_one_waits_for_its_own_yes',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final host = WatchedHost(TestHost().gate, []);
      var reading = true;
      final a = await firstDevice(fake, ana, host: host, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      final first = _approvalOf(a.state)!;
      // The new device begins again: its newer commitment is in the record, as an inbox's round keeps every frame, and
      // the take that asks of it hasn't run.
      reading = false;
      await n.engine.useCode();
      await until(() async => (await a.api.inbox()).length == 1);
      final newer = (await a.api.inbox()).single;
      await a.store.write(keptApprovals, [
        ...a.store.read(keptApprovals)! as List<Object?>,
        {
          'id': newer.id,
          'from_user_id': newer.fromUserId,
          'from_device_id': newer.fromDeviceId,
          'message': newer.message,
          'created_at': newer.createdAt.toUtc().toIso8601String(),
        },
      ]);
      await a.api.clearInbox(newer.id);
      reading = true;

      // The person's yes to the question shown offers nothing, and the newer attempt is asked of.
      await a.engine.approveDevice(_deviceOf(n), first.question!);
      expect(_asked(host, 'approval_offer'), isEmpty);
      final second = _approvalOf(a.state)!;
      expect((second.device, second.phase, second.question), (_deviceOf(n), ApprovalPhase.asked, newer.id));
      expect(second.fingerprint, isNot(first.fingerprint));
      // Its own yes offers to it, and the new device takes that offer.
      await a.engine.approveDevice(_deviceOf(n), second.question!);
      expect(_asked(host, 'approval_offer'), hasLength(1));
      await until(() => _offered(n));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // mobile#355, with step 5's review M1: a yes that met an identity this device doesn't hold read the inbox, whose
  // newer commitment of the device's replaced the question, and was tried again at once on that new question: an offer
  // to a fingerprint the person never saw.
  test(
    'a_yes_tried_again_after_the_inbox_offers_only_to_the_question_it_answered',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      var replaced = false;
      final host = WatchedHost(
        TestHost().gate,
        [],
        answer: (command) {
          if (!replaced || command['cmd'] != 'observe_user' || command['user_id'] != ana) return null;
          replaced = false;
          return {'state': 'rejected', 'verified': true, 'reason': 'not_own_identity'};
        },
      );
      var reading = true;
      final a = await firstDevice(fake, ana, host: host, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      final first = _approvalOf(a.state)!;
      // The new device begins again, and its newer commitment waits in the inbox, which the yes reads.
      reading = false;
      await n.engine.useCode();
      await until(() async => (await a.api.inbox()).length == 1);
      reading = true;
      replaced = true;
      await a.engine.approveDevice(_deviceOf(n), first.question!);
      expect(_asked(host, 'approval_offer'), isEmpty);
      final second = _approvalOf(a.state)!;
      expect(second.phase, ApprovalPhase.asked);
      expect(second.fingerprint, isNot(first.fingerprint));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 26's M1: the approving app started again while it showed the code. Its question comes back, and the kept
  // reveal gives the same code once the yes offers again (the same offer, as the core gives it).
  test(
    'the_approving_device_still_confirms_after_its_app_started_again_at_the_code',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      final code = await _toTheCode(a, n);
      final again = await restarted(fake, a);
      await until(() => _approvalOf(again.state)?.phase == ApprovalPhase.asked);
      await again.engine.approveDevice(_deviceOf(n), _questionOf(again));
      await until(() => _approvalOf(again.state)?.phase == ApprovalPhase.code);
      expect(_approvalOf(again.state)?.code, code);
      await n.engine.acceptCode(code);
      await again.engine.confirmApproval(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      await Future.wait([again.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 26's M2: the question ends with the new device's attempt, by the engine's clock.
  test(
    "«Is_this_device_yours?»_goes_once_the_new_device's_attempt_is_over",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      a.clock.advance(const Duration(minutes: 9));
      await turnEnded(a);
      expect(_approvalOf(a.state)?.phase, ApprovalPhase.asked);
      a.clock.advance(const Duration(minutes: 1));
      await turnEnded(a);
      expect(_approvalOf(a.state), isNull);
      expect(_keptSteps(a), isNot(contains(ApprovalStep.commitment)));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 26's M3: the code's attempt replaces the QR's in the core, so the QR on screen would open nothing.
  test(
    'a_code_attempt_no_device_got_shows_a_new_QR',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final first = _qrOf(n);
      fake.cutRequest((method: 'POST', path: '/api/devices/${_deviceOf(a)}/inbox'));
      await expectLater(
        n.engine.useCode(),
        throwsA(isA<CoreError>().having((e) => (e.code, e.what), 'refusal', ('not_found', 'approver'))),
      );
      final shown = _qrOf(n);
      expect(shown, isA<String>());
      expect(shown, isNot(first));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 26's M5: between another device's change of keys and this one taking its transfer, an offer, or an approval
  // from a scanned QR, would certify the new device under the identity it replaced.
  test(
    'the_approving_device_offers_nothing_while_the_identity_it_holds_was_replaced',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      var replaced = false;
      final host = WatchedHost(
        TestHost().gate,
        log,
        answer: (command) => replaced && command['cmd'] == 'observe_user' && command['user_id'] == ana
            ? {'state': 'rejected', 'verified': true, 'reason': 'not_own_identity'}
            : null,
      );
      final a = await firstDevice(fake, ana, host: host);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final qr = _qrOf(n)!;
      final scanned = (await a.engine.scannedDevice(qr))!;
      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      replaced = true;
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(log, isNot(contains('approval_offer')));
      expect(_approvalOf(a.state)?.phase, ApprovalPhase.asked);
      await expectLater(a.engine.approveScanned(qr, scanned), throwsA(isA<StateError>()));
      expect(log, isNot(contains('approval_from_qr')));
      // Its identity the API's again: the yes offers.
      replaced = false;
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      expect(log, contains('approval_offer'));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M2: what the scan's Try again does goes by the transfer it has to send, not by what the state shows:
  // once its hold ended, none waits, and the person is told to scan again, nothing sent.
  test(
    "a_scanned_device's_try_again_sends_only_a_transfer_that_still_waits",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final bodies = <String>[];
      String? to;
      final a = await firstDevice(fake, ana, client: _inboxOf(fake, () => to, bodies));
      final n = await _newDevice(fake, ana);
      to = _deviceOf(n);
      // Another new device's question up meanwhile, which the state shows before the approval that waits.
      final other = await _newDevice(fake, ana);
      await other.engine.beginApproval();
      await other.engine.useCode();
      await until(() => _approvalOf(a.state)?.device == _deviceOf(other));
      await n.engine.beginApproval();
      final qr = _qrOf(n)!;
      final scanned = (await a.engine.scannedDevice(qr))!;
      fake.cutRequest((method: 'POST', path: '/api/devices/${_deviceOf(n)}/inbox'));
      // Approved, its send failed: the engine says the transfer waits, whatever the state shows first.
      expect(await a.engine.approveScanned(qr, scanned), isFalse);
      // Its hold's ten minutes pass: no transfer waits any more, and a Try again sends nothing and says so.
      a.clock.advance(attemptLife);
      await turnEnded(a);
      await expectLater(
        a.engine.sendScanned(_deviceOf(n)),
        throwsA(isA<CoreError>().having((e) => (e.code, e.what), 'refusal', ('not_found', 'transfer'))),
      );
      expect(bodies, hasLength(1));
      await Future.wait([a.engine.stop(), n.engine.stop(), other.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M5: this device approves one new device at a time. While one it approved hasn't put up its list,
  // another's scan is refused and its question waits: that one's transfer would carry the list naming the first
  // without its certificate, and the hold would then wait for it alone.
  test(
    "while_a_device_this_one_approved_sets_up,_another_one's_scan_is_refused_and_its_question_waits",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      var reading = true;
      final n = await _newDevice(fake, ana, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      await n.engine.acceptCode(await _toTheCode(a, n));
      reading = false;
      await a.engine.confirmApproval(_deviceOf(n));
      final other = await _newDevice(fake, ana);
      await other.engine.beginApproval();
      final qr = _qrOf(other)!;
      final scanned = (await a.engine.scannedDevice(qr))!;
      await expectLater(a.engine.approveScanned(qr, scanned), throwsA(_waits));
      expect(log, isNot(contains('approval_from_qr')));
      await other.engine.useCode();
      await until(() => _keptSteps(a).contains(ApprovalStep.commitment));
      await turnEnded(a);
      expect((_approvalOf(a.state)?.device, _approvalOf(a.state)?.phase), (_deviceOf(n), ApprovalPhase.confirmed));

      // The first one's list up, the other one is asked.
      reading = true;
      n.connect(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      await until(() => _approvalOf(a.state)?.device == _deviceOf(other));
      expect(_approvalOf(a.state)?.phase, ApprovalPhase.asked);
      await Future.wait([a.engine.stop(), n.engine.stop(), other.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 too: a question asked before a scan's approval began goes no further while that one sets up: neither its yes's
  // offer nor its Confirm.
  test(
    "a_question_asked_before_a_scan's_approval_goes_no_further_until_that_device_is_set_up",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      final asking = await _newDevice(fake, ana);
      await asking.engine.beginApproval();
      await asking.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      // A new device a scans and approves, which reads its inbox only as it connects again: its list waits till then.
      Future<TestDevice> scannedAndWaiting() async {
        final scanned = await _newDevice(fake, ana, hears: (event) => event.type != 'DEVICE_MESSAGE');
        await scanned.engine.beginApproval();
        final qr = _qrOf(scanned)!;
        await a.engine.approveScanned(qr, (await a.engine.scannedDevice(qr))!);
        return scanned;
      }

      final first = await scannedAndWaiting();
      await expectLater(a.engine.approveDevice(_deviceOf(asking), _questionOf(a)), throwsA(_waits));
      expect(log, isNot(contains('approval_offer')));

      // That one set up, the yes offers; another scan's approval waiting, the Confirm goes no further.
      first.connect(_deviceOf(first));
      await until(() => first.state == EngineState.ready);
      await turnEnded(a);
      await a.engine.approveDevice(_deviceOf(asking), _questionOf(a));
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.code);
      await until(() => _offered(asking));
      await asking.engine.acceptCode(_approvalOf(a.state)!.code!);
      final second = await scannedAndWaiting();
      await expectLater(a.engine.confirmApproval(_deviceOf(asking)), throwsA(_waits));
      expect(log, isNot(contains('approval_confirm')));
      await Future.wait([a.engine.stop(), asking.engine.stop(), first.engine.stop(), second.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M6: the API names an inbox message's sender. A commitment that names another device than its sender
  // asks nothing: the person would be asked about one device, and the yes would offer to, and unlist, another.
  test(
    'a_commitment_that_names_another_device_than_its_sender_asks_nothing',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      final n = await _newDevice(fake, ana);
      final relay = await _newDevice(fake, ana);
      final begun = await n.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
      await relay.api.sendToDevice(
        _deviceOf(a),
        approvalFrameMessage((
          step: ApprovalStep.commitment,
          data: begun['commitment']! as String,
          name: 'Pixel 8 Pro',
        )),
      );
      await until(() async => (await a.api.inbox()).isEmpty);
      await turnEnded(a);
      expect(_approvalOf(a.state), isNull);
      expect(_keptSteps(a), isEmpty);
      await Future.wait([a.engine.stop(), n.engine.stop(), relay.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M6 too: the transfer goes to, and the hold waits for, the device the core approved (approval_confirm's device_id,
  // as the scan's), not the inbox's sender.
  test(
    'a_confirmed_transfer_goes_to_the_device_the_core_approved',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final host = _ConfirmsAnother(TestHost().gate);
      final bodies = <String>[];
      String? to;
      final a = await firstDevice(fake, ana, host: host, client: _inboxOf(fake, () => to, bodies));
      final b = await approvedDevice(fake, a);
      var reading = true;
      final n = await _newDevice(fake, ana, hears: (event) => reading || event.type != 'DEVICE_MESSAGE');
      await n.engine.acceptCode(await _toTheCode(a, n));
      reading = false;
      host.other = _deviceOf(b);
      to = _deviceOf(b);
      await a.engine.confirmApproval(_deviceOf(n));
      expect(bodies, hasLength(1));
      expect((_approvalOf(a.state)?.device, _approvalOf(a.state)?.phase), (_deviceOf(b), ApprovalPhase.confirmed));
      await Future.wait([a.engine.stop(), b.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M4 and M8: a Cancel after a transfer's send failed leaves the device on this device's list with no
  // certificate the API serves (review 26's I1). A change of keys can't keep it, and says why; the new device asking
  // again comes off the list first, and the fresh approval completes.
  test(
    "a_cancel_after_a_failed_send_leaves_the_device_to_approve_again,_and_a_key_change_says_why_it_can't_go",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final host = WatchedHost(TestHost().gate, []);
      final a = await firstDevice(fake, ana, host: host);
      final n = await _newDevice(fake, ana);
      await n.engine.acceptCode(await _toTheCode(a, n));
      fake.cutRequest((method: 'POST', path: '/api/devices/${_deviceOf(n)}/inbox'));
      await expectLater(a.engine.confirmApproval(_deviceOf(n)), throwsA(anything));
      await a.engine.declineDevice(_deviceOf(n));
      expect(_approvalOf(a.state), isNull);
      expect(await _heldList(a), contains(_deviceOf(n)));
      final refused = await a.engine.changeKeys().then<Object?>((_) => null, onError: (Object error) => error);
      expect(refused, isA<CoreError>().having((e) => (e.code, e.field), 'refusal', ('bad_command', 'certificates')));
      expect(devicesRefusal(refused!), deviceUnfinished);

      await n.engine.useCode();
      final fingerprint = _setupOf(n.state)!.fingerprint;
      await until(() => _approvalOf(a.state)?.fingerprint == fingerprint);
      expect(_approvalOf(a.state)?.unfinished, isTrue);
      await a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.code);
      await until(() => _offered(n));
      await n.engine.acceptCode(_approvalOf(a.state)!.code!);
      await a.engine.confirmApproval(_deviceOf(n));
      await until(() => n.state == EngineState.ready);
      expect(listDevices((await n.api.identity(ana)).deviceList), unorderedEquals([_deviceOf(a), _deviceOf(n)]));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M8: a transfer whose send failed goes again as it was, by the code and by the scan. The core approves
  // once: a second approval_confirm or approval_from_qr would be its `exists`, so the kept bytes are the only resend.
  test(
    'a_transfer_whose_send_failed_goes_again_as_it_was,_by_the_code_and_by_the_scan',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final bodies = <String>[];
      String? to;
      final a = await firstDevice(
        fake,
        ana,
        host: WatchedHost(TestHost().gate, log),
        client: _inboxOf(fake, () => to, bodies),
      );
      final n = await _newDevice(fake, ana);
      to = _deviceOf(n);
      await n.engine.acceptCode(await _toTheCode(a, n));
      bodies.clear();
      fake.cutRequest((method: 'POST', path: '/api/devices/${_deviceOf(n)}/inbox'));
      await expectLater(a.engine.confirmApproval(_deviceOf(n)), throwsA(anything));
      await a.engine.confirmApproval(_deviceOf(n));
      expect(log.where((cmd) => cmd == 'approval_confirm'), hasLength(1));
      expect(bodies, hasLength(2));
      expect(bodies.last, bodies.first);
      await until(() => n.state == EngineState.ready);
      await until(() => _approvalOf(a.state) == null);

      final m = await _newDevice(fake, ana);
      to = _deviceOf(m);
      await m.engine.beginApproval();
      final qr = _qrOf(m)!;
      final scanned = (await a.engine.scannedDevice(qr))!;
      bodies.clear();
      fake.cutRequest((method: 'POST', path: '/api/devices/${_deviceOf(m)}/inbox'));
      expect(await a.engine.approveScanned(qr, scanned), isFalse);
      await a.engine.sendScanned(_deviceOf(m));
      expect(log.where((cmd) => cmd == 'approval_from_qr'), hasLength(1));
      expect(bodies, hasLength(2));
      expect(bodies.last, bodies.first);
      await until(() => m.state == EngineState.ready);
      await Future.wait([a.engine.stop(), n.engine.stop(), m.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M8 too: the core reads the QR itself. Its reply naming another device than the one the person was asked about
  // sends nothing and holds nothing.
  test(
    "a_scan_the_core_reads_as_another_device's_sends_nothing_and_holds_nothing",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      String? other;
      final sent = <String>[];
      final a = await firstDevice(
        fake,
        ana,
        host: WatchedHost(
          TestHost().gate,
          [],
          answer: (command) => command['cmd'] == 'approval_from_qr' && other != null
              ? {'device_id': other, 'certificate': '', 'device_list': '', 'transfer': 'AAAA'}
              : null,
        ),
        client: watchedClient(
          fake,
          seen: (request) {
            if (request.method == 'POST' && request.url.path.endsWith('/inbox')) sent.add(request.url.path);
          },
        ),
      );
      final b = await approvedDevice(fake, a);
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final qr = _qrOf(n)!;
      final scanned = (await a.engine.scannedDevice(qr))!;
      other = _deviceOf(b);
      await expectLater(a.engine.approveScanned(qr, scanned), throwsA(isA<StateError>()));
      expect(sent, isEmpty);
      expect(_approvalOf(a.state), isNull);
      // Nothing held: this device's changes go on.
      await a.engine.removeDevice(_deviceOf(b));
      await Future.wait([a.engine.stop(), b.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Minor 5 of step 5's engines review: the API's limit refuses a send of the person's act for a moment (a 429 that
  // asks a second): the act waits it out once, on the engine's clock, and the same frame goes again. The new device's
  // commitment reaches the approving device, and the yes's offer goes as it was made: never a new approval_offer.
  test(
    "an_approval's_send_refused_for_a_moment_goes_once_the_API_lets_it",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final (commitments, offers) = (<String>[], <String>[]);
      TestDevice? fresh;
      final a = await firstDevice(
        fake,
        ana,
        host: WatchedHost(TestHost().gate, log),
        client: _inboxOf(fake, () => fresh == null ? null : _deviceOf(fresh), offers),
      );
      final n = fresh = testDevice(fake, ana, client: _inboxOf(fake, () => _deviceOf(a), commitments));
      await n.engine.start();
      await n.engine.beginApproval();

      fake.refuse((method: 'POST', path: '/api/devices/${_deviceOf(a)}/inbox'), 429, headers: {'Retry-After': '1'});
      final using = n.engine.useCode();
      await until(() {
        n.clock.advance(const Duration(seconds: 1));
        return commitments.length == 2;
      }, what: 'the commitment sent again');
      await using;
      expect(commitments.last, commitments.first);
      expect(_setupOf(n.state)?.way, SetupWay.code);
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked, what: 'the approving device asking');

      fake.refuse((method: 'POST', path: '/api/devices/${_deviceOf(n)}/inbox'), 429, headers: {'Retry-After': '1'});
      final approving = a.engine.approveDevice(_deviceOf(n), _questionOf(a));
      await until(() {
        a.clock.advance(const Duration(seconds: 1));
        return offers.length == 2;
      }, what: 'the offer sent again');
      await approving;
      expect(offers.last, offers.first);
      expect(log.where((cmd) => cmd == 'approval_offer'), hasLength(1));
      await until(() => _offered(n), what: 'the new device taking the offer');
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.code, what: 'the code shown');
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Minor 5 too: asked to wait longer than a few seconds, the act doesn't hold the engine's turn for it. It fails as
  // the rate limit, with its wait: never as no device having got the request, and never by dropping one without a
  // word.
  test(
    "an_approval's_send_the_API_holds_back_longer_fails_as_the_rate_limit",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final log = <String>[];
      final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, log));
      final n = await _newDevice(fake, ana);
      await n.engine.beginApproval();
      final limited = isA<duvet.DuvetApiException>()
          .having((e) => e.statusCode, 'status', 429)
          .having((e) => e.retryAfter, 'wait', const Duration(minutes: 1));

      fake.refuse((method: 'POST', path: '/api/devices/${_deviceOf(a)}/inbox'), 429, headers: {'Retry-After': '60'});
      final first = _qrOf(n);
      await expectLater(n.engine.useCode(), throwsA(limited));
      // Its attempt replaced the QR's in the core: a new QR, as the one on screen would open nothing.
      expect(_qrOf(n), allOf(isA<String>(), isNot(first)));

      await n.engine.useCode();
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      fake.refuse((method: 'POST', path: '/api/devices/${_deviceOf(n)}/inbox'), 429, headers: {'Retry-After': '60'});
      await expectLater(a.engine.approveDevice(_deviceOf(n), _questionOf(a)), throwsA(limited));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );
}
