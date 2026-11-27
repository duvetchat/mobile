import 'dart:convert';

import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart' show CoreError;
import 'package:duvet/e2e/legacy.dart' show legacyRecords;
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A group the API doesn't hold (mobile#369, the core's forget_group: duvetchat/e2e#55): a founding the API answered for
// and kept nothing of, or the API's group at the generation this device holds another one of. The device leaves its own
// (forget_group) and takes the API's, by making it again, by its welcome or by an external commit, held to the record
// the core answers: exactly the users and the owner its own group had. What the person typed goes in the group they end
// in. The desktop's #553 design (step5-fixes-desktop-4-report.md), case for case.
const _slow = Timeout(Duration(minutes: 4));
const _conversations = '/api/users/@me/conversations';
String _messagesPath(String conversation) => '$_conversations/$conversation/messages';

/// The text a device's core shows of a message, once it has it: null while it has none.
Future<String?> _textOn(TestDevice device, String conversation, String id) async {
  final shown = (await device.engine.messages(conversation, [id])).firstOrNull;
  return shown?.status == MessageStatus.ok ? shown!.text : null;
}

/// A message of the device's, sent through its engine.
Future<duvet.DirectMessage> _send(TestDevice device, String conversation, String text) async =>
    await device.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text)) ??
    (throw StateError('the message "$text" was not sent'));

/// The nonces of the person's messages waiting on the device.
Future<List<String?>> _waiting(TestDevice device, String conversation) async => [
  for (final one in await device.engine.pendingMessages(conversation)) one.nonce,
];

/// The users the device's core holds a device of in the conversation's group.
Future<Set<String>> _heldUsers(TestDevice device, String conversation) async => {
  for (final held in (await groupOf(device, conversation))?.devices ?? const <({String user, String device})>[])
    held.user,
};

/// The record the device keeps of the conversation (legacy_records), as it's kept.
Object? _recordOn(TestDevice device, String conversation) => (device.store.read(legacyRecords) as Map?)?[conversation];

http.Response _json(Object? body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The API's listing [answered], [conversation]'s group as [mls] says: a server listing a group it doesn't hold, or
/// none of one it holds (null).
http.Response _listedWith(http.Response answered, String conversation, Map<String, Object?>? mls) {
  final listed = (jsonDecode(answered.body) as List).cast<Map<String, Object?>>();
  for (final conv in listed) {
    if (conv['id'] == conversation) conv['mls'] = mls;
  }
  return _json(listed, answered.statusCode);
}

/// What a lying listing says of a group the API answered for and kept nothing of: kept, its founding the queue's one
/// entry, this device in it.
const _keptFounding = {'generation': 0, 'epoch': 1, 'last_seq': 1, 'floor_seq': 1, 'joined_seq': 1};

/// A client on the fake that lists [conversation] with the group the device founded there as kept ([_keptFounding])
/// from its founding's request on, until [stop]; and refuses each commit the device posts there as the validator
/// does (422) while [refusing] says so.
({http.Client client, void Function() stop}) _lyingAfterFounding(
  FakeApi fake,
  String conversation, {
  bool Function()? refusing,
}) {
  var lying = false;
  var stopped = false;
  return (
    client: watchedClient(
      fake,
      answer: (request) async =>
          (refusing?.call() ?? false) && request.method == 'POST' && request.url.path == commitsPath(conversation)
          ? _json({'error': 'commit refused'}, 422)
          : null,
      change: (request, answered) async {
        if (request.method == 'POST' && request.url.path == commitsPath(conversation)) lying = !stopped;
        final listing = request.method == 'GET' && request.url.path == _conversations;
        return lying && listing ? _listedWith(answered, conversation, _keptFounding) : answered;
      },
    ),
    stop: () {
      lying = false;
      stopped = true;
    },
  );
}

/// A client on the fake whose listing right after the device's first founding of [conversation] is refused (503), as
/// a device stopped before it lists again would leave it; and that keeps each founding's request, its body as JSON.
http.Client _listingLostAfterFounding(FakeApi fake, String conversation, [List<Map<String, Object?>>? founded]) {
  var (refuse, refused) = (false, false);
  return watchedClient(
    fake,
    answer: (request) async {
      if (request.method == 'POST' && request.url.path == commitsPath(conversation)) {
        founded?.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        refuse = !refused;
      } else if (refuse && request.method == 'GET' && request.url.path == _conversations) {
        (refuse, refused) = (false, true);
        return _json({'error': 'unavailable'}, 503);
      }
      return null;
    },
  );
}

/// A client on the fake that answers the group info of [conversation] 503 while [holding] says so.
http.Client _groupInfoHeld(FakeApi fake, String conversation, bool Function() holding) => watchedClient(
  fake,
  answer: (request) async => holding() && request.url.path == '$_conversations/$conversation/mls/group-info'
      ? _json({'error': 'unavailable'}, 503)
      : null,
);

/// Ana's device made a row of the DM's group without the group: Bo's founding, renewed [renewals] times by hand, then
/// Ana's external commit on its latest group info, refused by the API (the core told `invalid`). Both engines stopped,
/// their cores open. The group info each epoch had, by epoch.
Future<Map<int, duvet.MlsGroupInfo>> _refusedJoin(
  FakeApi fake,
  TestDevice a,
  TestDevice b,
  String conversation, {
  int renewals = 0,
}) async {
  await stoppedByHand(a);
  await b.engine.openConversation(conversation);
  await stoppedByHand(b);
  final infos = {1: await b.api.groupInfo(conversation)};
  for (var epoch = 2; epoch <= renewals + 1; epoch++) {
    await commitByHand(b, conversation);
    infos[epoch] = await b.api.groupInfo(conversation);
  }
  final info = infos[renewals + 1]!;
  await byHand(a, {
    'cmd': 'join_external',
    'conversation_id': conversation,
    'generation': info.generation,
    'group_info': info.groupInfo,
    'external_sender': fake.externalSender,
  });
  await a.host.handle<Object?>({
    'cmd': 'commit_result',
    'conversation_id': conversation,
    'accepted': false,
    'invalid': true,
  });
  await expectLater(
    a.host.handle<Object?>({'cmd': 'group', 'conversation_id': conversation}),
    throwsA(isA<CoreError>().having((error) => error.what, 'what', 'membership')),
  );
  return infos;
}

/// Ana's and Bo's first devices in their DM, Ana's founding answered for and kept nothing of, her core holding it: her
/// device stopped before it listed the conversation again (her core open).
Future<({FakeApi fake, String ana, String bo, TestDevice a, TestDevice b, String conversation})>
_forgottenFounding() async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(fake, ana, client: _listingLostAfterFounding(fake, conversation));
  final b = await firstDevice(fake, bo);
  fake.forget((method: 'POST', path: commitsPath(conversation)));
  await a.engine.openConversation(conversation).catchError((Object _) {});
  expect(await groupOf(a, conversation), isNotNull);
  expect(fake.viewOf(conversation)['mls'], isNull);
  await stoppedByHand(a);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, conversation: conversation);
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  group('no_group_on_the_api', () {
    // The server lists Ana's group as kept while she sends: her message is encrypted in it, its request cut. Listed as
    // it is, with no group, her device forgets it and founds it again at generation 0; the message, whose bytes no one
    // can open, goes under a new nonce, and Bo reads it and what follows.
    test(
      'a_founding_the_api_kept_nothing_of_is_made_again_at_generation_0,_'
      'and_a_message_cut_in_it_goes_under_a_new_nonce',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final lies = _lyingAfterFounding(fake, conversation);
        final a = await firstDevice(fake, ana, client: lies.client);
        final b = await firstDevice(fake, bo);
        fake.forget((method: 'POST', path: commitsPath(conversation)));
        await a.engine.openConversation(conversation);
        final first = (await groupOf(a, conversation))!;
        fake.cutRequest((method: 'POST', path: _messagesPath(conversation)));
        final cut = uuidv4();
        await a.engine
            .sendMessage(Outgoing(conversationId: conversation, nonce: cut, text: 'cut in it'))
            .catchError((Object _) => null);
        expect(await _waiting(a, conversation), [cut]);

        // Listed as it is: Ana's next READY makes the group again, and what waited goes there.
        lies.stop();
        a.connect(a.registered.last);
        await until(() => fake.viewOf(conversation)['mls'] != null, what: "Ana's group made again");
        await b.engine.openConversation(conversation);
        final held = await sameGroup([a, b], conversation);
        expect((held.generation, held.authenticator == first.authenticator), (0, false));
        await until(() async => (await _waiting(a, conversation)).isEmpty, what: 'the cut message sent');
        final went = (await a.engine.sentUnder(conversation, cut))!;
        await until(() async => await _textOn(b, conversation, went.messageId!) == 'cut in it');
        expect(went.nonce, isNot(cut));
        final next = await _send(a, conversation, 'after it');
        await until(() async => await _textOn(b, conversation, next.id) == 'after it');
      },
      skip: noCore,
      timeout: _slow,
    );

    // A commit of Ana's own in that group, which the API refused (it has no group), stays staged for a queue the API
    // doesn't have: it's let go (invalid) before the group is forgotten, which a staged commit refuses.
    test(
      "a_commit_of_the_device's_own_the_api_refused_there_is_let_go,_and_the_group_is_made_again",
      () async {
        final t = await _forgottenFounding();
        final held = (await groupOf(t.a, t.conversation))!;
        final made = await byHand(t.a, {'cmd': 'refresh', 'conversation_id': t.conversation});
        final renewal = duvet.Commit(
          generation: held.generation,
          epoch: held.epoch,
          commit: made['commit']! as String,
          groupInfo: made['group_info']! as String,
        );
        await expectLater(t.a.api.commit(t.conversation, renewal), throwsA(isA<duvet.DuvetApiException>()));
        await t.a.host.handle<Object?>({'cmd': 'commit_result', 'conversation_id': t.conversation, 'accepted': false});
        final again = await restarted(t.fake, t.a);
        await again.engine.openConversation(t.conversation);
        await t.b.engine.openConversation(t.conversation);
        final now = await sameGroup([again, t.b], t.conversation);
        expect(now.authenticator, isNot(held.authenticator));
      },
      skip: noCore,
      timeout: _slow,
    );

    // Ana's edit of one message and her deletion of another find no answer in the group, at generation 0, epoch 1. The
    // server loses the group: Bo's device lets it go and waits for her; hers lets it go and makes it again, at the same
    // numbers. Both changes are made again for the group made again, and Bo's device takes them.
    test(
      'a_change_waiting_across_a_forget_is_made_again_for_the_group_made_again_at_the_same_numbers',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        await a.engine.openConversation(conversation);
        final first = await sameGroup([a, b], conversation);
        final edited = await _send(a, conversation, 'as written');
        final deleted = await _send(a, conversation, 'to delete');
        await until(() async => await _textOn(b, conversation, deleted.id) == 'to delete');
        fake
          ..cutRequest((method: 'PATCH', path: '${_messagesPath(conversation)}/${edited.id}'))
          ..cutRequest((method: 'DELETE', path: '${_messagesPath(conversation)}/${deleted.id}'));
        await a.engine.editMessage(conversation, edited.id, 'edited');
        await a.engine.deleteMessage(conversation, deleted.id);

        fake.loseGroup(conversation);
        b.connect(b.registered.last);
        await until(() async => await groupOf(b, conversation) == null, what: "Bo's device letting the lost group go");
        a.connect(a.registered.last);
        final made = await sameGroup([a, b], conversation);
        expect(
          (made.generation, made.epoch, made.authenticator == first.authenticator),
          (first.generation, first.epoch, false),
        );
        await until(
          () async => await _textOn(b, conversation, edited.id) == 'edited',
          what: "Ana's edit on Bo's device",
        );
        await until(
          () async => (await b.engine.messages(conversation, [deleted.id])).isEmpty,
          what: "Ana's deletion on Bo's device",
        );
      },
      skip: noCore,
      timeout: _slow,
    );

    // A server that answers every founding and keeps none of it: Ana's device makes the group again once as it lets go
    // of the first, then once per open of the person's and once per run, never one after another on its own.
    test(
      'a_server_that_keeps_no_founding_gets_one_per_act_or_run,_never_one_after_another',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        var (foundings, listings) = (0, 0);
        final client = watchedClient(
          fake,
          seen: (request) {
            if (request.method == 'GET' && request.url.path == _conversations) listings++;
          },
          answer: (request) async {
            if (request.method != 'POST' || request.url.path != commitsPath(conversation)) return null;
            foundings++;
            return _json({'seq': 1, 'generation': 0, 'epoch': 1}, 201);
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        await a.engine.openConversation(conversation);
        await turnEnded(a);
        expect(foundings, 2);
        await a.engine.openConversation(conversation);
        await turnEnded(a);
        expect(foundings, 3);
        // A READY, and time passing, make none.
        final before = listings;
        a.connect(a.registered.last);
        await until(() => listings > before, what: "the READY's listing");
        a.clock.advance(const Duration(minutes: 10));
        await turnEnded(a);
        expect(foundings, 3);
        // Each act's founding was let go in its own turn: a start finds nothing to make again, and its first open makes
        // the group again once more as it lets go of the first.
        final again = await restarted(fake, a, client: client);
        await turnEnded(again);
        expect(foundings, 3);
        await again.engine.openConversation(conversation);
        await turnEnded(again);
        expect(foundings, 5);
      },
      skip: noCore,
      timeout: _slow,
    );

    // A member never makes a group: its device forgets the one the API doesn't hold, waits for the owner, and comes in
    // by the welcome of the owner's founding made again, held to the record.
    test(
      "a_member's_device_forgets_a_group_its_owner's_founding_left,_waits,_and_joins_the_one_made_again",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana);
        final founded = <Map<String, Object?>>[];
        final a = await firstDevice(fake, ana, client: _listingLostAfterFounding(fake, conversation, founded));
        final b = await firstDevice(fake, bo);
        fake.forget((method: 'POST', path: commitsPath(conversation)));
        await a.engine.openConversation(conversation).catchError((Object _) {});
        // The server gave Bo's device the founding's welcome, then kept nothing of it.
        await stoppedByHand(b);
        await byHand(b, {
          'cmd': 'apply',
          'conversation_id': conversation,
          'entries': [
            {
              'seq': 2,
              'kind': 'welcome',
              'data': founded.single['welcome'],
              'sent_at': DateTime.now().millisecondsSinceEpoch,
              'sender_user': ana,
              'sender_device': a.registered.last,
            },
          ],
          'external_sender': fake.externalSender,
        });
        expect((await groupOf(b, conversation))?.authenticator, (await groupOf(a, conversation))?.authenticator);

        // Bo's device starts again with no group listed: it forgets Ana's, and waits for her.
        final again = await restarted(fake, b);
        expect(await groupOf(again, conversation), isNull);
        expect(again.engine.conversationState(conversation), ConversationState.waitOwner(ana));
        expect(_recordOn(again, conversation), {
          'owner': ana,
          'members': [ana, bo],
          'exact': true,
        });
        // Ana opens it again: her device forgets hers too and founds it once more, and Bo's comes in.
        await a.engine.openConversation(conversation);
        await sameGroup([a, again], conversation);
        expect(_recordOn(again, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group("another_member's_group", () {
    // Ana's founding is forgotten and her device stops before it lists again; Bo makes the API's group. As Ana's
    // device starts, the welcome is another group's (another_group): it forgets its own and joins Bo's.
    test(
      'the_welcome_to_another_group_at_the_generation_the_device_holds_takes_it_into_the_apis',
      () async {
        final t = await _forgottenFounding();
        final own = (await groupOf(t.a, t.conversation))!;
        await t.b.engine.openConversation(t.conversation);
        final again = await restarted(t.fake, t.a);
        final held = await sameGroup([again, t.b], t.conversation);
        expect(held.authenticator, isNot(own.authenticator));
        final said = await _send(again, t.conversation, 'in the group they hold');
        await until(() async => await _textOn(t.b, t.conversation, said.id) == 'in the group they hold');
      },
      skip: noCore,
      timeout: _slow,
    );

    // Her own group past the API's epoch at that generation, by a renewal the API answered for and never kept: its
    // group info is of an epoch she saw pass, which only a device that forgot its own takes.
    test(
      'a_device_whose_own_group_passed_the_apis_epoch_takes_the_apis_after_forgetting_its_own',
      () async {
        final t = await _forgottenFounding();
        t.fake.refuse(
          (method: 'POST', path: commitsPath(t.conversation)),
          201,
          body: {'seq': 2, 'generation': 0, 'epoch': 2},
        );
        await commitByHand(t.a, t.conversation);
        expect((await groupOf(t.a, t.conversation))!.epoch, 2);
        await t.b.engine.openConversation(t.conversation);
        final again = await restarted(t.fake, t.a);
        final held = await sameGroup([again, t.b], t.conversation);
        expect(held.devices.length, 2);
      },
      skip: noCore,
      timeout: _slow,
    );

    // One read brings the welcome to the API's group at the generation Ana's device holds another of (another_group),
    // then Bo's restart of the API's group and its welcome, which her device takes. The note was of a generation she no
    // longer holds: nothing is forgotten, and she stays in the generation she joined.
    test(
      'a_note_of_another_group_at_a_generation_the_same_read_went_past_forgets_nothing',
      () async {
        final t = await _forgottenFounding();
        await t.b.engine.openConversation(t.conversation);
        await stoppedByHand(t.b);
        final made = await byHand(t.b, {
          'cmd': 'reset_group',
          'conversation_id': t.conversation,
          'members': [t.ana, t.bo],
          'key_packages': {
            for (final user in [t.ana, t.bo]) user: [for (final kp in await t.b.api.claimKeyPackages(user)) kp.data],
          },
        });
        final taken = await t.b.api.commit(
          t.conversation,
          duvet.Commit(
            generation: made['generation']! as int,
            epoch: 0,
            commit: made['commit']! as String,
            groupInfo: made['group_info']! as String,
            initialGroupInfo: made['initial_group_info']! as String,
            welcome: made['welcome'] as String?,
          ),
        );
        await t.b.host.handle<Object?>({
          'cmd': 'commit_result',
          'conversation_id': t.conversation,
          'accepted': true,
          'seq': taken.seq,
        });

        final commands = <Map<String, Object?>>[];
        final again = await restarted(t.fake, t.a, host: WatchedHost(t.a.host, [], commands: commands));
        final b = await restarted(t.fake, t.b);
        expect((await sameGroup([again, b], t.conversation)).generation, 1);
        await turnEnded(again);
        expect([
          for (final command in commands)
            if (const {'forget_group', 'join_external'}.contains(command['cmd'])) command['cmd'],
        ], isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Ana's own renewal loses its epoch to Bo's commit in the API's group (409) and stays staged, for a queue that is
    // another group's and never settles it. The welcome to the API's group is acted on all the same: her commit never
    // entered a group the API holds, so it's let go, and her device comes in.
    test(
      "a_commit_of_the_device's_own_another_commit_beat_keeps_no_welcome_to_another_group_from_being_acted_on",
      () async {
        final t = await _forgottenFounding();
        final own = (await groupOf(t.a, t.conversation))!;
        await t.b.engine.openConversation(t.conversation);
        await stoppedByHand(t.b);
        await commitByHand(t.b, t.conversation);
        final made = await byHand(t.a, {'cmd': 'refresh', 'conversation_id': t.conversation});
        final renewal = duvet.Commit(
          generation: own.generation,
          epoch: own.epoch,
          commit: made['commit']! as String,
          groupInfo: made['group_info']! as String,
        );
        await expectLater(
          t.a.api.commit(t.conversation, renewal),
          throwsA(isA<duvet.DuvetApiException>().having((error) => error.statusCode, 'status', 409)),
        );
        await t.a.host.handle<Object?>({'cmd': 'commit_result', 'conversation_id': t.conversation, 'accepted': false});

        final b = await restarted(t.fake, t.b);
        final again = await restarted(t.fake, t.a);
        final held = await sameGroup([again, b], t.conversation);
        expect(held.authenticator, isNot(own.authenticator));
      },
      skip: noCore,
      timeout: _slow,
    );

    // The record outlives a restart between the forget and the join, exact as the core answered it, and the join
    // takes it as it was kept.
    test(
      'the_exact_record_outlives_a_restart_between_the_forget_and_the_join,_which_takes_it_as_kept',
      () async {
        final t = await _forgottenFounding();
        await t.b.engine.openConversation(t.conversation);
        var holding = true;
        final client = _groupInfoHeld(t.fake, t.conversation, () => holding);
        var again = await restarted(t.fake, t.a, client: client);
        final record = {
          'members': [t.ana, t.bo],
          'exact': true,
        };
        await until(() => _recordOn(again, t.conversation) != null, what: 'the record of the forgotten group');
        expect(_recordOn(again, t.conversation), record);
        expect(await groupOf(again, t.conversation), isNull);
        // Its app ends before it joins; the group info comes once it starts again.
        await stoppedByHand(again);
        holding = false;
        final commands = <Map<String, Object?>>[];
        again = await restarted(
          t.fake,
          again,
          host: WatchedHost(again.host, [], commands: commands),
          client: client,
        );
        await sameGroup([again, t.b], t.conversation);
        expect(
          [
            for (final command in commands)
              if (command['cmd'] == 'join_external') command['expected'],
          ],
          [record],
        );
        expect(_recordOn(again, t.conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // A join the API refuses leaves the device a row without its group, which joins nothing the API's group hasn't
    // passed: it waits, holding its record and what the person typed, and comes in once another member's commit moves
    // the group on.
    test(
      'a_row_without_its_group_waits,_and_nothing_is_lost_meanwhile',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        var refusing = false;
        final lies = _lyingAfterFounding(fake, conversation, refusing: () => refusing);
        final a = await firstDevice(fake, ana, client: lies.client);
        final b = await firstDevice(fake, bo);
        fake.forget((method: 'POST', path: commitsPath(conversation)));
        await a.engine.openConversation(conversation);
        fake.cutRequest((method: 'POST', path: _messagesPath(conversation)));
        final cut = uuidv4();
        await a.engine
            .sendMessage(Outgoing(conversationId: conversation, nonce: cut, text: 'typed before'))
            .catchError((Object _) => null);
        await stoppedByHand(a);
        lies.stop();
        await b.engine.openConversation(conversation);

        // Ana's device takes the welcome as another group's and forgets its own; the API refuses its joins (422).
        refusing = true;
        final again = await restarted(fake, a, client: lies.client);
        await until(
          () => again.engine.conversationState(conversation) == ConversationState.waitRejoin,
          what: 'the refused join waiting',
        );
        await turnEnded(again);
        expect(await groupOf(again, conversation), isNull);
        expect(_recordOn(again, conversation), {
          'members': [ana, bo],
          'exact': true,
        });
        expect(await _waiting(again, conversation), [cut]);

        // Bo's next commit moves the group on, and the API takes Ana's join: her device comes in, and what she typed
        // goes, under a new nonce.
        await stoppedByHand(b);
        await commitByHand(b, conversation);
        refusing = false;
        final bAgain = await restarted(fake, b);
        await sameGroup([again, bAgain], conversation);
        again.connect(again.registered.last);
        await until(() async => (await _waiting(again, conversation)).isEmpty, what: 'the message that waited sent');
        final went = (await again.engine.sentUnder(conversation, cut))!;
        await until(() async => await _textOn(bAgain, conversation, went.messageId!) == 'typed before');
        expect(_recordOn(again, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  group('the_record', () {
    // The server adds Eve to the DM as it answers Ana's founding, which it keeps nothing of. The record of the group
    // Ana's device forgets is Ana and Bo, exactly: it founds nothing with Eve, and says so.
    test(
      'an_api_that_lists_someone_else_in_the_dm_after_the_forget_gets_members_changed,_never_a_group_with_them',
      () async {
        final fake = FakeApi();
        final (ana, bo, eve) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final founded = <String>[];
        final client = watchedClient(
          fake,
          change: (request, answered) async {
            if (request.method == 'POST' && request.url.path == commitsPath(conversation)) {
              founded.add(request.url.path);
              if (founded.length == 1) fake.addMembers(conversation, [eve]);
            }
            return answered;
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        final e = await firstDevice(fake, eve);
        fake.forget((method: 'POST', path: commitsPath(conversation)));
        await a.engine.openConversation(conversation);
        expect(a.engine.conversationState(conversation), ConversationState.membersChanged([ana, bo, eve]));
        expect(founded, hasLength(1));
        expect(await groupOf(a, conversation), isNull);
        expect(await groupOf(e, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Bo's device forgets its group once the server lists none, then the server lists it again and serves him the
    // group info of the epoch Cy was still in: the record, which the group Bo forgot had without Cy, refuses it.
    test(
      "an_old_epoch's_group_info_served_to_a_device_that_forgot_is_refused_for_the_member_removed_since",
      () async {
        final fake = FakeApi();
        final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
        var noGroup = false;
        duvet.MlsGroupInfo? old;
        final commits = <String>[];
        final client = watchedClient(
          fake,
          seen: (request) {
            if (request.method == 'POST' && request.url.path == commitsPath(conversation)) commits.add('commit');
          },
          change: (request, answered) async {
            if (request.method != 'GET') return answered;
            if (noGroup && request.url.path == _conversations) return _listedWith(answered, conversation, null);
            if (old case final served? when request.url.path == '$_conversations/$conversation/mls/group-info') {
              return _json({
                'generation': served.generation,
                'epoch': served.epoch,
                'group_info': served.groupInfo,
              }, 200);
            }
            return answered;
          },
        );
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo, client: client);
        final c = await firstDevice(fake, cy);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b, c], conversation);
        final withCy = await b.api.groupInfo(conversation);
        await a.engine.removeMember(conversation, cy);
        await until(() async => !(await _heldUsers(b, conversation)).contains(cy), what: "Cy's removal on Bo's device");

        noGroup = true;
        b.connect(b.registered.last);
        await until(() async => await groupOf(b, conversation) == null, what: "Bo's device forgetting its group");
        expect(_recordOn(b, conversation), {
          'owner': ana,
          'members': [ana, bo],
          'exact': true,
        });
        noGroup = false;
        old = withCy;
        commits.clear();
        b.connect(b.registered.last);
        await until(
          () => b.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged,
          what: 'the old group info refused',
        );
        expect(await groupOf(b, conversation), isNull);
        expect(commits, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The one case a forget's exact record changes for a welcome: Cy's device, which forgot the group of Ana, Bo and
    // Cy, is welcomed back by an addition into the group as it is since, without Bo. Its welcome is held to exactly the
    // record's users, so it's refused, and the conversation asks the person; held as a record from before the cutover
    // holds one, it would be taken.
    test(
      'a_welcome_after_a_forget_is_held_to_exactly_the_records_users',
      () async {
        final fake = FakeApi();
        final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
        // Ana may claim Cy's key packages once Cy is out: a friend's.
        fake.befriend(ana, cy);
        var noGroup = false;
        final client = watchedClient(
          fake,
          change: (request, answered) async => noGroup && request.method == 'GET' && request.url.path == _conversations
              ? _listedWith(answered, conversation, null)
              : answered,
        );
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        final c = await firstDevice(fake, cy, client: client);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b, c], conversation);
        noGroup = true;
        c.connect(c.registered.last);
        await until(() async => await groupOf(c, conversation) == null, what: "Cy's device forgetting its group");
        final record = {
          'owner': ana,
          'members': [ana, bo, cy],
          'exact': true,
        };
        expect(_recordOn(c, conversation), record);
        await c.engine.stop();
        noGroup = false;

        // Bo goes, then Cy, and Cy is added back: the welcome is to a group of Ana and Cy.
        await a.engine.removeMember(conversation, bo);
        await a.engine.removeMember(conversation, cy);
        await a.engine.addMember(conversation, cy);
        final commands = <Map<String, Object?>>[];
        final again = await restarted(
          fake,
          c,
          host: WatchedHost(c.host, [], commands: commands),
          client: client,
        );
        await until(
          () => again.engine.conversationState(conversation) == ConversationState.membersChanged([ana, cy]),
          what: 'the welcome refused for the record',
        );
        expect(await groupOf(again, conversation), isNull);
        final held = [
          for (final command in commands)
            if (command['cmd'] == 'apply')
              for (final entry in (command['entries']! as List).cast<Map<String, Object?>>())
                if (entry['kind'] == 'welcome') entry['expected'],
        ];
        expect(held, isNotEmpty);
        expect(held, everyElement(record));
      },
      skip: noCore,
      timeout: _slow,
    );

    // A blocked group the API doesn't hold is forgotten like any other: Ana's device takes the welcome to the group
    // the server had Bo's device found, Eve in it, then that group's renewal, which blocks her own. The record, Ana and
    // Bo, refuses Eve's group: her device holds none, and says so.
    test(
      "a_blocked_group_the_api_doesn't_hold_is_forgotten,_and_the_device_takes_no_group_with_a_user_its_record_lacks",
      () async {
        final t = await _forgottenFounding();
        final eve = t.fake.addUser();
        await firstDevice(t.fake, eve);
        await stoppedByHand(t.b);
        final made = await byHand(t.b, {
          'cmd': 'create_group',
          'conversation_id': t.conversation,
          'kind': 'group',
          'owner': t.bo,
          'members': [t.ana, t.bo, eve],
          'key_packages': {
            t.ana: [for (final kp in await t.b.api.claimKeyPackages(t.ana)) kp.data],
          },
          'external_sender': t.fake.externalSender,
          'legacy': false,
        });
        final taken = await t.b.api.commit(
          t.conversation,
          duvet.Commit(
            generation: 0,
            epoch: 0,
            commit: made['commit']! as String,
            groupInfo: made['group_info']! as String,
            initialGroupInfo: made['initial_group_info']! as String,
            welcome: made['welcome'] as String?,
          ),
        );
        await t.b.host.handle<Object?>({
          'cmd': 'commit_result',
          'conversation_id': t.conversation,
          'accepted': true,
          'seq': taken.seq,
        });
        await commitByHand(t.b, t.conversation);

        final again = await restarted(t.fake, t.a);
        await until(
          () => again.engine.conversationState(t.conversation)?.name == ConversationNotice.membersChanged,
          what: "Eve's group refused",
        );
        expect(await groupOf(again, t.conversation), isNull);
        expect(_recordOn(again, t.conversation), {
          'members': [t.ana, t.bo],
          'exact': true,
        });
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  // A row without its group (a join the API refused) is no group to make: create_group would answer `exists`, once
  // every member's key packages were claimed. It waits for the API's group to pass the epoch it saw, and says so.
  group('a_row_without_its_group', () {
    // The API lists no group of the DM any more: at a start, an open and a send, Ana's device claims no key package,
    // and the conversation says it waits for another member.
    test(
      'where_the_api_lists_no_group,_it_claims_no_key_package_and_waits_to_be_let_back_in',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        var lost = false;
        final claims = <String>[];
        final client = watchedClient(
          fake,
          seen: (request) {
            if (request.url.path.endsWith('/key-packages/claim')) claims.add(request.url.path);
          },
          change: (request, answered) async => lost && request.method == 'GET' && request.url.path == _conversations
              ? _listedWith(answered, conversation, null)
              : answered,
        );
        final a = await firstDevice(fake, ana, client: client);
        final b = await firstDevice(fake, bo);
        await _refusedJoin(fake, a, b, conversation);

        lost = true;
        final again = await restarted(fake, a, client: client);
        await until(
          () => again.engine.conversationState(conversation) == ConversationState.waitRejoin,
          what: 'the row waiting, said at the start',
        );
        await again.engine.openConversation(conversation).catchError((Object _) {});
        await again.engine
            .sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'not now'))
            .catchError((Object _) => null);
        await turnEnded(again);
        expect(claims, isEmpty);
        expect(again.engine.conversationState(conversation), ConversationState.waitRejoin);
        expect(await groupOf(again, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The server serves a group info of an epoch Ana's row saw pass (stale_group_info): her device joins nothing, and
    // the conversation says it waits for another member.
    test(
      'a_group_info_behind_the_epoch_it_saw_waits_to_be_let_back_in',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        duvet.MlsGroupInfo? served;
        final client = watchedClient(
          fake,
          change: (request, answered) async {
            if (served case final old?
                when request.method == 'GET' && request.url.path == '$_conversations/$conversation/mls/group-info') {
              return _json({'generation': old.generation, 'epoch': old.epoch, 'group_info': old.groupInfo}, 200);
            }
            return answered;
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        final b = await firstDevice(fake, bo);
        final infos = await _refusedJoin(fake, a, b, conversation, renewals: 1);

        served = infos[1];
        final again = await restarted(fake, a, client: client);
        await until(
          () => again.engine.conversationState(conversation) == ConversationState.waitRejoin,
          what: 'the old group info refused, waiting',
        );
        expect(await groupOf(again, conversation), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The founding's welcome to Ana's device is of an epoch her row saw pass (stale_welcome): an apply's result and
    // nothing more, reported as no failure to open. Her device comes in by its external commit on the API's group.
    test(
      "a_founding's_welcome_of_an_epoch_it_saw_pass_is_passed_by,_and_it_comes_in_by_its_external_commit",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final a = await firstDevice(fake, ana);
        final b = await firstDevice(fake, bo);
        await _refusedJoin(fake, a, b, conversation, renewals: 1);

        final commands = <Map<String, Object?>>[];
        final again = await restarted(fake, a, host: WatchedHost(a.host, [], commands: commands));
        await sameGroup([again, await restarted(fake, b)], conversation);
        expect([
          for (final command in commands)
            if (command['cmd'] == 'apply')
              for (final entry in (command['entries']! as List).cast<Map<String, Object?>>()) entry['kind'],
        ], contains('welcome'));
        expect([for (final command in commands) command['cmd']], contains('join_external'));
        expect(fake.decryptFailures, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );
  });
}
