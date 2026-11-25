import 'package:duvet/e2e/host.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A device's commits (PLAN-E2E-CLIENTES.md, «Qué se manda», its commit rows, and «Un commit sin respuesta»): what the
// API answers is what the core is told, a commit whose answer is lost goes again with its bytes, and one whose bytes
// are lost is settled by the queue; the weekly renewal of a device's leaf, and the commits the core says are due. The
// desktop's commits.test.ts, case for case, with its review's rulings.
const _slow = Timeout(Duration(minutes: 3));
const _day = Duration(days: 1);

/// A device's core, whose refresh_due names the conversations in [due], and which notes each commit_result's fields.
CoreHost _hostOf(
  List<String> due,
  List<Map<String, Object?>> results, {
  CoreError? Function(Map<String, Object?> command)? fail,
}) => WatchedHost(
  TestHost().gate,
  [],
  // Each commit_result, the ones [fail] fails too.
  fail: (command) {
    if (command['cmd'] == 'commit_result') results.add(command);
    return fail?.call(command);
  },
  answer: (command) => command['cmd'] == 'refresh_due'
      ? {
          'conversations': [...due],
        }
      : null,
);

typedef _Dm = ({
  FakeApi fake,
  TestDevice a,
  TestDevice b,
  String conversation,
  List<String> due,
  List<String> posted,
  http.Client Function() watch,
  List<Map<String, Object?>> aResults,
  List<Map<String, Object?>> bResults,
});

/// Ana's and Bo's first devices, on cores whose renewals are due where [due] says, in a DM whose group Ana made. What
/// they post to its commits goes into [posted], in order, through the clients [watch] makes, a restarted device's too.
Future<_Dm> _dm({CoreError? Function(Map<String, Object?> command)? aFails}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final posted = <String>[];
  http.Client watch() => watchedClient(
    fake,
    seen: (request) {
      if (request.method == 'POST' && request.url.path == commitsPath(conversation)) posted.add(request.body);
    },
  );
  final due = <String>[];
  final (aResults, bResults) = (<Map<String, Object?>>[], <Map<String, Object?>>[]);
  final a = await firstDevice(
    fake,
    ana,
    host: _hostOf(due, aResults, fail: aFails),
    client: watch(),
  );
  final b = await firstDevice(fake, bo, host: _hostOf(due, bResults), client: watch());
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (
    fake: fake,
    a: a,
    b: b,
    conversation: conversation,
    due: due,
    posted: posted,
    watch: watch,
    aResults: aResults,
    bResults: bResults,
  );
}

List<Map<String, Object?>> _invalids(List<Map<String, Object?>> results) => [
  for (final result in results)
    if (result['invalid'] == true) result,
];

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'a_losing_commit_applies_the_winner_and_tries_again',
    () async {
      final (:fake, :a, :b, :conversation, :due, :posted, watch: _, :aResults, :bResults) = await _dm();
      // Both renew their leaves at once: their commits reach the API together, for the same epoch.
      due.add(conversation);
      fake.gather((method: 'POST', path: commitsPath(conversation)), 2);
      final before = posted.length;
      a.clock.advance(_day);
      b.clock.advance(_day);
      // The loser was told so, applied the winner's commit, and renewed its leaf on top of it.
      await until(() => posted.length == before + 3);
      await sameGroup([a, b], conversation);
      final lost = [
        for (final result in [...aResults, ...bResults])
          if (result['accepted'] == false) result,
      ];
      expect(lost, [
        {'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': false},
      ]);
      final renewals = [
        for (final e in (await a.api.queue(conversation, 2)).entries)
          if (e.kind == 'commit') e,
      ];
      expect([for (final e in renewals) e.epoch], [1, 2]);
      expect({for (final e in renewals) e.senderUser}, hasLength(2));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_commit_cut_before_its_answer_settles',
    () async {
      final (:fake, :a, :b, :conversation, :due, :posted, :watch, :aResults, bResults: _) = await _dm();
      due.add(conversation);
      final path = (method: 'POST', path: commitsPath(conversation));
      // The group's creation went first.
      bool sent(int n) => posted.length == n + 1;

      // With its bytes: its answer is lost, and the same request goes again, which the API answers as it did.
      fake.loseAnswer(path);
      a.clock.advance(_day);
      await until(() => sent(1));
      await until(() {
        a.clock.advance(const Duration(seconds: 2));
        return sent(2);
      });
      expect(posted[2], posted[1]);
      await sameGroup([a, b], conversation);
      expect(_invalids(aResults), isEmpty);

      // Without them: the app stops after the API took it, its answer lost. Started again (with nothing due, so it
      // renews nothing at its start), the queue settles it.
      fake.loseAnswer(path);
      a.clock.advance(_day);
      await until(() => sent(3));
      due.clear();
      final again = await restarted(fake, a, client: watch());
      await sameGroup([again, b], conversation);
      expect((await groupOf(again, conversation))!.epoch, 3);
      expect(_invalids(aResults), isEmpty);

      // Without them, and it never reached the API: the queue doesn't have it, and a minute after the start it's said to
      // be refused. Then the device commits again.
      due.add(conversation);
      fake.cutRequest(path);
      again.clock.advance(_day);
      await until(() => sent(4));
      due.clear();
      final third = await restarted(fake, again, client: watch());
      expect(_invalids(aResults), isEmpty);
      third.clock.advance(const Duration(seconds: 60));
      await until(() => _invalids(aResults).length == 1);
      due.add(conversation);
      third.clock.advance(_day);
      await until(() => sent(5));
      final held = await sameGroup([third, b], conversation);
      expect(held.epoch, 4);
      await third.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // C1 of the desktop's review: a group's creation whose request never got through, and whose bytes went with the app.
  // The API lists the conversation without a group; started again, the device drops the creation its core kept and
  // makes the group anew, claiming the key packages once more for it, and never again at each open.
  test(
    "a_group's_creation_cut_before_its_answer_is_made_again_after_a_restart",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final claims = <String>[];
      http.Client watch() => watchedClient(
        fake,
        seen: (request) {
          if (request.url.path.endsWith('/key-packages/claim')) claims.add(request.url.path);
        },
      );
      final a = await firstDevice(fake, ana, client: watch());
      final b = await firstDevice(fake, bo);
      // Ana opens the DM: her creation's request is cut, and her app closes before it goes again.
      fake.cutRequest((method: 'POST', path: commitsPath(conversation)));
      await a.engine.openConversation(conversation);
      expect(claims, hasLength(2));
      expect(await groupOf(a, conversation), isNotNull);
      expect(await groupOf(b, conversation), isNull);

      // Started again: the group is made anew, and Bo's device comes in by its welcome.
      final again = await restarted(fake, a, client: watch());
      await sameGroup([again, b], conversation);
      expect(claims, hasLength(4));
      final commits = [
        for (final e in (await b.api.queue(conversation, 0)).entries)
          if (e.kind == 'commit') (e.senderUser, e.epoch),
      ];
      expect(commits, [(ana, 0)]);
      // Opened again, it has its group: no key package is claimed.
      await again.engine.openConversation(conversation);
      expect(claims, hasLength(4));
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'invalid_is_said_only_for_a_refused_or_unsent_commit',
    () async {
      final (:fake, :a, :b, :conversation, :due, :posted, :watch, :aResults, bResults: _) = await _dm();
      due.add(conversation);
      final path = (method: 'POST', path: commitsPath(conversation));
      bool sent(int n) => posted.length == n + 1;

      // A refusal of the validator's (422): the commit never entered.
      fake.refuse(path, 422, body: {'error': 'commit refused', 'code': 'invalid_commit'});
      a.clock.advance(_day);
      await until(() => _invalids(aResults).length == 1);
      expect(_invalids(aResults), [
        {'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': false, 'invalid': true},
      ]);

      // Any other refusal says only that it wasn't taken (M1 of the desktop's review), which the queue settles: with the
      // queue read whole, a minute past the start, the API doesn't have it (Ruling 25).
      final told = aResults.length;
      fake.refuse(path, 403, body: {'error': "you aren't a member of this conversation"});
      a.clock.advance(_day);
      await until(() => aResults.length > told);
      expect(aResults[told], {'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': false});
      await until(() => _invalids(aResults).length == 2);

      // A commit never sent, the app started again: not before a minute from the start, nor with the queue behind.
      fake.cutRequest(path);
      a.clock.advance(_day);
      await until(() => sent(3));
      due.clear();
      final again = await restarted(fake, a, client: watch());
      again.clock.advance(const Duration(seconds: 59));
      await turnEnded(again);
      expect(_invalids(aResults), hasLength(2));
      fake.refuse(
        (method: 'GET', path: '/api/users/@me/conversations/$conversation/mls/queue'),
        500,
        body: {'error': 'internal server error'},
      );
      again.clock.advance(const Duration(seconds: 1));
      await turnEnded(again);
      expect(_invalids(aResults), hasLength(2));
      // The queue read again, whole, a minute past the start: now it's said.
      await until(() {
        again.clock.advance(const Duration(seconds: 2));
        return _invalids(aResults).length == 3;
      });
      due.add(conversation);
      again.clock.advance(_day);
      await until(() => sent(4));
      await sameGroup([again, b], conversation);
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M1 of the desktop's review: a resend whose first send entered can be refused (a 403 once the device left its list).
  // Told only that it wasn't taken, the core keeps the commit for the queue, which brings it back as its own.
  test(
    "a_refusal_other_than_the_validator's_leaves_the_commit_to_the_queue",
    () async {
      final (:fake, :a, :b, :conversation, :due, :posted, watch: _, :aResults, bResults: _) = await _dm();
      due.add(conversation);
      final path = (method: 'POST', path: commitsPath(conversation));
      // The group's creation went first.
      bool sent(int n) => posted.length == n + 1;
      // The API takes the renewal, its answer lost; the same bytes, sent again, are refused.
      fake.loseAnswer(path);
      a.clock.advance(_day);
      await until(() => sent(1));
      fake.refuse(path, 403, body: {'error': "this device isn't on your device list"});
      await until(() {
        a.clock.advance(const Duration(seconds: 2));
        return posted.length >= 3;
      });
      await until(() => aResults.any((result) => result['accepted'] == false));
      expect(_invalids(aResults), isEmpty);
      // The queue brings it back as the device's own: its group goes on, renewed once.
      final held = await sameGroup([a, b], conversation);
      expect((held.epoch, held.blocked), (2, false));
      expect(posted, hasLength(3));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the desktop's review: the refusal said of a commit whose bytes were lost is forgotten only once the core took
  // it, so a call that fails is made again at the conversation's next turn.
  test(
    "a_refusal_said_of_a_lost_commit_is_said_again_when_the_core's_call_fails",
    () async {
      var failed = false;
      final (:fake, :a, :b, :conversation, :due, :posted, :watch, :aResults, bResults: _) = await _dm(
        aFails: (command) {
          if (command['cmd'] != 'commit_result' || command['invalid'] != true || failed) return null;
          failed = true;
          return CoreError('internal', message: 'the call was cut');
        },
      );
      due.add(conversation);
      final path = (method: 'POST', path: commitsPath(conversation));
      // The group's creation went first.
      bool sent(int n) => posted.length == n + 1;
      // A renewal that never reached the API, the app started again: a minute on, the refusal is said, and the core's
      // call fails.
      fake.cutRequest(path);
      a.clock.advance(_day);
      await until(() => sent(1));
      due.clear();
      final again = await restarted(fake, a, client: watch());
      again.clock.advance(const Duration(seconds: 60));
      await until(() => _invalids(aResults).isNotEmpty);
      // The next turn says it again; then the device commits once more.
      await until(() {
        again.clock.advance(const Duration(seconds: 2));
        return _invalids(aResults).length >= 2;
      }, timeout: const Duration(seconds: 15));
      due.add(conversation);
      again.clock.advance(_day);
      await until(() => sent(2));
      final held = await sameGroup([again, b], conversation);
      expect(held.epoch, 2);
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_due_commit_is_made_after_a_random_wait,_and_whoever_loses_finds_it_done',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      var posts = 0;
      http.Client watch() => watchedClient(
        fake,
        seen: (request) {
          if (request.method == 'POST' && request.url.path == commitsPath(conversation)) posts++;
        },
      );
      var draws = 0;
      double random() {
        draws++;
        return 0.5;
      }

      final a = await firstDevice(fake, ana);
      final b1 = await firstDevice(fake, bo);
      final b2 = await approvedDevice(fake, b1);
      final b3 = await approvedDevice(fake, b1);
      await a.engine.openConversation(conversation);
      await sameGroup([a, b1, b2, b3], conversation);
      final third = b3.registered.first;
      // Bo's two listed devices again, waiting half of 5 s for their due commits.
      final bo1 = await _again(fake, b1, random, watch());
      final bo2 = await _again(fake, b2, random, watch());

      // Bo's first device takes his third off his list: his listed devices then hold a leaf no list has.
      fake.gather((method: 'POST', path: commitsPath(conversation)), 2);
      final before = posts;
      final signed = await bo1.host.handle<Map<String, Object?>>({
        'cmd': 'sign_device_list',
        'remove': [third],
      });
      final served = await bo1.api.identity(bo);
      final version = await bo1.api.putDeviceList(
        duvet.DeviceListUpload(deviceList: signed['device_list']! as String, baseVersion: served.deviceListVersion),
      );
      await bo1.host.handle<Object?>({'cmd': 'device_list_uploaded', 'version': version});

      // Each waits a random while before it takes the leaf out.
      await until(() => draws >= 2);
      bo1.clock.advance(const Duration(seconds: 2));
      bo2.clock.advance(const Duration(seconds: 2));
      await turnEnded(bo1);
      await turnEnded(bo2);
      expect(posts, before);
      bo1.clock.advance(const Duration(milliseconds: 500));
      bo2.clock.advance(const Duration(milliseconds: 500));
      // One takes the epoch; the other, told it lost, applies it and finds nothing left to do.
      await until(() => posts == before + 2);
      await until(() async => !(await groupOf(a, conversation))!.devices.any((d) => d.device == third));
      final held = await sameGroup([a, bo1, bo2], conversation);
      expect([for (final d in held.devices) d.device], isNot(contains(third)));
      await turnEnded(bo1);
      await turnEnded(bo2);
      expect(posts, before + 2);
      final after = [
        for (final e in (await a.api.queue(conversation, 2)).entries)
          if (e.kind == 'commit') e,
      ];
      expect(after, hasLength(1));
      for (final d in [a, bo1, bo2, b3]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "the_weekly_refresh_commits_where_it's_due",
    () async {
      final (:fake, :a, :b, :conversation, :due, :posted, watch: _, aResults: _, bResults: _) = await _dm();
      // A second conversation of theirs, whose renewal isn't due.
      final other = fake.addConversation(group: true, members: [a.user, b.user], owner: a.user);
      await a.engine.openConversation(other);
      await sameGroup([a, b], other);
      due.add(conversation);
      final before = posted.length;
      a.clock.advance(_day);
      await until(() => posted.length == before + 1);
      final held = await sameGroup([a, b], conversation);
      expect(held.epoch, 2);
      expect((await groupOf(b, other))!.epoch, 1);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M7 of the desktop's review: one renewal that fails doesn't hold up the others.
  test(
    "a_renewal_that_fails_doesn't_stop_the_others",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final first = fake.addConversation(group: false, members: [ana, bo]);
      final second = fake.addConversation(group: true, members: [ana, bo], owner: ana);
      final due = <String>[];
      final a = await firstDevice(
        fake,
        ana,
        host: WatchedHost(
          TestHost().gate,
          [],
          fail: (command) => command['cmd'] == 'refresh' && command['conversation_id'] == first
              ? CoreError('storage', message: 'the disk is full')
              : null,
          answer: (command) => command['cmd'] == 'refresh_due'
              ? {
                  'conversations': [...due],
                }
              : null,
        ),
      );
      final b = await firstDevice(fake, bo);
      await a.engine.openConversation(first);
      await a.engine.openConversation(second);
      await sameGroup([a, b], first);
      await sameGroup([a, b], second);
      due.addAll([first, second]);
      a.clock.advance(_day);
      await until(() async => (await groupOf(b, second))!.epoch == 2);
      await sameGroup([a, b], second);
      expect((await groupOf(b, first))!.epoch, 1);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}

/// The device again with [random] for its waits, on [client]: its app restarted.
Future<TestDevice> _again(FakeApi fake, TestDevice device, double Function() random, http.Client client) async {
  await device.engine.stop();
  final again = testDevice(
    fake,
    device.user,
    host: device.host,
    store: device.store,
    token: device.token,
    client: client,
    random: random,
  );
  await again.engine.start();
  return again;
}
