import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FCircularProgress;

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;

/// The start of a chat, and what friends are doing.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpApp(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  Finder button(String label) => find.byWidgetPredicate((w) => w is DuvetButton && w.label == label);

  const song = UserActivity(name: 'Spotify', listening: true, details: 'Night Drive', state: 'Chromatics');

  testWidgets('a DM starts with the person, what they\'re doing, the Spaces shared and Call', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.presence.value = {_maya: Presence.online};
        r.activities.value = {
          _maya: [song],
        };
        r.spaceMembers['s-guild'] = {FakeRepository.me.id, _maya};
      },
    );
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();

    expect(find.text('This is the start of your conversation with Maya.'), findsOneWidget);
    expect(find.text('Listening to Spotify'), findsOneWidget);
    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Chromatics'), findsOneWidget);
    expect(find.text('Design Guild'), findsOneWidget);
    expect(button('Call'), findsOneWidget);
  });

  testWidgets('a room starts with its name and Space, and Invite people for those who may', (tester) async {
    await pumpApp(tester);
    await openGeneral(tester);
    expect(find.text('The start of #general in Design Guild.'), findsOneWidget);
    expect(button('Invite people'), findsOneWidget);
  });

  testWidgets('no Invite people where the room forbids invites', (tester) async {
    await pumpApp(tester, setUp: (r) => r.noInvites.add('r-general'));
    await openGeneral(tester);
    expect(find.text('The start of #general in Design Guild.'), findsOneWidget);
    expect(button('Invite people'), findsNothing);
  });

  testWidgets('a chat starts only once there\'s nothing older to load', (tester) async {
    ChatMessage note(String id, int minute) => FakeRepository.message(
      id,
      author: FakeRepository.leo,
      name: 'Leo',
      text: 'note $id',
      at: DateTime(2026, 10, 29, 9).add(Duration(minutes: minute)),
    );
    await pumpApp(
      tester,
      setUp: (r) {
        r.history['r-general'] = [for (var i = 0; i < 100; i++) note('m-$i', 10 + i)];
        r.olderPages['r-general'] = [
          [for (var i = 0; i < 3; i++) note('o-$i', i)],
        ];
        r.pageDelay = const Duration(seconds: 1);
      },
    );
    await openGeneral(tester);
    const start = 'The start of #general in Design Guild.';

    // A full page: older ones may come, and they're on their way.
    await tester.fling(find.byType(ListView).last, const Offset(0, 6000), 4000);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FCircularProgress), findsOneWidget);
    expect(find.text(start), findsNothing);

    // Fewer than a page came: that was the start.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.fling(find.byType(ListView).last, const Offset(0, 6000), 4000);
    await tester.pumpAndSettle();
    expect(find.text('note o-0'), findsOneWidget);
    expect(find.text(start), findsOneWidget);
  });

  testWidgets('friends online say what they\'re doing; offline, their handle', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.friendsOnServer = const Friends(
          friends: [
            Member(userId: _maya, username: 'maya', alias: 'Maya'),
            Member(userId: FakeRepository.leo, username: 'leo'),
          ],
        );
        r.presence.value = {_maya: Presence.online, FakeRepository.leo: Presence.offline};
        r.activities.value = {
          _maya: [song],
          FakeRepository.leo: [const UserActivity(name: 'Celeste')],
        };
      },
    );
    final semantics = tester.ensureSemantics();
    await tester.tap(find.bySemanticsLabel('Friends').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('Listening to Night Drive — Chromatics'), findsOneWidget);
    expect(find.text('@leo'), findsOneWidget);
    expect(find.text('Playing Celeste'), findsNothing);
    semantics.dispose();
  });
}
