import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/devices.dart' show takenAway;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/store.dart';
import 'package:flutter_test/flutter_test.dart';

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
  await approver.engine.approveDevice(_deviceOf(fresh));
  await until(() => _approvalOf(approver.state)?.phase == ApprovalPhase.code);
  await until(() => _offered(fresh));
  return _approvalOf(approver.state)!.code!;
}

/// Another six digits than these.
String _otherThan(String code) => ((int.parse(code) + 1) % 1000000).toString().padLeft(6, '0');

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

      // The approving device asks the person, naming the new device and showing the same fingerprint.
      await until(() => _approvalOf(a.state)?.phase == ApprovalPhase.asked);
      expect(
        _approvalOf(a.state),
        DeviceApproval(
          device: _deviceOf(n),
          name: 'Pixel 8 Pro',
          fingerprint: setup.fingerprint!,
          phase: ApprovalPhase.asked,
        ),
      );
      await a.engine.approveDevice(_deviceOf(n));
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
      await again.engine.approveDevice(_deviceOf(n));
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
      await a.engine.approveDevice(_deviceOf(n));
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
      await a.engine.approveScanned(qr, scanned!);
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
      await a.engine.approveDevice(_deviceOf(n));
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
      await a.engine.approveDevice(_deviceOf(n));
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
      await again.engine.approveDevice(_deviceOf(n));
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
      await a.engine.approveDevice(_deviceOf(n));
      expect(log, isNot(contains('approval_offer')));
      expect(_approvalOf(a.state)?.phase, ApprovalPhase.asked);
      await expectLater(a.engine.approveScanned(qr, scanned), throwsA(isA<StateError>()));
      expect(log, isNot(contains('approval_from_qr')));
      // Its identity the API's again: the yes offers.
      replaced = false;
      await a.engine.approveDevice(_deviceOf(n));
      expect(log, contains('approval_offer'));
      await Future.wait([a.engine.stop(), n.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );
}
