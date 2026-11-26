import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Joining and making a conversation's group (PLAN-E2E-CLIENTES.md, «Entrar a un grupo»), and a blocked group's
// restart: who makes a group, and how the others come into it. The desktop's groups.test.ts, case for case, with its
// review's rulings.
const _slow = Timeout(Duration(minutes: 3));

/// What a device posted to the conversation's commits route.
List<String> _commitsPosted(List<http.Request> seen, String conversation) => [
  for (final request in requestsOf(seen))
    if (request == 'POST ${commitsPath(conversation)}') request,
];

/// A group of Ana's, Bo's and Cy's first devices, Ana its owner, whose group Ana made as she opened it.
Future<({FakeApi fake, String ana, String bo, String cy, String conversation, List<TestDevice> devices})> _group({
  List<http.Request>? boSeen,
}) async {
  final fake = FakeApi();
  final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
  final a = await firstDevice(fake, ana);
  final b = await firstDevice(fake, bo, client: boSeen == null ? null : watchedClient(fake, seen: boSeen.add));
  final c = await firstDevice(fake, cy);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b, c], conversation);
  return (fake: fake, ana: ana, bo: bo, cy: cy, conversation: conversation, devices: [a, b, c]);
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'the_owner_makes_a_new_group_and_the_others_wait',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo, client: watchedClient(fake, seen: seen.add));
      final c = await firstDevice(fake, cy);
      // Bo opens the group before its owner: he waits for her, and nothing is made.
      await b.engine.openConversation(conversation);
      expect(b.engine.conversationState(conversation), ConversationState.waitOwner(ana));
      expect(_commitsPosted(seen, conversation), isEmpty);
      expect(await groupOf(b, conversation), isNull);

      // Ana opens it: she makes it, and the others come in by its welcome.
      await a.engine.openConversation(conversation);
      final held = await sameGroup([a, b, c], conversation);
      expect({for (final d in held.devices) d.user}, {ana, bo, cy});
      await until(() => b.engine.conversationState(conversation) == null);
      expect(a.engine.conversationState(conversation), isNull);
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "either_member_makes_a_DM's",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo], owner: ana);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      // Bo, who isn't the one who started the DM, opens it first and makes its group.
      await b.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);
      final creation = (await a.api.queue(conversation, 0)).entries.first;
      expect((creation.kind, creation.senderUser, creation.generation, creation.epoch), ('commit', bo, 0, 0));
      expect(b.engine.conversationState(conversation), isNull);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'two_members_make_a_legacy_group_at_once_and_end_in_the_same_one',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      final [a, b, c] = [await firstDevice(fake, ana), await firstDevice(fake, bo), await firstDevice(fake, cy)];
      // Both open it at once: both make a group, and their creations reach the API together.
      fake.gather((method: 'POST', path: commitsPath(conversation)), 2);
      await Future.wait([a.engine.openConversation(conversation), b.engine.openConversation(conversation)]);
      await sameGroup([a, b, c], conversation);
      // One creation took epoch 0; the other's maker came in by the winner's welcome.
      final entries = (await a.api.queue(conversation, 0)).entries;
      expect([
        for (final e in entries)
          if (e.kind == 'commit' && e.epoch == 0) e.seq,
      ], hasLength(1));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_blocked_group_offers_its_restart_to_its_owner,_and_everyone_joins_the_next_generation',
    () async {
      final (:fake, :ana, bo: _, cy: _, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      // Its owner is offered the restart, the others wait for her.
      expect(a.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.mine, owner: ana));
      expect(b.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.owner, owner: ana));
      expect(c.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.owner, owner: ana));

      // Bo can't restart it; Ana can, and everyone joins the next generation, the notices gone.
      await b.engine.restartGroup(conversation);
      expect((await groupOf(b, conversation))!.generation, 0);
      await a.engine.restartGroup(conversation);
      final after = await sameGroup([a, b, c], conversation);
      expect((after.generation, after.blocked), (1, false));
      await until(() => [a, b, c].every((d) => d.engine.conversationState(conversation) == null));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the desktop's review: the restart's commit and its welcome are two messages of the gateway's. A device that
  // hears the commit first reads the welcome from the queue, after the commit it counted: no external commit races.
  test(
    "a_restart's_welcome_brings_every_device_in,_though_its_event_comes_after_the_commit's_turn",
    () async {
      final (:fake, ana: _, bo: _, cy: _, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      fake.holdEvents();
      await a.engine.restartGroup(conversation);
      final restart = (await a.api.queue(conversation, 0)).entries.last;
      expect(restart.kind, 'welcome');
      // The commit's event alone, and the engines' turns for it; then the welcome's.
      fake.releaseEvents(only: (event) => event.type == 'MLS_COMMIT');
      await turnEnded(b);
      await turnEnded(c);
      fake.releaseEvents();
      final after = await sameGroup([a, b, c], conversation);
      expect((after.generation, after.blocked), (1, false));
      // Nothing after the restart's welcome: no device made an external commit.
      expect((await a.api.queue(conversation, restart.seq)).entries, isEmpty);
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the desktop's review: a commit that takes a user out of the group is answered by listing the conversations
  // again, which no longer have them: their device doesn't try to come back, and nothing is retried.
  test(
    "a_removed_user's_device_doesn't_try_to_come_back",
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, :bo, cy: _, :conversation, :devices) = await _group(boSeen: seen);
      final [a, b, c] = devices;
      // Ana, its owner, takes Bo out, by hand (Task 23 does it in the app).
      await stoppedByHand(a);
      final before = seen.length;
      await removeByHand(a, conversation, bo);
      // Bo's device applies its removal; Cy's goes on with Ana's.
      await until(() async => await groupOf(b, conversation) == null);
      await sameGroup([a, c], conversation);
      await turnEnded(b);
      // Later, and a few minutes on: never the group's info, a commit or the queue again.
      for (var n = 0; n < 5; n++) {
        b.clock.advance(const Duration(minutes: 1));
        await turnEnded(b);
      }
      final after = requestsOf(seen.sublist(before));
      expect(after.where((r) => r.contains('/mls/')), isEmpty);
      expect(after, contains('GET /api/users/@me/conversations'));
      expect(b.engine.conversationState(conversation), isNull);
      await a.host.close();
      await b.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I4 of the desktop's task 16 review: a member removed and added back has a new membership, after the rows of their
  // absence, which this device doesn't hold. Those give way to the notice, and the pages go on to what the device holds
  // from before (Ruling 15 hides rows; it doesn't end the list): they end only where it holds nothing older.
  test(
    'a_member_removed_and_added_back_pages_on_to_the_history_the_device_holds',
    () async {
      final (:fake, ana: _, bo: _, :cy, :conversation, :devices) = await _group();
      final [a, b, c] = devices;
      final mine = (await c.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'mine')))!;
      final keyPackages = await a.api.claimKeyPackages(cy);
      await stoppedByHand(a);
      await removeByHand(a, conversation, cy);
      await until(() async => await groupOf(c, conversation) == null);
      final away = (await b.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'away')))!;
      await addByHand(a, conversation, cy, keyPackages);
      await until(() async => await groupOf(c, conversation) != null);
      expect(away.id.compareTo(fake.membershipOf(conversation, cy)), lessThan(0));
      // The row of Cy's absence isn't on Cy's device, and Cy's own message from before is: the pages go on to it.
      expect(await c.engine.messages(conversation, [away.id]), isEmpty);
      expect(await c.engine.heldBefore(conversation, away.seq!), isTrue);
      // Nothing older than it: there they end.
      expect(await c.engine.heldBefore(conversation, mine.seq!), isFalse);
      await a.host.close();
      await b.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the desktop's review, for an addition: a user removed and added back has a count in the queue, and the
  // welcome that brings them back follows the addition's commit there.
  test(
    'a_user_removed_and_added_back_comes_in_by_the_new_welcome',
    () async {
      final (:fake, :ana, bo: _, :cy, :conversation, :devices) = await _group();
      final [a, b, c] = devices;
      // Key packages of Cy's, claimed while they share the group: Ana can't claim them once Cy is out of hers.
      final keyPackages = await a.api.claimKeyPackages(cy);
      await stoppedByHand(a);
      final removal = await removeByHand(a, conversation, cy);
      await until(() async => await groupOf(c, conversation) == null);
      await turnEnded(c);

      // Ana adds Cy back. Cy's device hears nothing of it while minutes pass, then the addition's commit, and its turn
      // ends; then the welcome.
      fake.holdEvents();
      await addByHand(a, conversation, cy, keyPackages);
      for (var minute = 0; minute < 3; minute++) {
        c.clock.advance(const Duration(minutes: 1));
        await turnEnded(c);
      }
      fake.releaseEvents(only: (event) => event.type == 'MLS_COMMIT');
      await turnEnded(c);
      fake.releaseEvents();
      await until(() async => await groupOf(c, conversation) != null);
      final since = [
        for (final e in (await b.api.queue(conversation, removal.seq)).entries)
          if (e.kind == 'commit') e.senderUser,
      ];
      expect(since, [ana]);
      await sameGroup([a, b, c], conversation);
      await a.host.close();
      await b.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // The core's #46: a restart founds the next generation with the API's members and owner. Whom it leaves out (those
  // the core's group holds that the API no longer lists) the person is told first, and it's made only on their yes.
  test(
    'a_restart_names_who_it_leaves_out,_and_restarts_once_the_person_says_yes',
    () async {
      final (:fake, :ana, :bo, :cy, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      // The server took Cy out with no commit: the API lists Ana and Bo.
      fake.dropMembers(conversation, [cy]);
      final last = (await a.api.queue(conversation, 0)).lastSeq;
      expect(await a.engine.restartGroup(conversation), [cy]);
      expect((await a.api.queue(conversation, last)).entries, isEmpty);

      expect(await a.engine.restartGroup(conversation, leaving: [cy]), isEmpty);
      final after = await sameGroup([a, b], conversation);
      expect((after.generation, after.blocked), (1, false));
      expect({for (final d in after.devices) d.user}, {ana, bo});
      await until(() => [a, b].every((d) => d.engine.conversationState(conversation) == null));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The core's #46: a successor restarts a blocked group its owner left only on the owner's statement, which its core
  // holds. The server took the owner out with none: the reset is refused, and the group stays blocked.
  test(
    "a_successor's_restart_without_the_owner's_statement_leaves_the_group_blocked",
    () async {
      final (:fake, :ana, :bo, cy: _, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      fake.dropMembers(conversation, [ana]);
      // Bo, next in line, is the API's owner: his device hears of it at its next session.
      b.connect(b.registered.last);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      final last = (await b.api.queue(conversation, 0)).lastSeq;
      expect(await b.engine.restartGroup(conversation), [ana]);
      await expectLater(
        b.engine.restartGroup(conversation, leaving: [ana]),
        throwsA(isA<CoreError>().having((e) => e.rule, 'rule', 'member_list_mismatch')),
      );
      expect((await b.api.queue(conversation, last)).entries, isEmpty);
      expect((await groupOf(b, conversation))!.blocked, isTrue);
      expect(b.engine.conversationState(conversation)?.name, ConversationNotice.blocked);
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The owner leaves the blocked group with her statement, which the API's proposal carries to every member's core:
  // Bo, her successor, is offered the restart, which leaves her out on his yes, and Cy's core takes its welcome.
  test(
    'a_successor_restarts_a_group_its_owner_left,_on_her_statement',
    () async {
      final (:fake, :ana, :bo, :cy, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      await a.engine.leaveConversation(conversation);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      await until(() async => (await b.api.queue(conversation, 0)).entries.any((e) => e.kind == 'proposal'));
      await turnEnded(b);
      await turnEnded(c);
      expect(await b.engine.restartGroup(conversation), [ana]);
      expect(await b.engine.restartGroup(conversation, leaving: [ana]), isEmpty);
      final after = await sameGroup([b, c], conversation);
      expect((after.generation, after.blocked), (1, false));
      expect({for (final d in after.devices) d.user}, {bo, cy});
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The core's #46: a device out of a restart's next generation (here, one whose maker brought it no welcome) never
  // joins it by an external commit on its own while its members aren't those its core holds: the conversation says its
  // members changed, and it joins on the person's yes.
  test(
    "a_restart_that_brings_this_device_no_welcome_waits_for_the_person's_yes",
    () async {
      final (:fake, ana: _, :bo, :cy, :conversation, :devices) = await _group();
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      // Ana leaves the blocked group with her statement, which reaches Bo's core and Cy's with its proposal.
      await a.engine.leaveConversation(conversation);
      await until(() async => (await b.api.queue(conversation, 0)).entries.any((e) => e.kind == 'proposal'));
      await turnEnded(b);
      await turnEnded(c);
      // Bo restarts it by hand without Cy's key packages: no welcome for Cy's device.
      await stoppedByHand(b);
      final made = await byHand(b, {
        'cmd': 'reset_group',
        'conversation_id': conversation,
        'owner': bo,
        'members': [bo, cy],
        'key_packages': {bo: <String>[], cy: <String>[]},
      });
      final taken = await b.api.commit(
        conversation,
        duvet.Commit(
          generation: made['generation']! as int,
          epoch: 0,
          commit: made['commit']! as String,
          groupInfo: made['group_info']! as String,
          initialGroupInfo: made['initial_group_info']! as String,
          welcome: made['welcome'] as String?,
        ),
      );
      await b.host.handle<Object?>({
        'cmd': 'commit_result',
        'conversation_id': conversation,
        'accepted': true,
        'seq': taken.seq,
      });
      await until(() => c.engine.conversationState(conversation) == ConversationState.membersChanged);
      // Cy's device didn't come in on its own.
      expect((await c.api.queue(conversation, taken.seq)).entries.where((e) => e.kind == 'commit'), isEmpty);
      expect((await groupOf(c, conversation))!.generation, 0);

      await c.engine.acceptMembers(conversation);
      await until(() async => (await groupOf(c, conversation))?.generation == 1);
      expect(c.engine.conversationState(conversation), isNull);
      await a.engine.stop();
      await b.host.close();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M1 of the review: a refused restart says so once (the core's rule_violation reaches the caller) and keeps Restart
  // off until a new entry comes, so no further tap claims anyone's key packages for nothing.
  test(
    'a_refused_restart_keeps_restart_off_until_a_new_entry_comes',
    () async {
      final seen = <http.Request>[];
      final (:fake, :ana, :bo, :cy, :conversation, :devices) = await _group(boSeen: seen);
      final [a, b, c] = await blockedByHand(fake, conversation, devices);
      fake.dropMembers(conversation, [ana]);
      b.connect(b.registered.last);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      await expectLater(
        b.engine.restartGroup(conversation, leaving: [ana]),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'rule_violation')),
      );
      expect(b.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.none, owner: bo));
      final from = seen.length;
      expect(await b.engine.restartGroup(conversation, leaving: [ana]), isEmpty);
      expect(requestsOf(seen.sublist(from)).where((r) => r.contains('/key-packages/claim')), isEmpty);
      // A new entry (Cy's leave, which the API proposes) offers it again.
      await c.engine.leaveConversation(conversation);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The core's #46 with honest cores (M5 of the review, the desktop's case): the server keeps Ana's leave statement
  // from Cy, so Bo's restart, which leaves her out on his core's statement, is refused at Cy's core. Cy's device
  // doesn't join it on its own, keeps that across a restart of the app (M4), says why it can't leave from there (M6),
  // and joins on the person's yes.
  test(
    "a_refused_restart_welcome_waits_for_the_person's_yes,_across_a_restart",
    () async {
      final cySeen = <http.Request>[];
      final (:fake, :ana, :bo, :cy, :conversation, :devices) = await _group();
      var [a, b, c] = await blockedByHand(fake, conversation, devices);
      fake.hideStatements(cy);
      await a.engine.leaveConversation(conversation);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      await until(() async => (await b.api.queue(conversation, 0)).entries.any((e) => e.kind == 'proposal'));
      await turnEnded(b);
      await turnEnded(c);
      expect(await b.engine.restartGroup(conversation), [ana]);
      expect(await b.engine.restartGroup(conversation, leaving: [ana]), isEmpty);
      await until(() => c.engine.conversationState(conversation) == ConversationState.membersChanged);

      // The app again, on the same record and core: still the person's to say, and nothing joined.
      c = await restarted(fake, c, client: watchedClient(fake, seen: cySeen.add));
      await turnEnded(c);
      expect(c.engine.conversationState(conversation), ConversationState.membersChanged);
      expect(requestsOf(cySeen), isNot(contains('POST ${commitsPath(conversation)}')));
      await expectLater(
        c.engine.leaveConversation(conversation),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'not_in_group')),
      );

      await c.engine.acceptMembers(conversation);
      final after = await sameGroup([b, c], conversation);
      expect((after.generation, after.blocked), (1, false));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M6 of the desktop's review: a conversation shown while the engine can't work yet (here, before the person set up
  // their first device) gets its group once the engine is ready.
  test(
    'a_conversation_opened_before_the_device_is_ready_gets_its_group_once_it_is',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo], owner: ana);
      final a = await firstDevice(fake, ana);
      final b = testDevice(fake, bo);
      await b.engine.start();
      expect(b.state, const EngineState.firstDevice());
      await b.engine.openConversation(conversation);
      expect(await groupOf(b, conversation), isNull);
      await b.engine.makeIdentity();
      await b.engine.keySaved();
      await sameGroup([a, b], conversation);
      final creation = (await a.api.queue(conversation, 0)).entries.first;
      expect(creation.senderUser, bo);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
