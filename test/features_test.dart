import 'package:duvet/chat_view.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/message_tokens.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/composer_controller.dart';
import 'package:duvet/widgets/prism.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;
const _design = 'dddddddd-0000-4000-8000-000000000001';
const _gone = 'eeeeeeee-0000-4000-8000-000000000002';
const _designRoom = Room(id: _design, spaceId: 's-guild', name: 'design', kind: RoomKind.text, position: 2);

void main() {
  group('message tokens', () {
    test('split text, mentions and custom emoji, and read them by name', () {
      final content = 'hey <@$_maya> <:${FakeRepository.party.id}:>!';
      expect(tokenize(content).map((t) => t.runtimeType), [TextToken, MentionToken, TextToken, EmojiToken, TextToken]);
      expect(
        readableContent(content, nameOf: (id) => id == _maya ? 'Maya' : null, emojiNameOf: (_) => 'party'),
        'hey @Maya :party:!',
      );
      expect(readableContent('<@0a0a0a0a-ffff>'), '@0a0a0a0a');
      expect(mentionedIn(content), {_maya});
      expect(
        readableContent('see <#$_design> and <#$_gone>', roomNameOf: (id) => id == _design ? 'design' : null),
        'see #design and #unknown',
      );
      expect(tokenize('<#$_design>').single, isA<RoomToken>());
    });

    test('emoji-only messages of up to five show large', () {
      expect(isJumboEmoji('😂'), isTrue);
      expect(isJumboEmoji('👨‍👩‍👧 🇦🇷 ❤️'), isTrue);
      expect(isJumboEmoji('<:${FakeRepository.party.id}:> 👍🏽'), isTrue);
      expect(isJumboEmoji('😂😂😂😂😂😂'), isFalse);
      expect(isJumboEmoji('ok 😂'), isFalse);
      expect(isJumboEmoji('10:30'), isFalse);
    });
  });

  group('composer', () {
    ComposerController composer(String text) => ComposerController(accent: () => Colors.blue)
      ..value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );

    test('a picked mention and custom emoji go out as codes', () {
      final c = composer('hi @ma');
      expect(c.query, (trigger: '@', query: 'ma', start: 3));
      c.insertMention(FakeRepository.everyone[1]);
      expect(c.text, 'hi @Maya ');
      c.value = TextEditingValue(
        text: '${c.text}so :pa',
        selection: TextSelection.collapsed(offset: c.text.length + 6),
      );
      c.insertCustomEmoji(FakeRepository.party);
      expect(c.text, 'hi @Maya so :party: ');
      expect(c.encoded, 'hi <@$_maya> so <:${FakeRepository.party.id}:> ');
      // Typed by hand, a name stays text.
      expect((composer('@Maya')).encoded, '@Maya');
    });

    test('a picked room goes out as <#id>, and comes back as #name to edit', () {
      final c = composer('see #de');
      expect(c.query, (trigger: '#', query: 'de', start: 4));
      c.insertRoom(_designRoom);
      expect(c.text, 'see #design ');
      expect(c.encoded, 'see <#$_design> ');
      // Typed by hand, a name stays text.
      expect(composer('#design').encoded, '#design');

      c.setEncoded(
        'in <#$_design>',
        nameOf: (_) => null,
        emojiNameOf: (_) => null,
        roomNameOf: (id) => id == _design ? 'design' : null,
      );
      expect(c.text, 'in #design');
      expect(c.encoded, 'in <#$_design>');
    });

    test('a time is not an emoji query, a lone colon neither', () {
      expect(composer('at 10:30').query, isNull);
      expect(composer('note :').query, isNull);
      expect(composer('so :jo').query, (trigger: ':', query: 'jo', start: 3));
    });
  });

  testWidgets('emoji search ranks as on desktop', (tester) async {
    final catalog = await tester.runAsync(EmojiCatalog.load);
    expect(catalog!.categories.length, 9);
    expect(catalog.search('joy').first.emoji, '😂');
    expect(catalog.search('thumbs').first.emoji, '👍');
    expect(catalog.nameOf('🍕'), 'pizza');
  });

  group('chat', () {
    late SemanticsHandle semantics;
    String? clipboard;
    setUp(() {
      ChatView.debugPickMedia = null;
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        },
      );
    });

    Future<FakeRepository> openGeneral(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
      semantics = tester.ensureSemantics();
      final repository = FakeRepository();
      setUp?.call(repository);
      await tester.pumpWidget(DuvetApp(repository: repository));
      // The bundled emoji load off the fake clock, then go in synchronously.
      EmojiCatalog.debugUse((await tester.runAsync(EmojiCatalog.load))!);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spaces').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Design Guild'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('# general'));
      await tester.pumpAndSettle();
      return repository;
    }

    Future<void> send(WidgetTester tester) async {
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pumpAndSettle();
    }

    testWidgets('in dark, a mention of you lights its bubble, with no outline, once', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = await openGeneral(tester);
      ChatMessage from(String id, String text) =>
          FakeRepository.message(id, author: FakeRepository.leo, name: 'leo', text: text);
      repository.push('r-general', MessageCreated(from('m-gem', 'ping <@${FakeRepository.me.id}>')));
      await tester.pump();
      expect(find.byType(PrismAnchor), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && ((w.decoration as BoxDecoration?)?.border as Border?)?.top.width == 1.5,
        ),
        findsNothing,
      );
      // Come in sight as it arrived, its arrival is due, and plays through.
      expect(tester.widget<PrismBubble>(find.byType(PrismBubble)).onArrive, isNotNull);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      // The chat built again, it isn't due anymore.
      repository.push('r-general', MessageCreated(from('m-after', 'thanks')));
      await tester.pumpAndSettle();
      expect(tester.widget<PrismBubble>(find.byType(PrismBubble)).onArrive, isNull);
      semantics.dispose();
    });

    testWidgets('in dark, a reply that pings you lights its bubble too, with no outline', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = await openGeneral(tester);
      repository.push(
        'r-general',
        MessageCreated(
          FakeRepository.message(
            'm-reply',
            author: FakeRepository.leo,
            name: 'leo',
            text: 'A loud reply',
            reply: MessageReply(
              messageId: 'm0',
              authorId: FakeRepository.me.id,
              authorName: 'Gaby',
              content: 'hm',
              mentionAuthor: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Its text names nobody: the light comes from the bubble's corner.
      expect(find.ancestor(of: find.text('A loud reply'), matching: find.byType(PrismBubble)), findsOneWidget);
      expect(find.byType(PrismAnchor), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && ((w.decoration as BoxDecoration?)?.border as Border?)?.top.width == 1.5,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('in dark, a mention\'s light moves as the list scrolls, and a bubble held up isn\'t lit again', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = await openGeneral(tester);
      void push(String id, String text) => repository.push(
        'r-general',
        MessageCreated(FakeRepository.message(id, author: FakeRepository.leo, name: 'leo', text: text)),
      );
      // Enough to scroll, the mention a few lines up from the bottom.
      for (var i = 0; i < 14; i++) {
        push('m-before-$i', 'line $i');
      }
      await tester.pumpAndSettle();
      push('m-lit', 'ping <@${FakeRepository.me.id}>');
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        push('m-after-$i', 'reply $i');
      }
      await tester.pumpAndSettle();

      // The light's own layer, which holds nothing else.
      Future<List<int>> light() async {
        final layer = tester.renderObject<RenderRepaintBoundary>(
          find.descendant(of: find.byType(PrismBubble), matching: find.byType(RepaintBoundary)).first,
        );
        final bytes = await tester.runAsync(() async => (await (await layer.toImage()).toByteData())!);
        return bytes!.buffer.asUint8List();
      }

      final before = await light();
      await tester.drag(find.byType(PrismBubble), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(find.byType(PrismBubble), findsOneWidget);
      expect(await light(), isNot(equals(before)));
      // The pictures took real time, in which the deep links' plugin, absent here, fails: not this test's.
      expect(tester.takeException(), anyOf(isNull, isA<MissingPluginException>()));

      // Held up: a copy over the list, lit too, neither of them due.
      await tester.longPress(find.byType(PrismAnchor));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final bubbles = tester.widgetList<PrismBubble>(find.byType(PrismBubble));
      expect(bubbles, hasLength(2));
      expect(bubbles.map((b) => b.onArrive), everyElement(isNull));
      semantics.dispose();
    });

    testWidgets('in dark, an unread mention lights up as its chat opens, and not when it opens again', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = await openGeneral(tester);
      bool due() =>
          find.byType(PrismBubble).evaluate().isNotEmpty &&
          tester.widget<PrismBubble>(find.byType(PrismBubble)).onArrive != null;
      Future<void> reopen() async {
        await tester.tap(find.bySemanticsLabel('Back').last);
        await tester.pumpAndSettle();
        // Unread, as the app counts it, on the way in.
        repository.mentions.value = {'r-general': 1};
        await tester.tap(find.text('# general'));
        for (var i = 0; i < 20 && !due(); i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      repository.history['r-general']!.add(
        FakeRepository.message(
          'm-unread',
          author: FakeRepository.leo,
          name: 'leo',
          text: 'ping <@${FakeRepository.me.id}>',
        ),
      );
      await reopen();
      expect(due(), isTrue);
      await tester.pumpAndSettle();
      // Still counted unread, say: it has lit up, and doesn't again.
      await reopen();
      await tester.pumpAndSettle();
      expect(find.byType(PrismBubble), findsOneWidget);
      expect(due(), isFalse);
      semantics.dispose();
    });

    testWidgets('mentions show as names, and a mention of you lights its bubble', (tester) async {
      final repository = await openGeneral(tester);
      repository.push(
        'r-general',
        MessageCreated(
          FakeRepository.message('m9', author: FakeRepository.leo, name: 'leo', text: 'ping <@$_maya> and <@$_me>'),
        ),
      );
      await tester.pumpAndSettle();
      // Read with its time, which closes the run.
      expect(find.bySemanticsLabel(RegExp(r'^ping @Maya and @Gaby\n09:00$')), findsOneWidget);
      // Only the bubble that mentions the user is lit, from the mention.
      expect(find.byType(PrismBubble), findsOneWidget);
      expect(find.descendant(of: find.byType(PrismBubble), matching: find.byType(PrismAnchor)), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('@ suggests up to 10, as the desktop, in a panel that scrolls (#78)', (tester) async {
      await openGeneral(
        tester,
        setUp: (r) => r.extraRoomMembers.addAll([
          for (var i = 0; i < 12; i++) Member(userId: 'u-m$i', username: 'mod$i', alias: 'Mod $i'),
        ]),
      );
      await tester.enterText(find.byType(EditableText), '@mod');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mention suggestions, 10'), findsOneWidget);
      expect(tester.getSize(find.bySemanticsLabel('Mention suggestions, 10')).height, lessThanOrEqualTo(300));
      final last = find.bySemanticsLabel('Mod 9, @mod9');
      await tester.dragUntilVisible(last, find.bySemanticsLabel('Mod 0, @mod0'), const Offset(0, -60));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('@Mod 9 '), findsOneWidget);
      semantics.dispose();
    });

    void addDesign(FakeRepository r) => r.spaces.value = [
      for (final s in r.spaces.value)
        Space(
          id: s.id,
          name: s.name,
          onlineCount: s.onlineCount,
          sections: [
            ...s.sections,
            const RoomSection(name: 'More', rooms: [_designRoom]),
          ],
        ),
    ];

    testWidgets('a room mention shows its name and opens it; one hidden or gone shows #unknown (#83)', (tester) async {
      final repository = await openGeneral(tester);
      // After sign-in, which seeds the Spaces.
      addDesign(repository);
      repository.push(
        'r-general',
        MessageCreated(
          FakeRepository.message('m9', author: FakeRepository.leo, name: 'leo', text: 'see <#$_design> or <#$_gone>'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^see #design or #unknown\n09:00$')), findsOneWidget);
      await tester.tapOnText(find.textRange.ofSubstring('#unknown'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('# design'), findsNothing);

      await tester.tapOnText(find.textRange.ofSubstring('#design'));
      // The bubble waits to see if it's a double tap (a reply) first.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('# design'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('typing # suggests the Space\'s rooms; the pick goes out as <#id> (#83)', (tester) async {
      final repository = await openGeneral(tester);
      // After sign-in, which seeds the Spaces.
      addDesign(repository);
      await tester.enterText(find.byType(EditableText), 'over in #de');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Room suggestions, 1'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(RegExp('^#design')));
      await tester.pumpAndSettle();
      expect(find.text('over in #design '), findsOneWidget);
      await send(tester);
      expect(repository.sent.last.content, 'over in <#$_design>');
      semantics.dispose();
    });

    testWidgets('typing @ suggests members; the pick goes out as a mention', (tester) async {
      final repository = await openGeneral(tester);
      await tester.enterText(find.byType(EditableText), 'thanks @ma');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mention suggestions, 1'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Maya, @maya'));
      await tester.pumpAndSettle();
      expect(find.text('thanks @Maya '), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Mention suggestions')), findsNothing);
      await send(tester);
      expect(repository.sent.last.content, 'thanks <@$_maya>');
      expect(find.bySemanticsLabel(RegExp(r'^thanks @Maya\n')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('typing :name suggests emoji, Unicode and the space\'s own', (tester) async {
      final repository = await openGeneral(tester);
      await tester.enterText(find.byType(EditableText), 'nice :grinni');
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(':grinning:'));
      await tester.pumpAndSettle();
      expect(find.text('nice 😀'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'yay :par');
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(':party:'));
      await tester.pumpAndSettle();
      await send(tester);
      expect(repository.sent.last.content, 'yay <:${FakeRepository.party.id}:>');
      semantics.dispose();
    });

    testWidgets('the picker inserts emoji and sends stickers', (tester) async {
      final repository = await openGeneral(tester);
      await tester.tap(find.bySemanticsLabel('Emoji and stickers'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Emoji and stickers'), findsWidgets);
      await tester.enterText(find.byType(EditableText).last, 'pizza');
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('pizza'));
      await tester.pumpAndSettle();
      expect(find.text('🍕'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Add photos, a sticker or a mention'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Add to message'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Sticker'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Sticker, wave'));
      await tester.pumpAndSettle();
      expect(repository.sent.last.sticker?.id, FakeRepository.wave.id);
      expect(find.bySemanticsLabel('Sticker, wave'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('photos and GIFs attach, can be removed, and send', (tester) async {
      ChatView.debugPickMedia = (_) async => const [
        OutgoingFile(path: '/nowhere/party.gif', name: 'party.gif', contentType: 'image/gif'),
        OutgoingFile(path: '/nowhere/cat.jpg', name: 'cat.jpg', contentType: 'image/jpeg'),
      ];
      final repository = await openGeneral(tester);
      await tester.tap(find.bySemanticsLabel('Add photos, a sticker or a mention'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Photos & GIFs'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('GIF, party.gif'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Remove cat.jpg'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Photo, cat.jpg'), findsNothing);

      await send(tester);
      expect(repository.sent.last.files.single.name, 'party.gif');
      expect(find.bySemanticsLabel('GIF, party.gif'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a picked file can be marked as a spoiler, and sends named as one', (tester) async {
      ChatView.debugPickMedia = (_) async => const [
        OutgoingFile(path: '/nowhere/cat.jpg', name: 'cat.jpg', contentType: 'image/jpeg'),
      ];
      final repository = await openGeneral(tester);
      await tester.tap(find.bySemanticsLabel('Add photos, a sticker or a mention'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Photos & GIFs'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Mark cat.jpg as spoiler'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Spoiler, Photo, cat.jpg'), findsOneWidget);
      // Twice is back to a plain photo; three times, a spoiler again.
      await tester.tap(find.bySemanticsLabel('Mark cat.jpg as spoiler'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Photo, cat.jpg'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Mark cat.jpg as spoiler'));
      await tester.pumpAndSettle();

      await send(tester);
      expect(repository.sent.last.files.single.name, 'SPOILER_cat.jpg');
      semantics.dispose();
    });

    testWidgets('a GIF waits for a tap when animations are off', (tester) async {
      final repository = await openGeneral(tester);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      repository.push(
        'r-general',
        MessageCreated(
          ChatMessage(
            id: 'm10',
            authorId: FakeRepository.leo,
            authorName: 'leo',
            content: '',
            createdAt: DateTime(2026, 10, 23, 10),
            attachments: const [
              MessageAttachment(
                id: 'a1',
                filename: 'dance.gif',
                contentType: 'image/gif',
                url: 'https://example.invalid/dance.gif',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gif = find.bySemanticsLabel('GIF, dance.gif');
      expect(tester.getSemantics(gif).hint, 'Double tap to play');
      expect(find.text('GIF ▶'), findsOneWidget);
      await tester.tap(gif);
      // A double tap replies: a single tap waits to be sure it isn't one.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.text('GIF'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the members sheet lists by presence and mentions from a profile', (tester) async {
      await openGeneral(tester);
      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Members'));
      await tester.pumpAndSettle();
      // Maya is reported online; nobody else is reported at all.
      expect(find.text('ONLINE — 1'), findsOneWidget);
      expect(find.text('MEMBERS — 2'), findsOneWidget);
      expect(find.text('1 online · 3'), findsOneWidget);

      await tester.enterText(find.byType(EditableText).last, 'le');
      await tester.pumpAndSettle();
      expect(find.text('ONLINE — 1'), findsNothing);
      await tester.enterText(find.byType(EditableText).last, '');
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Maya, Online · @maya · owner'));
      await tester.pumpAndSettle();
      // Her profile over the members sheet: back returns to it.
      expect(find.bySemanticsLabel('Maya’s profile'), findsWidgets);
      expect(find.text('ONLINE — 1'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Maya’s profile'), findsNothing);
      expect(find.text('ONLINE — 1'), findsOneWidget);

      // Mention closes both.
      await tester.tap(find.bySemanticsLabel('Maya, Online · @maya · owner'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Mention Maya'));
      await tester.pumpAndSettle();
      expect(find.text('ONLINE — 1'), findsNothing);
      expect(find.text('@Maya '), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('back from members or pinned messages leaves the composer unfocused', (tester) async {
      await openGeneral(tester);
      bool composing() => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
      for (final sheet in ['Members', 'Pinned messages']) {
        await tester.showKeyboard(find.byType(EditableText));
        expect(composing(), isTrue);
        await tester.tap(find.bySemanticsLabel('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel(sheet));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(composing(), isFalse, reason: sheet);
      }
      semantics.dispose();
    });

    testWidgets('a long press opens the message menu; back closes it', (tester) async {
      await openGeneral(tester);
      await tester.longPress(find.text('Pushed the new type ramp'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Message options'), findsWidgets);
      expect(find.bySemanticsLabel('Mention Leo'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mention Leo'), findsNothing);

      await tester.longPress(find.text('Pushed the new type ramp'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Copy text'));
      await tester.pumpAndSettle();
      expect(clipboard, 'Pushed the new type ramp');

      await tester.longPress(find.text('Pushed the new type ramp'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Copy link'));
      await tester.pumpAndSettle();
      expect(clipboard, startsWith('https://duvet.chat/channels/'));
      semantics.dispose();
    });
  });
}
