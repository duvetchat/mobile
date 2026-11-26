import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/search.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/search.dart';
import 'package:duvet/theme.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:http/http.dart' as http;

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';
import '../support/fake_repository.dart';

// A conversation's search runs on the device (PLAN-E2E-CLIENTES.md, Task 21, as the desktop's Task 20; decision 42):
// its words, from:, mentions:, dates and has: through the core's search, its results drawn from the device's database.
// pinned: and has:sticker, which the API keeps in the clear, go to its search without words, and their text comes from
// the device. Search everywhere mixes the Spaces', which the API searches, with one search on the device over every
// conversation. Ana's device is her app's own engine (the repository's), on a core of the test's; Bo's and Cy's are
// devices of their own. The desktop's search.test.ts in Dart.
const _slow = Timeout(Duration(minutes: 3));
const _space = '0193a4b2-0000-7000-8000-0000000005a0';
const _room = '0193a4b2-0000-7000-8000-0000000005a1';

final _random = Random.secure();

/// The start of a local day, [days] from today, as the search's dates are written.
DateTime _dayFrom(int days) {
  final today = DateTime.now();
  return DateTime(today.year, today.month, today.day + days);
}

typedef _Talk = ({
  FakeApi fake,
  TestApp app,
  String ana,
  String bo,
  TestDevice b,
  String conversation,
  ConversationTarget target,
});

/// Ana and Bo in a DM, both set up, its group made by Ana's app as she opened it, then left: her app hears its gateway
/// events as the app does. [answer] takes a request before the fake does, as a Space's search.
Future<_Talk> _talking({
  Future<http.Response?> Function(http.Request request)? answer,
  bool Function(GatewayEvent event)? hears,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final app = await appOn(fake, ana, answer: answer, hears: hears);
  await app.ready();
  final b = await firstDevice(fake, bo);
  addTearDown(b.engine.stop);
  final target = ConversationTarget(conversation);
  app.repository.chatShown(target);
  await until(() async => await groupOf(b, conversation) != null && await _held(app, conversation));
  app.repository.chatHidden(target);
  await app.repository.refreshConversations();
  return (fake: fake, app: app, ana: ana, bo: bo, b: b, conversation: conversation, target: target);
}

/// Whether Ana's core holds the conversation's group.
Future<bool> _held(TestApp app, String conversation) => app.core
    .handle<Object?>({'cmd': 'group', 'conversation_id': conversation})
    .then((_) => true, onError: (_) => false);

/// Waits until Ana's core holds these messages of the conversation, opened.
Future<void> _heldByAna(TestApp app, String conversation, List<String> ids) => until(() async {
  final rows = await shownMessages(app.core, conversation, ids);
  return rows.length == ids.length && rows.every((row) => row.status == MessageStatus.ok);
});

/// A message of the device's with a picture in it, made and sent by hand: sending files is the attachments' task.
Future<duvet.DirectMessage> _withPicture(TestDevice device, String conversation, String text) async {
  final nonce = uuidv4();
  String random() => base64Encode(List.generate(32, (_) => _random.nextInt(256)));
  final picture = {
    'id': uuidv7(),
    'key': random(),
    'sha256': random(),
    'name': 'apples.png',
    'type': 'image/png',
    'size': 2048,
  };
  final made = await device.host.handle<Map<String, Object?>>({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': messageEnvelope(text, [picture]),
  });
  final sent = await device.api.sendMessage(
    conversation,
    duvet.EncryptedMessage(ciphertext: made['ciphertext']! as String, nonce: nonce),
  );
  await device.host.handle<Object?>({
    'cmd': 'sent',
    'conversation_id': conversation,
    'nonce': nonce,
    'message_id': sent.id,
    'seq': sent.seq,
  });
  return sent;
}

/// The device's message of [text] (or [sticker]) in the conversation, the API's copy of it.
Future<duvet.DirectMessage> _says(TestDevice device, String conversation, {String? text, String? sticker}) async =>
    (await device.engine.sendMessage(
      Outgoing(conversationId: conversation, nonce: uuidv4(), text: text, stickerAttachmentId: sticker),
    ))!;

/// What a search's hits say, newest first.
List<String> _texts(List<SearchHit> hits) => [for (final hit in hits) hit.message.content];

/// The requests the app made to the API's search of a conversation, from [from] on.
List<http.Request> _conversationSearches(TestApp app, {int from = 0}) => [
  for (final r in app.seen.skip(from))
    if (r.url.path.contains('/conversations/') && r.url.path.endsWith('/messages/search')) r,
];

/// A Space's search as the API answers one: these room messages, each at its time.
http.Response _spaceAnswer(List<({String id, DateTime at, String content})> found) => http.Response(
  jsonEncode({
    'total_results': found.length,
    'messages': [
      for (final m in found)
        {
          'id': m.id,
          'room_id': _room,
          'author_id': _space,
          'content': m.content,
          'type': 0,
          'created_at': m.at.toUtc().toIso8601String(),
          'updated_at': m.at.toUtc().toIso8601String(),
        },
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "a_conversation's_search_runs_on_the_device,_with_from,_mentions,_dates_and_has",
    () async {
      final (fake: _, :app, :ana, :bo, :b, :conversation, :target) = await _talking();
      final repository = app.repository;
      final mine = await repository.send(target, 'Àpples and pears', nonce: uuidv4());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final told = await _says(b, conversation, text: 'apples for <@$ana>');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final picture = await _withPicture(b, conversation, 'a photo of the apples');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final plums = await _says(b, conversation, text: 'plums');
      await _heldByAna(app, conversation, [told.id, picture.id, plums.id]);
      final searching = app.seen.length;
      Future<SearchPage> search(
        String text, {
        List<String> authors = const [],
        List<String> mentions = const [],
        List<String> has = const [],
        DateTime? after,
        DateTime? before,
      }) => repository.search(
        SearchQuery(
          text,
          conversationId: conversation,
          authorIds: authors,
          mentionIds: mentions,
          has: has,
          after: after,
          before: before,
        ),
      );

      // Words, each the start of one of the message's words, its case and accents aside: newest first.
      final found = await search('APPLES');
      expect(_texts(found.hits), ['a photo of the apples', 'apples for <@$ana>', 'Àpples and pears']);
      expect((found.total, found.next), (3, null));
      expect(
        [for (final hit in found.hits) (hit.message.id, hit.target)],
        [(picture.id, target), (told.id, target), (mine.id, target)],
      );
      final first = found.hits.first.message;
      expect((first.authorId, first.waiting, first.loading, first.encrypted), (bo, false, false, true));
      // from:, mentions:, the dates and has:, alone and with the words.
      expect(_texts((await search('apples', authors: [bo])).hits), ['a photo of the apples', 'apples for <@$ana>']);
      expect(_texts((await search('', mentions: [ana])).hits), ['apples for <@$ana>']);
      expect((await search('apples', after: _dayFrom(0), before: _dayFrom(1))).hits, hasLength(3));
      expect((await search('apples', before: _dayFrom(0))).hits, isEmpty);
      expect((await search('', after: _dayFrom(1))).hits, isEmpty);
      expect(_texts((await search('', has: ['image'])).hits), ['a photo of the apples']);
      expect(_texts((await search('photo', has: ['file'])).hits), ['a photo of the apples']);
      expect((await search('', has: ['sound'])).hits, isEmpty);
      expect((await search('', has: ['video', 'image'], authors: [ana])).hits, isEmpty);
      // Punctuation alone is nothing to search for: the API answers as it does for a Space's, and the device lists
      // nothing.
      await expectLater(
        search('?!'),
        throwsA(
          isA<duvet.DuvetApiException>().having(
            (e) => e.body,
            'body',
            contains('a search needs some text or a filter'),
          ),
        ),
      );

      // A page at a time, the next from where the last ended.
      for (var n = 0; n <= 25; n++) {
        await _says(b, conversation, text: 'fig $n');
      }
      await until(() async => (await search('fig')).total == 26);
      final page = await search('fig');
      expect(page.hits, hasLength(25));
      final second = await repository.search(page.next!);
      expect(_texts(second.hits), ['fig 0']);
      expect(second.next, isNull);
      // None of it went to the API's search but the punctuation alone, without it.
      expect([for (final r in _conversationSearches(app, from: searching)) r.url.query], ['']);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_search_with_words_never_asks_the_server_about_a_conversation',
    () async {
      final (fake: _, :app, :ana, :bo, :b, :conversation, target: _) = await _talking(
        answer: (request) async =>
            request.url.path == '/api/spaces/$_space/messages/search' ? _spaceAnswer(const []) : null,
      );
      final repository = app.repository;
      final sent = await _says(b, conversation, text: 'kiwi');
      await _heldByAna(app, conversation, [sent.id]);
      final words = [
        SearchQuery('kiwi', conversationId: conversation),
        SearchQuery('kiwi', conversationId: conversation, authorIds: [bo], has: const ['image', 'file']),
        SearchQuery('kiwi', conversationId: conversation, mentionIds: [ana], after: _dayFrom(-1)),
      ];
      final searching = app.seen.length;
      for (final query in words) {
        await repository.search(query);
      }
      expect(_texts((await repository.search(words.first)).hits), ['kiwi']);
      final everywhere = await searchEverywhere(repository, 'kiwi', spaces: [_space]);
      expect(_texts(everywhere), ['kiwi']);
      // Nor does anything follow from what they found: no request names the conversation's messages, or the one found,
      // which would tell the API what the words found.
      bool named(http.Request r) =>
          r.url.path.contains('/conversations/$conversation/messages') || r.url.toString().contains(sent.id);
      expect([for (final r in app.seen.skip(searching).where(named)) r.url], isEmpty);
      // Words with what only the API knows can't go anywhere: they're refused, asking nobody.
      final before = app.seen.length;
      for (final query in [
        SearchQuery('kiwi', conversationId: conversation, pinned: true),
        SearchQuery('kiwi', conversationId: conversation, has: const ['sticker']),
      ]) {
        await expectLater(
          repository.search(query),
          throwsA(isA<ActionFailed>().having((e) => e.message, 'message', Notice.searchSplit.text)),
        );
      }
      expect(app.seen.length, before);
      expect(_conversationSearches(app), isEmpty);
      // Search everywhere still asked the Space, words and all.
      final spaces = [
        for (final r in app.seen)
          if (r.url.path == '/api/spaces/$_space/messages/search') r.url.queryParameters['query'],
      ];
      expect(spaces, ['kiwi']);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "search_everywhere_mixes_the_spaces'_results_with_the_device's_own",
    () async {
      final around = <String, DateTime>{};
      final (:fake, :app, :ana, bo: _, :b, :conversation, target: _) = await _talking(
        answer: (request) async => request.url.path != '/api/spaces/$_space/messages/search'
            ? null
            : _spaceAnswer([
                (
                  id: '0193a4b2-0000-7000-8000-0000000000f2',
                  at: around['newer']!,
                  content: 'melons in the room, later',
                ),
                (
                  id: '0193a4b2-0000-7000-8000-0000000000f1',
                  at: around['older']!,
                  content: 'melons in the room, before',
                ),
              ]),
      );
      final repository = app.repository;
      // A second DM, with Cy, whose group Ana's app makes as she opens it.
      final cy = fake.addUser();
      final other = fake.addConversation(group: false, members: [ana, cy]);
      final c = await firstDevice(fake, cy);
      await repository.refreshConversations();
      repository.chatShown(ConversationTarget(other));
      await until(() async => await groupOf(c, other) != null && await _held(app, other));
      repository.chatHidden(ConversationTarget(other));

      around['older'] = DateTime.now().subtract(const Duration(minutes: 1));
      final fromBo = await _says(b, conversation, text: 'melons from Bo');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fromCy = await _says(c, other, text: 'melons from Cy');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repository.send(ConversationTarget(other), 'no fruit here', nonce: uuidv4());
      await _heldByAna(app, conversation, [fromBo.id]);
      await _heldByAna(app, other, [fromCy.id]);
      around['newer'] = DateTime.now().add(const Duration(minutes: 1));

      final found = await searchEverywhere(repository, 'melons', spaces: [_space]);
      expect(_texts(found), [
        'melons in the room, later',
        'melons from Cy',
        'melons from Bo',
        'melons in the room, before',
      ]);
      expect([for (final hit in found) hit.target.id], [_room, other, conversation, _room]);
      // A conversation the app doesn't list (one the user left) isn't among them, though the device still holds it.
      fake.deleteConversation(other);
      await repository.refreshConversations();
      expect(_texts(await searchEverywhere(repository, 'melons', spaces: [_space])), isNot(contains('melons from Cy')));
      // One search on the device, over every conversation: the API's conversations' search had nothing asked.
      expect(_conversationSearches(app), isEmpty);
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // The desktop's review, M3: the core's search runs over every conversation its database holds, a group the person
  // left among them; its rows mustn't push the listed conversations' out of the 20 that show.
  test(
    "a_group_the_person_left_doesn't_push_the_listed_conversations_out_of_the_device's_results",
    () async {
      final (:fake, :app, :ana, bo: _, :b, :conversation, target: _) = await _talking();
      final repository = app.repository;
      final listed = await _says(b, conversation, text: 'grapes from Bo');
      // A group of Cy's with Ana, whose 101 newer rows of grapes fill the core's first page.
      final cy = fake.addUser();
      final left = fake.addConversation(group: true, members: [cy, ana], owner: cy);
      final c = await firstDevice(fake, cy);
      await c.engine.openConversation(left);
      await repository.refreshConversations();
      await until(() async => await _held(app, left));
      final grapes = [for (var n = 0; n < 101; n++) (await _says(c, left, text: 'grapes $n')).id];
      await _heldByAna(app, conversation, [listed.id]);
      await _heldByAna(app, left, grapes);
      fake.deleteConversation(left);
      await repository.refreshConversations();

      expect(_texts(await searchEverywhere(repository, 'grapes', spaces: const [])), ['grapes from Bo']);
      await c.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'pinned_and_sticker_filters_ask_the_server,_and_draw_from_the_device',
    () async {
      final (fake: _, :app, :ana, :bo, :b, :conversation, :target) = await _talking();
      final repository = app.repository;
      final pinned = await _says(b, conversation, text: 'pin me');
      final sticker = uuidv7();
      final stuck = await _says(b, conversation, sticker: sticker);
      await _says(b, conversation, text: 'leave me');
      await _heldByAna(app, conversation, [pinned.id, stuck.id]);
      await repository.pin(target, pinned.id, pinned: true);
      final searching = app.seen.length;

      // Pinned: the API's search finds it, and its text is the device's: the API's row has none.
      final pins = await repository.search(SearchQuery('', conversationId: conversation, pinned: true));
      expect(_texts(pins.hits), ['pin me']);
      expect(pins.total, 1);
      final pin = pins.hits.single.message;
      expect((pin.id, pin.authorId, pin.pinned), (pinned.id, bo, true));
      expect(
        (await repository.search(SearchQuery('', conversationId: conversation, pinned: true, authorIds: [ana]))).hits,
        isEmpty,
      );
      // A sticker: in the clear on the API's row, beside the device's empty envelope.
      final stickers = await repository.search(SearchQuery('', conversationId: conversation, has: const ['sticker']));
      expect([for (final hit in stickers.hits) (hit.message.id, hit.message.stickerUrl != null)], [(stuck.id, true)]);
      expect(_texts(stickers.hits), ['']);
      // Each went to the API's search without words; a search of the device's alone didn't.
      await repository.search(SearchQuery('pin', conversationId: conversation));
      expect(
        [
          for (final r in _conversationSearches(app, from: searching))
            (
              r.url.queryParameters['pinned'],
              r.url.queryParametersAll['has']?.join(','),
              r.url.queryParameters.containsKey('query'),
            ),
        ],
        [('true', null, false), ('true', null, false), (null, 'sticker', false)],
      );
      // What needs both the API and the device can't go to either: refused, asking nobody.
      final before = app.seen.length;
      for (final query in [
        SearchQuery('', conversationId: conversation, pinned: true, has: const ['image']),
        SearchQuery('', conversationId: conversation, has: const ['sticker', 'sound']),
      ]) {
        await expectLater(
          repository.search(query),
          throwsA(isA<ActionFailed>().having((e) => e.message, 'message', Notice.searchSplit.text)),
        );
      }
      expect(app.seen.length, before);
    },
    skip: noCore,
    timeout: _slow,
  );

  // The desktop's review, M5: a sticker's envelope is empty on the device, and only the API's row says which sticker
  // it is: one the app holds shows as its sticker, any other is left out, and nothing asks the API for its row.
  test(
    "a_sticker's_message_found_on_the_device_shows_as_its_sticker,_never_as_an_empty_card",
    () async {
      final unheard = uuidv7();
      // Ana's app never hears one sticker's message: her device takes it from the queue; the app holds no row of it.
      final (fake: _, :app, ana: _, :bo, :b, :conversation, target: _) = await _talking(
        hears: (event) => event.type != 'DM_MESSAGE_CREATE' || (event.data! as Map)['sticker_attachment_id'] != unheard,
      );
      final repository = app.repository;
      final heard = uuidv7();
      final shown = await _says(b, conversation, sticker: heard);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final hidden = await _says(b, conversation, sticker: unheard);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final said = await _says(b, conversation, text: 'a word');
      await _heldByAna(app, conversation, [shown.id, hidden.id, said.id]);
      final searching = app.seen.length;
      Future<List<(String, bool)>> found(SearchQuery query) async => [
        for (final hit in (await repository.search(query)).hits) (hit.message.id, hit.message.stickerUrl != null),
      ];
      expect(await found(SearchQuery('', conversationId: conversation, authorIds: [bo])), [
        (said.id, false),
        (shown.id, true),
      ]);
      expect(await found(SearchQuery('', conversationId: conversation, after: _dayFrom(0))), [
        (said.id, false),
        (shown.id, true),
      ]);
      expect([for (final r in app.seen.skip(searching)) r.url.path], isNot(contains(contains('/messages'))));
    },
    skip: noCore,
    timeout: _slow,
  );

  // Rule 9 of the desktop's task 20 review: the core's own limits refuse a search past them, and the person reads why.
  test(
    "a_conversation's_search_past_the_core's_limits_says_why",
    () async {
      final (fake: _, :app, ana: _, bo: _, b: _, :conversation, target: _) = await _talking();
      Future<SearchPage> search(String text, {List<String> authors = const []}) =>
          app.repository.search(SearchQuery(text, conversationId: conversation, authorIds: authors));
      Matcher refused(String why) => throwsA(isA<ActionFailed>().having((e) => e.message, 'message', why));
      await expectLater(search('a' * 201), refused("a search's text has 200 characters at most"));
      await expectLater(
        search('', authors: [for (var n = 0; n < 11; n++) uuidv7()]),
        refused('a search takes 10 authors at most'),
      );
    },
    skip: noCore,
    timeout: _slow,
  );

  test("a_conversation's_search_on_a_device_that_isn't_ready_says_so", () async {
    final repository = DuvetRepository(connectGateway: false);
    addTearDown(repository.dispose);
    await expectLater(
      repository.search(const SearchQuery('kiwi', conversationId: '0193a4b2-0000-7000-8000-0000000000c1')),
      throwsA(isA<ActionFailed>().having((e) => e.message, 'message', Notice.notReady.text)),
    );
  });

  group('what a search takes to the device', () {
    test('is its words, authors, mentions, dates and the kinds of files the core tells apart', () {
      final (after, before) = (DateTime.utc(2026, 11, 24), DateTime.utc(2026, 11, 25));
      final search = deviceSearchOf(
        text: 'apples',
        authors: const ['a'],
        mentions: const ['b'],
        has: const ['image', 'sound', 'file', 'video'],
        after: after,
        before: before,
      )!;
      expect(search.page(limit: 25).toCommand(), {
        'cmd': 'search',
        'text': 'apples',
        'from': ['a'],
        'mentions': ['b'],
        'after': after.millisecondsSinceEpoch,
        'before': before.millisecondsSinceEpoch,
        'has': ['image', 'audio', 'file', 'video'],
        'limit': 25,
        'offset': 0,
      });
    });

    test("is nothing when it needs what only the API knows, a kind of file the device can't tell, or nothing", () {
      expect(deviceSearchOf(pinned: true), isNull);
      expect(deviceSearchOf(text: 'x', pinned: false), isNull);
      expect(deviceSearchOf(has: const ['sticker']), isNull);
      expect(deviceSearchOf(has: const ['image', 'sticker']), isNull);
      // A link or an embed: an encrypted message has no preview, and its links aren't searched.
      expect(deviceSearchOf(has: const ['link']), isNull);
      expect(deviceSearchOf(has: const ['link', 'image'])?.page(limit: 1).toCommand()['has'], ['image']);
      // Nothing to search for, or punctuation alone: the API refuses it, as it refuses a Space's.
      expect(deviceSearchOf(), isNull);
      expect(deviceSearchOf(text: '?! ...'), isNull);
      expect(deviceSearchOf(text: '¿qué?')?.page(limit: 1).toCommand()['text'], '¿qué?');
    });

    test('the API takes no words, punctuation alone being none, and of has: only file and sticker', () {
      expect(apiTakes(text: '?'), isTrue);
      expect(apiTakes(text: 'a?'), isFalse);
      expect(apiTakes(has: const ['file', 'sticker']), isTrue);
      expect(apiTakes(has: const ['image']), isFalse);
    });
  });

  // The desktop's review, I2: the core's search doesn't stop when another replaces it, and its answer comes after.
  testWidgets("a_replaced_search's_answer_is_dropped", (tester) async {
    final repository = _HeldSearches();
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: RepositoryScope(
            repository: repository,
            child: const InChatSearch(target: ConversationTarget('c-1'), title: 'Bo'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'first');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(EditableText), 'second');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('second, found'), findsOneWidget);
    repository.first.complete();
    await tester.pumpAndSettle();
    expect(find.text('first, found'), findsNothing);
    expect(find.text('second, found'), findsOneWidget);
  });
}

/// Searches whose first one answers only once [first] completes, after the one that replaced it.
class _HeldSearches extends FakeRepository {
  final first = Completer<void>();

  @override
  Future<SearchPage> search(SearchQuery query) async {
    if (query.text == 'first') await first.future;
    final hit = SearchHit(
      target: const ConversationTarget('c-1'),
      message: ChatMessage(
        id: query.text,
        authorId: 'u-bo',
        authorName: 'Bo',
        content: '${query.text}, found',
        createdAt: DateTime.now(),
      ),
    );
    return (hits: [hit], total: 1, next: null);
  }
}
