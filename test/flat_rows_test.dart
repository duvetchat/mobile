// #292: Flat rows, the desktop's message layout (MessageList.svelte), as a
// choice beside Bubbles: a group's first row has the avatar, the name and the
// time, then plain lines; a reply's quote over its head line; reactions and
// files under the text. Bubbles stays the default.
import 'dart:async';
import 'dart:math' show max;

import 'package:clock/clock.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart' show Duvet;
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/prism.dart';
import 'package:duvet/widgets/skeleton.dart' show Bone;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// The fake, with a chat's first page held back while a test says.
class _Held extends FakeRepository {
  Completer<void>? holdHistory;

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    if (before == null) await holdHistory?.future;
    return super.messages(target, before: before);
  }
}

/// No links: the app's own would start listening to the platform's.
class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;

ChatMessage _at(String id, String author, String text, int hour, int minute, {int day = 23, MessageReply? reply}) =>
    FakeRepository.message(
      id,
      author: author,
      name: author == _maya ? 'Maya' : 'Gaby',
      text: text,
      at: DateTime(2026, 10, day, hour, minute),
      reply: reply,
    );

void main() {
  late SemanticsHandle semantics;
  setUpAll(() => DeepLinkSource.instance = _NoLinks());

  // On the messages' day, so a head line reads "Today at" whenever it runs.
  Future<void> onTheDay(Future<void> Function() body) => withClock(Clock.fixed(DateTime(2026, 10, 23, 12)), body);

  Future<_Held> pumpApp(WidgetTester tester, {List<ChatMessage>? maya}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = _Held();
    final appearance = Appearance(MemoryAppearanceStore());
    await appearance.load();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    // After the start, which seeds the history.
    if (maya != null) repository.history['c-maya'] = maya;
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text(name)));
    await tester.pumpAndSettle();
  }

  bool checked(WidgetTester tester, String label) =>
      tester.getSemantics(find.bySemanticsLabel(label).last).flagsCollection.isChecked.toString().contains('isTrue');

  // Appearance's choice, then Maya's chat.
  Future<void> openMaya(WidgetTester tester, {String layout = 'Flat rows'}) async {
    await tab(tester, 'You');
    await tapLabel(tester, layout);
    await tab(tester, 'Chats');
    await tester.tap(find.text('Maya').first);
    await tester.pumpAndSettle();
  }

  Finder text(String t) => find.text(t, findRichText: true);
  Finder filled(Color color) => find.byWidgetPredicate(
    (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == color,
  );
  Finder avatar(String name, double size) =>
      find.byWidgetPredicate((w) => w is UserAvatar && w.name == name && w.size == size);

  testWidgets('Appearance has Bubbles and Flat rows, Bubbles by default, and a chat follows the pick', (tester) async {
    await pumpApp(tester);
    await tab(tester, 'You');
    expect(checked(tester, 'Bubbles'), isTrue);
    expect(checked(tester, 'Flat rows'), isFalse);
    await tapLabel(tester, 'Flat rows');
    expect(checked(tester, 'Flat rows'), isTrue);

    // The user's own message on the left as everyone's, with no azure.
    await tab(tester, 'Chats');
    await tester.tap(find.text('Maya').first);
    await tester.pumpAndSettle();
    const mine = 'Yes, way better than the side panels.';
    const hers = 'Hey! Did you see the new tab bar?';
    expect(tester.getTopLeft(text(mine)).dx, tester.getTopLeft(text(hers)).dx);
    expect(filled(Duvet.azure), findsNothing);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();

    // Bubbles again: the user's own on the right, on azure.
    await openMaya(tester, layout: 'Bubbles');
    expect(tester.getTopLeft(text(mine)).dx, greaterThan(tester.getTopLeft(text(hers)).dx));
    expect(find.ancestor(of: text(mine), matching: filled(Duvet.azure)), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a group\'s first row has the avatar, the name and the time; the next rows are its lines', (
    tester,
  ) async {
    await onTheDay(() async {
      await pumpApp(
        tester,
        maya: [
          _at('m1', _maya, 'First line', 9, 0),
          _at('m2', _maya, 'Second line', 9, 2),
          _at('m3', _maya, 'Third line', 9, 4),
          _at('m4', _me, 'My answer', 9, 5),
        ],
      );
      await openMaya(tester);
      expect(avatar('Maya', 36), findsOneWidget);
      expect(avatar('Gaby', 36), findsOneWidget);
      expect(find.text('Today at 09:00'), findsOneWidget);
      expect(find.text('Today at 09:05'), findsOneWidget);
      expect(find.text('Maya'), findsNWidgets(2), reason: 'the chat bar and her group');
      expect(find.text('Gaby'), findsOneWidget);
      // The lines under one another, by the avatar's column.
      final left = tester.getTopLeft(text('First line')).dx;
      for (final line in ['Second line', 'Third line', 'My answer']) {
        expect(tester.getTopLeft(text(line)).dx, left, reason: line);
      }
      expect(tester.getTopLeft(avatar('Maya', 36)).dx, lessThan(left));
      final name = find.descendant(of: find.byType(ListView), matching: find.text('Maya'));
      expect(tester.getTopLeft(name).dx, left, reason: 'the head line starts where the text does');
      expect(tester.getTopLeft(text('Second line')).dy, greaterThan(tester.getBottomLeft(text('First line')).dy));
    });
    semantics.dispose();
  });

  testWidgets('a new group after five minutes, after a reply and on a new day, as on the desktop', (tester) async {
    await onTheDay(() async {
      await pumpApp(
        tester,
        maya: [
          _at('m0', _maya, 'Last night', 23, 58, day: 22),
          _at('m1', _maya, 'Morning', 9, 0),
          _at('m2', _maya, 'Six minutes on', 9, 6),
          _at(
            'm3',
            _maya,
            'A reply a minute on',
            9,
            7,
            reply: const MessageReply(messageId: 'm1', authorName: 'Maya', content: 'Morning'),
          ),
        ],
      );
      await openMaya(tester);
      expect(avatar('Maya', 36), findsNWidgets(4));
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('23:58'), findsOneWidget, reason: 'an older day says the time alone');
      for (final time in ['Today at 09:00', 'Today at 09:06', 'Today at 09:07']) {
        expect(find.text(time), findsOneWidget, reason: time);
      }
    });
    semantics.dispose();
  });

  testWidgets('a reply\'s quote sits over its head line, and its reactions under its text', (tester) async {
    await onTheDay(() async {
      await pumpApp(
        tester,
        maya: [
          _at('m1', _me, 'Ship it?', 9, 0),
          FakeRepository.message(
            'm2',
            author: _maya,
            name: 'Maya',
            text: 'Shipping now',
            at: DateTime(2026, 10, 23, 9, 1),
            reply: const MessageReply(messageId: 'm1', authorName: 'Gaby', content: 'Ship it?'),
            reactions: [
              Reaction(emoji: '🎉', users: {_me}),
            ],
          ),
        ],
      );
      await openMaya(tester);
      final quote = find.bySemanticsLabel(RegExp(r'^Replying to Gaby: Ship it\?'));
      final head = find.text('Today at 09:01');
      final body = text('Shipping now');
      final reaction = find.bySemanticsLabel(RegExp('^tada 1|^🎉 1|party popper 1'));
      expect(tester.getTopLeft(quote).dy, lessThan(tester.getTopLeft(head).dy));
      expect(tester.getTopLeft(head).dy, lessThan(tester.getTopLeft(body).dy));
      expect(tester.getTopLeft(reaction.last).dy, greaterThan(tester.getBottomLeft(body).dy));
    });
    semantics.dispose();
  });

  testWidgets('a swipe left replies and a long press opens the options, as on bubbles', (tester) async {
    await pumpApp(tester);
    await openMaya(tester);
    final message = text('Hey! Did you see the new tab bar?');
    final x = tester.getTopLeft(message).dx;
    await tester.drag(message, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Maya — Hey! Did you see the new tab bar?'), findsOneWidget);
    expect(tester.getTopLeft(message).dx, x, reason: 'it slides back on release');
    await tester.tap(find.bySemanticsLabel('Cancel reply'));
    await tester.pumpAndSettle();

    await tester.longPress(message);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Message options'), findsWidgets);
    await tapLabel(tester, 'Reply');
    expect(find.text('Replying to Maya — Hey! Did you see the new tab bar?'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets("while a chat loads, flat rows' blocks are all on the left, a group's avatar beside them", (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    // Where each block is: const blocks are one widget, so by their elements.
    List<Rect> bones() => [
      for (final e in find.byWidgetPredicate((w) => w is Bone).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero) & (e.renderObject! as RenderBox).size,
    ];
    Future<void> openHeld(String layout) async {
      await tab(tester, 'You');
      await tapLabel(tester, layout);
      await tab(tester, 'Chats');
      repository.holdHistory = Completer<void>();
      await tester.tap(find.text('Maya').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.bySemanticsLabel('Loading messages'), findsOneWidget);
    }

    Future<void> leave() async {
      repository.holdHistory!.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
    }

    // Bubbles: the user's own runs on the right.
    await openHeld('Bubbles');
    expect(bones().map((r) => r.left).reduce(max), greaterThan(200));
    await leave();

    await openHeld('Flat rows');
    expect(bones().map((r) => r.left), everyElement(lessThan(100)));
    expect(bones().where((r) => r.size == const Size(36, 36)), isNotEmpty);
    await leave();
    semantics.dispose();
  });

  testWidgets('a mention of the user washes its row, with no lit bubble', (tester) async {
    await pumpApp(tester, maya: [_at('m1', _maya, 'Can you look, <@$_me>?', 9, 0)]);
    await openMaya(tester);
    expect(find.byType(PrismBubble), findsNothing);
    final washed = find.byWidgetPredicate(
      (w) => w is AnimatedContainer && (w.decoration as BoxDecoration?)?.gradient != null,
    );
    expect(washed, findsOneWidget);

    // Painted: the light behind the avatar, fading out toward the row's end.
    final row = tester.getRect(washed);
    final pixels = (await tester.runAsync(() async {
      final image = await captureImage(find.byType(DuvetApp).evaluate().single);
      return (bytes: (await image.toByteData())!, width: image.width);
    }))!;
    const ratio = 3;
    Color at(Offset p) {
      final i = ((p.dy * ratio).round() * pixels.width + (p.dx * ratio).round()) * 4;
      final b = pixels.bytes;
      return Color.fromARGB(b.getUint8(i + 3), b.getUint8(i), b.getUint8(i + 1), b.getUint8(i + 2));
    }

    final lit = at(Offset(row.left + 4, row.center.dy));
    final unlit = at(Offset(row.right - 2, row.center.dy));
    expect(unlit, Duvet.light.background);
    // Darker in red and green than the page, by the light's violet: 18% of it in light.
    expect((unlit.r - lit.r) * 255, greaterThan(10));
    expect((unlit.g - lit.g) * 255, greaterThan(10));
    semantics.dispose();
  });
}
