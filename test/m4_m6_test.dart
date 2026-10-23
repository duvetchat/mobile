import 'dart:async';

import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/search.dart';
import 'package:duvet/spaces.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _Links implements DeepLinkSource {
  final controller = StreamController<Uri>.broadcast();
  @override
  Stream<Uri> get links => controller.stream;
}

/// M4 · Navigation & search, and M6 · Spaces & invites.
void main() {
  late SemanticsHandle semantics;
  late _Links links;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  setUp(() {
    links = _Links();
    DeepLinkSource.instance = links;
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

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  void twoRooms(FakeRepository r) {
    r.spaces.value = const [
      Space(
        id: 's-guild',
        name: 'Design Guild',
        sections: [
          RoomSection(
            name: null,
            rooms: [
              Room(id: 'r-general', spaceId: 's-guild', name: 'general', kind: RoomKind.text, position: 0),
              Room(id: 'r-crit', spaceId: 's-guild', name: 'crit', kind: RoomKind.text, position: 1),
            ],
          ),
        ],
      ),
    ];
    r.history['r-crit'] = [FakeRepository.message('c1', author: FakeRepository.maya, name: 'Maya', text: 'Crit at 7')];
  }

  test('matches are bold accent text, never a block', () {
    final spans = highlighted('Press the button, press!', 'press', const Color(0xFF2F5FE0));
    final marked = [
      for (final s in spans.cast<TextSpan>())
        if (s.style?.fontWeight == FontWeight.w700) s.text,
    ];
    expect(marked, ['Press', 'press']);
    expect(spans.cast<TextSpan>().every((s) => s.style?.backgroundColor == null), isTrue);
  });

  test('invite codes come from links or the code alone', () {
    expect(inviteCodeOf('duvet.chat/invite/paper-club'), 'paper-club');
    expect(inviteCodeOf('https://duvet.chat/invite?code=abc'), 'abc');
    expect(inviteCodeOf('  k7Qe2m '), 'k7Qe2m');
    expect(inviteCodeOf('not a code!'), isNull);
  });

  testWidgets('the chat title opens the Channel Switcher; a pick swaps the chat', (tester) async {
    await pumpApp(tester, setUp: twoRooms);
    await openGeneral(tester);
    await tapLabel(tester, 'Channel general, switch channel');
    // The current room is selected.
    final current = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^# general')).last);
    expect(current.getSemanticsData().flagsCollection.isSelected.toString(), contains('isTrue'));
    await tapLabel(tester, RegExp(r'^# crit'));
    expect(find.text('Crit at 7'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('in-chat search finds, counts, and jumps; a room can widen to its Space', (tester) async {
    final repository = await pumpApp(tester, setUp: twoRooms);
    await openGeneral(tester);
    await tapLabel(tester, 'Search');
    await tester.enterText(find.byType(EditableText), 'ramp');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(repository.searches.last.roomId, 'r-general');
    expect(find.text('1 result in #general'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Leo, .*Pushed the new type ramp')), findsOneWidget);

    await tapLabel(tester, 'Search all of Design Guild');
    expect(repository.searches.last.roomId, isNull);
    expect(repository.searches.last.spaceId, 's-guild');

    await tapLabel(tester, 'Pinned');
    expect(repository.searches.last.pinned, isTrue);

    await tapLabel(tester, RegExp(r'^Leo'));
    expect(find.byType(EditableText), findsOneWidget); // back in the chat
    await tester.pump(const Duration(seconds: 1));
    semantics.dispose();
  });

  testWidgets('pins: pin from a message, list them in a sheet, unpin, jump', (tester) async {
    final repository = await pumpApp(tester);
    await openGeneral(tester);
    await tester.longPress(find.text('Pushed the new type ramp'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Pin');
    expect(repository.pinChanges.single, ('m3', true));

    repository.pinned['r-general'] = [repository.history['r-general']!.single];
    await tapLabel(tester, 'More');
    await tapLabel(tester, 'Pinned messages');
    expect(find.text('1 message in #general'), findsOneWidget);
    await tapLabel(tester, 'Unpin Leo’s message');
    expect(repository.pinChanges.last, ('m3', false));
    expect(find.text('Nothing pinned yet'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a thread shows the chain and replies into it', (tester) async {
    final repository = await pumpApp(tester);
    final root = repository.history['r-general']!.single;
    repository.threads['m3'] = [
      root,
      FakeRepository.message(
        't1',
        author: FakeRepository.maya,
        name: 'Maya',
        text: 'Looks great',
        reply: const MessageReply(messageId: 'm3', authorName: 'Leo', content: 'Pushed the new type ramp'),
      ),
    ];
    await openGeneral(tester);
    await tester.longPress(find.text('Pushed the new type ramp'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'View thread');
    expect(find.text('Thread'), findsOneWidget);
    expect(find.text('1 reply'), findsOneWidget);
    expect(find.text('Looks great'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Agreed');
    await tester.pump();
    await tapLabel(tester, 'Send');
    expect(repository.sent.last.replyTo, 'm3');
    semantics.dispose();
  });

  testWidgets('global search: messages, people and Spaces, with filters', (tester) async {
    final repository = await pumpApp(tester);
    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    expect(find.text('Search messages, people and Spaces'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, 'ma');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.bySemanticsLabel('Maya, @maya'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'design');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('SPACES'), findsOneWidget);
    await tapLabel(tester, 'Messages');
    expect(find.text('SPACES'), findsNothing);
    expect(repository.searches.map((q) => q.spaceId), contains('s-guild'));
    semantics.dispose();
  });

  testWidgets('a person in global search opens your DM with them', (tester) async {
    // The server takes a moment: the dropdown has gone by then.
    await pumpApp(tester, setUp: (r) => r.dmDelay = const Duration(milliseconds: 300));
    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'ma');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Maya, @maya');
    // The chat with Maya, its composer named for her.
    expect(find.bySemanticsLabel(RegExp(r'^Message Maya')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('an invite link opens the join sheet; joining opens the Space', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.invites['paper'] = const InvitePreview(
        code: 'paper',
        spaceId: 's-guild',
        spaceName: 'Paper Club',
        memberCount: 412,
        description: 'A slow book club.',
      ),
    );
    links.controller.add(Uri.parse('https://duvet.chat/invite?code=paper'));
    await tester.pumpAndSettle();
    expect(find.text('Join a Space'), findsOneWidget);
    expect(find.text('A slow book club.'), findsOneWidget);
    await tapLabel(tester, 'Join Paper Club');
    expect(repository.joined, ['paper']);
    expect(find.text('# general'), findsOneWidget); // the Space's directory
    semantics.dispose();
  });

  testWidgets('a message link opens its chat', (tester) async {
    await pumpApp(tester);
    links.controller.add(
      Uri.parse('duvet://conversations/0a0a0a0a-0000-4000-8000-0000000000c1/0a0a0a0a-0000-4000-8000-0000000000d1'),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Back'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('join by pasting a code from the Spaces menu', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.invites['k7Qe2m'] = const InvitePreview(code: 'k7Qe2m', spaceId: 's-x', spaceName: 'Fieldwork'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': 'duvet.chat/invite/k7Qe2m'} : null,
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Join or create a Space');
    await tapLabel(tester, 'Join with an invite');
    await tapLabel(tester, 'Paste');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Join Fieldwork');
    expect(repository.joined, ['k7Qe2m']);
    semantics.dispose();
  });

  testWidgets('create a Space: the preview follows the name; Create', (tester) async {
    final repository = await pumpApp(tester);
    pickSpaceIcon = () async => null;
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Join or create a Space');
    await tapLabel(tester, 'Create a Space');
    expect(find.text('New Space'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, 'Cumbia Collective');
    await tester.pump();
    expect(find.text('Cumbia Collective'), findsWidgets);
    expect(find.text('17 of 50 characters'), findsOneWidget);
    await tapLabel(tester, 'Create Space');
    expect(repository.created.single.$1, 'Cumbia Collective');
    semantics.dispose();
  });

  testWidgets('a DM the server refuses says why', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) => r.dmRefused = 'You can only message friends. Send Maya a friend request first.',
    );
    await tester.tap(find.byType(EditableText).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'ma');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Maya, @maya');
    expect(find.text('You can only message friends. Send Maya a friend request first.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('an invite leads to a room the user may invite people to', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) {
        twoRooms(r);
        r.noInvites.add('r-general');
      },
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Invite people');
    expect(find.text('They’ll land in #crit.'), findsOneWidget);
    expect(repository.invitesMade.single.$1, 'r-crit');
    semantics.dispose();
  });

  testWidgets('where no room allows invites, Invite people says so', (tester) async {
    final repository = await pumpApp(tester, setUp: (r) => r.noInvites.add('r-general'));
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Invite people');
    expect(find.textContaining('You can’t invite people to Design Guild'), findsOneWidget);
    expect(repository.invitesMade, isEmpty);
    await tester.pump(const Duration(seconds: 5));
    semantics.dispose();
  });

  testWidgets('an invite that fails says why, and can be tried again', (tester) async {
    await pumpApp(tester, setUp: (r) => r.inviteFailures = 1);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Invite people');
    expect(find.text('You can’t invite people to #general'), findsOneWidget);
    await tapLabel(tester, 'Try again');
    expect(find.text('duvet.chat/invite?code=k7Qe2m'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('its owner deletes a Space, after typing its name', (tester) async {
    final repository = await pumpApp(tester);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Design Guild, Space menu');
    expect(find.bySemanticsLabel('Leave Space'), findsNothing);
    await tapLabel(tester, 'Delete Space');
    // Not until its name is typed.
    final delete = find.bySemanticsLabel('Delete Space').last;
    expect(tester.getSemantics(delete).flagsCollection.isEnabled.toString(), contains('isFalse'));
    await tester.enterText(find.byType(EditableText).last, 'Design Guild');
    await tester.pump();
    await tapLabel(tester, 'Delete Space');
    expect(repository.deletedSpaces, ['s-guild']);
    // Back on the Spaces grid, without it.
    expect(find.text('Design Guild'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the Space menu invites, marks read, and leaves', (tester) async {
    final repository = await pumpApp(tester, setUp: (r) => r.spaceOwner = false);
    repository.unread.value = {'r-general'};
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    // Unread: the card's name is bold.
    expect(find.bySemanticsLabel(RegExp(r'^Design Guild, unread')), findsOneWidget);
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Invite people');
    expect(find.text('duvet.chat/invite?code=k7Qe2m'), findsOneWidget);
    await tapLabel(tester, '1 day');
    expect(repository.invitesMade.last, ('r-general', const Duration(days: 1)));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Mark all as read');
    expect(repository.unread.value, isEmpty);

    await tapLabel(tester, 'Design Guild, Space menu');
    await tapLabel(tester, 'Leave Space');
    await tapLabel(tester, 'Leave Space');
    expect(repository.left, ['s-guild']);
    semantics.dispose();
  });
}
