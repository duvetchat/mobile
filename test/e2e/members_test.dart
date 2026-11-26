import 'dart:convert';

import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Who is in a conversation (PLAN-E2E-CLIENTES.md, Task 23: its Task 22 in Dart, case for case): making a DM or a group
// makes its group at once; a group's owner adds and removes one user a commit, 20 members at most with the owner; a
// member leaves with a statement their device signs, and the next member's commit takes them out. With step 3's closing
// review's two rules, and a change cut before its answer (Review Focus 3).
const _slow = Timeout(Duration(minutes: 3));

String _membersPath(String conversation) => '/api/users/@me/conversations/$conversation/members';

/// What a device asked of the members routes, and of the key packages' claims.
List<String> _memberRequests(List<http.Request> seen) => [
  for (final request in requestsOf(seen))
    if (request.contains('/members') || request.contains('/key-packages/claim')) request,
];

/// The users whose devices have leaves in the group as a device holds it.
Set<String> _usersIn(HeldGroup held) => {for (final d in held.devices) d.user};

/// The users the core's group lists as its members, in the order they entered.
Future<List<String>> _listed(TestDevice device, String conversation) async {
  final held = await device.host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversation});
  return [for (final m in (held['members']! as List).cast<Map<String, Object?>>()) m['user_id']! as String];
}

/// A group Ana made with Bo and Cy, each on a first device, its group made as she made it; [seen] her requests.
Future<({FakeApi fake, String ana, String bo, String cy, String group, List<TestDevice> devices})> _group({
  List<http.Request>? seen,
  http.Client Function(FakeApi fake)? cyClient,
}) async {
  final fake = FakeApi();
  final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
  final a = await firstDevice(fake, ana, client: seen == null ? null : watchedClient(fake, seen: seen.add));
  final b = await firstDevice(fake, bo);
  final c = await firstDevice(fake, cy, client: cyClient?.call(fake));
  final group = (await a.engine.createGroup('Crew', [bo, cy])).id;
  await sameGroup([a, b, c], group);
  return (fake: fake, ana: ana, bo: bo, cy: cy, group: group, devices: [a, b, c]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'making_a_DM_makes_its_group_at_once',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final b = await firstDevice(fake, bo);
      // Nobody opens it: Ana's device makes its group as the DM is made, and Bo's comes in by its welcome.
      final dm = (await a.engine.createDM(bo)).id;
      expect(requestsOf(seen), contains('POST ${commitsPath(dm)}'));
      expect(_usersIn(await sameGroup([a, b], dm)), {ana, bo});
      final creation = (await a.api.queue(dm, 0)).entries.first;
      expect((creation.kind, creation.senderUser, creation.epoch), ('commit', ana, 0));

      // A group the same way: its owner makes it.
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      expect(_usersIn(await sameGroup([a, b], group)), {ana, bo});
      // The DM asked for again is the one they have, its group made once.
      expect((await a.engine.createDM(bo)).id, dm);
      expect(requestsOf(seen).where((r) => r == 'POST ${commitsPath(dm)}'), hasLength(1));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'the_owner_adds_a_member_with_one_commit,_and_their_devices_join_by_its_welcome',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final b = await firstDevice(fake, bo);
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      // Cy, Ana's friend, with two devices.
      fake.befriend(ana, cy);
      final c1 = await firstDevice(fake, cy);
      final c2 = await approvedDevice(fake, c1);
      final before = (await a.api.queue(group, 0)).lastSeq;
      final from = seen.length;

      final member = await a.engine.addMember(group, cy);
      expect(member.userId, cy);
      // Their key packages, then one request: a commit of exactly that user, and its welcome.
      expect(_memberRequests(seen.sublist(from)), [
        'POST /api/users/$cy/key-packages/claim',
        'POST ${_membersPath(group)}',
      ]);
      final added = (await a.api.queue(group, before)).entries;
      expect([for (final e in added) (e.kind, e.senderUser)], [('commit', ana), ('welcome', ana)]);
      // Both of Cy's devices come in by it, and every device ends in one epoch.
      final held = await sameGroup([a, b, c1, c2], group);
      expect({for (final d in held.devices) d.device}, containsAll([c1.registered.last, c2.registered.last]));
      expect(await _listed(c2, group), [ana, bo, cy]);
      for (final d in [a, b, c1, c2]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 4: asked for at once, five additions go one after another, each a commit on the epoch the one before
  // made, and every device converges.
  test(
    'five_members_are_five_commits,_in_turn',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final others = [for (var i = 0; i < 6; i++) fake.addUser()];
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final devices = [for (final user in others) await firstDevice(fake, user)];
      final group = (await a.engine.createGroup('Crew', [others.first])).id;
      await sameGroup([a, devices.first], group);
      final five = others.sublist(1);
      for (final user in five) {
        fake.befriend(ana, user);
      }
      final epoch = (await groupOf(a, group))!.epoch;
      final before = (await a.api.queue(group, 0)).lastSeq;
      final from = seen.length;

      await Future.wait([for (final user in five) a.engine.addMember(group, user)]);
      // Five requests, none of them beaten to its epoch: five commits, each on the epoch the one before made.
      expect(requestsOf(seen.sublist(from)).where((r) => r == 'POST ${_membersPath(group)}'), hasLength(5));
      final commits = [
        for (final e in (await a.api.queue(group, before)).entries)
          if (e.kind == 'commit') (e.senderUser, e.epoch),
      ];
      expect(commits, [for (var n = 0; n < 5; n++) (ana, epoch + n)]);
      final held = await sameGroup([a, ...devices], group);
      expect(held.epoch, epoch + 5);
      expect(_usersIn(held), {ana, ...others});
      for (final d in [a, ...devices]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'the_21st_member_is_refused_before_a_key_package_is_asked_for',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final nineteen = [for (var i = 0; i < 19; i++) fake.addUser()];
      final last = fake.addUser();
      fake.befriend(ana, last);
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      // A group of 20, its owner among them; the others have no device yet.
      final group = fake.addConversation(group: true, members: [ana, ...nineteen], owner: ana);
      await a.engine.openConversation(group);
      await until(() async => await groupOf(a, group) != null);
      final from = seen.length;

      await expectLater(
        a.engine.addMember(group, last),
        throwsA(isA<CoreError>().having((e) => (e.code, e.limit), 'refusal', ('too_many_members', 20))),
      );
      // Nothing was asked: none of their key packages, no commit.
      expect(_memberRequests(seen.sublist(from)), isEmpty);
      await a.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 3's closing review: the API refuses a group of more than 20 with its owner, which the app's own cap holds first.
  test(
    'a_group_past_20_members_is_refused_before_it_is_asked_for',
    () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final others = [for (var i = 0; i < 20; i++) fake.addUser()];
      final seen = <http.Request>[];
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final from = seen.length;
      await expectLater(
        a.engine.createGroup('Crowd', others),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'too_many_members')),
      );
      expect(requestsOf(seen.sublist(from)), isNot(contains('POST /api/users/@me/conversations')));
      // Its owner and 19 others are 20: that one is made, with its group.
      final group = (await a.engine.createGroup('Twenty', others.sublist(1))).id;
      expect(await _listed(a, group), hasLength(20));
      await a.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'removing_a_member_takes_their_devices_out',
    () async {
      final seen = <http.Request>[];
      final (:fake, :ana, :bo, :cy, :group, :devices) = await _group(seen: seen);
      final [a, b, c] = devices;
      final c2 = await approvedDevice(fake, c);
      await sameGroup([a, b, c, c2], group);
      final from = seen.length;

      await a.engine.removeMember(group, cy);
      expect(_memberRequests(seen.sublist(from)), ['DELETE ${_membersPath(group)}/$cy']);
      // Both of Cy's devices are out; Ana's and Bo's go on without them, as the API's list does.
      await until(() async => await groupOf(c, group) == null && await groupOf(c2, group) == null);
      expect(_usersIn(await sameGroup([a, b], group)), {ana, bo});
      expect(await _listed(b, group), [ana, bo]);
      final listed = (await a.api.api.getConversations()).singleWhere((conv) => conv.id == group);
      expect([for (final m in listed.members) m.userId], [ana, bo]);
      for (final d in [a, b, c, c2]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "leaving_sends_a_signed_statement,_and_the_next_member's_commit_takes_the_leaver_out",
    () async {
      final cySeen = <http.Request>[];
      final (fake: _, :ana, :bo, :cy, :group, :devices) = await _group(
        cyClient: (fake) => watchedClient(fake, seen: cySeen.add),
      );
      final [a, b, c] = devices;
      await c.engine.leaveConversation(group);
      // A statement alone, signed by Cy's device (the fake checks it as the API does): no commit of their own removal.
      final leave = cySeen.singleWhere((r) => r.method == 'DELETE' && r.url.path == '${_membersPath(group)}/@me');
      expect((jsonDecode(leave.body) as Map).keys, ['statement']);
      expect(requestsOf(cySeen), isNot(contains('POST ${commitsPath(group)}')));
      expect(c.engine.conversationState(group), isNull);

      // The API proposes the removal of Cy's leaf; once their wait for it passes, a member's commit makes it.
      await until(() async => (await a.api.queue(group, 0)).entries.any((e) => e.kind == 'proposal'));
      await turnEnded(a);
      await turnEnded(b);
      a.clock.advance(const Duration(seconds: 5));
      b.clock.advance(const Duration(seconds: 5));
      await until(() async {
        final [heldA, heldB] = [await groupOf(a, group), await groupOf(b, group)];
        return heldA != null && heldB != null && !_usersIn(heldA).contains(cy) && !_usersIn(heldB).contains(cy);
      });
      expect(_usersIn(await sameGroup([a, b], group)), {ana, bo});
      expect(await _listed(a, group), [ana, bo]);
      final entries = (await a.api.queue(group, 0)).entries;
      final proposal = entries.lastWhere((e) => e.kind == 'proposal');
      expect(proposal.statement, isNotNull);
      expect([
        for (final e in entries)
          if (e.seq > proposal.seq && e.kind == 'commit') e.senderUser,
      ], hasLength(1));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 3's closing review (M6): a leave whose answer was lost, sent again, finds its user no longer a member: the
  // API's 403 is the leave.
  test(
    'a_leave_sent_again_after_its_answer_was_lost_is_taken_as_the_leave',
    () async {
      http.Request? first;
      final (:fake, ana: _, bo: _, :cy, :group, :devices) = await _group(
        cyClient: (fake) => watchedClient(
          fake,
          answer: (request) async {
            if (request.method != 'DELETE' || !request.url.path.endsWith('/members/@me')) return null;
            if (first == null) {
              // Cut on the way: the API takes it only after the person tries again.
              first = request;
              throw http.ClientException('the connection was cut');
            }
            await fake.client.send(first!);
            return null;
          },
        ),
      );
      final c = devices[2];
      await expectLater(c.engine.leaveConversation(group), throwsA(anything));
      // The second goes after the first reached the API: a 403, which the list says is the leave.
      await c.engine.leaveConversation(group);
      expect([for (final conv in await c.api.api.getConversations()) conv.id], isNot(contains(group)));
      expect(() => fake.membershipOf(group, cy), throwsStateError);
      for (final d in devices) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 3: an addition whose answer was lost, and the app gone before it went again, its bytes with it. The
  // core keeps the commit staged; the queue says the API took it, so it settles as taken, and the next change goes on.
  test(
    'an_addition_cut_before_its_answer_settles',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, di) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      fake
        ..befriend(ana, cy)
        ..befriend(ana, di);
      final c = await firstDevice(fake, cy);
      fake.loseAnswer((method: 'POST', path: _membersPath(group)));
      await expectLater(a.engine.addMember(group, cy), throwsA(anything));

      final again = await restarted(fake, a);
      final held = await sameGroup([again, b, c], group);
      expect(_usersIn(held), {ana, bo, cy});
      // Nothing waits any more: Di's addition goes through.
      final d = await firstDevice(fake, di);
      await again.engine.addMember(group, di);
      expect(_usersIn(await sameGroup([again, b, c, d], group)), {ana, bo, cy, di});
      for (final device in [again, b, c, d]) {
        await device.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The app's own wiring: its new group gets its group as it's made, its members change through its engine, and the
  // cap holds before anything is asked.
  test(
    "the_app_makes_a_new_group's_group_at_once,_and_changes_its_members_through_its_engine",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final app = await appOn(fake, ana);
      await app.ready();
      final b = await firstDevice(fake, bo);
      final c = await firstDevice(fake, cy);
      fake.befriend(ana, cy);
      final group = (await app.repository.createGroup('Crew', [bo])).id;
      await until(() async => await groupOf(b, group) != null);
      expect(app.count('POST', commitsPath(group)), 1);

      await app.repository.addToConversation(group, cy);
      expect(app.count('POST', _membersPath(group)), 1);
      await until(() async => await groupOf(c, group) != null);
      await app.repository.removeFromConversation(group, cy);
      expect(app.count('DELETE', '${_membersPath(group)}/$cy'), 1);
      await until(() async => await groupOf(c, group) == null);

      final from = app.seen.length;
      await expectLater(
        app.repository.createGroup('Crowd', [for (var i = 0; i < 20; i++) fake.addUser()]),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'A group can have 20 members at most')),
      );
      expect(app.count('POST', '/api/users/@me/conversations', from: from), 0);
      await b.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
