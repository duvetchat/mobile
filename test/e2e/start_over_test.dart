import 'dart:convert';

import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Starting over (PLAN-E2E-CLIENTES.md, Task 27; decision 47): a new device without the recovery key or another device
// makes a new identity for the user, its recovery key shown until it's saved, uploaded in the place of the one before
// (`reset`), and comes back into its conversations once another member commits the removal of the devices before. The
// desktop's start-over.test.ts, but Bun's box.
const _slow = Timeout(Duration(minutes: 3));
const _identity = (method: 'PUT', path: '/api/users/@me/identity');

String _deviceOf(TestDevice device) => device.registered.last;

/// Another device of the user's, on a session of its own: a new device, as its start leaves it.
Future<TestDevice> _newDevice(FakeApi fake, String user, {CoreHost? host, http.Client? client}) async {
  final device = testDevice(fake, user, host: host, client: client);
  await device.engine.start();
  expect(device.state, EngineState.newDevice);
  return device;
}

/// The member's device takes out the leaves of [user]'s devices before they started over, by hand, its engine
/// stopped: it observes their new identity and commits what's pending, as the API's removals' proposal leads it to
/// (the fake proposes none).
Future<void> _commitTheirRemoval(TestDevice member, String conversation, String user) async {
  await stoppedByHand(member);
  for (final identity in await member.api.identities([user])) {
    await member.host.handle<Object?>({
      'cmd': 'observe_user',
      'user_id': identity.userId,
      'identity_key': identity.identityKey,
      'device_list': identity.deviceList,
      'certificates': identity.certificates,
    });
  }
  final held = (await groupOf(member, conversation))!;
  final made = await byHand(member, {'cmd': 'commit_pending', 'conversation_id': conversation});
  final taken = await member.api.commit(
    conversation,
    duvet.Commit(
      generation: held.generation,
      epoch: held.epoch,
      commit: made['commit']! as String,
      groupInfo: made['group_info']! as String,
    ),
  );
  await member.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': true,
    'seq': taken.seq,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "starting_over_makes_a_new_identity_and_waits_for_another_member's_commit_to_rejoin",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final identities = <Map<String, Object?>>[];
      final client = watchedClient(
        fake,
        seen: (request) {
          if (request.method == _identity.method && request.url.path == _identity.path) {
            identities.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          }
        },
      );
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      await a.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);
      // Ana's only device is gone, and with it what would set up another: a new device starts over.
      await a.engine.stop();
      final before = await b.api.identity(ana);
      final n = await _newDevice(fake, ana, client: client);
      await n.engine.resetIdentity();
      final key = n.state.recoveryKey;
      expect(key, recoveryKeyShape);
      expect(n.state, EngineState.settingUp(DeviceSetup.reset, recoveryKey: key));
      // Nothing goes up before the person saved the new key.
      expect(identities, isEmpty);

      await n.engine.keySaved();
      expect(n.state.stage, EngineStage.ready);
      final after = await n.api.identity(ana);
      expect(after.identityKey, isNot(before.identityKey));
      expect(listDevices(after.deviceList), [_deviceOf(n)]);
      expect(identities, [
        allOf(
          containsPair('reset', true),
          containsPair('replaces', before.identityKey),
          containsPair('identity_key', after.identityKey),
        ),
      ]);
      expect(
        [
          for (final d in await n.api.devices())
            if (d.id == _deviceOf(a)) d.listed,
        ],
        [false],
      );
      expect(n.store.read(keptReset), isNull);

      // The DM waits: its group still has the leaf of the device before, which only another member's commit takes out.
      await n.engine.openConversation(conversation);
      await until(() => n.engine.conversationState(conversation)?.name == ConversationNotice.waitRejoin);
      await _commitTheirRemoval(b, conversation, ana);
      final back = await restarted(fake, b);
      await until(() => n.engine.conversationState(conversation) == null);
      await sameGroup([n, back], conversation);
      await Future.wait([n.engine.stop(), back.engine.stop()]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "starting_over's_recovery_key_shows_until_it's_saved,_and_a_start_over_cut_before_its_upload_finishes_with_it",
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      await a.engine.stop();
      final log = <String>[];
      final store = MemoryStore();
      // The record names the identity it replaces before the core makes the new one.
      final recordedFirst = <bool>[];
      final host = WatchedHost(
        TestHost().gate,
        log,
        fail: (command) {
          if (command['cmd'] == 'reset_identity') recordedFirst.add(store.read(keptReset) != null);
          return null;
        },
      );
      final n = testDevice(fake, ana, host: host, store: store);
      await n.engine.start();
      await n.engine.resetIdentity();
      final key = n.state.recoveryKey;
      expect(key, recoveryKeyShape);
      // Its upload cut: the key still shows, then waits for Finish once its page closes.
      fake.cutRequest(_identity);
      await expectLater(n.engine.keySaved(), throwsA(isA<http.ClientException>()));
      expect(n.state.recoveryKey, key);
      await n.engine.uploadLater();
      const waiting = EngineState.settingUp(DeviceSetup.reset, finishing: true);
      expect(n.state, waiting);
      // The app starts again: still a start over of its own, never a first device's race lost.
      final again = await restarted(fake, n);
      expect(again.state, waiting);
      await again.engine.finishSetup();
      expect(again.state.recoveryKey, key);
      await again.engine.keySaved();
      expect(again.state.stage, EngineStage.ready);
      expect(listDevices((await again.api.identity(ana)).deviceList), [_deviceOf(again)]);
      expect(log.where((cmd) => cmd == 'reset_identity'), hasLength(2));
      expect(recordedFirst, [true, true]);
      expect(store.read(keptReset), isNull);
      await again.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review 27's M3: another identity there meanwhile (409) can't be replaced by this one, made for the one before: the
  // installation starts again as a new device (Ruling 26), and its state says why once the key's page goes.
  test(
    'a_start_over_another_identity_beat_starts_the_device_again,_its_state_saying_why',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await firstDevice(fake, ana);
      await a.engine.stop();
      final n = await _newDevice(fake, ana);
      final before = _deviceOf(n);
      await n.engine.resetIdentity();
      expect(n.state.recoveryKey, recoveryKeyShape);
      fake.refuse(_identity, 409, body: {'error': 'identity changed', 'identity_key': 'another'});
      await n.engine.keySaved();
      expect(n.state, const EngineState(EngineStage.newDevice, listChanged: true));
      expect(_deviceOf(n), isNot(before));
      expect(n.store.read(keptReset), isNull);
      await n.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
