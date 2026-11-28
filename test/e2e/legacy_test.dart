import 'package:duvet/e2e/legacy.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A conversation from before the cutover (PLAN-E2E-CLIENTES.md, «Entrar a un grupo», its record; Ruling 14): its
// members as this device first saw them, which its group must have, until the person says the members of today are
// fine. The desktop's legacy.test.ts, with its review's rulings.
const _slow = Timeout(Duration(minutes: 3));

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "a_legacy_group_is_held_to_its_record;_the_person's_yes_drops_the_record_and_joins_by_external_commit",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, dee) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      // Cy's device sees the conversation first, with its three members: that's its record.
      final c = await firstDevice(fake, cy);
      expect(c.store.read(legacyRecords), {
        conversation: {
          'owner': ana,
          'members': [ana, bo, cy],
        },
      });

      // Then a member the record doesn't have shows up, and Ana makes the group with the members of today.
      fake.addMembers(conversation, [dee]);
      final a = await firstDevice(fake, ana);
      await a.engine.openConversation(conversation);
      expect((await groupOf(a, conversation))!.epoch, 1);

      // Cy's device refuses its welcome: the group isn't the one it knew. It says so, and offers to go on.
      await until(() => c.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
      expect(await groupOf(c, conversation), isNull);

      // Cy says yes: the members the question named are the record, which the device's external commit is held to; once
      // it holds the group, the record is let go.
      await acceptAsShown(c, conversation);
      await sameGroup([a, c], conversation);
      expect(c.engine.conversationState(conversation), isNull);
      expect(c.store.read(legacyRecords), {conversation: false});
      final entries = (await c.api.queue(conversation, 2)).entries;
      expect([for (final e in entries) (e.kind, e.senderUser)], [('commit', cy)]);
      await a.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Minor 7 of step 5's engines review: a generation the person was asked about goes from the record with its
  // conversation, so being added into it again later doesn't ask them of a conversation they had left.
  test(
    'a_conversation_this_user_is_no_longer_in_lets_its_refused_generation_go',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, dee) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      final c = await firstDevice(fake, cy);
      fake.addMembers(conversation, [dee]);
      final a = await firstDevice(fake, ana);
      await a.engine.openConversation(conversation);
      await until(() => c.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
      expect(refusedGenerationsIn(c.store).containsKey(conversation), isTrue);

      // Ana takes Cy out; Cy's Leave finds the conversation gone, and lets it go, its refusal with it.
      await a.engine.removeMember(conversation, cy);
      await c.engine.leaveConversation(conversation);
      expect(refusedGenerationsIn(c.store).containsKey(conversation), isFalse);
      await a.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of the desktop's review: a record the storage didn't take is kept for the session, so the conversation is still
  // held to the members this device first saw, not to whatever the next look finds.
  test(
    "a_record_the_storage_can't_keep_holds_for_the_session",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, dee) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      final store = KeyRefusingStore(legacyRecords);
      final c = await firstDevice(fake, cy, store: store);
      expect(store.read(legacyRecords), isNull);
      fake.addMembers(conversation, [dee]);
      final a = await firstDevice(fake, ana);
      await a.engine.openConversation(conversation);
      await until(() => c.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
      expect(await groupOf(c, conversation), isNull);
      await a.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M6 of the desktop's review: the person's yes makes the group where there's none, without the record it dropped.
  test(
    "the_person's_yes_makes_the_group_of_a_conversation_that_has_none",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo], owner: ana, legacy: true);
      // Bo's device keeps the conversation's two members; then Cy joins it, as the server alone changes it, before
      // Ana's and Cy's devices first see it.
      final b = await firstDevice(fake, bo);
      fake.addMembers(conversation, [cy]);
      final a = await firstDevice(fake, ana);
      final c = await firstDevice(fake, cy);
      // Opened, Bo's device won't make a group with members its record doesn't have.
      await b.engine.openConversation(conversation);
      expect(b.engine.conversationState(conversation)?.name, ConversationNotice.membersChanged);
      expect(await groupOf(b, conversation), isNull);
      // Bo says yes: the group is made with the members of today, and the others come in.
      await acceptAsShown(b, conversation);
      final held = await sameGroup([a, b, c], conversation);
      expect({for (final d in held.devices) d.user}, {ana, bo, cy});
      expect(b.store.read(legacyRecords), {conversation: false});
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M2 of the review: the person's yes, refused the group's info as the conversation is gone, lists the conversations
  // again and lets it go, as any turn does (I2 of the desktop's review), instead of failing into the tap. The yes reads
  // the list first (the members and generation it's given for, task 23's round 2): the conversation goes right after.
  test(
    "the_person's_yes_lets_go_a_conversation_whose_group_info_is_refused",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, dee) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      final seen = <http.Request>[];
      var goAfterList = false;
      final c = await firstDevice(
        fake,
        cy,
        client: watchedClient(
          fake,
          seen: seen.add,
          change: (request, answered) async {
            if (goAfterList && request.method == 'GET' && request.url.path == '/api/users/@me/conversations') {
              // Deleted once the yes has its list: its group's info is refused.
              goAfterList = false;
              fake
                ..deleteConversation(conversation)
                ..refuse(
                  (method: 'GET', path: '/api/users/@me/conversations/$conversation/mls/group-info'),
                  403,
                  body: {'error': "you aren't a member of this conversation"},
                );
            }
            return answered;
          },
        ),
      );
      fake.addMembers(conversation, [dee]);
      final a = await firstDevice(fake, ana);
      await a.engine.openConversation(conversation);
      await until(() => c.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
      final before = seen.length;
      goAfterList = true;
      await acceptAsShown(c, conversation);
      expect(requestsOf(seen.sublist(before)), [
        'GET /api/users/@me/conversations',
        'GET /api/users/@me/conversations/$conversation/mls/group-info',
        'GET /api/users/@me/conversations',
      ]);
      expect(c.engine.conversationState(conversation), isNull);
      await a.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // What a forget's record is kept over (`before`, mobile#369): a record from before the cutover, or one let go, comes
  // back once the device holds the group; a creation's goes; an earlier forget's `before` is carried on; the person's
  // yes (M2 of mobile#395's review), which holding the group lets go, is kept as let go. A yes alone is let go once the
  // group is held. Each as the record keeps it, read back.
  test('a_forget_keeps_what_its_record_replaces_and_gives_it_back_once_the_group_is_held', () async {
    final store = MemoryStore();
    final records = LegacyRecords(store);
    const forgotten = (owner: 'o', members: ['o', 'm'], exact: true);
    final exact = {
      'owner': 'o',
      'members': ['o', 'm'],
      'exact': true,
    };
    final legacy = {
      'owner': 'o',
      'members': ['o', 'm', 'x'],
    };
    await store.write(legacyRecords, {
      'legacy': legacy,
      'let_go': false,
      'made': {
        'owner': 'o',
        'members': ['o', 'm'],
        'created': true,
      },
    });
    const yes = (owner: 'o', members: ['o', 'm', 'y'], exact: false);
    for (final id in ['chosen', 'yes']) {
      await records.chosen(id, yes);
    }
    expect((store.read(legacyRecords)! as Map)['yes'], {
      'owner': 'o',
      'members': ['o', 'm', 'y'],
      'chosen': true,
    });
    // What a push's engine holds its welcomes to, as a record from before the cutover.
    final kept = records.kept('yes')!;
    expect((kept.owner, kept.exact), ('o', false));
    expect(kept.members, yes.members);
    for (final id in ['legacy', 'let_go', 'made', 'chosen']) {
      await records.forgot(id, forgotten);
    }
    // Forgotten again before the group is held: what the first forget kept over is carried on.
    await records.forgot('legacy', forgotten);
    expect(store.read(legacyRecords), {
      'legacy': {...exact, 'before': legacy},
      'let_go': {...exact, 'before': false},
      'made': exact,
      'chosen': {...exact, 'before': false},
      'yes': {
        'owner': 'o',
        'members': ['o', 'm', 'y'],
        'chosen': true,
      },
    });
    expect(records.kept('let_go')?.exact, isTrue);

    for (final id in ['legacy', 'let_go', 'made', 'chosen', 'yes']) {
      await records.heldGroup(id);
    }
    expect(store.read(legacyRecords), {'legacy': legacy, 'let_go': false, 'chosen': false, 'yes': false});
  });

  test('a_record_is_its_owner_and_members_as_the_core_takes_them', () {
    expect(expectedOf((owner: 'o', members: ['o', 'm'], exact: false)), {
      'owner': 'o',
      'members': ['o', 'm'],
    });
    expect(expectedOf((owner: null, members: ['a', 'b'], exact: false)), {
      'members': ['a', 'b'],
    });
    // A forgotten group's record goes back as the core gave it (mobile#369).
    expect(expectedOf((owner: null, members: ['a', 'b'], exact: true)), {
      'members': ['a', 'b'],
      'exact': true,
    });
    // What the record reads: a record; anything else (a dropped one's false included) is none.
    final read = recordIn({
      'owner': 'a',
      'members': ['a', 'b'],
    })!;
    expect(read.owner, 'a');
    expect(read.members, ['a', 'b']);
    expect(read.exact, isFalse);
    expect(recordIn({'members': <String>[], 'exact': true, 'before': false})?.exact, isTrue);
    expect(
      recordIn({
        'members': ['a'],
      })?.owner,
      isNull,
    );
    expect(recordIn(false), isNull);
    expect(recordIn({'members': 'a'}), isNull);
    expect(recordIn({'owner': 1, 'members': <String>[]}), isNull);
    expect(deviceRecord, isNot(contains(legacyRecords)));
  });
}
