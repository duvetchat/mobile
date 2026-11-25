import 'dart:convert';

import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/send.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// What a device sends to a conversation (PLAN-E2E-CLIENTES.md, «Enviar», and «Qué se manda», its message rows): a
// message encrypted by the core, sent with its nonce and bound to the ID the API gives it; one without an answer sent
// again with the same bytes; what waits, sent first and in order; a refusal that keeps the message; an edit and a
// deletion taken from the entries their answers give. The desktop's send.test.ts, case for case.
const _slow = Timeout(Duration(minutes: 3));

String _messagesPath(String conversation) => '/api/users/@me/conversations/$conversation/messages';

/// Ana's and Bo's first devices, in a DM whose group Ana made (Ana's on [aHost], hearing what [aHears] lets through),
/// and every request Ana's device made, with its body.
Future<
  ({
    FakeApi fake,
    String ana,
    String bo,
    TestDevice a,
    TestDevice b,
    String conversation,
    List<http.Request> seen,
    http.Client aClient,
  })
>
_dm({CoreHost? aHost, bool Function(GatewayEvent event)? aHears}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final seen = <http.Request>[];
  final aClient = watchedClient(fake, seen: seen.add);
  final a = await firstDevice(fake, ana, host: aHost, client: aClient, hears: aHears);
  final b = await firstDevice(fake, bo);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, conversation: conversation, seen: seen, aClient: aClient);
}

/// The message posts Ana's device made to the conversation, their bodies as JSON.
List<Map<String, Object?>> _posts(List<http.Request> seen, String conversation) => [
  for (final request in seen)
    if (request.method == 'POST' && request.url.path == _messagesPath(conversation))
      (jsonDecode(request.body) as Map).cast<String, Object?>(),
];

/// The text a device's core shows of a message, once it has it: null while it has none.
Future<String?> _textOn(TestDevice device, String conversation, String id) async {
  final shown = (await device.engine.messages(conversation, [id])).firstOrNull;
  return shown?.status == MessageStatus.ok ? shown!.text : null;
}

/// The nonces of the messages that wait on the device, in the order they were made: each the person sent it with,
/// which stays its own when it's made again under another.
Future<List<String?>> _nonces(TestDevice device, String conversation) async => [
  for (final pending in await device.engine.pendingMessages(conversation)) pending.nonce,
];

/// The IDs of the conversation's messages, in their queue's order, as a device reads it.
Future<List<String>> _queued(TestDevice device, String conversation) async => [
  for (final entry in (await device.api.queue(conversation, 0)).entries)
    if (entry.kind == 'message') entry.messageId!,
];

/// The group's epoch as the device's core holds it.
Future<int> _epochOf(TestDevice device, String conversation) async => (await groupOf(device, conversation))!.epoch;

/// Fails unless [future] fails.
Future<void> _refused(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {
    return;
  }
  fail('it was taken');
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test('mentions_are_the_users_the_text_names_outside_code', () {
    final (x, y, z) = (uuidv4(), uuidv4(), uuidv4());
    final text = 'hi <@$x> and <@$y>, `<@$z>` in code,\n```\n<@$z>\n```\nand <@$x> again, <@nobody>';
    expect(mentionsIn(text), [x, y]);
    expect(mentionsIn('no one'), isEmpty);
    // The API takes 20 at most: the first 20 the text names go.
    final many = List.generate(25, (_) => uuidv4());
    expect(mentionsIn(many.map((id) => '<@$id>').join(' ')), many.take(20).toList());
  });

  test(
    'a_message_is_encrypted,_sent_and_bound_to_its_id',
    () async {
      final (fake: _, ana: _, :bo, :a, :b, :conversation, :seen, aClient: _) = await _dm();
      final nonce = uuidv4();
      final text = 'hello <@$bo>, and `<@${uuidv4()}>`';
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: text)))!;
      expect((sent.conversationId, sent.nonce), (conversation, nonce));
      // The request carries the core's ciphertext and the nonce, whom the text names outside code, and no text.
      final post = _posts(seen, conversation).single;
      expect(post, allOf(containsPair('nonce', nonce), containsPair('mentions', [bo])));
      expect(post['ciphertext'], isA<String>());
      expect(post.containsKey('content'), isFalse);
      expect(jsonEncode(post), isNot(contains('hello')));
      // Ana's core binds it to its ID and number: it waits no more.
      final [shown] = await a.engine.messages(conversation, [sent.id]);
      expect((shown.messageId, shown.seq, shown.status, shown.text), (sent.id, sent.seq, MessageStatus.ok, text));
      expect(await _nonces(a, conversation), isEmpty);
      // Bo's device opens it.
      await until(() async => await _textOn(b, conversation, sent.id) == text);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_message_cut_before_its_answer_is_sent_again_with_the_same_bytes',
    () async {
      // Ana's device doesn't hear its own messages' events, which its queue would settle them with first.
      final (:fake, ana: _, bo: _, :a, :b, :conversation, :seen, :aClient) = await _dm(
        aHears: (event) => event.type != 'DM_MESSAGE_CREATE',
      );
      final path = (method: 'POST', path: _messagesPath(conversation));
      // The API takes it, and its answer is lost: the message waits on Ana's device.
      final nonce = uuidv4();
      fake.loseAnswer(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'once')));
      expect(await _nonces(a, conversation), [nonce]);
      // Sent again (the person's Retry): the same bytes, which the API answers with the message it posted.
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'once')))!;
      final [first, retried] = _posts(seen, conversation);
      expect((retried['nonce'], retried['ciphertext']), (nonce, first['ciphertext']));
      expect(await _nonces(a, conversation), isEmpty);
      expect(await _queued(b, conversation), [sent.id]);
      await until(() async => await _textOn(b, conversation, sent.id) == 'once');

      // Its request cut on its way, and the app closed: started again, the device sends it with the same bytes.
      fake.cutRequest(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'twice')));
      final before = _posts(seen, conversation).length;
      final again = await restarted(fake, a, client: aClient);
      await until(() async => (await _nonces(again, conversation)).isEmpty);
      final [lost, resent] = _posts(seen, conversation).sublist(before - 1);
      expect((resent['nonce'], resent['ciphertext']), (lost['nonce'], lost['ciphertext']));
      // One message of it, which Bo opens.
      final ids = await _queued(b, conversation);
      expect(ids, hasLength(2));
      await until(() async => await _textOn(b, conversation, ids[1]) == 'twice');
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'pending_messages_go_first_and_in_order,_after_the_queue',
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, :seen, :aClient) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      // Two messages whose requests never reach the API: they wait, in the order they were made.
      final (first, second, third) = (uuidv4(), uuidv4(), uuidv4());
      fake.cutRequest(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: first, text: 'first')));
      fake.cutRequest(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: second, text: 'second')));
      expect(await _nonces(a, conversation), [first, second]);

      // Ana's app closes; meanwhile Bo renews his leaf. Started again, her device reads the queue first, then sends
      // what waits, in its order.
      await a.engine.stop();
      await stoppedByHand(b);
      await commitByHand(b, conversation);
      final mark = seen.length;
      final again = await restarted(fake, a, client: aClient);
      await until(() async => (await _nonces(again, conversation)).isEmpty);
      final after = [
        for (final request in seen.skip(mark))
          request.url.path.endsWith('/mls/queue') ? '${request.method} queue' : '${request.method} ${request.url.path}',
      ];
      final read = after.indexOf('GET queue');
      final sends = [
        for (final (i, line) in after.indexed)
          if (line == 'POST ${path.path}') i,
      ];
      expect(read, greaterThanOrEqualTo(0));
      expect(sends, hasLength(2));
      expect(sends.first, greaterThan(read));

      // A new message goes after them. (The second's first try went to the first: what waits goes first.)
      await again.engine.sendMessage(Outgoing(conversationId: conversation, nonce: third, text: 'third'));
      expect([for (final post in _posts(seen, conversation)) post['nonce']], [first, first, first, second, third]);
      final bob = await restarted(fake, b);
      final ids = await _queued(bob, conversation);
      expect(ids, hasLength(3));
      await until(() async => await _textOn(bob, conversation, ids[2]) == 'third');
      expect([for (final id in ids) await _textOn(bob, conversation, id)], ['first', 'second', 'third']);
      await again.engine.stop();
      await bob.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_stale_message_is_discarded_and_encrypted_again',
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, :seen, aClient: _) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      // A message that never reached the API, while the group moves on six epochs: no member could open it now.
      final nonce = uuidv4();
      fake.cutRequest(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'late')));
      await stoppedByHand(b);
      for (var i = 0; i < 6; i++) {
        await commitByHand(b, conversation);
      }
      await until(() async => await _epochOf(a, conversation) == 7);
      // Sent again: the core says it's stale, so it's dropped and its text encrypted again, under another nonce.
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'late')))!;
      expect(sent.nonce, isNot(nonce));
      expect(await _nonces(a, conversation), isEmpty);
      final bob = await restarted(fake, b);
      await until(() async => await _textOn(bob, conversation, sent.id) == 'late');

      // The API says it's stale (409): the device encrypts it again, under another nonce.
      final refused = uuidv4();
      final held = (await groupOf(a, conversation))!;
      fake.refuse(path, 409, body: {'error': 'stale message', 'generation': held.generation, 'epoch': held.epoch});
      final posted = (await a.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: refused, text: 'again'),
      ))!;
      expect(posted.nonce, isNot(refused));
      expect([for (final post in _posts(seen, conversation)) post['nonce']].where((n) => n == refused), hasLength(1));
      expect(await _nonces(a, conversation), isEmpty);
      await until(() async => await _textOn(bob, conversation, posted.id) == 'again');
      await a.engine.stop();
      await bob.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_refused_send_keeps_its_message',
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, :seen, :aClient) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      // The pause (503) and a refusal (409) keep it, to be sent again; the update (426) too, and the device then waits
      // for its update. What waits goes first, so each refusal is said to what's ahead of the new one too: the refused
      // one stays, and the next goes on; the update stops them all.
      final kept = <String>[];
      for (final (status, body, times) in [
        (503, null, 1),
        (409, {'error': 'this nonce was sent with another message'}, 2),
        (426, null, 1),
      ]) {
        final nonce = uuidv4();
        for (var i = 0; i < times; i++) {
          fake.refuse(path, status, body: body);
        }
        await _refused(
          a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'refused ($status)')),
        );
        kept.add(nonce);
        expect(await _nonces(a, conversation), kept);
      }
      expect(a.state.stage, EngineStage.update);
      expect(_posts(seen, conversation), hasLength(4));
      // Dismiss drops one; started again, the device sends the others, once each.
      await a.engine.discardMessage(conversation, kept[1]);
      expect(await _nonces(a, conversation), [kept[0], kept[2]]);
      final again = await restarted(fake, a, client: aClient);
      await until(() async => (await _nonces(again, conversation)).isEmpty);
      final ids = await _queued(b, conversation);
      expect(ids, hasLength(2));
      await until(() async => await _textOn(b, conversation, ids[1]) != null);
      expect([for (final id in ids) await _textOn(b, conversation, id)], ['refused (503)', 'refused (426)']);
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'an_edit_and_a_deletion_apply_from_the_entry_their_answer_gives',
    () async {
      // Ana's device hears none of its own changes' events: what its core takes of them comes from the answers.
      final (:fake, ana: _, bo: _, :a, :b, :conversation, seen: _, aClient: _) = await _dm(
        aHears: (event) => event.type != 'DM_MESSAGE_UPDATE' && event.type != 'DM_MESSAGE_DELETE',
      );
      Future<int?> through() async =>
          (await a.host.handle<Map<String, Object?>>({
                'cmd': 'apply',
                'conversation_id': conversation,
                'entries': <Object?>[],
              }))['applied_through']
              as int?;
      const text = 'first words';
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text)))!;
      await until(() async => await _textOn(b, conversation, sent.id) == text);

      // Its answer lost, the edit goes again with the same bytes, which the API answers with the same entry.
      fake.loseAnswer((method: 'PATCH', path: '${_messagesPath(conversation)}/${sent.id}'));
      await a.engine.editMessage(conversation, sent.id, 'second words');
      expect(await _textOn(a, conversation, sent.id), 'second words');
      a.clock.advance(const Duration(seconds: 2));
      await until(() async => await _textOn(b, conversation, sent.id) == 'second words');
      final edits = [
        for (final entry in (await b.api.queue(conversation, 0)).entries)
          if (entry.kind == 'edit') entry,
      ];
      expect(edits, hasLength(1));
      await until(() async => await through() == edits.single.seq);
      final [edited] = await a.engine.messages(conversation, [sent.id]);
      expect(edited.text, 'second words');
      expect(edited.editedAt, isNotNull);

      await a.engine.deleteMessage(conversation, sent.id);
      final deletion = (await b.api.queue(conversation, 0)).entries.firstWhere((entry) => entry.kind == 'delete');
      expect(await through(), deletion.seq);
      expect(await a.engine.messages(conversation, [sent.id]), isEmpty);
      await until(() async => (await b.engine.messages(conversation, [sent.id])).isEmpty);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_sticker_goes_in_the_clear_with_an_empty_envelope',
    () async {
      final commands = <Map<String, Object?>>[];
      final host = WatchedHost(TestHost().gate, [], commands: commands);
      final (fake: _, ana: _, bo: _, :a, :b, :conversation, :seen, aClient: _) = await _dm(aHost: host);
      final (sticker, nonce) = (uuidv4(), uuidv4());
      final sent = (await a.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: nonce, stickerAttachmentId: sticker),
      ))!;
      // Each time the core gives its bytes, the same empty envelope.
      final envelopes = [
        for (final command in commands)
          if (command['cmd'] == 'encrypt') command['envelope'],
      ];
      expect(envelopes, isNotEmpty);
      expect(envelopes.every((envelope) => jsonEncode(envelope) == '{}'), isTrue);
      expect(
        _posts(seen, conversation).single,
        allOf(containsPair('nonce', nonce), containsPair('sticker_attachment_id', sticker)),
      );
      expect(sent.stickerAttachmentId, sticker);
      // Bo's core opens it: a message without text.
      await until(
        () async => (await b.engine.messages(conversation, [sent.id])).firstOrNull?.status == MessageStatus.ok,
      );
      expect((await b.engine.messages(conversation, [sent.id])).single.text, isNull);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Missing 1 of the desktop's task 16 review: a commit of the device's waiting for its word kept every message from
  // being encrypted.
  test(
    "a_message_sent_while_a_commit_of_this_device's_waits_for_its_answer_goes_once_the_commit_settles",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      // Ana makes the DM's group, and its creation's answer is lost: her commit waits in flight for its word.
      fake.loseAnswer((method: 'POST', path: commitsPath(conversation)));
      await a.engine.openConversation(conversation);
      // Her message: the commit's request goes again, which the API answers as it did, then the message is encrypted.
      final sent = (await a.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'after the commit'),
      ))!;
      await until(() async => await _textOn(b, conversation, sent.id) == 'after the commit');
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the desktop's task 16 review: a message made again under another nonce is still the person's first one.
  test(
    'a_message_made_again_whose_request_fails_is_still_one_message:_its_Retry_sends_it_once,_and_Dismiss_drops_it',
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, seen: _, aClient: _) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      // Two messages that never reached the API, while the group moves on six epochs: their bytes go stale.
      final (first, second) = (uuidv4(), uuidv4());
      for (final (nonce, text) in [(first, 'one'), (second, 'two')]) {
        fake.cutRequest(path);
        await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: text)));
      }
      await stoppedByHand(b);
      for (var i = 0; i < 6; i++) {
        await commitByHand(b, conversation);
      }
      await until(() async => await _epochOf(a, conversation) == 7);
      // Dismiss drops the second; the first's Retry makes it again under another nonce, and its request is cut: it waits
      // under the nonce the person sent it with.
      await a.engine.discardMessage(conversation, second);
      fake.cutRequest(path);
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: first, text: 'one')));
      expect(await _nonces(a, conversation), [first]);
      // Retried again by that nonce: sent once, under the new one.
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: first, text: 'one')))!;
      expect(sent.nonce, isNot(first));
      expect(await _nonces(a, conversation), isEmpty);
      final bob = await restarted(fake, b);
      expect(await _queued(bob, conversation), [sent.id]);
      await until(() async => await _textOn(bob, conversation, sent.id) == 'one');
      await a.engine.stop();
      await bob.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M3 of the desktop's task 16 review: a message whose answer and event were lost went, and its Dismiss mustn't drop it.
  test(
    "Dismiss_reads_the_queue_first:_a_message_that_went_isn't_dropped",
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, seen: _, aClient: _) = await _dm(
        aHears: (event) => event.type != 'DM_MESSAGE_CREATE',
      );
      final nonce = uuidv4();
      fake.loseAnswer((method: 'POST', path: _messagesPath(conversation)));
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'it went')));
      expect(await _nonces(a, conversation), [nonce]);
      // Dismissed: the queue's copy says it went, and the device keeps it as sent, its text its own.
      await a.engine.discardMessage(conversation, nonce);
      expect(await _nonces(a, conversation), isEmpty);
      final [id] = await _queued(b, conversation);
      expect(await _textOn(a, conversation, id), 'it went');
      expect(fake.decryptFailures, isEmpty);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the desktop's task 16 review: the device reads 100 of a conversation's messages that wait; a new one past
  // them is refused.
  test(
    'a_new_message_is_refused_once_100_wait_in_its_conversation',
    () async {
      final (fake: _, ana: _, bo: _, :a, :b, :conversation, :seen, aClient: _) = await _dm();
      for (var i = 0; i < 100; i++) {
        await a.host.handle<Object?>({
          'cmd': 'encrypt',
          'conversation_id': conversation,
          'nonce': uuidv4(),
          'envelope': {'text': 'waits $i'},
        });
      }
      final before = _posts(seen, conversation).length;
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'too many')));
      expect(_posts(seen, conversation), hasLength(before));
      expect(await a.engine.pendingMessages(conversation), hasLength(100));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I3 of the desktop's task 16 review: an edit or a deletion is the API's word too. One not answered yet is kept in
  // the record (never its text) and made again at the next start; a message's changes go one after the other; one
  // refused for good with nobody waiting for it is told; an update (426) keeps it; the pause (503) waits as it says.
  test(
    "an_edit_or_a_deletion_not_answered_yet_is_kept,_in_its_message's_order,_and_made_again_at_start",
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation, :seen, :aClient) = await _dm();
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'one')))!;
      final path = '${_messagesPath(conversation)}/${sent.id}';
      int patches() => seen.where((r) => r.method == 'PATCH' && r.url.path == path).length;
      final refused = <({String conversationId, String messageId, String kind})>[];
      var device = a;
      // The app again, on the same core and record, told of refusals from its start.
      Future<void> restart() async {
        await device.engine.stop();
        device = testDevice(
          fake,
          device.user,
          host: device.host,
          store: device.store,
          token: device.token,
          client: aClient,
        );
        device.engine.changesRefused.listen(refused.add);
        await device.engine.start();
      }

      // Two edits of one message: the first's request is cut, and the second waits behind it. Neither text is kept.
      fake.cutRequest((method: 'PATCH', path: path));
      await a.engine.editMessage(conversation, sent.id, 'two');
      await a.engine.editMessage(conversation, sent.id, 'three');
      expect(patches(), 1);
      expect(jsonEncode(a.store.read(pendingChanges)), allOf(contains(sent.id), isNot(contains('three'))));
      // The app closes before any answer: started again, the device makes them again and sends them, in order.
      await restart();
      await until(() async => await _textOn(b, conversation, sent.id) == 'three');
      await until(() async => device.store.read(pendingChanges) == null);

      // Refused for good when nobody waits for it (made again as the app started): the person is told.
      fake.cutRequest((method: 'PATCH', path: path));
      await device.engine.editMessage(conversation, sent.id, 'four');
      fake.refuse((method: 'PATCH', path: path), 403, body: {'error': 'only its author changes a message'});
      await restart();
      await until(() async => refused.isNotEmpty);
      expect(refused, [(conversationId: conversation, messageId: sent.id, kind: 'edit')]);
      expect(device.store.read(pendingChanges), isNull);

      // The pause: tried again once its Retry-After passed, not before.
      fake.refuse((method: 'PATCH', path: path), 503);
      final paused = patches();
      await device.engine.editMessage(conversation, sent.id, 'five');
      expect(patches(), paused + 1);
      device.clock.advance(const Duration(seconds: 2));
      await turnEnded(device);
      expect(patches(), paused + 1);
      device.clock.advance(const Duration(seconds: 58));
      await until(() async => await _textOn(b, conversation, sent.id) == 'five');

      // An update (426) keeps it for after the update: started again, it goes.
      fake.refuse((method: 'DELETE', path: path), 426);
      await _refused(device.engine.deleteMessage(conversation, sent.id));
      expect(device.state.stage, EngineStage.update);
      await restart();
      await until(() async => (await b.engine.messages(conversation, [sent.id])).isEmpty);
      expect(refused, hasLength(1));
      await device.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_send_while_the_device_is_not_ready_is_refused_and_keeps_nothing',
    () async {
      // A device that isn't ready (here: a new device of a user set up elsewhere) sends nothing, and the core keeps
      // nothing of the message.
      final fake = FakeApi();
      final ana = fake.addUser();
      final conversation = fake.addConversation(group: false, members: [ana, fake.addUser()]);
      final first = await firstDevice(fake, ana);
      final fresh = testDevice(fake, ana);
      await fresh.engine.start();
      expect(fresh.state, EngineState.newDevice);
      await _refused(fresh.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'no')));
      await first.engine.stop();
      await fresh.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );
}
