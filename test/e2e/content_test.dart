import 'dart:convert';
import 'dart:typed_data';

import 'package:duvet/data/duvet_repository.dart' show notYetRead, readFrom, withRow;
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart' show previewOf;
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/send.dart';
import 'package:duvet/e2e/sync.dart' show entryOf;
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/encryption/conversation_start.dart';
import 'package:duvet/theme.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A conversation as the device draws it (PLAN-E2E-CLIENTES.md, «La vista de una conversación»): the API's rows, each
// with what this device's own database holds of it; a row it doesn't hold waits for it, rows from before the user
// joined give way to a notice, and a conversation from before the cutover says when its older messages went. The
// desktop's content.test.ts, case for case.
const _slow = Timeout(Duration(minutes: 3));

/// An encrypted message as the API lists it, before this device's database is asked.
ChatMessage _listed(String id, {String author = 'a'}) =>
    ChatMessage(id: id, authorId: author, authorName: 'Ana', content: '', createdAt: DateTime(2026, 11, 25));

/// A row of the device's own database, as `messages` gives it.
ShownMessage _shown(String id, {String status = 'ok', String? text, String? sharedBy}) => ShownMessage.of({
  'conversation_id': 'c',
  'message_id': id,
  'seq': 1,
  'user_id': 'a',
  'device_id': 'd',
  'sent_at': 0,
  'edited_at': null,
  'status': status,
  'text': text,
  'attachments': <Object?>[],
  'shared_by': sharedBy,
  'reply_to': null,
});

Widget _drawn({required bool legacy, DateTime? cutoverAt, required bool beforeJoining}) => MaterialApp(
  home: FTheme(
    data: Duvet.theme(Brightness.light),
    child: Material(
      child: ConversationStart(legacy: legacy, cutoverAt: cutoverAt, beforeJoining: beforeJoining),
    ),
  ),
);

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "a_row_the_core_doesn't_hold_waits,_and_an_import_fills_it",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      var b = await firstDevice(fake, bo);
      await a.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);

      // Ana sends a message, while Bo's device is away; its copy of it doesn't open there (one byte of it spoiled).
      await b.engine.stop();
      final sent = (await a.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'kept for Bo'),
      ))!;
      await b.host.open(bo);
      final entry = (await a.api.queue(conversation, 0)).entries.firstWhere((e) => e.messageId == sent.id);
      final spoiled = Uint8List.fromList(base64Decode(entry.data!));
      spoiled[spoiled.length - 1] ^= 0xff;
      await b.host.handle<Object?>({
        'cmd': 'apply',
        'conversation_id': conversation,
        'entries': [
          {...entryOf(entry), 'data': base64Encode(spoiled)},
        ],
      });
      b = await restarted(fake, b);

      // The row waits on Bo's device: the chat draws it as waiting, as one his core never had.
      final [waiting] = await b.engine.messages(conversation, [sent.id]);
      expect((waiting.messageId, waiting.status, waiting.text), (sent.id, MessageStatus.waiting, null));
      String name(String user) => user == ana ? 'Ana' : 'someone';
      final listed = _listed(sent.id, author: ana);
      expect(withRow(listed, waiting, nameOf: name), isA<ChatMessage>().having((m) => m.waiting, 'waiting', isTrue));
      expect(await b.engine.messages(conversation, [uuidv4()]), isEmpty);
      // Applied on this device and not held: it waits.
      expect(withRow(listed, null, nameOf: name, applied: (through: 1)).waiting, isTrue);
      // Not yet asked: neither waiting nor any text.
      expect((listed.waiting, listed.content), (false, ''));

      // Ana shares the conversation's history with Bo: the import fills the row, which then shows its text.
      final certificates = (await a.api.identity(bo)).certificates;
      final gate = a.host as CoreGate;
      final made = await gate.share({
        'cmd': 'history_share',
        'conversation_id': conversation,
        'to_user': bo,
        'range': 'all',
        'devices': certificates,
      });
      final from = (await b.api.identity(ana)).certificates.first;
      for (final key in (made['keys']! as List).cast<Map<String, Object?>>()) {
        await b.host.handle<Object?>({'cmd': 'receive_direct', 'message': key['message'], 'from_certificate': from});
      }
      final shareId = made['share_id']! as String;
      final parts = [for (var n = 0; n < (made['parts']! as int); n++) await gate.sharePart(shareId, n)];
      expect(await (b.host as CoreGate).importShare(shareId, parts), containsPair('imported', isA<int>()));
      final [filled] = await b.engine.messages(conversation, [sent.id]);
      expect((filled.status, filled.text, filled.sharedBy), (MessageStatus.ok, 'kept for Bo', ana));
      final drawn = withRow(listed, filled, nameOf: name);
      expect((drawn.waiting, drawn.content, drawn.sharedBy), (false, 'kept for Bo', 'Ana'));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test("a_chat's_messages_read_again_take_what_the_device_holds,_and_wait_for_what_it_doesn't", () {
    // Listed before the device could be read (no text, not waiting), then read again: the one it holds shows its text,
    // the encrypted one it holds nothing of waits, and a notice and a message still being sent stay as they are.
    final shown = _listed('a').copyWith(seq: 1);
    final unheld = _listed('b').copyWith(seq: 2);
    final notice = ChatMessage(id: 'c', authorId: 'a', authorName: 'Ana', content: '', createdAt: DateTime(2026));
    final sending = ChatMessage(
      id: 'pending:n',
      authorId: 'a',
      authorName: 'Ana',
      content: 'on its way',
      createdAt: DateTime(2026),
      pending: true,
    );
    final read = readFrom(
      [shown, unheld, notice, sending],
      {'a': _shown('a', text: 'here')},
      nameOf: (_) => 'Bo',
      applied: (through: 2),
    );
    expect(
      [for (final m in read) (m.content, m.waiting)],
      [('here', false), ('', true), ('', false), ('on its way', false)],
    );
  });

  // M4 of the desktop's task 16 review: a row of another author's, under an ID the API names for this one, isn't
  // theirs.
  // The review of task 16: what a conversation draws comes from the device alone (I1, M4: the API's words never reach
  // this, as the repository lists a conversation's message with no text, embeds or files), and a row not applied yet
  // loads (M2).
  test('an_encrypted_row_draws_only_what_the_device_holds_of_it', () {
    final row = _shown('m', text: 'said by a');
    final quoted = _shown('q', text: 'quoted');
    final replying = _listed('m').copyWith(
      seq: 2,
      reply: const MessageReply(messageId: 'q', authorId: 'a', authorName: 'Ana', content: ''),
    );
    // Held: its text, and its quote's from the quoted row.
    final drawn = withRow(replying, row, nameOf: (_) => '', quoted: quoted);
    expect((drawn.content, drawn.reply?.content, drawn.waiting), ('said by a', 'quoted', false));
    // Nothing held: waiting, with no text, its quote's neither.
    final none = withRow(replying, null, nameOf: (_) => '', applied: (through: 2));
    expect((none.content, none.reply?.content, none.waiting), ('', '', true));
    // A held row whose sender isn't the author the API names: waiting, never its text under another's name.
    final other = withRow(_listed('m', author: 'b').copyWith(seq: 2), row, nameOf: (_) => '');
    expect((other.content, other.waiting), ('', true));
  });

  // M2 of task 17's review: a quote's text is drawn only under the author the API names for the quoted message, as
  // the row itself is.
  test("a_quote's_text_is_drawn_only_under_its_author", () {
    final quoted = _shown('q', text: 'said by a');
    final row = _shown('m', text: 'an answer');
    MessageReply quoting(String author) =>
        MessageReply(messageId: 'q', authorId: author, authorName: author, content: '');
    final byA = withRow(
      _listed('m').copyWith(seq: 2, reply: quoting('a')),
      row,
      nameOf: (_) => '',
      quoted: quoted,
    );
    expect(byA.reply?.content, 'said by a');
    final byB = withRow(
      _listed('m').copyWith(seq: 2, reply: quoting('b')),
      row,
      nameOf: (_) => '',
      quoted: quoted,
    );
    expect(byB.reply?.content, '');
  });

  test("a_row_the_engine_hasn't_applied_yet_is_loading,_neither_empty_nor_waiting", () {
    final late = _listed('x').copyWith(seq: 7);
    final loading = withRow(late, null, nameOf: (_) => '', applied: (through: 5));
    expect((loading.loading, loading.waiting, loading.content), (true, false, ''));
    final applied = withRow(late, null, nameOf: (_) => '', applied: (through: 7));
    expect((applied.loading, applied.waiting), (false, true));
    // Held as waiting (its copy came, not opened): waiting, whatever the number.
    final copy = withRow(
      late,
      _shown('x', status: 'waiting'),
      nameOf: (_) => '',
      applied: (through: 5),
    );
    expect((copy.loading, copy.waiting), (false, true));
  });

  // M1 of task 17's review (the desktop's N4): out of its group, a row the device doesn't hold isn't coming, and
  // waits; before the conversation's first apply this run, it's loading.
  test("out_of_its_group_a_row_the_device_doesn't_hold_waits,_and_before_any_apply_it's_loading", () {
    final late = _listed('x').copyWith(seq: 7);
    final out = withRow(late, null, nameOf: (_) => '', applied: (through: null));
    expect((out.loading, out.waiting), (false, true));
    final before = withRow(late, null, nameOf: (_) => '');
    expect((before.loading, before.waiting), (true, false));
    // Unread (the device can't be read), every encrypted row loads.
    expect(
      [
        for (final m in notYetRead([late, _listed('notice')])) (m.loading, m.waiting),
      ],
      [(true, false), (false, false)],
    );
  });

  // mobile#409: a row this device doesn't hold, numbered before it joined the conversation's group (its joinedSeq), was
  // never sealed for it, and nothing will deliver it: it says it's not on this device, in the waiting row's place. From
  // joinedSeq on, or while joinedSeq isn't known, it waits.
  test("a_row_from_before_this_device_joined_that_it_doesn't_hold_is_not_on_this_device", () {
    ChatMessage drawn(int seq, {int? joined, ShownMessage? row, ({int? through})? applied = (through: 9)}) => withRow(
      _listed('x').copyWith(seq: seq),
      row,
      nameOf: (_) => '',
      applied: applied,
      joined: joined,
    );
    final before = drawn(4, joined: 5);
    expect((before.waiting, before.beforeDevice, before.loading, before.content), (true, true, false, ''));
    for (final waits in [drawn(5, joined: 5), drawn(6, joined: 5), drawn(4)]) {
      expect((waits.waiting, waits.beforeDevice), (true, false));
    }
    // Held, opened or not, it's no longer missing, whatever its number.
    expect(drawn(4, joined: 5, row: _shown('x', text: 'kept')).beforeDevice, isFalse);
    expect(drawn(4, joined: 5, row: _shown('x', status: 'waiting')).beforeDevice, isFalse);
    // Not applied yet this run, it loads.
    final loading = drawn(4, joined: 5, applied: null);
    expect((loading.loading, loading.beforeDevice), (true, false));
    // Read again once a shared history brought its row: its text, and nothing more of where it was.
    final shared = withRow(
      before,
      _shown('x', text: 'shared'),
      nameOf: (_) => '',
      applied: (through: 9),
      joined: 5,
    );
    expect((shared.content, shared.waiting, shared.beforeDevice), ('shared', false, false));
    // A chat's page reads it so, and the chat takes it in place of the waiting row it showed.
    final [page] = readFrom(
      [_listed('y').copyWith(seq: 2)],
      const {},
      nameOf: (_) => '',
      applied: (through: 9),
      joined: 3,
    );
    expect(page.beforeDevice, isTrue);
    expect(drawn(4).heldAs(before).beforeDevice, isTrue);
    // The Chats tab's line says it, as it says a waiting one waits.
    expect(previewOf(before, (content) => content), Notice.beforeDevice.text);
    expect(previewOf(drawn(5, joined: 5), (content) => content), Notice.waiting.text);
  });

  // mobile#409: a new device of someone already in the conversation (approved by their first) joins its group by an
  // external commit, whose number the engine keeps as where it joined, as the API lists it: what came before was never
  // sealed for it and isn't on it; what comes after, it holds.
  test(
    'a_new_device_draws_what_came_before_it_joined_as_not_on_it',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      await a.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);
      Future<duvet.DirectMessage> said(String text) async =>
          (await b.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text)))!;
      final before = await said('before');

      final phone = await approvedDevice(fake, a);
      await sameGroup([a, b, phone], conversation);
      await until(() => phone.engine.joinedSeq(conversation) != null, what: 'where the new device joined');
      final listed = (await phone.api.api.getConversations()).firstWhere((conv) => conv.id == conversation);
      final joined = phone.engine.joinedSeq(conversation);
      expect(listed.mls!.joinedSeq, isNotNull);
      expect(joined, listed.mls!.joinedSeq);
      expect(joined, greaterThan(before.seq!));
      final after = await said('after');
      await until(() async => (await phone.engine.messages(conversation, [after.id])).isNotEmpty);

      final held = {
        for (final row in await phone.engine.messages(conversation, [before.id, after.id])) row.messageId: row,
      };
      ChatMessage drawn(duvet.DirectMessage m) => withRow(
        _listed(m.id, author: bo).copyWith(seq: m.seq),
        held[m.id],
        nameOf: (_) => 'Bo',
        applied: phone.engine.appliedThrough(conversation),
        joined: joined,
      );
      final (earlier, later) = (drawn(before), drawn(after));
      expect((earlier.waiting, earlier.beforeDevice, earlier.content), (true, true, ''));
      expect((later.waiting, later.beforeDevice, later.content), (false, false, 'after'));
      for (final device in [a, b, phone]) {
        await device.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  testWidgets("the_line_about_the_cutover_shows_on_a_legacy_conversation,_with_the_server's_date", (tester) async {
    final cutoverAt = await tester.runAsync(() async {
      final fake = FakeApi()..cutoverAt = '2026-12-01T09:30:00Z';
      final a = await firstDevice(fake, fake.addUser());
      final at = a.engine.cutoverAt;
      await a.engine.stop();
      return at;
    });
    expect(cutoverAt, DateTime.utc(2026, 12, 1, 9, 30));
    final line = Notice.cutover.fill({'date': '1 December 2026'});
    await tester.pumpWidget(_drawn(legacy: true, cutoverAt: cutoverAt, beforeJoining: false));
    expect(find.text(line), findsOneWidget);
    await tester.pumpWidget(_drawn(legacy: false, cutoverAt: cutoverAt, beforeJoining: false));
    expect(find.textContaining('end-to-end encryption'), findsNothing);
    await tester.pumpWidget(_drawn(legacy: true, cutoverAt: null, beforeJoining: false));
    expect(find.textContaining('end-to-end encryption'), findsNothing);
  }, skip: noCore != null);

  testWidgets('rows_from_before_the_user_joined_give_way_to_one_notice', (tester) async {
    const joined = '0193a4b2-0000-7000-8000-000000000050';
    ({String id, int? seq}) row(String id, {int? seq = 1}) => (id: id, seq: seq);
    final early = row('0193a4b2-0000-7000-8000-000000000010');
    final shared = row('0193a4b2-0000-7000-8000-000000000020');
    final notice = row('0193a4b2-0000-7000-8000-000000000030', seq: null);
    final later = row('0193a4b2-0000-7000-8000-000000000060');
    bool held(String id) => id == shared.id;
    (List<String>, bool) draw(List<({String id, int? seq})> rows, String? joinedAs) {
      final drawn = drawnRows(rows, joinedAs, idOf: (r) => r.id, encrypted: (r) => r.seq != null, held: held);
      return ([for (final r in drawn.rows) r.id], drawn.beforeJoining);
    }

    // The one the device doesn't hold goes; the one it holds (shared with it), the call notice and the row since stay.
    final (drawn, noticed) = draw([early, shared, notice, later], joined);
    expect(drawn, [shared.id, notice.id, later.id]);
    expect(noticed, isTrue);
    // None from before: no notice.
    expect(draw([later], joined).$1, [later.id]);
    expect(draw([later], joined).$2, isFalse);
    // Without the membership, nothing goes.
    expect(draw([early, later], null).$1, [early.id, later.id]);
    expect(draw([early, later], null).$2, isFalse);
    expect(_shown(shared.id).status, MessageStatus.ok);

    // The notice shows once, above the chat.
    await tester.pumpWidget(_drawn(legacy: false, beforeJoining: true));
    expect(find.text(Notice.beforeJoining.text), findsOneWidget);
    await tester.pumpWidget(_drawn(legacy: false, beforeJoining: false));
    expect(find.byType(Text), findsNothing);
  });
}
