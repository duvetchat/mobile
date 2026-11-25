import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A conversation as the app's own repository draws it, over a real engine and core (PLAN-E2E-CLIENTES.md, «La vista de
// una conversación»): what task 17's review found between the engine and the chat. The desktop's ConversationView and
// content tests, through the app's own wiring.
const _slow = Timeout(Duration(minutes: 3));

String _messagesPath(String conversation) => '/api/users/@me/conversations/$conversation/messages';

/// The epoch the app's core holds of the conversation's group: null without one.
Future<int?> _epoch(TestApp app, String conversation) async {
  try {
    final held = await app.core.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversation});
    return held['epoch'] as int?;
  } catch (_) {
    return null;
  }
}

typedef _Chat = ({
  FakeApi fake,
  String ana,
  String bo,
  TestApp app,
  TestDevice b,
  String conversation,
  ConversationTarget target,
});

/// Ana's app, ready, and Bo's first device in a conversation of theirs whose group is made: a DM Ana's app opened,
/// or a [group] of Bo's he opened.
Future<_Chat> _chat({bool group = false}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: group, members: [bo, ana], owner: bo);
  final app = await appOn(fake, ana);
  await app.ready();
  final b = await firstDevice(fake, bo);
  final target = ConversationTarget(conversation);
  if (group) {
    await b.engine.openConversation(conversation);
  } else {
    app.repository.chatShown(target);
  }
  await until(() async => await _epoch(app, conversation) != null && await groupOf(b, conversation) != null);
  return (fake: fake, ana: ana, bo: bo, app: app, b: b, conversation: conversation, target: target);
}

/// A group of Bo's and Cy's, where Bo said two things before Ana joined it on the server (she has no leaf yet).
Future<({FakeApi fake, String ana, String conversation, ConversationTarget target})> _joinedLate() async {
  final fake = FakeApi();
  final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: true, members: [bo, cy], owner: bo);
  final b = await firstDevice(fake, bo);
  final c = await firstDevice(fake, cy);
  await b.engine.openConversation(conversation);
  await sameGroup([b, c], conversation);
  for (final text in ['one', 'two']) {
    await b.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text));
  }
  await b.engine.stop();
  await c.engine.stop();
  fake.addMembers(conversation, [ana]);
  return (fake: fake, ana: ana, conversation: conversation, target: ConversationTarget(conversation));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  // I1 of task 17's review (the desktop's N1): a message made again goes under a new nonce, which the gateway's copy
  // carries. That copy reaches the chat under the nonce the person sent it with, in the place of their row; with its
  // answer lost, a Retry by that nonce answers with the message, and posts nothing.
  test(
    "a_message_made_again_reaches_the_chat_under_the_person's_nonce,_and_its_Retry_posts_nothing",
    () async {
      final (:fake, ana: _, bo: _, :app, :b, :conversation, :target) = await _chat();
      final events = <MessageEvent>[];
      final heard = app.repository.messageEvents(target).listen(events.add);
      addTearDown(heard.cancel);
      final path = (method: 'POST', path: _messagesPath(conversation));
      final first = uuidv4();
      fake.cutRequest(path);
      await expectLater(app.repository.send(target, 'once', nonce: first), throwsA(anything));
      await stoppedByHand(b);
      for (var i = 0; i < 6; i++) {
        await commitByHand(b, conversation);
      }
      await until(() async => await _epoch(app, conversation) == 7);
      // Retried, it's made again under a new nonce, which the API takes; its answer is lost, and its event comes.
      fake.loseAnswer(path);
      await expectLater(app.repository.resend(target, first), throwsA(anything));
      await until(() => events.whereType<MessageCreated>().isNotEmpty);
      final copies = [for (final event in events.whereType<MessageCreated>()) event.message];
      expect({for (final m in copies) m.nonce}, {first});
      // The copy bound it on the device. Retried again, it's the message sent already: it answers, and nothing goes.
      await until(() async => (await app.repository.messages(target)).every((m) => !m.pending));
      final posts = app.count('POST', _messagesPath(conversation));
      expect((await app.repository.resend(target, first)).id, copies.first.id);
      expect(app.count('POST', _messagesPath(conversation)), posts);
      await b.host.close();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M1 of task 17's review: a page read before this device can be read draws its encrypted rows as loading, neither
  // empty nor waiting.
  test(
    'a_page_read_before_the_device_can_be_read_draws_its_rows_as_loading',
    () async {
      final (:fake, :ana, :conversation, :target) = await _joinedLate();
      final app = await appOn(fake, ana);
      await until(() => app.repository.conversations.value.any((c) => c.id == conversation));
      final page = await app.repository.messages(target);
      expect([for (final m in page) (m.loading, m.waiting)], [(true, false), (true, false)]);
    },
    skip: noCore,
    timeout: _slow,
  );

  // I5 of task 17's review (Ruling 15): once this device can be read, rows from before the user joined that it doesn't
  // hold give way to the one notice, also on a page read before.
  test(
    'rows_from_before_joining_give_way_once_the_device_can_be_read,_also_on_a_page_read_before',
    () async {
      final (:fake, :ana, :conversation, :target) = await _joinedLate();
      final app = await appOn(fake, ana);
      await until(() => app.repository.conversations.value.any((c) => c.id == conversation));
      final page = await app.repository.messages(target);
      expect(page, hasLength(2));
      await app.ready();
      expect(await app.repository.withContent(target, page), isEmpty);
      expect(app.repository.chatStart(target).beforeJoining, isTrue);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M2 of task 17's review: the Chats tab's preview of a message that isn't the newest is drawn only under the author
  // the server names for it, as any row is.
  test(
    'a_preview_is_drawn_only_under_the_author_the_server_names',
    () async {
      final (fake: _, :ana, bo: _, :app, :b, :conversation, :target) = await _chat();
      final first = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'first by bo'),
      ))!;
      final second = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'second by bo'),
      ))!;
      await until(() => app.repository.latest.value[conversation]?.content == 'second by bo');
      // A server that names someone else as the first one's author, for the Chats tab.
      app.repository.opened(
        target,
        'Bo',
        latest: ChatMessage(id: first.id, authorId: ana, authorName: 'Ana', content: '', createdAt: DateTime.now()),
      );
      // Bo's edit of his second makes the device's view of the conversation read again.
      await b.engine.editMessage(conversation, second.id, 'second, edited');
      await until(() => app.repository.latest.value[conversation]?.content == 'second, edited');
      expect(app.repository.recents.value.single.previewText, Notice.waiting.text);
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of task 17's review (M3's view half, as the desktop's): a Dismiss of a message that went, its answer and its
  // event lost, brings the API's copy into the chat, under the nonce the person sent it with.
  test(
    "a_Dismiss_whose_message_went_shows_the_API's_copy",
    () async {
      final (:fake, ana: _, bo: _, :app, :b, :conversation, :target) = await _chat();
      final events = <MessageEvent>[];
      final heard = app.repository.messageEvents(target).listen(events.add);
      addTearDown(heard.cancel);
      final nonce = uuidv4();
      fake.holdEvents();
      fake.loseAnswer((method: 'POST', path: _messagesPath(conversation)));
      await expectLater(app.repository.send(target, 'it went', nonce: nonce), throwsA(anything));
      await app.repository.discard(target, nonce);
      await until(() => events.whereType<MessageCreated>().isNotEmpty);
      final copy = events.whereType<MessageCreated>().single.message;
      expect((copy.nonce, copy.content), (nonce, 'it went'));
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M3 of task 17's review: an edit the server refused for good resolves (this device shows it, and the chat puts
  // nothing back), and the app hears it, to tell the person wherever they are.
  test(
    'an_edit_refused_for_good_resolves_and_is_told_wherever_the_person_is',
    () async {
      final (:fake, ana: _, bo: _, :app, :b, :conversation, :target) = await _chat();
      final told = <ChangeRefused>[];
      final heard = app.repository.changesRefused.listen(told.add);
      addTearDown(heard.cancel);
      final sent = await app.repository.send(target, 'one', nonce: uuidv4());
      fake.refuse(
        (method: 'PATCH', path: '${_messagesPath(conversation)}/${sent.id}'),
        403,
        body: {'error': 'only its author changes a message'},
      );
      await app.repository.edit(target, sent.id, 'two');
      await until(() => told.isNotEmpty);
      expect([for (final t in told) (t.conversationId, t.messageId, t.deletion)], [(conversation, sent.id, false)]);
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M7 of task 17's review: past a long absence, a page reads a few of the API's pages, and the next goes on from where
  // it stopped, to what the device holds from before (the desktop's view test, through the app's paging).
  test(
    'the_pages_go_on_past_rows_from_before_joining_while_the_device_holds_older_ones',
    () async {
      final (:fake, :ana, :bo, :app, :b, :conversation, :target) = await _chat(group: true);
      final mine = await app.repository.send(target, 'from before', nonce: uuidv4());
      final keyPackages = await b.api.claimKeyPackages(ana);
      await stoppedByHand(b);
      await removeByHand(b, conversation, ana);
      await until(() async => await _epoch(app, conversation) == null);
      // Ana away: Bo's 350 messages, then she's back.
      fake.addOpaqueMessages(conversation, bo, 350);
      await addByHand(b, conversation, ana, keyPackages);
      await until(() async => await _epoch(app, conversation) != null);
      await app.repository.refreshConversations();
      final after = await app.repository.send(target, 'after', nonce: uuidv4());
      final from = app.seen.length;
      final page = await app.repository.messages(target);
      expect([for (final m in page) m.id], [after.id]);
      expect(app.count('GET', _messagesPath(conversation), from: from), lessThanOrEqualTo(3));
      // Short, with more behind it: the chat pages on.
      expect(app.repository.olderBeyond(target, page.first.id), isTrue);
      final older = await app.repository.messages(target, before: page.first.id);
      expect([for (final m in older) m.id], [mine.id]);
      expect(app.repository.olderBeyond(target, older.first.id), isFalse);
      await b.host.close();
    },
    skip: noCore,
    timeout: _slow,
  );
}
