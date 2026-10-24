import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// The fake, with the room permissions a test takes away, and an edit
/// answered as the API answers it: the message alone, without its files,
/// reactions or reply.
class _Fake extends FakeRepository {
  final denied = <(String, int)>{};

  /// Takes [bit] away in [roomId].
  void deny(int bit, [String roomId = 'r-general']) => denied.add((roomId, bit));

  @override
  bool canInRoom(String spaceId, String roomId, int bit) =>
      !denied.contains((roomId, bit)) && super.canInRoom(spaceId, roomId, bit);

  @override
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content) async {
    await super.edit(target, messageId, content);
    return ChatMessage(
      id: messageId,
      authorId: FakeRepository.me.id,
      authorName: 'gaby',
      content: content,
      createdAt: DateTime(2026, 10, 23, 9),
      edited: true,
    );
  }
}

/// What the chat does as the desktop app does: updates, moderation, bots'
/// messages, live notices, spoilers, mentions, reading and sending.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<_Fake> pumpApp(WidgetTester tester, void Function(_Fake r)? setUp) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = _Fake();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    return repository;
  }

  Future<_Fake> openMaya(WidgetTester tester, {void Function(_Fake r)? setUp}) async {
    final repository = await pumpApp(tester, setUp);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> longPress(WidgetTester tester, String text) async {
    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  group('updates', () {
    ChatMessage notes() => ChatMessage(
      id: 'm9',
      authorId: _maya,
      authorName: 'Maya',
      content: 'see the notes',
      createdAt: DateTime(2026, 10, 23, 10),
      pinned: true,
      reply: MessageReply(
        messageId: 'm2',
        authorId: _me,
        authorName: 'Gaby',
        content: 'Yes, way better than the side panels.',
      ),
      reactions: [
        Reaction(emoji: '👍', users: {_maya}),
      ],
      attachments: const [
        MessageAttachment(
          id: 'a',
          filename: 'notes.pdf',
          contentType: 'application/pdf',
          url: 'https://example.invalid/notes.pdf',
        ),
      ],
    );

    testWidgets('a link preview\'s update keeps the file, reactions, reply, pin and author', (tester) async {
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(notes()));
      await tester.pumpAndSettle();
      // What MESSAGE_UPDATE carries for it: none of those, and no author.
      repository.push(
        'c-maya',
        MessageUpdated(
          ChatMessage(
            id: 'm9',
            authorId: _maya,
            authorName: 'Unknown',
            content: 'see the notes',
            createdAt: DateTime(2026, 10, 23, 10),
            embeds: const [MessageEmbed(title: 'The notes', url: 'https://duvet.chat/notes')],
          ),
          withAuthor: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The notes'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^PDF, notes\.pdf')), findsOneWidget);
      expect(find.bySemanticsLabel('👍 1'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Replying to Gaby: Yes, way better')), findsOneWidget);
      expect(find.text('Maya'), findsWidgets);
      expect(find.text('Unknown'), findsNothing);
      await longPress(tester, 'see the notes');
      expect(find.bySemanticsLabel('Unpin'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an edit shows in the replies that quote it', (tester) async {
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(notes()));
      await tester.pumpAndSettle();
      repository.push(
        'c-maya',
        MessageUpdated(
          ChatMessage(
            id: 'm2',
            authorId: _me,
            authorName: 'Gaby',
            content: 'Yes, much better.',
            createdAt: DateTime(2026, 10, 23, 9),
            edited: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Replying to Gaby: Yes, much better\.')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('saving your own edit keeps the message\'s file and reactions', (tester) async {
      final repository = await openMaya(
        tester,
        setUp: (r) => r.history['c-maya']![1] = ChatMessage(
          id: 'm2',
          authorId: _me,
          authorName: 'Gaby',
          content: 'Yes, way better than the side panels.',
          createdAt: DateTime(2026, 10, 23, 9),
          reactions: [
            Reaction(emoji: '👍', users: {_maya}),
          ],
          attachments: const [
            MessageAttachment(
              id: 'a',
              filename: 'panels.pdf',
              contentType: 'application/pdf',
              url: 'https://example.invalid/panels.pdf',
            ),
          ],
        ),
      );
      await longPress(tester, 'Yes, way better than the side panels.');
      await tapLabel(tester, 'Edit');
      await tester.enterText(find.byType(EditableText), 'Yes, much better.');
      await tester.pump();
      await tapLabel(tester, 'Save edit');
      expect(repository.edits.single, ('m2', 'Yes, much better.'));
      expect(find.text('Yes, much better.'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^PDF, panels\.pdf')), findsOneWidget);
      expect(find.bySemanticsLabel('👍 1'), findsOneWidget);
      semantics.dispose();
    });
  });
}
