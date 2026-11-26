import 'package:duvet/e2e/deviceless.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Members without a device (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo», Task 23; decision 14): who has no
// identity, or none of whose devices connected lately, is named before anything is sent and told to the core, which
// notes what this device sends them; once a device of theirs comes in, this device hands them what it noted, as a
// catch-up, which their device imports by itself (Task 31). The desktop's deviceless tests, case for case.
const _slow = Timeout(Duration(minutes: 3));

/// Ana's first device, its core watched, and her DM with Bo, who has no device yet, made as she made it and open.
Future<({FakeApi fake, String ana, String bo, String dm, TestDevice a, List<Map<String, Object?>> asked})> _dm() async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final asked = <Map<String, Object?>>[];
  final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, [], commands: asked));
  final dm = (await a.engine.createDM(bo)).id;
  await a.engine.openConversation(dm);
  return (fake: fake, ana: ana, bo: bo, dm: dm, a: a, asked: asked);
}

/// What the catch-ups for [b]'s device brought, once its engine imported them by itself: the texts of these messages
/// of the conversation. Its engine imports with the app quiet, which its clock says.
Future<List<String?>> _imported(TestDevice b, String conversation, List<String> ids) async {
  late List<String?> texts;
  await until(() async {
    b.clock.advance(quietBeforeImport);
    texts = [for (final m in await b.engine.messages(conversation, ids)) m.text];
    return texts.length == ids.length;
  });
  return texts;
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'a_member_without_devices_is_named_before_sending,_and_noted_for_the_core',
    () async {
      final (:fake, ana: _, :bo, :dm, :a, :asked) = await _dm();
      // Bo has no identity: the conversation says so, and the core was told.
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]));
      expect(asked.where((c) => c['cmd'] == 'without_devices').last['users'], [bo]);

      // Cy has one, but none of their devices connected lately: they count too, in a group.
      final cy = fake.addUser();
      final c = await firstDevice(fake, cy);
      fake.setActive(cy, false);
      final group = (await a.engine.createGroup('Crew', [bo, cy])).id;
      await sameGroup([a, c], group);
      await a.engine.openConversation(group);
      await until(() => a.engine.conversationState(group) == ConversationState.noDevice([bo, cy]));
      expect(asked.where((c) => c['cmd'] == 'without_devices').last['users'], [bo, cy]);
      // Sending goes on all the same.
      await a.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: 'hello all'));
      await a.engine.stop();
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'what_was_sent_to_a_member_without_devices_goes_to_them_when_their_first_device_joins',
    () async {
      final (fake: fake, ana: _, :bo, :dm, :a, :asked) = await _dm();
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]));
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi Bo')))!;

      // Bo's first device comes in by its own commit: Ana's hands it what it noted, its key to his device's inbox.
      final b = await firstDevice(fake, bo);
      await until(() => asked.any((c) => c['cmd'] == 'catch_up_delivered' && c['user_id'] == bo));
      await until(() => a.engine.conversationState(dm) == null);
      expect(await _imported(b, dm, [sent.id]), ['hi Bo']);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_catch-up_refused_for_a_day_keeps_its_notes',
    () async {
      final (fake: fake, ana: _, :bo, :dm, :a, :asked) = await _dm();
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]));
      final first = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'one')))!;
      // The API takes one catch-up a day for each member: this one is refused for it.
      fake.refuse((method: 'PUT', path: RegExp(r'/history-shares/[0-9a-f-]+$')), 429);
      final b = await firstDevice(fake, bo);
      await until(() => asked.where((c) => c['cmd'] == 'catch_up').isNotEmpty);
      await turnEnded(a);
      expect(asked.where((c) => c['cmd'] == 'catch_up_delivered'), isEmpty);

      // Meanwhile Bo's device reads what's new; what came before it waits for the day, its notes kept, and isn't made
      // again before it.
      final second = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'two')))!;
      await turnEnded(a);
      expect(asked.where((c) => c['cmd'] == 'catch_up'), hasLength(1));
      a.clock.advance(const Duration(days: 1));
      await until(() => asked.any((c) => c['cmd'] == 'catch_up_delivered' && c['user_id'] == bo));
      expect(await _imported(b, dm, [first.id, second.id]), containsAll(['one', 'two']));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I3 of the review: a member's device with the chat on screen while the owner adds a user who has no device yet. Its
  // core is told of them as the group's members change, so what it sends meanwhile reaches that user's first device by
  // its catch-up.
  test(
    'a_member_added_without_a_device_gets_what_was_sent_meanwhile_once_their_first_device_joins',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final asked = <Map<String, Object?>>[];
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo, host: WatchedHost(TestHost().gate, [], commands: asked));
      final group = (await a.engine.createGroup('Crew', [bo])).id;
      await sameGroup([a, b], group);
      // Bo's chat is on screen: who has no device was worked out as it opened (nobody).
      await b.engine.openConversation(group);
      await until(() => asked.any((c) => c['cmd'] == 'without_devices'));
      expect(b.engine.conversationState(group), isNull);

      // Ana adds Cy, who has no device yet: Bo's device applies the addition and tells its core of Cy.
      fake.befriend(ana, cy);
      await a.engine.addMember(group, cy);
      await until(() => b.engine.conversationState(group) == ConversationState.noDevice([cy]));
      expect(asked.where((c) => c['cmd'] == 'without_devices').last['users'], [cy]);
      final sent = (await b.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: 'welcome Cy')))!;

      // Cy's first device joins: Bo's hands it what it noted.
      final c = await firstDevice(fake, cy);
      await until(() => asked.any((command) => command['cmd'] == 'catch_up_delivered' && command['user_id'] == cy));
      expect(await _imported(c, group, [sent.id]), ['welcome Cy']);
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M3 of the review: a catch-up whose turn was skipped (the engine left «ready» before it ran) doesn't keep its key,
  // which would skip every later one for that member: what was heard goes, and the next apply asks for it again.
  test(
    'a_catch-up_whose_turn_was_skipped_is_asked_for_again',
    () async {
      final (fake: _, ana: _, :bo, :dm, :a, asked: _) = await _dm();
      final turns = <Future<void> Function()>[];
      final catchUps = CatchUps(a.engine, turns.add);
      catchUps
        ..due(dm, [bo])
        ..due(dm, [bo]);
      // One turn is enough: it carries all that's noted by then.
      expect(turns, hasLength(1));
      // The engine left «ready»: that turn never runs, and its key goes with what was heard.
      turns.clear();
      catchUps
        ..dropQueued()
        ..due(dm, [bo]);
      expect(turns, hasLength(1));
      await a.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // A catch-up whose upload failed past its PUT (a part refused) goes again after its wait with the package it made,
  // which the API takes again: one package, its share and its part sent twice, delivered.
  test(
    'a_catch-up_whose_upload_failed_midway_goes_again_with_its_package',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final asked = <Map<String, Object?>>[];
      final seen = <http.Request>[];
      final a = await firstDevice(
        fake,
        ana,
        host: WatchedHost(TestHost().gate, [], commands: asked),
        client: watchedClient(fake, seen: seen.add),
      );
      final dm = (await a.engine.createDM(bo)).id;
      await a.engine.openConversation(dm);
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]));
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi again')))!;
      fake.refuse((method: 'PUT', path: RegExp(r'/history-shares/[0-9a-f-]+/parts/0$')), 500);
      final b = await firstDevice(fake, bo);
      List<String> puts(String end) => [
        for (final r in seen)
          if (r.method == 'PUT' && r.url.path.contains('/history-shares/') && r.url.path.endsWith(end)) r.url.path,
      ];
      await until(() => puts('/parts/0').isNotEmpty);
      expect(asked.where((c) => c['cmd'] == 'catch_up_delivered'), isEmpty);

      // Its wait over (2 s), the same package goes up again, and is delivered.
      await until(() {
        a.clock.advance(const Duration(seconds: 2));
        return asked.any((c) => c['cmd'] == 'catch_up_delivered' && c['user_id'] == bo);
      });
      expect(asked.where((c) => c['cmd'] == 'catch_up'), hasLength(1));
      final parts = puts('/parts/0');
      expect((parts.length, parts.toSet().length), (2, 1));
      expect(
        seen.where((r) => r.method == 'PUT' && RegExp(r'/history-shares/[0-9a-f-]+$').hasMatch(r.url.path)),
        hasLength(2),
      );
      expect(await _imported(b, dm, [sent.id]), ['hi again']);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
