import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  Future<FakeRepository> pumpApp(WidgetTester tester, {bool signedIn = true}) async {
    final repository = FakeRepository(signedIn: signedIn);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> openMaya(WidgetTester tester) async {
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
  }

  testWidgets('signing in shows the conversations', (tester) async {
    await pumpApp(tester, signedIn: false);
    expect(find.text('Sign in to Duvet'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(0), 'gaby@duvet.chat');
    await tester.enterText(find.byType(EditableText).at(1), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t reach Duvet. Check your connection.'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(1), 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);
  });

  // forui's delegates bring material_ui's localizations, and the framework's TextField reads its own: without
  // flutter_localizations' too, only English had them, and in any other language the fields failed to build.
  testWidgets('signing in works in another language', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es', 'ES')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await pumpApp(tester, signedIn: false);

    await tester.enterText(find.byType(EditableText).at(0), 'gaby@duvet.chat');
    await tester.enterText(find.byType(EditableText).at(1), 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
  });

  testWidgets('a chat loads its history and takes live messages', (tester) async {
    final repository = await pumpApp(tester);
    final unreadTitle = tester.widget<Text>(find.text('Maya'));
    expect(unreadTitle.style?.fontWeight, FontWeight.w700);

    await openMaya(tester);
    expect(find.text('Hey! Did you see the new tab bar?'), findsOneWidget);
    expect(find.text('Yes, way better than the side panels.'), findsOneWidget);
    expect(repository.reads.last, (const ConversationTarget('c-maya'), 'm2'));
    expect(repository.unread.value, isNot(contains('c-maya')));

    repository.pushTyping('c-maya', const TypingUser(userId: FakeRepository.maya, name: 'Maya'));
    // A broadcast stream delivers in a microtask, after the first frame.
    await tester.pump();
    await tester.pump();
    expect(find.text('Maya is typing…'), findsOneWidget);

    repository.push(
      'c-maya',
      MessageCreated(FakeRepository.message('m4', author: FakeRepository.maya, name: 'Maya', text: 'Shipping it')),
    );
    await tester.pump();
    expect(find.text('Shipping it'), findsOneWidget);
    expect(find.text('Maya is typing…'), findsNothing);
    // The open chat stays read.
    expect(repository.unread.value, isNot(contains('c-maya')));

    repository.push('c-maya', const MessageDeleted('m4'));
    await tester.pump();
    expect(find.text('Shipping it'), findsNothing);
  });

  testWidgets('a sent message shows once, even when the gateway echo comes first', (tester) async {
    final repository = await pumpApp(tester);
    await openMaya(tester);

    repository.holdSends = Completer();
    await tester.enterText(find.byType(EditableText), 'On my way');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();
    expect(find.text('On my way'), findsOneWidget);
    expect(repository.sent.single.content, 'On my way');

    // The gateway's echo carries the nonce the composer sent.
    final nonce = repository.sent.single.nonce;
    repository.push(
      'c-maya',
      MessageCreated(
        FakeRepository.message('sent-1', author: FakeRepository.me.id, name: 'Gaby', text: 'On my way', nonce: nonce),
      ),
    );
    await tester.pump();
    repository.holdSends!.complete();
    await tester.pumpAndSettle();
    expect(find.text('On my way'), findsOneWidget);
  });

  testWidgets('spaces drill down to a room', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(find.text('Design Guild'), findsOneWidget);

    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    expect(find.text('VOICE'), findsOneWidget);
    // Each room previews its last message.
    expect(find.text('Leo: Pushed the new type ramp'), findsOneWidget);
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    expect(find.text('Pushed the new type ramp'), findsOneWidget);
  });

  testWidgets('an opened room joins the recent chats', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats').last);
    await tester.pumpAndSettle();
    // "# room · Space" over "Author: text".
    expect(find.text('# general · Design Guild'), findsOneWidget);
    expect(find.text('Leo: Pushed the new type ramp'), findsOneWidget);
    // The DMs never opened here still follow.
    expect(find.text('Leo'), findsOneWidget);
  });

  testWidgets('signing out returns to the login screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('You').last);
    await tester.pumpAndSettle();
    expect(find.text('@gaby'), findsOneWidget);

    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Duvet'), findsOneWidget);
  });

  test('facehash hashes names as facehash-sv does', () {
    // Reference values from facehash-sv's stringHash, run in Node.
    expect(Facehash.hash('Maya'), 2390972);
    expect(Facehash.hash('Duvet'), 66401620);
    expect(Facehash.hash('gaby'), 3164849);
    expect(Facehash.hash('a much longer display name to overflow 32 bits'), 401172730);
    expect(Facehash.hash('ñandú 🐢'), 1745150799);
  });

  testWidgets('an avatar stays round in a wider gutter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          child: SizedBox(width: 40, child: UserAvatar(name: 'maya', size: 32)),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Facehash)), const Size(32, 32));
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('facehash shows the initial as its mouth until it talks', (tester) async {
    Widget face(double mouthOpen) => MaterialApp(
      home: Facehash(name: 'maya', mouthOpen: mouthOpen),
    );
    await tester.pumpWidget(face(0));
    expect(find.text('M'), findsOneWidget);
    await tester.pumpWidget(face(0.5));
    expect(find.text('M'), findsNothing);
    // Let a blink run its course, then tear down with no timer left.
    await tester.pump(const Duration(seconds: 7));
  });
}
