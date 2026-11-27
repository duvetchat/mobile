import 'dart:convert';

import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/inbox.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';
import '../support/fake_api.dart';

// The inbox (PLAN-E2E-CLIENTES.md, «El buzón»): what other devices sent this one, read at start, at each READY and on
// DEVICE_MESSAGE; each message deleted only once it's handled. The desktop's inbox.test.ts, case for case, with its
// review's rulings.
String _frame(String data) => approvalFrameMessage((step: ApprovalStep.commitment, data: data, name: null));
String _bytes(String text) => base64Encode(utf8.encode(text));

/// A request of [device]'s to be approved, as its core makes one, naming it: one that names another device than its
/// sender goes as the approvals take it (review 27's M6).
Future<String> _commitmentOf(TestDevice device) async =>
    (await device.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'}))['commitment']! as String;

/// The IDs of the messages the record keeps under [key].
List<Object?> _kept(EngineStore store, String key) => [for (final m in (store.read(key) as List?) ?? const []) m['id']];

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test("a_rotation's_transfer_is_taken_from_the_inbox,_and_the_own_user_is_observed_after", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final a = await firstDevice(fake, ana);
    final b = testDevice(fake, ana);
    await b.engine.start();
    expect(b.state, EngineState.newDevice);

    // Ana's first device approves her second by its QR, by hand (Task 27 does it in the app); the second lists itself.
    await a.engine.stop();
    await a.host.open(ana);
    final begun = await b.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
    final approved = await a.host.handle<Map<String, Object?>>({'cmd': 'approval_from_qr', 'qr': begun['qr']});
    await b.host.handle<Object?>({'cmd': 'approval_receive', 'transfer': approved['transfer']});
    final version = await b.api.putDeviceList(
      duvet.DeviceListUpload(
        deviceList: approved['device_list']! as String,
        certificate: approved['certificate']! as String,
        baseVersion: 1,
      ),
    );
    await b.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': version});
    await b.engine.stop();
    final log = <String>[];
    // It hears no IDENTITY_UPDATE, which observes the user too: what observes after the transfer is the inbox's rule.
    final second = testDevice(
      fake,
      ana,
      host: WatchedHost(b.host, log),
      store: b.store,
      token: b.token,
      hears: (event) => event.type != 'IDENTITY_UPDATE',
    );
    await second.engine.start();
    expect(second.state, EngineState.ready);

    // The first device changes the keys, keeping the second: its transfer goes to the second's inbox.
    final served = await a.api.identity(ana);
    await a.host.handle<Object?>({
      'cmd': 'observe_user',
      'user_id': ana,
      'identity_key': served.identityKey,
      'device_list': served.deviceList,
      'certificates': served.certificates,
    });
    final rotated = await a.host.handle<Map<String, Object?>>({
      'cmd': 'rotate_keys',
      'remove': <String>[],
      'certificates': served.certificates,
    });
    final published = await a.api.putIdentity(
      duvet.IdentityUpload(
        identityKey: rotated['identity_key']! as String,
        deviceList: rotated['device_list']! as String,
        certificate: rotated['certificate']! as String,
        encryptedIdentity: rotated['encrypted_identity']! as String,
        wrappedBackupKey: rotated['wrapped_backup_key']! as String,
        wrappedPreviousBackupKeys: rotated['wrapped_previous_backup_keys'] as String?,
        replaces: served.identityKey,
        transfers: [
          for (final t in (rotated['transfers']! as List).cast<Map<String, Object?>>())
            duvet.IdentityTransfer(
              deviceId: t['device_id']! as String,
              certificate: t['certificate']! as String,
              message: t['transfer']! as String,
            ),
        ],
      ),
    );
    await a.host.handle<Object?>({'cmd': 'identity_uploaded'});
    await a.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': published.deviceListVersion});

    // The second takes it on DEVICE_MESSAGE, then observes its own user: it holds the new identity, and stays ready.
    await eventually(() async => expect(await second.api.inbox(), isEmpty), timeout: const Duration(seconds: 20));
    await eventually(
      () => expect(log.lastIndexOf('observe_user'), greaterThan(log.lastIndexOf('receive_direct'))),
      timeout: const Duration(seconds: 20),
    );
    expect(log, contains('receive_direct'));
    final status = await second.host.handle<Map<String, Object?>>({'cmd': 'status'});
    expect(status['identity_key'], rotated['identity_key']);
    expect(second.state, EngineState.ready);
    await second.engine.stop();
    await a.host.close();
  }, skip: noCore);

  test("an_inbox_message_is_deleted_only_once_it's_handled", () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    var cut = true;
    var refusedByCode = 0;
    final log = <String>[];
    final host = WatchedHost(
      TestHost().gate,
      log,
      fail: (command) {
        if (command['cmd'] != 'receive_direct') return null;
        // The first message the core reads is cut midway; the second after that is a transfer the core keeps for later.
        if (cut) {
          cut = false;
          return CoreError('internal', message: 'the call was cut');
        }
        if (++refusedByCode == 2) return CoreError('not_found', message: 'no approval accepted its code', what: 'code');
        return null;
      },
    );
    final a = await firstDevice(fake, ana, host: host);
    final other = testDevice(fake, ana);
    await other.engine.start();
    final another = testDevice(fake, ana);
    await another.engine.start();
    final device = a.registered.single;

    // Other devices of Ana's write to this one: a step of an approval, two messages of the core's, and another device's
    // step. Their DEVICE_MESSAGE events wait for good: here the reads are READY's, one at a time.
    fake.holdEvents();
    final sent = [
      await other.api.sendToDevice(device, _frame(await _commitmentOf(other))),
      for (final message in [_bytes("not the core's"), _bytes('kept for later')])
        await other.api.sendToDevice(device, message),
      await another.api.sendToDevice(device, _frame(await _commitmentOf(another))),
    ];
    final [firstFrame, _, kept, lastFrame] = sent;
    // The first round keeps the frame, then stops at the cut call: only the frame is deleted.
    a.connect(device);
    await eventually(() => expect(log, contains('receive_direct')));
    await eventually(() async => expect([for (final m in await a.api.inbox()) m.id], sent.sublist(1)));

    // The next READY reads it again: what the core can't read is dropped, the transfer kept, the frame kept.
    a.connect(device);
    await eventually(() async => expect(await a.api.inbox(), isEmpty));
    expect(_kept(a.store, keptApprovals), [firstFrame, lastFrame]);
    expect(_kept(a.store, keptTransfers), [kept]);
    await a.engine.stop();
    await other.engine.stop();
    await another.engine.stop();
  }, skip: noCore);

  // I4 of the desktop's review: a message's sender certificate goes with it, and one the core takes only with what a
  // later task gives (a history or a catch-up key) waits in the record instead of going.
  test("a_message_goes_to_the_core_with_its_sender's_certificate,_and_one_its_task_takes_is_kept_for_it", () async {
    final fake = FakeApi();
    final (ana, bo) = (fake.addUser(), fake.addUser());
    fake.addConversation(group: false, members: [ana, bo]);
    final commands = <Map<String, Object?>>[];
    var refusal = CoreError('bad_command', message: 'from_certificate is required', field: 'from_certificate');
    final a = await firstDevice(
      fake,
      ana,
      host: WatchedHost(
        TestHost().gate,
        [],
        commands: commands,
        fail: (command) => command['cmd'] == 'receive_direct' ? refusal : null,
      ),
    );
    final b = await firstDevice(fake, bo);
    final device = a.registered.single;
    fake.holdEvents();
    final first = await b.api.sendToDevice(device, _bytes('a history key'));
    a.connect(device);
    await eventually(() async => expect(await a.api.inbox(), isEmpty));
    final received = commands.lastWhere((c) => c['cmd'] == 'receive_direct');
    // Bo's device's certificate, as Bo's identity serves it, and Ana's identity as the API serves it.
    final bos = await a.api.identity(bo);
    expect(received['from_certificate'], bos.certificates.single);
    expect(received['identity_key'], (await a.api.identity(ana)).identityKey);
    expect(_kept(a.store, keptLater), [first]);

    // Users to observe first wait in the record too.
    refusal = CoreError('needs_identities', message: 'observe them', users: [bo]);
    final second = await b.api.sendToDevice(device, _bytes('another key'));
    a.connect(device);
    await eventually(() async => expect(await a.api.inbox(), isEmpty));
    expect(_kept(a.store, keptLater), [first, second]);
    await a.engine.stop();
    await b.engine.stop();
  }, skip: noCore);

  // Minor 3 of step 5's engines review: a key its sender won't send again, which the core couldn't take as it came
  // (here, its sender's certificate not served yet), is given to the core again first at each round until it's taken:
  // then it leaves the record, and its catch-up comes in.
  test(
    'a_key_the_core_could_not_take_is_given_to_it_again_the_next_round',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final a = await firstDevice(fake, ana);
      final dm = (await a.engine.createDM(bo)).id;
      await a.engine.openConversation(dm);
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]));
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi Bo')))!;

      // Bo's first device: the first time its core is given a message from another device, it can't take it yet.
      var refuse = true;
      final b = await firstDevice(
        fake,
        bo,
        host: WatchedHost(
          TestHost().gate,
          [],
          fail: (command) {
            if (command['cmd'] != 'receive_direct' || !refuse) return null;
            refuse = false;
            return CoreError('bad_command', message: 'from_certificate is required', field: 'from_certificate');
          },
        ),
      );
      // Ana's device hands him its catch-up: its key comes, and waits in the record, the inbox read past it.
      await until(() => _kept(b.store, keptLater).isNotEmpty, what: 'the key kept for later');
      await until(() async => (await b.api.inbox()).isEmpty, what: 'the inbox read past it');

      // The next round gives it to the core again: taken, it leaves the record, and the catch-up comes in.
      b.connect(b.registered.last);
      await until(() => _kept(b.store, keptLater).isEmpty, what: 'the key taken, out of the record');
      await until(() async {
        b.clock.advance(quietBeforeImport);
        return [
          for (final m in await b.engine.messages(dm, [sent.id])) m.text,
        ].contains('hi Bo');
      }, what: 'the catch-up imported');
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // M3 of the desktop's review: approvals are between the user's own devices.
  test("an_approval's_step_from_another_user_is_dropped,_never_kept", () async {
    final fake = FakeApi();
    final (ana, bo) = (fake.addUser(), fake.addUser());
    fake.addConversation(group: false, members: [ana, bo]);
    final a = await firstDevice(fake, ana);
    final b = await firstDevice(fake, bo);
    final mine = testDevice(fake, ana);
    await mine.engine.start();
    final device = a.registered.single;
    fake.holdEvents();
    await b.api.sendToDevice(device, _frame('Qk9C'));
    final own = await mine.api.sendToDevice(device, _frame(await _commitmentOf(mine)));
    a.connect(device);
    await eventually(() async => expect(await a.api.inbox(), isEmpty));
    expect(_kept(a.store, keptApprovals), [own]);
    for (final engine in [a.engine, b.engine, mine.engine]) {
      await engine.stop();
    }
  }, skip: noCore);

  // M4 of the desktop's review: a message whose call is cut every time holds the inbox for five rounds at most.
  test('a_message_whose_call_is_cut_five_rounds_running_goes', () async {
    final fake = FakeApi();
    final ana = fake.addUser();
    final log = <String>[];
    final a = await firstDevice(
      fake,
      ana,
      host: WatchedHost(
        TestHost().gate,
        log,
        fail: (command) =>
            command['cmd'] == 'receive_direct' ? CoreError('internal', message: 'the call was cut') : null,
      ),
    );
    final other = testDevice(fake, ana);
    await other.engine.start();
    final device = a.registered.single;
    fake.holdEvents();
    await other.api.sendToDevice(device, _bytes('it ends every call'));
    for (var round = 1; round <= 5; round++) {
      a.connect(device);
      await eventually(() => expect(log.where((cmd) => cmd == 'receive_direct'), hasLength(round)));
      if (round < 5) expect(await a.api.inbox(), hasLength(1));
    }
    await eventually(() async => expect(await a.api.inbox(), isEmpty));
    expect(_kept(a.store, keptLater), isEmpty);
    await a.engine.stop();
    await other.engine.stop();
  }, skip: noCore);

  // Step 5's fuzzing: a page whose last message is the one the read began after (the server's word, which the API never
  // gives so: its after is exclusive) had the next read begin there again, and a server that kept sending it held the
  // engine's one turn, which the inbox takes, for good, each round handling the page anew.
  test("an_inbox_page_that_doesn't_go_past_where_its_read_began_ends_the_round", () async {
    const user = '0193a4b2-0000-7000-8000-000000000001';
    // A full page of approval frames from the user's own devices, which the record keeps: no core is asked.
    final page = [
      for (var n = 0; n < 100; n++)
        {
          'id': '0193a4b2-0000-7000-8000-${n.toString().padLeft(12, '0')}',
          'from_user_id': user,
          'from_device_id': '0193a4b2-0000-7000-8000-0000000000dd',
          'message': _frame(base64Encode([n])),
          'created_at': '2026-11-26T10:00:00Z',
        },
    ];
    final reads = <String?>[];
    final cleared = <String?>[];
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        cleared.add(request.url.queryParameters['through']);
        return http.Response('', 204);
      }
      reads.add(request.url.queryParameters['after']);
      // A server that gives up after a while: the test can't wait for good.
      if (reads.length > 5) return http.Response('{"error":"enough"}', 500);
      return http.Response(jsonEncode(page), 200);
    });
    final engine = E2EEngine(
      host: _NoCore(),
      api: duvet.E2eApi(duvet.RestClient(client, router: fakeRouter, token: 'token', duvetClient: engineClient)),
      events: const Stream.empty(),
      store: MemoryStore(),
      clock: TestClock(),
      user: user,
      deviceName: 'Pixel 8 Pro',
      registered: (_) {},
      // No conversation is drawn: nothing goes anywhere.
      shown: (_, {required fresh}) async => null,
    );
    expect(await takeInbox(engine, {}), isFalse);
    // Its first page, then the same page again, past whose last message nothing came: the round ends there.
    expect(reads, [null, page.last['id']]);
    expect(cleared, [page.last['id']]);
    expect(_kept(engine.store, keptApprovals), hasLength(20));
  });

  // M3 of step 4's closing review: the record keeps 20 messages the core can't take yet. One more waits in the inbox
  // rather than push out the oldest, whose copy there is gone: a history's or a catch-up's key would never open.
  test('a_message_for_later_past_the_records_twenty_waits_in_the_inbox,_and_pushes_none_out', () async {
    const user = '0193a4b2-0000-7000-8000-0000000000aa';
    final page = [
      for (var n = 0; n < 21; n++)
        {
          'id': uuidv7(),
          'from_user_id': '0193a4b2-0000-7000-8000-0000000000bb',
          'from_device_id': '0193a4b2-0000-7000-8000-0000000000dd',
          'message': _bytes('a key, $n'),
          'created_at': '2026-11-26T10:00:00Z',
        },
    ];
    final cleared = <String?>[];
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        cleared.add(request.url.queryParameters['through']);
        return http.Response('', 204);
      }
      if (request.url.path.endsWith('/identity')) return http.Response('{"error":"no identity"}', 404);
      return http.Response(jsonEncode(page), 200);
    });
    final engine = E2EEngine(
      host: _ForLater(),
      api: duvet.E2eApi(duvet.RestClient(client, router: fakeRouter, token: 'token', duvetClient: engineClient)),
      events: const Stream.empty(),
      store: MemoryStore(),
      clock: TestClock(),
      user: user,
      deviceName: 'Pixel 8 Pro',
      registered: (_) {},
      // No conversation is drawn: nothing goes anywhere.
      shown: (_, {required fresh}) async => null,
    );
    await takeInbox(engine, {});
    expect(_kept(engine.store, keptLater), [for (final message in page.take(20)) message['id']]);
    expect(cleared, [page[19]['id']]);
  });
}

/// A core that can't take any message yet: each needs what a later task gives (a history's or a catch-up's key whose
/// sender's certificate isn't served yet).
class _ForLater implements CoreHost {
  @override
  Future<T> handle<T>(Map<String, Object?> command) async =>
      throw CoreError('bad_command', message: 'from_certificate is required', field: 'from_certificate');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A core no test of this file's own reaches: each command fails.
class _NoCore implements CoreHost {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
