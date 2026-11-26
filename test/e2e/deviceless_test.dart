import 'dart:typed_data';

import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Members without a device (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo», Task 23; decision 14): who has no
// identity, or none of whose devices connected lately, is named before anything is sent and told to the core, which
// notes what this device sends them; once a device of theirs comes in, this device hands them what it noted, as a
// catch-up. Their device importing it is Task 31's: done here by hand. The desktop's deviceless tests, case for case.
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

/// The catch-ups for Bo's device that the API has, imported by hand as Task 31 imports them: their parts, once its key
/// came by the inbox.
Future<void> _imported(TestDevice b) async {
  final gate = b.host as CoreGate;
  await until(() async {
    final shares = await b.api.shares();
    if (shares.isEmpty) return false;
    for (final share in shares) {
      final parts = <Uint8List>[for (var n = 0; n < share.parts; n++) await b.api.sharePart(share.id, n)];
      try {
        await gate.importShare(share.id, parts);
      } on Object {
        // Its key isn't in yet.
        return false;
      }
      await b.api.ackShare(share.id);
    }
    return true;
  });
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
      await _imported(b);
      expect(
        [
          for (final m in await b.engine.messages(dm, [sent.id])) m.text,
        ],
        ['hi Bo'],
      );
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
      await _imported(b);
      expect([
        for (final m in await b.engine.messages(dm, [first.id, second.id])) m.text,
      ], containsAll(['one', 'two']));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
