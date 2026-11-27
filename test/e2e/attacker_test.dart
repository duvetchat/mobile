import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:duvet/data/models.dart' show ConversationTarget, MessageCreated;
import 'package:duvet/e2e/conventions.dart' show maxFileName;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/legacy.dart' show legacyRecords;
import 'package:duvet/e2e/store.dart' show externalSender;
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/ed25519.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Step 5: the server as an attacker, against the Android app's engine (PLAN-E2E-CLIENTES.md, «Lo que el paso 5
// revisa»). End-to-end encryption lets the server withhold and delay, but never read, forge, or make a device act on
// its word alone: the device never takes a device, an identity or a key the person didn't accept, never loses or forges
// a message the person holds, confirms only what the server took («Restricciones globales»), and goes on where the plan
// says it goes on. Each case is a lie the fake API tells, on real cores, held to the rule it names; what the server
// only withholds is its right, and no case's. The desktop's engine/attacker.test.ts, case for case.
const _slow = Timeout(Duration(minutes: 4));
const _identity = (method: 'PUT', path: '/api/users/@me/identity');
const _deviceList = (method: 'PUT', path: '/api/users/@me/device-list');
const _keyPackages = (method: 'PUT', path: '/api/users/@me/devices/@me/key-packages');
const _inbox = (method: 'DELETE', path: '/api/users/@me/devices/@me/inbox');
String _messagesPath(String conversation) => '/api/users/@me/conversations/$conversation/messages';

final _random = Random.secure();

/// The text a device's core shows of a message, once it has it: null while it has none.
Future<String?> _textOn(TestDevice device, String conversation, String id) async {
  final shown = (await device.engine.messages(conversation, [id])).firstOrNull;
  return shown?.status == MessageStatus.ok ? shown!.text : null;
}

Future<Map<String, Object?>> _status(TestDevice device) => device.host.handle<Map<String, Object?>>({'cmd': 'status'});

/// A message of the device's, sent through its engine.
Future<duvet.DirectMessage> _send(TestDevice device, String conversation, String text) async =>
    await device.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text)) ??
    (throw StateError('the message "$text" was not sent'));

/// The message [id] as the device's connection heard it come (DM_MESSAGE_CREATE), as the server sent it.
Map<String, Object?> _heard(TestDevice device, String id) => [
  for (final event in device.heard)
    if (event.type == 'DM_MESSAGE_CREATE' && (event.data! as Map)['id'] == id)
      (event.data! as Map).cast<String, Object?>(),
].first;

/// What [drawn] draws without [hidden]: a page that never showed them.
PageDrawing _without(PageDrawing drawn, String hidden) =>
    (id, {required fresh}) async => switch (await drawn(id, fresh: fresh)) {
      final shown? => (
        group: shown.group,
        owner: shown.owner,
        users: [
          for (final user in shown.users)
            if (user != hidden) user,
        ],
      ),
      null => null,
    };

/// Whether [request] posts a message to the conversation.
bool _posts(http.Request request, String conversation) =>
    request.method == 'POST' && request.url.path == _messagesPath(conversation);

/// The device's work until now, what it set going in its conversations' lanes included (a start's and a READY's
/// resend), whose requests go outside the turn.
Future<void> _settled(TestDevice device) async {
  for (var round = 0; round < 3; round++) {
    await turnEnded(device);
  }
}

/// Ana's and Bo's first devices in their DM, whose group Ana made; Ana's hears what [aHears] lets through.
Future<({FakeApi fake, String ana, String bo, TestDevice a, TestDevice b, String conversation})> _dm({
  bool Function(GatewayEvent event)? aHears,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(fake, ana, hears: aHears);
  final b = await firstDevice(fake, bo);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, conversation: conversation);
}

/// Ana's first device and a second one it approved (her list's version 2), whose requests [seen] is told of first,
/// Bo's first device, their DM's group, and a message of Bo's that both of Ana's devices hold. [older] is Ana's
/// identity as the API served it before her second device was listed: a list a server could serve again.
Future<
  ({
    FakeApi fake,
    String ana,
    String bo,
    TestDevice a1,
    TestDevice a2,
    http.Client? a2Client,
    TestDevice b,
    String conversation,
    Map<String, Object?> older,
    String message,
  })
>
_anaWithTwoDevices({void Function(http.Request request)? seen}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a2Client = seen == null ? null : watchedClient(fake, seen: seen);
  final a1 = await firstDevice(fake, ana);
  final older = fake.identityOf(ana);
  final a2 = await approvedDevice(fake, a1, client: a2Client);
  final b = await firstDevice(fake, bo);
  await a1.engine.openConversation(conversation);
  await sameGroup([a1, a2, b], conversation);
  final kept = await _send(b, conversation, 'kept');
  await until(() async => await _textOn(a2, conversation, kept.id) == 'kept');
  return (
    fake: fake,
    ana: ana,
    bo: bo,
    a1: a1,
    a2: a2,
    a2Client: a2Client,
    b: b,
    conversation: conversation,
    older: older,
    message: kept.id,
  );
}

/// The API serves the user's identity as [served] from now on (none for null), to everyone, by both of its routes.
void _serveAs(FakeApi fake, String user, Map<String, Object?>? served) =>
    fake.servedAs = (view) => view['user_id'] != user ? view : (served == null ? null : {...served});

/// The server tells the user's devices their identity changed, whatever it serves.
void _identityUpdate(FakeApi fake, String user, Map<String, Object?> served) => fake.tell(user, (
  type: 'IDENTITY_UPDATE',
  data: {'user_id': user, 'identity_key': served['identity_key'], 'device_list_version': served['device_list_version']},
));

/// Counts the device lists a device puts up, and fails each past the third: a device that puts its list up again and
/// again, on a fake whose answers come at once, would never end its start.
({List<String> puts, void Function(http.Request request) seen}) _listPuts() {
  final puts = <String>[];
  return (
    puts: puts,
    seen: (request) {
      if (request.method != _deviceList.method || request.url.path != _deviceList.path) return;
      puts.add(request.url.path);
      if (puts.length > 3) throw http.ClientException('this list went up three times already', request.url);
    },
  );
}

/// Another device of the user's starts over by hand (Task 27 does it in the app), its engine stopped: a new identity,
/// listing that device alone, which the API takes in the place of the one it serves.
Future<void> _resetFrom(TestDevice device) async {
  final made = await device.host.handle<Map<String, Object?>>({'cmd': 'reset_identity'});
  final published = await device.api.putIdentity(
    duvet.IdentityUpload(
      identityKey: made['identity_key']! as String,
      deviceList: made['device_list']! as String,
      certificate: made['certificate']! as String,
      encryptedIdentity: made['encrypted_identity']! as String,
      wrappedBackupKey: made['wrapped_backup_key']! as String,
      replaces: (await device.api.identity(device.user)).identityKey,
      reset: true,
    ),
  );
  await device.host.handle<Object?>({'cmd': 'identity_uploaded'});
  await device.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': published.deviceListVersion});
}

/// The character [code], written so: what hides in a name is read where it's written.
String _c(int code) => String.fromCharCode(code);

void main() {
  // An app's repository on the fake takes path_provider's answer from a mocked channel (support/app_repository.dart).
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  group('a_list_the_server_hides_or_rolls_back_is_refused', () {
    // «Arranque», step 5, and the core's observe_user: a list older than the one the device holds is `older_list`, and
    // the device keeps its own, which names it. Ruling 26 starts over only a device the API never listed; decision 13:
    // a device's data goes on the person's word alone.
    test(
      'an_older_list_of_the_users_own_from_before_this_device_was_listed_leaves_it_ready_with_what_it_holds',
      () async {
        final (:puts, :seen) = _listPuts();
        final t = await _anaWithTwoDevices(seen: seen);
        final device = (await _status(t.a2))['device_id'];
        _serveAs(t.fake, t.ana, t.older);
        // And a server that lies there too: whatever list this device puts up, another won.
        t.fake.refuse(
          _deviceList,
          409,
          body: {
            'error': 'device list changed',
            'device_list': t.older['device_list'],
            'version': t.older['device_list_version'],
          },
          always: true,
        );
        final before = puts.length;
        final again = await restarted(t.fake, t.a2, client: t.a2Client);
        expect(again.state, EngineState.ready);
        expect((await _status(again))['device_id'], device);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
        expect(puts.sublist(before), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'an_older_list_whose_own_list_the_api_takes_again_is_not_put_up_again_and_again',
      () async {
        final (:puts, :seen) = _listPuts();
        final t = await _anaWithTwoDevices(seen: seen);
        _serveAs(t.fake, t.ana, t.older);
        final before = puts.length;
        // The API takes the list it holds again (200), and still serves the older one.
        final again = await restarted(t.fake, t.a2, client: t.a2Client);
        expect(again.state, EngineState.ready);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
        expect(puts.sublist(before), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'an_older_list_heard_of_while_ready_changes_nothing',
      () async {
        final t = await _anaWithTwoDevices();
        _serveAs(t.fake, t.ana, t.older);
        _identityUpdate(t.fake, t.ana, t.older);
        await turnEnded(t.a2);
        expect(t.a2.state, EngineState.ready);
        final next = await _send(t.b, t.conversation, 'after the lie');
        await until(() async => await _textOn(t.a2, t.conversation, next.id) == 'after the lie');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The approver and a contact hold the newer list too: neither takes the approved device out on the older one.
    test(
      'a_device_the_person_approved_stays_in_the_approvers_and_a_contacts_groups_when_its_list_is_rolled_back',
      () async {
        final t = await _anaWithTwoDevices();
        final approved = (await _status(t.a2))['device_id']! as String;
        _serveAs(t.fake, t.ana, t.older);
        _identityUpdate(t.fake, t.ana, t.older);
        final a1Again = await restarted(t.fake, t.a1);
        final bAgain = await restarted(t.fake, t.b);
        await bAgain.engine.openConversation(t.conversation);
        final next = await _send(bAgain, t.conversation, "to every device of Ana's");
        await until(() async => await _textOn(t.a2, t.conversation, next.id) == "to every device of Ana's");
        for (final device in [a1Again, bAgain]) {
          expect([for (final one in (await groupOf(device, t.conversation))!.devices) one.device], contains(approved));
        }
        expect(a1Again.state, EngineState.ready);
      },
      skip: noCore,
      timeout: _slow,
    );

    // observe_user of the user's own: an identity this device doesn't hold is not_own_identity, which the inbox may
    // explain with a transfer; without one, the plan says the device is off the list (removed). It takes none of it.
    test(
      'another_users_identity_served_as_the_users_own_takes_nothing_from_the_device',
      () async {
        final t = await _anaWithTwoDevices();
        final own = await _status(t.a1);
        _serveAs(t.fake, t.ana, {...t.fake.identityOf(t.bo), 'user_id': t.ana});
        final again = await restarted(t.fake, t.a1);
        expect([EngineStage.ready, EngineStage.removed], contains(again.state.stage));
        final now = await _status(again);
        expect([now['device_id'], now['identity_key']], [own['device_id'], own['identity_key']]);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
      },
      skip: noCore,
      timeout: _slow,
    );

    // A 404 says the user has no identity: a first device's. A device whose core holds the one the API took is none,
    // and makes no second one (the core refuses): withholding it is the server's right, starting over the person's.
    test(
      'no_identity_served_leaves_a_device_that_holds_one_as_it_was_then_another_served_elsewhere_deletes_nothing',
      () async {
        final t = await _anaWithTwoDevices();
        final own = await _status(t.a2);
        _serveAs(t.fake, t.ana, null);
        final again = await restarted(t.fake, t.a2);
        expect(again.state, EngineState.ready);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
        // Then another device of Ana's starts over, and the API serves its identity: this one is off that list, and
        // what it holds stays until the person's word.
        t.fake.servedAs = (view) => view;
        final other = testDevice(t.fake, t.ana);
        await other.engine.start();
        await stoppedByHand(other);
        await _resetFrom(other);
        await until(() => again.state == EngineState.removed);
        expect((await _status(again))['device_id'], own['device_id']);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The same with a change of keys of this device's that waits for its upload: the change waits on, to go up as the
    // same one once the person finishes it, as identity.dart has it whenever the API doesn't serve the one it made.
    test(
      'no_identity_served_to_a_device_whose_change_of_keys_waits_leaves_the_change_waiting',
      () async {
        final t = await _anaWithTwoDevices();
        await t.a1.engine.changeKeys();
        t.fake.cutRequest(_identity);
        await expectLater(t.a1.engine.keySaved(), throwsA(isA<http.ClientException>()));
        final own = await _status(t.a1);
        expect(own['waiting_upload'], 'rotate_keys');
        _serveAs(t.fake, t.ana, null);
        final again = await restarted(t.fake, t.a1);
        expect(again.state, const EngineState.rotation());
        expect((await _status(again))['identity_key'], own['identity_key']);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  // A case the plan's list implies: «Estados» says a device is removed when another device took it off the list, which
  // the signed list proves. DEVICE_REMOVE is the server's word alone, which the engine takes as it comes, for an honest
  // removal ends the device's sessions at once and would leave nothing to check it with. The limit, pinned: the server
  // can make a listed device say it was removed until its next start, which finds it listed; what it holds stays,
  // unless the person starts it over on that word.
  group('a_removal_only_the_server_says_of_deletes_nothing', () {
    test(
      'a_device_remove_of_a_device_still_listed_shows_it_removed_until_its_next_start',
      () async {
        final t = await _anaWithTwoDevices();
        final device = (await _status(t.a1))['device_id']! as String;
        t.fake.tell(t.ana, (type: 'DEVICE_REMOVE', data: {'device_id': device}));
        await turnEnded(t.a1);
        expect(t.a1.state, EngineState.removed);
        final again = await restarted(t.fake, t.a1);
        expect(again.state, EngineState.ready);
        expect((await _status(again))['device_id'], device);
        expect(await _textOn(again, t.conversation, t.message), 'kept');
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('an_event_repeated_or_reordered_is_applied_once_in_order', () {
    // Review Focus 4: the number decides. What's repeated is skipped, a gap asks for the queue, and the queue's pages
    // and the events meet in one order: messages, an edit and a deletion, beside the commits sync_test.dart holds.
    test(
      'messages_an_edit_and_a_deletion_heard_late_backwards_and_twice_end_as_their_author_left_them',
      () async {
        final t = await _dm();
        t.fake.holdEvents();
        final first = await _send(t.b, t.conversation, 'first');
        final second = await _send(t.b, t.conversation, 'second');
        await t.b.engine.editMessage(t.conversation, first.id, 'first, edited');
        await t.b.engine.deleteMessage(t.conversation, second.id);
        // The edit and the deletion come first, twice: Ana's device reads what they leave out from the queue.
        t.fake.releaseEvents(
          only: (event) => event.type == 'DM_MESSAGE_UPDATE' || event.type == 'DM_MESSAGE_DELETE',
          reverse: true,
          repeat: true,
        );
        await until(() async => await _textOn(t.a, t.conversation, first.id) == 'first, edited');
        // Then the messages themselves, backwards and twice, long after.
        t.fake.releaseEvents(reverse: true, repeat: true);
        await turnEnded(t.a);
        final shown = (await t.a.engine.messages(t.conversation, [first.id])).single;
        expect((shown.status, shown.text), (MessageStatus.ok, 'first, edited'));
        expect(shown.editedAt, isNotNull);
        expect(await t.a.engine.messages(t.conversation, [second.id]), isEmpty);
        expect(t.fake.decryptFailures, isEmpty);
        expect((await groupOf(t.a, t.conversation))!.blocked, isFalse);
      },
      skip: noCore,
      timeout: _slow,
    );

    // «El buzón»: each message is handled, then deleted. An inbox that keeps them (its DELETE answered, nothing
    // deleted) serves them again at every round: each one's work is done once.
    test(
      'an_inbox_served_again_and_again_and_device_message_heard_twice_take_a_rotations_transfer_once',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final a1 = await firstDevice(fake, ana);
        final a2 = await approvedDevice(fake, a1);
        fake.refuse(_inbox, 204, always: true);
        await a1.engine.changeKeys();
        await a1.engine.keySaved();
        final rotated = (await a1.api.identity(ana)).identityKey;
        await until(() async => (await _status(a2))['identity_key'] == rotated);
        final device = (await _status(a2))['device_id']! as String;
        for (var round = 0; round < 2; round++) {
          for (var times = 0; times < 2; times++) {
            fake.tell(ana, (type: 'DEVICE_MESSAGE', data: {'device_id': device, 'id': uuidv7()}), device: device);
          }
          a2.connect(device);
          await turnEnded(a2);
        }
        expect(a2.state, EngineState.ready);
        expect((await _status(a2))['identity_key'], rotated);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('an_entry_served_twice_with_other_bytes_is_refused', () {
    // Review Focus 4 and the core's apply: an entry under a number already applied is skipped, whatever it holds.
    test(
      'another_entry_heard_under_a_number_the_device_applied_changes_nothing_there',
      () async {
        final t = await _dm();
        final first = await _send(t.b, t.conversation, 'first');
        final second = await _send(t.b, t.conversation, 'second');
        await until(() async => await _textOn(t.a, t.conversation, second.id) == 'second');
        // The server tells Ana's device that the first message's number holds the second's bytes.
        t.fake.tell(t.ana, (
          type: 'DM_MESSAGE_CREATE',
          data: {..._heard(t.a, first.id), 'ciphertext': second.ciphertext},
        ));
        await turnEnded(t.a);
        expect(await _textOn(t.a, t.conversation, first.id), 'first');
        expect(await _textOn(t.a, t.conversation, second.id), 'second');
        expect(t.fake.decryptFailures, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The core's apply counts every entry in the group, one it can't open too: the first copy of a number that comes is
    // the one it applies. A changed copy opens nothing and shows no other text, and the queue's own copy, under that
    // number, is skipped: its message waits, as if the server withheld it, which it could as well with a changed copy
    // in both. The device goes on.
    test(
      'a_changed_copy_heard_first_takes_its_number_the_queues_own_copy_is_skipped_and_its_message_waits',
      () async {
        var deaf = false;
        final t = await _dm(aHears: (_) => !deaf);
        deaf = true;
        final first = await _send(t.b, t.conversation, 'first');
        // Ana's device heard it come, and took none of it.
        await until(() => t.a.heard.any((e) => e.type == 'DM_MESSAGE_CREATE' && (e.data! as Map)['id'] == first.id));
        deaf = false;
        final bytes = base64Decode(first.ciphertext!);
        bytes[bytes.length - 1] ^= 1;
        t.fake.tell(t.ana, (
          type: 'DM_MESSAGE_CREATE',
          data: {..._heard(t.a, first.id), 'ciphertext': base64Encode(bytes)},
        ));
        await turnEnded(t.a);
        final second = await _send(t.b, t.conversation, 'second');
        await until(() async => await _textOn(t.a, t.conversation, second.id) == 'second', what: 'the next message');
        expect(
          [
            for (final row in await t.a.engine.messages(t.conversation, [first.id])) row.status,
          ],
          [MessageStatus.waiting],
        );
        expect((await groupOf(t.a, t.conversation))!.blocked, isFalse);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('a_group_whose_external_sender_isnt_the_apis_is_refused', () {
    // The core's contract: the API is the groups' one external sender, and the clients take only removals from it,
    // signed with its key. A welcome under another key: failures_test.dart's
    // «another_external_sender_is_refused,_and_the_pinned_one_stays». «El motor», its external sender: the client pins
    // the key the first time it sees it, and a different one is a warning, never a change (Ruling 32).
    test(
      'another_key_served_after_the_pinned_one_and_a_removal_proposed_under_it_take_no_one_out_and_the_group_goes_on',
      () async {
        final t = await _dm();
        final pinned = t.fake.externalSender;
        expect(t.a.engine.serverKeyChanged.value, isFalse);
        final bos = (await _status(t.b))['device_id']! as String;
        final other = Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));
        t.fake.externalSender = base64Encode(ed25519PublicKey(other));
        final again = await restarted(t.fake, t.a);
        expect(again.store.read(externalSender), pinned);
        // Said to the person, never taken: «una distinta es un aviso» (M2 of step 4's closing review).
        expect(again.engine.serverKeyChanged.value, isTrue);
        t.fake.proposeRemoval(t.conversation, bos, seed: other);
        await turnEnded(again);
        await turnEnded(t.b);
        final next = await _send(again, t.conversation, 'still here');
        await until(() async => await _textOn(t.b, t.conversation, next.id) == 'still here');
        final held = await sameGroup([again, t.b], t.conversation);
        expect(held.blocked, isFalse);
        expect([for (final one in held.devices) one.device], contains(bos));
        expect(again.engine.conversationState(t.conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('the_servers_deleted_ids_delete_nothing_the_client_holds', () {
    // The core's contract: a deletion is its author's tombstone (decision 16); backup_import's `deleted` erases only
    // what an import brought; and an entry the queue serves with `deleted` opens nothing. The device's files of it may
    // go from memory (task 19's review), its row never.
    test(
      'a_message_the_server_lists_as_deleted_its_author_never_having_deleted_it_stays_where_its_held',
      () async {
        final t = await _dm();
        final kept = await _send(t.b, t.conversation, 'kept');
        await until(() async => await _textOn(t.a, t.conversation, kept.id) == 'kept');
        t.fake.markDeleted(t.conversation, kept.id);
        final deleted = {
          'seq': kept.seq,
          'kind': 'message',
          'data': '',
          'deleted': true,
          'sent_at': kept.sentAt,
          'message_id': kept.id,
          'generation': kept.generation,
          'epoch': kept.epoch,
          'sender_user': kept.authorId,
          'sender_device': kept.senderDeviceId,
        };
        t.fake.tell(t.ana, (
          type: 'DM_MESSAGE_DELETE',
          data: {'id': kept.id, 'conversation_id': t.conversation, 'entry': deleted},
        ));
        t.fake.tell(t.ana, (type: 'DM_MESSAGE_DELETE', data: {'id': kept.id, 'conversation_id': t.conversation}));
        await turnEnded(t.a);
        expect(await _textOn(t.a, t.conversation, kept.id), 'kept');
        expect(await t.a.api.deletedMessages(t.conversation), contains(kept.id));
        final again = await restarted(t.fake, t.a);
        expect(await _textOn(again, t.conversation, kept.id), 'kept');
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('a_group_holds_only_whom_the_device_can_account_for', () {
    // C1 of step 4's closing reviews: a device founds a group only with the members it can account for, its creator
    // with the person's picks, whatever the API lists to its engine; and a group that holds someone the conversation
    // doesn't show is said before anything more is sent there, which protects whoever joins by a welcome.
    test(
      'the_api_listing_a_third_member_to_the_creators_engine_founds_no_group_with_them',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        // The server plants an account of its own in the group Ana makes, after it answers her creation.
        final commits = <String>[];
        var planted = false;
        final client = watchedClient(
          fake,
          seen: (request) {
            if (request.method == 'POST' && request.url.path.endsWith('/mls/commits')) commits.add(request.url.path);
            if (planted || request.method != 'GET' || request.url.path != '/api/users/@me/conversations') return;
            if (fake.conversationIds.firstOrNull case final made?) {
              planted = true;
              fake.addMembers(made, [eve]);
            }
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        final conversation = (await a.engine.createGroup('Plans', [bo])).id;
        await turnEnded(a);
        expect(planted, isTrue);
        expect(a.engine.conversationState(conversation), ConversationState.membersChanged);
        expect(await groupOf(a, conversation), isNull);
        expect(commits, isEmpty);
        expect(await groupOf(e, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Kept past its founding, the record would hold a later welcome of this device's to the members it began with.
    test(
      'the_creators_picks_found_its_group_and_go_once_the_device_holds_it',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        final conversation = (await a.engine.createDM(bo)).id;
        await sameGroup([a, b], conversation);
        expect((a.store.read(legacyRecords) as Map?)?.containsKey(conversation) ?? false, isFalse);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_welcome_whose_group_holds_a_user_the_conversation_doesnt_is_said_and_nothing_is_sent',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        await stoppedByHand(b);
        // Ana's device is shown an account of the server's in the group, and founds it with them; Bo's never is.
        fake.addMembers(conversation, [eve]);
        await a.engine.openConversation(conversation);
        await until(() async => await groupOf(e, conversation) != null, what: "the group on the planted device");
        fake.dropMembers(conversation, [eve]);
        final posts = <String>[];
        final again = await restarted(
          fake,
          b,
          client: watchedClient(
            fake,
            seen: (request) {
              if (request.method == 'POST' && request.url.path == _messagesPath(conversation)) posts.add('message');
            },
          ),
        );
        await until(() async => await groupOf(again, conversation) != null, what: "the welcome on Bo's device");
        await turnEnded(again);
        expect(again.engine.conversationState(conversation), ConversationState.groupDiffers([ana, bo, eve]));
        await expectLater(_send(again, conversation, 'for Ana alone'), throwsA(isA<StateError>()));
        expect(posts, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-C1 of step 4's closing re-review: nothing goes to a conversation the person doesn't see, whoever its group
    // holds. A listing that leaves it out after the welcome stops what goes there, as one hiding a member does.
    test(
      'a_conversation_the_page_draws_no_more_after_the_welcome_takes_nothing',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        await stoppedByHand(b);
        fake.addMembers(conversation, [eve]);
        await a.engine.openConversation(conversation);
        await until(() async => await groupOf(e, conversation) != null, what: 'the group on the planted device');
        fake.dropMembers(conversation, [eve]);
        final posts = <String>[];
        var listed = true;
        final honest = fake.drawnTo(bo);
        final again = await restarted(
          fake,
          b,
          client: watchedClient(
            fake,
            seen: (request) {
              if (_posts(request, conversation)) posts.add('message');
            },
          ),
          drawn: (id, {required fresh}) async => listed ? honest(id, fresh: fresh) : null,
        );
        await until(() async => await groupOf(again, conversation) != null, what: "the welcome on Bo's device");
        await turnEnded(again);
        expect(again.engine.conversationState(conversation), ConversationState.groupDiffers([ana, bo, eve]));
        // From now on the server leaves the conversation out of what Bo's page lists: it draws it no more.
        listed = false;
        await expectLater(_send(again, conversation, 'for Ana alone'), throwsA(isA<StateError>()));
        expect(posts, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-C1, and a message that waits: each delivery, a start's and a READY's, is held to what the page draws then. Not
    // while the group holds someone the page doesn't draw, nor while it draws the conversation no more; then it goes.
    test(
      'a_message_that_waits_goes_at_a_start_or_a_READY_only_to_a_group_its_page_draws',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo, eve], owner: ana);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b, e], conversation);
        var cut = true;
        final posts = <String>[];
        final client = watchedClient(
          fake,
          answer: (request) async {
            if (!_posts(request, conversation)) return null;
            if (cut) throw http.ClientException('no answer', request.url);
            posts.add('message');
            return null;
          },
        );
        // What Bo's page draws: everyone, everyone but Eve, or nothing.
        final honest = fake.drawnTo(bo);
        var page = honest;
        Future<ShownConversation?> drawn(String id, {required bool fresh}) => page(id, fresh: fresh);
        final b2 = await restarted(fake, b, client: client, drawn: drawn);
        await expectLater(_send(b2, conversation, 'waits'), throwsA(anything));
        cut = false;
        page = _without(honest, eve);
        final again = await restarted(fake, b2, client: client, drawn: drawn);
        await _settled(again);
        expect(posts, isEmpty);
        Future<void> ready() async {
          fake.tell(bo, (
            type: 'READY',
            data: {
              'user': {'id': bo},
            },
          ));
          await _settled(again);
        }

        await ready();
        expect(posts, isEmpty);
        page = (_, {required fresh}) async => null;
        await ready();
        expect(posts, isEmpty);
        page = honest;
        await ready();
        await until(() => posts.isNotEmpty, what: 'the message that waited, once its group is as drawn');
        expect(posts, ['message']);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-C1, the app's own drawing: what it draws comes from its session's listings, and before the first is in nothing
    // goes. A send waits for one, then is held to what it draws.
    test(
      "a_send_before_the_session's_first_listing_waits_for_one_and_goes_to_no_group_holding_whom_it_doesn't_draw",
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        // The server fails the app's first listing, as it signs in, and holds Bo's welcome from his connection, as
        // everything else while the group is founded: what his app draws comes from no listing made meanwhile.
        var listings = 0;
        var quiet = false;
        final app = await appOn(
          fake,
          bo,
          hears: (event) => !quiet && event.type != 'MLS_WELCOME',
          answer: (request) async {
            if (request.method != 'GET' || request.url.path != '/api/users/@me/conversations') return null;
            if (++listings > 1) return null;
            return http.Response(
              jsonEncode({'error': 'internal server error'}),
              500,
              headers: {'content-type': 'application/json'},
            );
          },
        );
        await app.ready();
        final a = await firstDevice(fake, ana);
        final e = await firstDevice(fake, eve);
        // Ana's device is shown an account of the server's in the group, and founds it with them; Bo's app never is.
        quiet = true;
        fake.addMembers(conversation, [eve]);
        await a.engine.openConversation(conversation);
        await until(() async => await groupOf(e, conversation) != null, what: 'the group on the planted device');
        fake.dropMembers(conversation, [eve]);
        quiet = false;
        final from = app.seen.length;
        await expectLater(
          app.repository.send(ConversationTarget(conversation), 'for Ana alone', nonce: uuidv4()),
          throwsA(anything),
        );
        expect(app.count('POST', _messagesPath(conversation), from: from), 0);
        expect(app.repository.conversationStates.value[conversation]?.name, ConversationNotice.groupDiffers);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-I1 of step 4's closing re-review: a DM is two people, and its view shows one other: drawn with more, it
    // differs.
    test(
      'a_dm_drawn_with_a_third_member_takes_nothing_for_a_group_of_the_person_and_them',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final posts = <String>[];
        final b = await firstDevice(
          fake,
          bo,
          client: watchedClient(
            fake,
            seen: (request) {
              if (_posts(request, conversation)) posts.add('message');
            },
          ),
          // A page that took the server's addition of Eve to the DM.
          drawn: (id, {required fresh}) async =>
              id != conversation ? null : (group: false, owner: null, users: [ana, bo, eve]),
        );
        final e = await firstDevice(fake, eve);
        // Eve's device is shown the DM as hers and Bo's, and founds its group: a DM of the two of them.
        fake.dropMembers(conversation, [ana]);
        fake.addMembers(conversation, [eve]);
        await e.engine.openConversation(conversation);
        await sameGroup([b, e], conversation);
        fake.dropMembers(conversation, [eve]);
        fake.addMembers(conversation, [ana, eve]);
        await turnEnded(b);
        await expectLater(_send(b, conversation, 'for Ana'), throwsA(isA<StateError>()));
        expect(posts, isEmpty);
        expect(b.engine.conversationState(conversation)?.name, ConversationNotice.groupDiffers);
        expect(b.engine.conversationState(conversation)?.users, unorderedEquals([bo, eve]));
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-I1, the app's own drawing: a DM is drawn as the person and the one other its view shows, whatever else its
    // listing holds, and no addition to it is taken.
    test(
      "the_app_draws_a_dm_as_the_person_and_whom_its_view_shows,_whatever_else_its_listing_holds",
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final app = await appOn(fake, ana, hears: (event) => event.type != 'MLS_WELCOME');
        await app.ready();
        final e = await firstDevice(fake, eve);
        // Eve's device is shown the DM as hers and Ana's, and founds its group: a DM of the two of them.
        fake.dropMembers(conversation, [bo]);
        fake.addMembers(conversation, [eve]);
        await e.engine.openConversation(conversation);
        await until(() async => await groupOf(e, conversation) != null, what: "Eve's group");
        // Then Ana's DM is listed with Bo first, whom its view shows, and Eve after him.
        fake.dropMembers(conversation, [eve]);
        fake.addMembers(conversation, [bo, eve]);
        await app.repository.refreshConversations();
        expect(app.repository.conversations.value.single.otherUserId, bo);
        final from = app.seen.length;
        await expectLater(
          app.repository.send(ConversationTarget(conversation), 'for Bo', nonce: uuidv4()),
          throwsA(anything),
        );
        expect(app.count('POST', _messagesPath(conversation), from: from), 0);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-I3 of step 4's closing re-review: an edit or a deletion that waits for its answer goes again only to a group
    // whose people the page draws. Each try looks, and so does a restart's, before its bytes are made again.
    test(
      'an_edit_and_a_deletion_that_wait_go_nowhere_while_the_group_holds_someone_the_page_doesnt_draw',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final changes = <String>[];
        var cut = false;
        final client = watchedClient(
          fake,
          answer: (request) async {
            final change =
                (request.method == 'PATCH' || request.method == 'DELETE') &&
                RegExp(r'/messages/[^/]+$').hasMatch(request.url.path);
            if (!change) return null;
            if (cut) throw http.ClientException('no answer', request.url);
            changes.add(request.method);
            return null;
          },
        );
        var hidden = false;
        final honest = fake.drawnTo(bo);
        Future<ShownConversation?> drawn(String id, {required bool fresh}) =>
            (hidden ? _without(honest, eve) : honest)(id, fresh: fresh);
        final b = await firstDevice(fake, bo, client: client, drawn: drawn);
        final e = await firstDevice(fake, eve);
        final id = (await e.engine.createGroup('three', [ana, bo])).id;
        await b.engine.openConversation(id);
        await sameGroup([b, e], id);
        final first = await _send(b, id, 'first');
        final second = await _send(b, id, 'second');
        // Made while the page draws Eve, their requests unanswered.
        cut = true;
        await b.engine.editMessage(id, first.id, 'edited');
        await b.engine.deleteMessage(id, second.id);
        await turnEnded(b);
        // From now on the page doesn't draw Eve, and the API would answer.
        hidden = true;
        cut = false;
        b.clock.advance(const Duration(minutes: 2));
        await _settled(b);
        expect(changes, isEmpty);
        expect(b.engine.conversationState(id)?.name, ConversationNotice.groupDiffers);
        // A restart makes them again only once its group is as drawn.
        final again = await restarted(fake, b, client: client, drawn: drawn);
        await _settled(again);
        expect(changes, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-M1 of step 4's closing re-review: a record made from a listing the API calls from before the cutover is held to
    // what the page draws too: such a listing with someone the page never showed founds nothing.
    test(
      'a_listing_called_from_before_the_cutover_founds_no_group_with_whom_the_page_never_drew',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo, eve], owner: ana, legacy: true);
        final commits = <String>[];
        final b = await firstDevice(
          fake,
          bo,
          client: watchedClient(
            fake,
            seen: (request) {
              if (request.method == 'POST' && request.url.path == commitsPath(conversation)) commits.add('commit');
            },
          ),
          drawn: _without(fake.drawnTo(bo), eve),
        );
        await firstDevice(fake, ana);
        await firstDevice(fake, eve);
        await b.engine.openConversation(conversation);
        await turnEnded(b);
        expect(commits, isEmpty);
        expect(await groupOf(b, conversation), isNull);
        expect(b.engine.conversationState(conversation)?.name, ConversationNotice.membersChanged);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-M2 of step 4's closing re-review: a creation's record never takes the place of one kept already. «Message»
    // on a contact answers the DM they have, from before the cutover: its record, as this device first saw it, stays.
    test(
      'a_creation_answered_with_a_conversation_that_has_a_record_keeps_that_record',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo], legacy: true);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        await turnEnded(a);
        Object? recordOn(TestDevice device) => (device.store.read(legacyRecords) as Map?)?[conversation];
        final first = recordOn(a);
        expect(first, {
          'members': [ana, bo],
        });
        expect((await a.engine.createDM(bo)).id, conversation);
        expect(recordOn(a), first);
        await sameGroup([a, b], conversation);
        await turnEnded(a);
        expect(recordOn(a), first);
      },
      skip: noCore,
      timeout: _slow,
    );

    // N-M3 of step 4's closing re-review: the creator's picks are kept whatever the API answers its creation with. One
    // answered with a group of the server's has the creator's device join it held to them: it isn't joined.
    test(
      "a_creation_answered_with_another_group_is_held_to_the_creator's_picks",
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        // A group of the server's, Eve's and Bo's, founded before Ana's creation.
        final planted = fake.addConversation(group: true, members: [eve, bo], owner: eve);
        final e = await firstDevice(fake, eve);
        await firstDevice(fake, bo);
        await e.engine.openConversation(planted);
        await until(() async => await groupOf(e, planted) != null, what: "the server's group");
        // Ana's creation is answered with it, Ana in it.
        final commits = <String>[];
        final client = watchedClient(
          fake,
          seen: (request) {
            if (request.method == 'POST' && request.url.path == commitsPath(planted)) commits.add('commit');
          },
          change: (request, answered) async {
            if (request.method != 'POST' || request.url.path != '/api/users/@me/conversations') return answered;
            fake.addMembers(planted, [ana]);
            return http.Response(jsonEncode(fake.viewOf(planted)), 201, headers: {'content-type': 'application/json'});
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        expect((await a.engine.createGroup('Plans', [bo])).id, planted);
        await a.engine.openConversation(planted);
        await turnEnded(a);
        expect(commits, isEmpty);
        expect(await groupOf(a, planted), isNull);
        expect(a.engine.conversationState(planted)?.name, ConversationNotice.membersChanged);
      },
      skip: noCore,
      timeout: _slow,
    );

    // A device without a record (a DM's other member, a group's owner on another device) founds the conversation as
    // its page draws it; listed with someone the page doesn't draw, it founds nothing, and says so.
    test(
      'a_device_without_a_record_founds_as_its_page_draws,_and_nothing_with_a_listing_that_differs',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final drawn = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        final other = fake.addConversation(group: true, members: [ana, bo, eve], owner: ana);
        final a = await firstDevice(fake, ana, drawn: _without(fake.drawnTo(ana), eve));
        final b = await firstDevice(fake, bo);
        await firstDevice(fake, eve);
        await a.engine.openConversation(drawn);
        await sameGroup([a, b], drawn);
        await a.engine.openConversation(other);
        await turnEnded(a);
        expect(await groupOf(a, other), isNull);
        expect(a.engine.conversationState(other)?.name, ConversationNotice.membersChanged);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The honest leaver: a member who left with a statement, whose removal the API proposed, goes with the due commit
    // before anything is sent, which then goes without them.
    test(
      'a_member_who_left_goes_with_the_due_commit_before_a_send,_which_then_goes',
      () async {
        final fake = FakeApi();
        final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
        final a = await firstDevice(fake, ana, hears: (event) => event.type != 'MLS_PROPOSAL');
        final b = await firstDevice(fake, bo, hears: (event) => event.type != 'MLS_PROPOSAL');
        final c = await firstDevice(fake, cy);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b, c], conversation);
        await c.engine.leaveConversation(conversation);
        final sent = await _send(a, conversation, 'without Cy');
        final held = await groupOf(a, conversation);
        expect({for (final device in held!.devices) device.user}, {ana, bo});
        await until(() async => await _textOn(b, conversation, sent.id) == 'without Cy', what: "Bo's copy");
        expect(await _textOn(c, conversation, sent.id), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // A restart between a creation and its founding reads the person's picks back from the record: the group is founded
    // with them, and a listing that differs by then founds nothing.
    test(
      'a_restart_between_a_creation_and_its_founding_holds_it_to_the_picks_the_record_kept',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        var cut = true;
        final client = watchedClient(
          fake,
          answer: (request) async {
            if (!cut || request.method != 'POST' || !request.url.path.endsWith('/mls/commits')) return null;
            throw http.ClientException('no answer', request.url);
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        await firstDevice(fake, eve);
        final kept = (await a.engine.createGroup('Plans', [bo])).id;
        final made = (await a.engine.createGroup('Later', [bo])).id;
        await turnEnded(a);
        cut = false;
        // Before the restart, the server lists Eve in the second.
        fake.addMembers(made, [eve]);
        final again = await restarted(fake, a, client: client);
        await again.engine.openConversation(kept);
        await again.engine.openConversation(made);
        await turnEnded(again);
        final group = await groupOf(again, kept);
        expect({for (final device in group?.devices ?? const []) device.user}, {ana, bo});
        expect(await groupOf(again, made), isNull);
        expect(again.engine.conversationState(made)?.name, ConversationNotice.membersChanged);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The creator's device, its record kept (its listing differed), given a welcome to its conversation's group with
    // others in it: refused, as the record holds it, and said.
    test(
      "the_creator's_device_takes_no_welcome_with_others_than_its_picks",
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        var planted = false;
        final client = watchedClient(
          fake,
          seen: (request) {
            if (planted || request.method != 'GET' || request.url.path != '/api/users/@me/conversations') return;
            if (fake.conversationIds.firstOrNull case final made?) {
              planted = true;
              fake.addMembers(made, [eve]);
            }
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        final conversation = (await a.engine.createGroup('Plans', [bo])).id;
        await turnEnded(a);
        expect(a.engine.conversationState(conversation)?.name, ConversationNotice.membersChanged);
        // The server makes Eve the group's owner, has her device found it, and Ana's take its welcome.
        fake.setOwner(conversation, eve);
        await e.engine.openConversation(conversation);
        await until(() async => await groupOf(e, conversation) != null, what: "Eve's group");
        fake.setOwner(conversation, ana);
        await a.engine.openConversation(conversation);
        await turnEnded(a);
        expect(await groupOf(a, conversation), isNull);
        expect(a.engine.conversationState(conversation)?.name, ConversationNotice.membersChanged);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('a_row_the_server_makes_up_shows_nothing', () {
    // «La vista de una conversación» and I1 of step 4's closing review: an honest API serves a conversation its
    // numbered messages and its notices (types 2, 3 and 4) alone. Any other row is the server's own making: no
    // ciphertext, but files the server picks, under a member's name, as a voice note when its type says so. From a
    // page, a thread, a fetch or its event it shows nothing, in the chat, the Chats tab or Duvet's notices; a notice
    // shows as the notice it is, without any file the server lists on it.
    test(
      'a_conversations_row_neither_numbered_nor_a_notice_shows_nothing_from_a_page_or_an_event',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final target = ConversationTarget(conversation);
        final app = await appOn(fake, ana);
        await app.ready();
        final created = <String>[];
        final heard = app.repository.messageEvents(target).listen((event) {
          if (event case MessageCreated(:final message)) created.add(message.id);
        });
        addTearDown(heard.cancel);
        // Bo's voice note and picture, as the server makes them up, and a pin notice it lists a picture on.
        final voice = fake.addMadeUpRow(conversation, bo, type: 1);
        final picture = fake.addMadeUpRow(conversation, bo);
        final notice = fake.addMadeUpRow(conversation, bo, type: 2);
        final page = await app.repository.messages(target);
        expect([for (final m in page) (m.id, m.attachments.length)], [(notice['id'], 0)]);
        expect(await app.repository.thread(target, picture['id']! as String), isEmpty);
        await expectLater(app.repository.fetchMessage(target, voice['id']! as String), throwsA(anything));
        // Live: one made up, then a notice, which the chat hears after it.
        final live = fake.addMadeUpRow(conversation, bo, listed: false);
        fake.tell(ana, (type: 'DM_MESSAGE_CREATE', data: live));
        expect([for (final chat in app.repository.recents.value) chat.previewId], isNot(contains(live['id'])));
        expect([for (final n in app.repository.mentionNotices.value) n.messageId], isNot(contains(live['id'])));
        final after = fake.addMadeUpRow(conversation, bo, type: 2, listed: false);
        fake.tell(ana, (type: 'DM_MESSAGE_CREATE', data: after));
        await until(() => created.isNotEmpty, what: 'the notice heard after the made-up row');
        expect(created, [after['id']]);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('a_hostile_file_name_stays_a_name', () {
    // Review Focus 7 and «Convenciones entre clientes»: the name is the sender's word, cleaned again as it's read: its
    // last part, without what hides what it is, 255 characters at most. Here the sender is hostile; the server only
    // carries the file. A view shows and saves a file by that name (shownFile), and Settings → Attachments lists it
    // (fileNames).
    test(
      'a_senders_names_with_paths_unseen_characters_and_bidirectional_controls_are_shown_and_listed_as_names',
      () async {
        final t = await _dm();
        final names = [
          (r'C:\Users\Ana\Desktop\evil.exe', 'evil.exe'),
          ('../../.ssh/authorized_keys', 'authorized_keys'),
          ('invoice${_c(0x202e)}fdp.exe', 'invoicefdp.exe'),
          ('zero${_c(0x200b)}width${_c(0x2060)}word${_c(0xfeff)}.txt', 'zerowidthword.txt'),
          ('line${_c(0x2028)}and${_c(0x2029)}paragraph.txt', 'lineandparagraph.txt'),
          ('nul${_c(0)}bell${_c(7)}tab${_c(9)}.txt', 'nulbelltab.txt'),
          ('${_c(0x200b)}${_c(0x200c)}${_c(0x061c)}', 'file'),
          ('..', 'file'),
          ('${'a' * 300}.txt', 'a' * maxFileName),
        ];
        final bytes = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
        final sent = await sendWritten(t.a, t.conversation, [
          for (final (name, _) in names) (bytes: bytes, said: {'name': name}),
        ]);
        final files = await filesOn(t.b, t.conversation, sent.id);
        expect([for (final file in files) file.name], [for (final (_, name) in names) name]);
        final listed = await t.b.engine.fileNames();
        expect([for (final file in files) listed[file.id]], [for (final (_, name) in names) name]);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('a_2xx_that_stored_nothing_loses_nothing', () {
    // «Confirmar solo lo que el servidor tomó»: a confirmation follows a 2xx, which the client can't tell from a lie.
    // What it confirmed it keeps: nothing the person holds is lost, no second identity or key is made, and the device
    // goes on. One case per row of «Qué se manda y qué se le dice al núcleo»; the report says what the others cost.
    test(
      'an_identity_the_api_answered_for_and_never_kept_stays_on_the_device_which_makes_no_second_one',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final a = testDevice(fake, ana);
        await a.engine.start();
        await a.engine.makeIdentity();
        expect(shownKey(a.state), isNotNull);
        fake.refuse(_identity, 200, body: {'identity_id': uuidv7(), 'device_list_version': 1});
        await a.engine.keySaved();
        final made = await _status(a);
        expect(made['has_identity'], isTrue);
        // The person taps again: the core makes no second identity, so the key they saved stays this identity's.
        await a.engine.makeIdentity().catchError((Object _) {});
        expect(shownKey(a.state), isNull);
        expect((await _status(a))['identity_key'], made['identity_key']);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_list_the_api_answered_for_and_never_kept_stays_the_devices_its_removal_holding',
      () async {
        final fake = FakeApi();
        final ana = fake.addUser();
        final a1 = await firstDevice(fake, ana);
        final a2 = await approvedDevice(fake, a1);
        final second = (await _status(a2))['device_id']! as String;
        await a2.engine.stop();
        fake.refuse(_deviceList, 200, body: {'version': 3});
        await a1.engine.removeDevice(second);
        expect(a1.state, EngineState.ready);
        // The API still lists it, and this device keeps the list it signed without it.
        expect((await a1.api.identity(ana)).deviceListVersion, 2);
        final held = (await _status(a1))['device_list'];
        final again = await restarted(fake, a1);
        expect(again.state, EngineState.ready);
        expect((await _status(again))['device_list'], held);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'key_packages_the_api_answered_for_and_never_kept_leave_the_device_to_join_by_its_own_commit',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        // Bo's device's one upload as it starts.
        fake.refuse(_keyPackages, 200, body: {'handed_out': <String>[]});
        final b = await firstDevice(fake, bo);
        final a = await firstDevice(fake, ana);
        await a.engine.openConversation(conversation);
        final hello = await _send(a, conversation, 'hello');
        await until(() async => await _textOn(b, conversation, hello.id) == 'hello');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The API's own answers from here on, with nothing kept and no event sent (forget).
    //
    // A finding left for an issue (the desktop's desktop-electrobun#553, which the app shares): once the core confirmed
    // its creation (commit_result accepted), the API listing the conversation with no group makes _dropStale
    // (sync.dart) tell the core no answer came, which the core answers not_found (nothing waits), so every open and
    // send there throws before anything is encrypted. And once another member makes the API's group, this device stays
    // in its own, at the same numbers: its next message goes to the API, which takes it by them, and no one can read
    // it, nor it theirs, with no notice. What the person typed meanwhile isn't kept.
    test(
      'a_group_the_api_answered_for_and_never_kept_leaves_its_makers_message_waiting_and_the_device_goes_on',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        fake.forget((method: 'POST', path: commitsPath(conversation)));
        await a.engine.openConversation(conversation);
        final nonce = uuidv4();
        await a.engine
            .sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'kept here'))
            .catchError((Object _) => null);
        await turnEnded(a);
        expect([for (final one in await a.engine.pendingMessages(conversation)) one.nonce], [nonce]);
        // Bo's device makes the group the API keeps: Ana's goes into it, and what waited goes.
        await b.engine.openConversation(conversation);
        await until(
          () async => (await a.engine.pendingMessages(conversation)).isEmpty,
          what: "Ana's waiting message sent",
        );
        await sameGroup([a, b], conversation);
      },
      skip: "a group's creation the API answered for and never kept: step 5's finding, left for an issue",
      timeout: _slow,
    );

    test(
      'an_edit_the_api_answered_for_and_never_kept_is_its_authors_alone_and_what_follows_goes',
      () async {
        final t = await _dm();
        final message = await _send(t.b, t.conversation, 'as written');
        await until(() async => await _textOn(t.a, t.conversation, message.id) == 'as written');
        t.fake.forget((method: 'PATCH', path: '${_messagesPath(t.conversation)}/${message.id}'));
        await t.b.engine.editMessage(t.conversation, message.id, 'edited');
        expect(await _textOn(t.b, t.conversation, message.id), 'edited');
        final next = await _send(t.b, t.conversation, 'next');
        await until(() async => await _textOn(t.a, t.conversation, next.id) == 'next');
        expect(await _textOn(t.a, t.conversation, message.id), 'as written');
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_deletion_the_api_answered_for_and_never_kept_is_its_authors_alone_and_what_follows_goes',
      () async {
        final t = await _dm();
        final message = await _send(t.b, t.conversation, "still on Ana's");
        await until(() async => await _textOn(t.a, t.conversation, message.id) == "still on Ana's");
        t.fake.forget((method: 'DELETE', path: '${_messagesPath(t.conversation)}/${message.id}'));
        await t.b.engine.deleteMessage(t.conversation, message.id);
        expect(await t.b.engine.messages(t.conversation, [message.id]), isEmpty);
        final next = await _send(t.b, t.conversation, 'next');
        await until(() async => await _textOn(t.a, t.conversation, next.id) == 'next');
        expect(await _textOn(t.a, t.conversation, message.id), "still on Ana's");
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_history_package_or_its_key_in_the_inbox_the_api_answered_for_and_never_kept_is_offered_to_no_one',
      () async {
        final t = await _dm();
        await _send(t.a, t.conversation, 'shared');
        final share = RegExp(r'^/api/users/@me/conversations/[^/]+/history-shares/[^/]+/complete$');
        final inbox = RegExp(r'^/api/devices/[^/]+/inbox$');
        for (final lost in [share, inbox]) {
          t.fake.forget((method: 'POST', path: lost));
          await t.a.engine.shareHistory(t.conversation, t.bo, 'all');
          await turnEnded(t.a);
          await turnEnded(t.b);
          expect(t.b.engine.historyOffers.value[t.conversation] ?? const <HistoryOffer>[], isEmpty);
        }
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_message_the_api_answered_for_and_never_kept_stays_its_senders',
      () async {
        final t = await _dm();
        final page = await t.a.api.queue(t.conversation, 0);
        final at = DateTime.now().toUtc().toIso8601String();
        final answered = {
          'id': uuidv7(),
          'conversation_id': t.conversation,
          'author_id': t.ana,
          'content': null,
          'type': 0,
          'created_at': at,
          'updated_at': at,
          'seq': page.lastSeq + 1,
          'attachments': <Object?>[],
        };
        t.fake.refuse((method: 'POST', path: _messagesPath(t.conversation)), 201, body: answered);
        final nonce = uuidv4();
        final sent = await t.a.engine.sendMessage(
          Outgoing(conversationId: t.conversation, nonce: nonce, text: 'never kept'),
        );
        expect(sent?.id, answered['id']);
        expect(await _textOn(t.a, t.conversation, answered['id']! as String), 'never kept');
        expect([for (final one in await t.a.engine.pendingMessages(t.conversation)) one.nonce], isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );
  });
}
