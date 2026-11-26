import 'dart:convert';

import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/sync.dart' show entryOf;
import 'package:duvet_client/duvet.dart' as duvet;
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

/// A stopped device's core brought to the queue's end by hand, as its engine would: its next commit by hand goes on
/// the epoch the group is at.
Future<void> _caughtUp(FakeApi fake, TestDevice device, String conversation) async {
  Future<Map<String, Object?>> apply(List<Map<String, Object?>> entries) => byHand(device, {
    'cmd': 'apply',
    'conversation_id': conversation,
    'entries': entries,
    'external_sender': fake.externalSender,
  });
  final through = (await apply([]))['applied_through'] as int? ?? 0;
  await apply([for (final entry in (await device.api.queue(conversation, through)).entries) entryOf(entry)]);
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

  // Step 3's closing review: the API refuses a group of more than 20 with its owner, which the app's own cap holds
  // first.
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

  // M2 of the review: a change asked for again while the first, unanswered, still waits: the first goes again first,
  // and the second finds it done, as the person asked. A removal the same.
  test(
    'the_same_change_asked_again_after_it_went_unanswered_is_done_once',
    () async {
      final seen = <http.Request>[];
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final b = await firstDevice(fake, bo);
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      fake.befriend(ana, cy);
      final c = await firstDevice(fake, cy);
      List<String> asked(String method, String path) => [
        for (final r in requestsOf(seen))
          if (r == '$method $path') r,
      ];

      // The first never reaches the API; asked again before it goes again, it goes, and the second is that one.
      fake.cutRequest((method: 'POST', path: _membersPath(group)));
      await expectLater(
        a.engine.addMember(group, cy),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'unanswered')),
      );
      expect((await a.engine.addMember(group, cy)).userId, cy);
      expect(asked('POST', _membersPath(group)), hasLength(2));
      expect(_usersIn(await sameGroup([a, b, c], group)), {ana, bo, cy});

      fake.cutRequest((method: 'DELETE', path: '${_membersPath(group)}/$cy'));
      await expectLater(
        a.engine.removeMember(group, cy),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'unanswered')),
      );
      await a.engine.removeMember(group, cy);
      expect(asked('DELETE', '${_membersPath(group)}/$cy'), hasLength(2));
      expect(_usersIn(await sameGroup([a, b], group)), {ana, bo});
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review, the desktop's case (Review Focus 3): an addition whose answer is lost goes again, on its own,
  // with its bytes, to the members route, which the API answers as it did: the user is added once.
  test(
    'an_addition_whose_answer_is_lost_is_sent_again_with_its_bytes,_and_the_user_is_added_once',
    () async {
      final seen = <http.Request>[];
      final fake = FakeApi();
      final (ana, bo, di) = (fake.addUser(), fake.addUser(), fake.addUser());
      final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
      final b = await firstDevice(fake, bo);
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      fake.befriend(ana, di);
      final d = await firstDevice(fake, di);
      final from = seen.length;
      List<String> posted() => [
        for (final r in seen.sublist(from))
          if (r.method == 'POST' && r.url.path == _membersPath(group)) r.body,
      ];

      fake.loseAnswer((method: 'POST', path: _membersPath(group)));
      await expectLater(
        a.engine.addMember(group, di),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'unanswered')),
      );
      await until(() {
        a.clock.advance(const Duration(seconds: 2));
        return posted().length >= 2;
      });
      expect(posted().toSet(), hasLength(1));
      expect(requestsOf(seen.sublist(from)), isNot(contains('POST ${commitsPath(group)}')));
      expect(_usersIn(await sameGroup([a, b, d], group)), {ana, bo, di});
      final listed = (await a.api.api.getConversations()).singleWhere((conv) => conv.id == group);
      expect([for (final m in listed.members) m.userId], [ana, bo, di]);
      for (final device in [a, b, d]) {
        await device.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review, the desktop's case: another device of the user's left first, so the API's 403 (they aren't a
  // member any more) is this device's leave too, which the list confirms; and the same for a 404, the membership gone
  // as the API looked (the owner's removal crossing the leave).
  test(
    'a_leave_the_API_refuses_as_its_user_is_out_already_is_the_leave',
    () async {
      final (:fake, ana: _, bo: _, :cy, :group, :devices) = await _group();
      final [a, b, c] = devices;
      final c2 = await approvedDevice(fake, c);
      await sameGroup([a, b, c, c2], group);
      // Both leave at once: the API takes one, and answers the other 403. The fake holds both until both came.
      fake.gather((method: 'DELETE', path: '${_membersPath(group)}/@me'), 2);
      await Future.wait([c.engine.leaveConversation(group), c2.engine.leaveConversation(group)]);
      final listed = (await a.api.api.getConversations()).singleWhere((conv) => conv.id == group);
      expect([for (final m in listed.members) m.userId], isNot(contains(cy)));
      for (final d in [a, b, c, c2]) {
        await d.engine.stop();
      }

      // A 404 the list doesn't confirm is the failure it is; one it confirms (the owner's removal crossing the leave,
      // the membership gone as the API looked) is the leave.
      final other = FakeApi();
      final (ana2, bo2, cy2) = (other.addUser(), other.addUser(), other.addUser());
      String? group2;
      var crossed = false;
      final a2 = await firstDevice(other, ana2);
      final b2 = await firstDevice(other, bo2);
      final c3 = await firstDevice(
        other,
        cy2,
        client: watchedClient(
          other,
          answer: (request) async {
            final at = group2;
            if (at == null || request.method != 'DELETE' || request.url.path != '${_membersPath(at)}/@me') return null;
            if (crossed) other.dropMembers(at, [cy2]);
            return http.Response(
              jsonEncode({'error': 'not a member'}),
              404,
              headers: {'content-type': 'application/json'},
            );
          },
        ),
      );
      group2 = (await a2.engine.createGroup('Crew', [bo2, cy2])).id;
      await sameGroup([a2, b2, c3], group2);
      await expectLater(
        c3.engine.leaveConversation(group2),
        throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      crossed = true;
      await c3.engine.leaveConversation(group2);
      expect(() => other.membershipOf(group2!, cy2), throwsStateError);
      for (final d in [a2, b2, c3]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review, missing on both sides: a change another commit beat to its epoch (a 409) is made again on top of
  // it, three tries at most; and one sent again on its own after no answer came, beaten so, is made again too (the
  // desktop's review, «For task 23»).
  test(
    'a_change_another_commit_beat_to_its_epoch_is_made_again,_three_tries_at_most',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, di) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      var beat = 0;
      final seen = <http.Request>[];
      late final TestDevice b;
      final a = await firstDevice(
        fake,
        ana,
        client: watchedClient(
          fake,
          seen: seen.add,
          answer: (request) async {
            // Bo's commit takes the epoch first, as many times as asked.
            if (beat > 0 && request.method == 'POST' && request.url.path.endsWith('/members')) {
              beat--;
              final conversation = request.url.pathSegments[request.url.pathSegments.length - 2];
              await _caughtUp(fake, b, conversation);
              await commitByHand(b, conversation);
            }
            return null;
          },
        ),
      );
      b = await firstDevice(fake, bo);
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      fake
        ..befriend(ana, cy)
        ..befriend(ana, di);
      final c = await firstDevice(fake, cy);
      final d = await firstDevice(fake, di);
      await stoppedByHand(b);
      int posts() => seen.where((r) => r.method == 'POST' && r.url.path == _membersPath(group)).length;

      // Beaten once: made again on the epoch Bo's commit made, and taken.
      beat = 1;
      var from = posts();
      expect((await a.engine.addMember(group, cy)).userId, cy);
      expect(posts() - from, 2);
      await until(() async => await groupOf(c, group) != null);

      // Beaten three times: the third 409 is the answer.
      beat = 3;
      from = posts();
      await expectLater(
        a.engine.addMember(group, di),
        throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 409)),
      );
      expect(posts() - from, 3);

      // Cut on its way, then beaten as it goes again on its own: made again, and Di is in.
      beat = 0;
      fake.cutRequest((method: 'POST', path: _membersPath(group)));
      await expectLater(
        a.engine.addMember(group, di),
        throwsA(isA<CoreError>().having((e) => e.code, 'code', 'unanswered')),
      );
      beat = 1;
      await until(() async {
        a.clock.advance(const Duration(seconds: 2));
        return (await groupOf(d, group)) != null;
      });
      expect(_usersIn((await groupOf(a, group))!), {ana, bo, cy, di});
      await b.host.close();
      for (final device in [a, c, d]) {
        await device.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The desktop's review, «For task 23»: the engine's own refusals reach the person in the app's words, never as its
  // codes or as «not ready»: a DM's members don't change, only a group's owner changes its members, and a change still
  // on its way goes again on its own.
  test(
    "the_engine's_own_refusals_reach_the_person_in_the_app's_words",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final app = await appOn(fake, ana);
      await app.ready();
      final b = await firstDevice(fake, bo);
      fake
        ..befriend(ana, cy)
        ..befriend(bo, cy);
      Matcher says(String words) => throwsA(isA<ActionFailed>().having((e) => e.message, 'message', words));
      final dm = fake.addConversation(group: false, members: [ana, bo]);
      await expectLater(app.repository.addToConversation(dm, cy), says('A direct message’s members don’t change.'));
      final bos = (await b.engine.createGroup('Crew', [ana])).id;
      await expectLater(app.repository.addToConversation(bos, cy), says('Only the group’s owner changes its members.'));

      final group = (await app.repository.createGroup('Mine', [bo])).id;
      await until(() async => await groupOf(b, group) != null);
      fake.cutRequest((method: 'POST', path: _membersPath(group)));
      await expectLater(
        app.repository.addToConversation(group, cy),
        says('No answer came yet: Duvet tries again on its own.'),
      );
      await b.engine.stop();
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
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'A group can have 20 members at most.')),
      );
      expect(app.count('POST', '/api/users/@me/conversations', from: from), 0);
      await b.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
