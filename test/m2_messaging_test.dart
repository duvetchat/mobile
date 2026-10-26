import 'dart:ui' show Tristate;

import 'package:duvet/data/markdown.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/code_highlight.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;

/// M2 · Everyday messaging.
void main() {
  late SemanticsHandle semantics;

  Future<FakeRepository> openMaya(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> longPress(WidgetTester tester, String text) async {
    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  group('markdown', () {
    String shape(List<MdInline> list) => list
        .map(
          (i) => switch (i) {
            MdText(:final text) => text,
            MdCode(:final code) => '`$code`',
            MdStyled(:final styles, :final children) => '${styles.map((s) => s.name).join('+')}(${shape(children)})',
            MdSpoiler(:final children) => 'spoiler(${shape(children)})',
            MdLink(:final url, :final children) => 'link($url, ${shape(children)})',
          },
        )
        .join();

    test('inline markup as desktop reads it', () {
      expect(
        shape(parseInline('**bold** *it* _it_ __under__ ~~gone~~ `x*y` ||secret|| ***both***')),
        'bold(bold) italic(it) italic(it) underline(under) strike(gone) `x*y` spoiler(secret) bold+italic(both)',
      );
      expect(
        shape(parseInline('see [the notes](https://duvet.chat/notes) or https://duvet.chat.')),
        ('see link(https://duvet.chat/notes, the notes) or link(https://duvet.chat, https://duvet.chat).'),
      );
      // Snake case and mentions stay text.
      expect(shape(parseInline('snake_case_name <@$_maya>')), 'snake_case_name <@$_maya>');
    });

    test('blocks: code, quotes, lists, headings', () {
      final blocks = parseMarkdown(
        '# Plan\n> keep it\n> short\n- one\n- two\n1. first\n```dart\nfinal x = 1;\n```\nbye',
      );
      expect(blocks.map((b) => b.runtimeType), [MdHeading, MdQuote, MdList, MdList, MdCodeBlock, MdParagraph]);
      expect(plainInline((blocks[1] as MdQuote).inlines), 'keep it\nshort');
      expect((blocks[2] as MdList).ordered, isFalse);
      expect((blocks[3] as MdList).ordered, isTrue);
      expect(((blocks[4] as MdCodeBlock).language, (blocks[4] as MdCodeBlock).code), ('dart', 'final x = 1;'));
    });

    test('tables, as the desktop reads them: a header, a |---| line and its alignments, rows with a | (#26)', () {
      final blocks = parseMarkdown(
        'Roles:\n| Name | Role | Since |\n|:--|:-:|--:|\n| **Maya** | mod | 2024\n|Leo|\n\nbye',
      );
      expect(blocks.map((b) => b.runtimeType), [MdParagraph, MdTable, MdParagraph]);
      final table = blocks[1] as MdTable;
      expect(table.header.map(plainInline), ['Name', 'Role', 'Since']);
      expect(table.aligns, [MdAlign.start, MdAlign.center, MdAlign.end]);
      expect(table.rows.map((r) => r.map(plainInline).toList()), [
        ['Maya', 'mod', '2024'],
        ['Leo'],
      ]);
      // A | without the line under it is text.
      expect(parseMarkdown('a | b\nc').map((b) => b.runtimeType), [MdParagraph]);
    });

    test('code blocks in the desktop\'s languages are colored, by name or alias; others stay plain (#26)', () {
      const base = TextStyle(color: Color(0xFF000000));
      List<(String, Color?)> runs(TextSpan span) => [
        if (span.text case final t? when t.isNotEmpty) (t, span.style?.color),
        for (final c in span.children ?? const <InlineSpan>[]) ...runs(c as TextSpan),
      ];
      final dart = runs(highlightCode('final x = 1;', 'dart', base: base, dark: true)!);
      expect(dart.map((r) => r.$1).join(), 'final x = 1;');
      final keyword = dart.firstWhere((r) => r.$1 == 'final').$2;
      expect(keyword, isNot(base.color), reason: 'a keyword has its own color');
      expect(highlightCode('const a = 1', 'JS', base: base, dark: false), isNotNull);
      expect(highlightCode('fn main() {}', 'zig', base: base, dark: true), isNull);
    });

    testWidgets('a table reads a row a line, each cell after its column', (tester) async {
      final repository = await openMaya(tester);
      repository.push(
        'c-maya',
        MessageCreated(
          FakeRepository.message('t', author: _maya, name: 'Maya', text: '| Name | Role |\n|---|---|\n| Maya | mod |'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Name: Maya, Role: mod')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('renders: links open, spoilers reveal on tap, code is mono', (tester) async {
      final opened = <Uri>[];
      MessageText.openLink = (uri) async {
        opened.add(uri);
        return true;
      };
      final repository = await openMaya(tester);
      repository.push(
        'c-maya',
        MessageCreated(
          FakeRepository.message(
            'md',
            author: _maya,
            name: 'Maya',
            text: '**Plan** is `ready`: [notes](https://duvet.chat/notes) ||friday||',
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Screen readers hear the message in one stop, the spoiler hidden.
      expect(find.bySemanticsLabel('Maya\nPlan is ready: notes spoiler\n09:00'), findsOneWidget);
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('Plan is')),
      );
      final spans = <TextSpan>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text != null) spans.add(s);
        return true;
      });
      expect(spans.firstWhere((s) => s.text!.contains('ready')).style?.fontFamily, 'Fira Mono');
      expect(spans.firstWhere((s) => s.text == 'Plan').style?.fontWeight, FontWeight.w700);

      int id(String label) => CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Maya\nPlan is ready')));
      // One stop: the message's actions, then the spoiler's and the link's.
      expect(node.getSemanticsData().customSemanticsActionIds, [
        id('Reply'),
        id('Message options'),
        id('Reveal spoiler'),
        id('Open https://duvet.chat/notes'),
      ]);
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.customAction,
        id('Reveal spoiler'),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'notes friday')), findsOneWidget);
      final node2 = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Maya\nPlan is ready')));
      expect(node2.getSemanticsData().customSemanticsActionIds, isNot(contains(id('Reveal spoiler'))));
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        node2.id,
        SemanticsAction.customAction,
        id('Open https://duvet.chat/notes'),
      );
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://duvet.chat/notes')]);
      semantics.dispose();
    });
  });

  testWidgets('double-tap replies: the strip, the reference, and the quote above the sent bubble', (tester) async {
    final repository = await openMaya(tester);
    await tester.tap(find.text('Hey! Did you see the new tab bar?'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Hey! Did you see the new tab bar?'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Maya — Hey! Did you see the new tab bar?'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Yes!');
    await tester.pump();
    await tapLabel(tester, 'Send');
    expect(repository.sent.last.replyTo, 'm1');
    expect(find.textContaining('Replying to Maya —'), findsNothing);
    expect(find.bySemanticsLabel('Replying to Maya: Hey! Did you see the new tab bar?. Jump to message'), findsOne);
    semantics.dispose();
  });

  testWidgets('swiping a message left replies, as in WhatsApp; a short swipe or one to the right does not', (
    tester,
  ) async {
    await openMaya(tester);
    final message = find.text('Hey! Did you see the new tab bar?');
    final x = tester.getTopLeft(message).dx;
    await tester.drag(message, const Offset(-40, 0));
    await tester.pumpAndSettle();
    await tester.drag(message, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('Replying to Maya —'), findsNothing);

    await tester.drag(message, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Maya — Hey! Did you see the new tab bar?'), findsOneWidget);
    expect(tester.getTopLeft(message).dx, x, reason: 'it slides back on release');

    // From the row's empty space too, beside the bubble (#50).
    await tester.tap(find.bySemanticsLabel('Cancel reply'));
    await tester.pumpAndSettle();
    final beside = Offset(tester.getSize(find.byType(MaterialApp)).width - 24, tester.getCenter(message).dy);
    await tester.dragFrom(beside, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Maya — Hey! Did you see the new tab bar?'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a reply to a message not loaded opens it on its own', (tester) async {
    final repository = await openMaya(
      tester,
      setUp: (r) {
        r.older['c-maya'] = [FakeRepository.message('m0', author: _maya, name: 'Maya', text: 'Way back')];
        r.history['c-maya']!.add(
          FakeRepository.message(
            'm5',
            author: _maya,
            name: 'Maya',
            text: 'About that',
            reply: const MessageReply(messageId: 'm0', authorId: _maya, authorName: 'Maya', content: 'Way back'),
          ),
        );
      },
    );
    expect(repository.history['c-maya'], hasLength(3));
    await tapLabel(tester, RegExp('^Replying to Maya: Way back'));
    expect(find.bySemanticsLabel('Original message'), findsOneWidget);
    expect(find.text('Way back'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('scrolled up, a button jumps back to the newest messages', (tester) async {
    await openMaya(
      tester,
      setUp: (r) => r.history['c-maya'] = [
        for (var i = 0; i < 60; i++) FakeRepository.message('h$i', author: _maya, name: 'Maya', text: 'Message $i'),
      ],
    );
    const button = 'Jump to the newest messages';
    expect(find.bySemanticsLabel(button), findsNothing);

    await tester.fling(find.text('Message 59'), const Offset(0, 2000), 3000);
    await tester.pumpAndSettle();
    expect(find.text('Message 59'), findsNothing);

    await tapLabel(tester, button);
    expect(find.text('Message 59'), findsOneWidget);
    expect(find.bySemanticsLabel(button), findsNothing);
    semantics.dispose();
  });

  testWidgets('a reply to a message a page back scrolls to it, however long the page takes', (tester) async {
    await openMaya(
      tester,
      setUp: (r) {
        ChatMessage said(String id, String text, {MessageReply? reply}) =>
            FakeRepository.message(id, author: _maya, name: 'Maya', text: text, reply: reply);
        r
          ..pageDelay = const Duration(seconds: 10)
          ..olderPages['c-maya'] = [
            [said('m-old', 'Way back'), for (var i = 0; i < 20; i++) said('o$i', 'Older $i')],
          ]
          ..history['c-maya'] = [
            for (var i = 0; i < 100; i++) said('h$i', 'Message $i'),
            said(
              'm-new',
              'About that',
              reply: const MessageReply(messageId: 'm-old', authorId: _maya, authorName: 'Maya', content: 'Way back'),
            ),
          ];
      },
    );
    await tapLabel(tester, RegExp('^Replying to Maya: Way back'));
    // The page on its way, then the scroll to the message.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Original message'), findsNothing);
    expect(find.text('Way back'), findsOneWidget);
    expect(tester.getCenter(find.text('Way back')).dy, inInclusiveRange(0, tester.view.physicalSize.height));
    semantics.dispose();
  });

  testWidgets('a pin notice links its message and the pins, and those who may delete it (#26)', (tester) async {
    final repository = await openMaya(
      tester,
      setUp: (r) => r.history['c-maya']!.add(
        ChatMessage(
          id: 'n1',
          authorId: _maya,
          authorName: 'Maya',
          content: '',
          createdAt: DateTime(2026, 10, 23, 9, 5),
          isNotice: true,
          reply: const MessageReply(messageId: 'm1', authorId: _maya, authorName: 'Maya', content: ''),
        ),
      ),
    );
    final notice = find.bySemanticsLabel('Maya pinned a message to this conversation');
    expect(notice, findsOneWidget);
    expect(find.text('Maya pinned a message to this conversation. See all pinned messages.'), findsOneWidget);
    void act(String label) {
      final node = tester.getSemantics(notice);
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label)),
      );
    }

    act('See all pinned messages');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Pinned'), findsWidgets);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // Either of a DM's two may delete it.
    await tester.longPress(find.textContaining('See all pinned messages'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Delete');
    await tapLabel(tester, 'Delete');
    expect(repository.deletes, ['n1']);
    expect(notice, findsNothing);
    semantics.dispose();
  });

  testWidgets('editing your own message: the strip, Save, and "edited"', (tester) async {
    final repository = await openMaya(tester);
    await longPress(tester, 'Yes, way better than the side panels.');
    expect(find.bySemanticsLabel('Message options'), findsWidgets);
    await tapLabel(tester, 'Edit');
    expect(find.text('Editing message'), findsOneWidget);
    expect(find.text('Editing'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Yes, much better.');
    await tester.pump();
    await tapLabel(tester, 'Save edit');
    expect(repository.edits.single, ('m2', 'Yes, much better.'));
    expect(find.text('Yes, much better.'), findsOneWidget);
    expect(find.textContaining('edited'), findsOneWidget);
    expect(find.text('Editing message'), findsNothing);
    semantics.dispose();
  });

  testWidgets('return starts a new line; only Send sends, every line in one message', (tester) async {
    final repository = await openMaya(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.keyboardType, TextInputType.multiline);

    await tester.enterText(find.byType(EditableText), 'the list:\n- one\n- two');
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(repository.sent, isEmpty);

    await tapLabel(tester, 'Send');
    expect(repository.sent.single.content, 'the list:\n- one\n- two');
    semantics.dispose();
  });

  testWidgets('deleting your own message asks first', (tester) async {
    final repository = await openMaya(tester);
    // Typing first: the keyboard goes, and stays gone through the delete.
    await tester.showKeyboard(find.byType(EditableText).last);
    await tester.pumpAndSettle();
    await longPress(tester, 'Yes, way better than the side panels.');
    expect(tester.testTextInput.isVisible, isFalse);
    await tapLabel(tester, 'Delete');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('Delete this message?'), findsOneWidget);
    expect(find.text('It will be removed for everyone in this conversation. This can’t be undone.'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Delete for everyone').last);
    // Asked for at once, before the sheet has gone: leaving now can't lose it.
    await tester.pump();
    expect(repository.deletes, ['m2']);
    // Once the sheet has gone, the message goes to dust in its place, hidden,
    // before the list closes up.
    await tester.pump(const Duration(milliseconds: 400));
    final bubble = find.text('Yes, way better than the side panels.');
    final hidden = find.ancestor(
      of: bubble,
      matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Vanish'),
    );
    expect((tester.widget(hidden) as dynamic).hidden, isTrue);
    final dust = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dust');
    expect(dust, findsOneWidget);
    // Here its pixels are never read: the dust goes anyway, picture and all.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(dust, findsNothing);
    expect(bubble, findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    semantics.dispose();
  });

  testWidgets('others’ messages offer no edit or delete', (tester) async {
    await openMaya(tester);
    await longPress(tester, 'Hey! Did you see the new tab bar?');
    expect(find.bySemanticsLabel('Edit'), findsNothing);
    expect(find.bySemanticsLabel('Delete'), findsNothing);
    expect(find.bySemanticsLabel('Reply'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('reactions: chips read their count, a tap toggles, the quick bar adds, events update', (tester) async {
    final repository = await openMaya(
      tester,
      setUp: (r) {
        r.history['c-maya']![0] = FakeRepository.message(
          'm1',
          author: _maya,
          name: 'Maya',
          text: 'Hey! Did you see the new tab bar?',
          reactions: [
            Reaction(emoji: '👍', users: {_maya, _me}),
          ],
        );
      },
    );
    final thumbs = find.bySemanticsLabel('👍 2, you reacted');
    expect(thumbs, findsOneWidget);
    expect(tester.getSemantics(thumbs).getSemanticsData().flagsCollection.isToggled, Tristate.isTrue);

    await tester.tap(thumbs);
    await tester.pumpAndSettle();
    expect(repository.reactions.last, ('m1', '👍', false));
    expect(find.bySemanticsLabel('👍 1'), findsOneWidget);

    await longPress(tester, 'Hey! Did you see the new tab bar?');
    expect(find.bySemanticsLabel('Quick reactions'), findsOneWidget);
    await tapLabel(tester, RegExp('^React heart'));
    expect(repository.reactions.last, ('m1', '❤️', true));
    expect(find.bySemanticsLabel('❤️ 1, you reacted'), findsOneWidget);

    repository.push('*', const ReactionChanged(messageId: 'm1', userId: FakeRepository.leo, emoji: '❤️', added: true));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('❤️ 2, you reacted'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('who reacted: held chip or options, each emoji, oldest first, the API for anyone else (#94)', (
    tester,
  ) async {
    const gone = '0a0a0a0a-0000-4000-8000-000000000099';
    await openMaya(
      tester,
      setUp: (r) {
        r.users[gone] = const Member(userId: gone, username: 'nell', alias: 'Nell');
        r.history['c-maya']![0] = FakeRepository.message(
          'm1',
          author: _maya,
          name: 'Maya',
          text: 'Hey! Did you see the new tab bar?',
          reactions: [
            Reaction(emoji: '👍', users: {_maya, _me}),
            Reaction(emoji: '❤️', users: {gone, FakeRepository.leo}),
          ],
        );
      },
    );
    List<String> people() => [
      for (final label in ['Maya, @maya', 'Gaby, @gaby', 'Nell, @nell', 'leo, @leo'])
        if (find.bySemanticsLabel(label).evaluate().isNotEmpty) label,
    ];

    await tester.longPress(find.bySemanticsLabel('❤️ 2'));
    await tester.pumpAndSettle();
    expect(people(), ['Nell, @nell', 'leo, @leo']);

    await tapLabel(tester, '👍 2');
    expect(people(), ['Maya, @maya', 'Gaby, @gaby']);
    expect(
      tester.getSemantics(find.bySemanticsLabel('👍 2').last).flagsCollection.isChecked.toString(),
      contains('isTrue'),
    );

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await longPress(tester, 'Hey! Did you see the new tab bar?');
    await tapLabel(tester, 'Reactions');
    expect(people(), ['Maya, @maya', 'Gaby, @gaby']);
    semantics.dispose();
  });

  testWidgets('a spoiler picture stays covered until tapped', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        ChatMessage(
          id: 'sp',
          authorId: _maya,
          authorName: 'Maya',
          content: '',
          createdAt: DateTime(2026, 10, 23, 10),
          attachments: const [
            MessageAttachment(
              id: 'a',
              filename: 'SPOILER_ending.png',
              contentType: 'image/png',
              url: 'https://example.invalid/ending.png',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cover = find.bySemanticsLabel('Spoiler, Photo, ending.png');
    expect(cover, findsOneWidget);
    await tester.tap(cover);
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Photo, ending.png'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('after a reconnect the chat fetches what it missed', (tester) async {
    final repository = await openMaya(tester);
    repository.missed['c-maya'] = [
      FakeRepository.message('m7', author: _maya, name: 'Maya', text: 'Sent while you were away'),
    ];
    repository.resume();
    await tester.pumpAndSettle();
    expect(find.text('Sent while you were away'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('an unread chat opens at a "New messages" divider after the last read', (tester) async {
    await openMaya(
      tester,
      setUp: (r) {
        r.lastRead['c-maya'] = 'm1';
        r.history['c-maya']!.add(FakeRepository.message('m3', author: _maya, name: 'Maya', text: 'Hello?'));
      },
    );
    final divider = find.text('New messages');
    expect(divider, findsOneWidget);
    expect(
      tester.getTopLeft(divider).dy,
      greaterThan(tester.getTopLeft(find.text('Hey! Did you see the new tab bar?')).dy),
    );
    expect(tester.getTopLeft(divider).dy, lessThan(tester.getTopLeft(find.text('Hello?')).dy));
    semantics.dispose();
  });

  testWidgets('mentions show as a count on the Chats row, not a dot', (tester) async {
    semantics = tester.ensureSemantics();
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    repository.mentions.value = {'c-maya': 2};
    await tester.pumpAndSettle();
    expect(find.text('@2'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Maya, unread, 2 mentions')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a draft waits in its chat: text, files and reply', (tester) async {
    await openMaya(tester);
    await tester.tap(find.text('Hey! Did you see the new tab bar?'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Hey! Did you see the new tab bar?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'half a thought');
    await tester.pump();
    await tapLabel(tester, 'Back');
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(find.text('half a thought'), findsOneWidget);
    expect(find.textContaining('Replying to Maya'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a failed message keeps Retry, and can be deleted', (tester) async {
    final repository = await openMaya(tester);
    repository.failSends = true;
    await tester.enterText(find.byType(EditableText), 'into the void');
    await tester.pump();
    await tapLabel(tester, 'Send');
    expect(find.bySemanticsLabel('Message not sent'), findsWidgets);
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);

    await tapLabel(tester, 'Delete');
    expect(find.text('into the void'), findsNothing);
    semantics.dispose();
  });
}
