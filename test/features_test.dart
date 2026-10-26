import 'package:duvet/chat_view.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/message_tokens.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/composer_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;

void main() {
  group('message tokens', () {
    test('split text, mentions and custom emoji, and read them by name', () {
      final content = 'hey <@$_maya> <:${FakeRepository.party.id}:>!';
      expect(tokenize(content).map((t) => t.runtimeType), [TextToken, MentionToken, TextToken, EmojiToken, TextToken]);
      expect(
        readableContent(content, nameOf: (id) => id == _maya ? 'Maya' : null, emojiNameOf: (_) => 'party'),
        'hey @Maya :party:!',
      );
      expect(readableContent('<@0a0a0a0a-ffff>'), '@someone');
      expect(mentionedIn(content), {_maya});
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

    testWidgets('mentions show as names, and a mention of you is outlined', (tester) async {
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
      // Only the bubble that mentions the user is outlined.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && ((w.decoration as BoxDecoration?)?.border as Border?)?.top.width == 1.5,
        ),
        findsOneWidget,
      );
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

      await tester.tap(find.bySemanticsLabel('Maya, Online · @maya'));
      await tester.pumpAndSettle();
      // Her profile over the members sheet: back returns to it.
      expect(find.bySemanticsLabel('Maya’s profile'), findsWidgets);
      expect(find.text('ONLINE — 1'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Maya’s profile'), findsNothing);
      expect(find.text('ONLINE — 1'), findsOneWidget);

      // Mention closes both.
      await tester.tap(find.bySemanticsLabel('Maya, Online · @maya'));
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
      semantics.dispose();
    });
  });
}
