import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// Spaces as the desktop has them: what the user may see and do in each.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpApp(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    semantics = tester.ensureSemantics();
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

  testWidgets('Chats leaves out a room its Space no longer lists to the user', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.recentChats.opened(const RoomTarget(spaceId: 's-guild', roomId: 'r-general'), '# general');
        // A room the user can't see any more.
        r.recentChats.opened(const RoomTarget(spaceId: 's-guild', roomId: 'r-secret'), '# secret');
        // A Space the gateway hasn't told of yet: its room stays.
        r.recentChats.opened(const RoomTarget(spaceId: 's-later', roomId: 'r-news'), '# news');
      },
    );
    expect(find.bySemanticsLabel(RegExp(r'^# general')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^# news')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^# secret')), findsNothing);
    semantics.dispose();
  });

  group('refusals say the API\'s reason', () {
    Future<void> tapLabel(WidgetTester tester, Pattern label) async {
      await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
      await tester.pumpAndSettle();
    }

    Future<void> openSpaces(WidgetTester tester) async {
      await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
      await tester.pumpAndSettle();
    }

    Future<void> typeInvite(WidgetTester tester) async {
      await openSpaces(tester);
      await tapLabel(tester, 'Join or create a Space');
      await tapLabel(tester, 'Join with an invite');
      await tester.enterText(find.byType(EditableText).last, 'k7Qe2m');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
    }

    testWidgets('joining', (tester) async {
      final repository = await pumpApp(
        tester,
        setUp: (r) => r
          ..invites['k7Qe2m'] = const InvitePreview(code: 'k7Qe2m', spaceId: 's-x', spaceName: 'Fieldwork')
          ..refusals['joinInvite'] = 'You cannot be in more than 100 spaces',
      );
      await typeInvite(tester);
      await tapLabel(tester, 'Join Fieldwork');
      expect(repository.joined, ['k7Qe2m']);
      expect(find.text('You cannot be in more than 100 spaces'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an invite\'s preview', (tester) async {
      await pumpApp(tester, setUp: (r) => r.refusals['invite'] = 'Invite link not found or has expired');
      await typeInvite(tester);
      expect(find.text('Invite link not found or has expired'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('adding a bot', (tester) async {
      final repository = await pumpApp(
        tester,
        setUp: (r) {
          r.refusals['addBot'] = 'This bot is private — only team members can add it';
          r.history['r-general'] = [
            FakeRepository.message(
              'inv',
              author: FakeRepository.maya,
              name: 'Maya',
              text: 'Add this one https://duvet.chat/invite?bot=0190a3b2-0000-7000-8000-000000000002',
            ),
          ];
        },
      );
      await openSpaces(tester);
      await tester.tap(find.text('Design Guild'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('# general'));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Add to a Space');
      await tapLabel(tester, 'Design Guild');
      expect(repository.botsAdded, isEmpty);
      expect(find.text('This bot is private — only team members can add it'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
    });

    testWidgets('making a role', (tester) async {
      await pumpApp(tester, setUp: (r) => r.refusals['createRole'] = 'You don\'t have permission to manage roles');
      await openSpaces(tester);
      await tester.tap(find.text('Design Guild'));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Design Guild, Space menu');
      await tapLabel(tester, 'Space settings');
      await tapLabel(tester, RegExp(r'^Roles'));
      await tapLabel(tester, 'New role');
      await tester.enterText(find.byType(EditableText).last, 'Hosts');
      await tester.pump();
      await tapLabel(tester, 'Create');
      expect(find.text('You don\'t have permission to manage roles'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
    });
  });

  testWidgets('a new Space takes the API\'s limits: a name of 64 characters, a description of 256', (tester) async {
    final repository = await pumpApp(tester);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Join or create a Space').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Create a Space').last);
    await tester.pumpAndSettle();
    bool creates() => tester.widget<DuvetButton>(find.widgetWithText(DuvetButton, 'Create Space')).onPressed != null;
    final name = find.byType(EditableText).first;
    final about = find.byType(EditableText).last;

    // Counted as the API counts them: an emoji is one.
    await tester.enterText(name, '${'a' * 63}🎉');
    await tester.pump();
    expect(find.text('64 of 64 characters'), findsOneWidget);
    expect(creates(), isTrue);
    await tester.enterText(name, 'a' * 65);
    await tester.pump();
    expect(find.text('Up to 64 characters'), findsOneWidget);
    expect(creates(), isFalse);

    await tester.enterText(name, 'Cumbia Collective');
    await tester.enterText(about, 'b' * 257);
    await tester.pump();
    expect(find.text('Up to 256 characters'), findsOneWidget);
    expect(creates(), isFalse);
    await tester.enterText(about, 'b' * 256);
    await tester.pump();
    expect(find.text('256 of 256 characters'), findsOneWidget);
    await tester.tap(find.widgetWithText(DuvetButton, 'Create Space'));
    await tester.pumpAndSettle();
    expect(repository.created.single, ('Cumbia Collective', 'b' * 256, null));
    semantics.dispose();
  });
}
