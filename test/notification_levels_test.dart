import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// Notification levels: a place at nothing shows no unread mark nor mention count, which come back with its level, as
/// the repository keeps them.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpApp(WidgetTester tester) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> toSpaces(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
  }

  testWidgets('a chat at nothing shows no mention count nor unread mark in Chats, and gets them back', (tester) async {
    final repository = await pumpApp(tester);
    repository.mentions.value = {'c-maya': 2};
    await repository.setNotificationLevel('c-maya', NotificationTarget.conversation, NotificationLevel.nothing);
    await tester.pumpAndSettle();
    expect(find.text('@2'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Maya, unread')), findsNothing);

    await repository.setNotificationLevel('c-maya', NotificationTarget.conversation, NotificationLevel.mentions);
    await tester.pumpAndSettle();
    expect(find.text('@2'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Maya, unread, 2 mentions')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a Space at nothing has no news, but a room of it on every message keeps its own', (tester) async {
    final repository = await pumpApp(tester);
    repository.unread.value = {'r-general'};
    await repository.setNotificationLevel('s-guild', NotificationTarget.space, NotificationLevel.nothing);
    await toSpaces(tester);
    expect(find.bySemanticsLabel(RegExp(r'^Design Guild, unread')), findsNothing);

    await repository.setNotificationLevel('r-general', NotificationTarget.room, NotificationLevel.all);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Design Guild, unread')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a room at nothing has no unread mark in its Space\'s directory', (tester) async {
    final repository = await pumpApp(tester);
    repository.unread.value = {'r-general'};
    await toSpaces(tester);
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^# general, unread')), findsOneWidget);

    await repository.setNotificationLevel('r-general', NotificationTarget.room, NotificationLevel.nothing);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^# general, unread')), findsNothing);
    semantics.dispose();
  });

  // The menus choose a place's level, as the desktop's right click does: a long press on a Space or a room, and the
  // Space's own menu and a chat's.
  testWidgets('a long press on a Space chooses its notifications, and Nothing takes its news away', (tester) async {
    final repository = await pumpApp(tester);
    repository.unread.value = {'r-general'};
    await toSpaces(tester);
    expect(find.bySemanticsLabel(RegExp(r'^Design Guild, unread')), findsOneWidget);
    await tester.longPress(find.text('Design Guild'));
    await tester.pumpAndSettle();
    expect(find.text('Default (Only mentions)'), findsOneWidget);
    await tester.tap(find.text('Nothing'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices, ['s-guild space nothing']);
    expect(find.bySemanticsLabel(RegExp(r'^Design Guild, unread')), findsNothing);
    semantics.dispose();
  });

  testWidgets('a room\'s default is its Space\'s level, and the Space\'s menu has Notifications too', (tester) async {
    final repository = await pumpApp(tester);
    await repository.setNotificationLevel('s-guild', NotificationTarget.space, NotificationLevel.nothing);
    await toSpaces(tester);
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('# general', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Default (Nothing)'), findsOneWidget);
    await tester.tap(find.text('All messages'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices.last, 'r-general room all');

    await tester.tap(find.bySemanticsLabel('Design Guild, Space menu').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default (Only mentions)'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices.last, 's-guild space default');
    semantics.dispose();
  });

  // A message to another chat moves the Chats rows while a menu is open: the pick still goes, from either menu.
  void moveRows(FakeRepository repository) => repository.push(
    'c-team',
    MessageCreated(
      FakeRepository.message('n1', author: FakeRepository.leo, name: 'Leo', text: 'hi', at: DateTime(2026, 10, 24)),
    ),
  );

  testWidgets('a pick from the levels menu goes though the Chats rows moved meanwhile', (tester) async {
    final repository = await pumpApp(tester);
    await tester.longPress(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    moveRows(repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nothing'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices, ['c-maya conversation nothing']);
    semantics.dispose();
  });

  testWidgets('a chat\'s menu still opens the levels after its row moved', (tester) async {
    final repository = await pumpApp(tester);
    await tester.longPress(find.text('Maya'));
    await tester.pumpAndSettle();
    moveRows(repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nothing'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices, ['c-maya conversation nothing']);
    semantics.dispose();
  });

  testWidgets('a chat\'s menu chooses its notifications, with no default', (tester) async {
    final repository = await pumpApp(tester);
    await tester.longPress(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Default'), findsNothing);
    await tester.tap(find.text('Nothing'));
    await tester.pumpAndSettle();
    expect(repository.levelChoices, ['c-maya conversation nothing']);
    semantics.dispose();
  });
}
