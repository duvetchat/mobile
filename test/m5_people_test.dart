import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
const _leo = FakeRepository.leo;

/// M5 · People & conversations.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('an avatar opens a profile: bio, roles, Add friend, Mention', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.roleTags[_leo] = const [RoleTag('Moderator', color: 0xFF2F9E62)],
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Leo’s profile');
    expect(find.text('ROLES IN DESIGN GUILD'), findsOneWidget);
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.text('Nothing here yet.'), findsOneWidget);
    await tapLabel(tester, 'Add friend');
    expect(repository.friendCalls, ['send $_leo']);
    expect(find.bySemanticsLabel('Friend request sent'), findsOneWidget);

    await tapLabel(tester, 'Mention leo');
    expect(find.text('@leo '), findsOneWidget);
    semantics.dispose();
  });

  // #general of Design Guild, with [text] from Leo as its newest message.
  Future<FakeRepository> openWith(WidgetTester tester, String text, {void Function(FakeRepository r)? setUp}) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) {
        r.history['r-general'] = [FakeRepository.message('mm', author: _leo, name: 'Leo', text: text)];
        setUp?.call(r);
      },
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    return repository;
  }

  // A message's one stop for screen readers: its text, with Reply and
  // Message options.
  SemanticsNode messageNode(WidgetTester tester, Pattern text) {
    final options = CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Message options'));
    var node = tester.getSemantics(find.bySemanticsLabel(text).last);
    while (!(node.getSemanticsData().customSemanticsActionIds?.contains(options) ?? false)) {
      node = node.parent!;
    }
    return node;
  }

  List<String> actionsOf(SemanticsNode node) => [
    for (final id in node.getSemanticsData().customSemanticsActionIds ?? const <int>[])
      CustomSemanticsAction.getAction(id)!.label ?? '',
  ];

  Future<void> perform(WidgetTester tester, SemanticsNode node, String action) async {
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: action)),
    );
    await tester.pumpAndSettle();
  }

  // As a screen reader closes it: its grabber's Close.
  Future<void> closeSheet(WidgetTester tester) async {
    final close = tester.getSemantics(find.bySemanticsLabel('Close').last);
    close.owner!.performAction(close.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
  }

  testWidgets('a mention in a message opens who it names: tapped, or from a screen reader', (tester) async {
    await openWith(
      tester,
      'ask <@$_maya> about the tab bar',
      setUp: (r) => r.roleTags[_maya] = const [RoleTag('Designer', color: 0xFF2F9E62)],
    );

    await tester.tapOnText(find.textRange.ofSubstring('@Maya'));
    // The bubble waits to see if it's a double tap (a reply) first.
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.text('ROLES IN DESIGN GUILD'), findsOneWidget);
    expect(find.text('Designer'), findsOneWidget);
    await closeSheet(tester);
    expect(find.text('ROLES IN DESIGN GUILD'), findsNothing);

    // One stop: the text with its time, and the message's actions with the
    // mention's.
    final message = messageNode(tester, RegExp('ask @Maya about the tab bar'));
    expect(message.getSemanticsData().label, 'Leo\nask @Maya about the tab bar\n09:00');

    expect(actionsOf(message), containsAll(['Reply', 'Message options', 'Open Maya’s profile']));
    await perform(tester, message, 'Open Maya’s profile');
    expect(find.text('ROLES IN DESIGN GUILD'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a text message\'s Reply and Message options work from its one stop', (tester) async {
    await openWith(tester, 'ask <@$_maya> about the tab bar');
    await perform(tester, messageNode(tester, RegExp('ask @Maya about the tab bar')), 'Reply');
    expect(find.textContaining('Replying to', findRichText: true), findsOneWidget);
    await perform(tester, messageNode(tester, RegExp('ask @Maya about the tab bar')), 'Message options');
    expect(find.bySemanticsLabel('Copy text'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a message with no text bubble keeps Reply and Message options on itself', (tester) async {
    await openWith(tester, '🎉');
    final message = messageNode(tester, RegExp('🎉'));
    expect(actionsOf(message), containsAll(['Reply', 'Message options']));
    await perform(tester, message, 'Message options');
    expect(find.bySemanticsLabel('Copy text'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a mention offers its profile only where it shows: not in code, a link or a hidden spoiler', (
    tester,
  ) async {
    await openWith(tester, '`<@$_maya>` and [<@$_maya>](https://duvet.chat) and ||<@$_leo> did it||');
    final message = messageNode(tester, RegExp('^Leo\\n@Maya and @Maya and spoiler'));
    expect(actionsOf(message), isNot(contains('Open Maya’s profile')));
    // The spoiler hides who: no action names them until it's revealed.
    expect(actionsOf(message), isNot(contains('Open leo’s profile')));
    await perform(tester, message, 'Reveal spoiler');
    final revealed = messageNode(tester, RegExp('^Leo\\n@Maya and @Maya and @leo did it'));
    expect(actionsOf(revealed), contains('Open leo’s profile'));
    semantics.dispose();
  });

  testWidgets('two people shown by one name get an action each, for the right one', (tester) async {
    const other = '0a0a0a0a-0000-4000-8000-0000000000f2';
    const sam1 = '0a0a0a0a-0000-4000-8000-0000000000f3';
    const sam2 = '0a0a0a0a-0000-4000-8000-0000000000f4';
    await openWith(
      tester,
      '<@$_maya> meet <@$other>, and <@$sam1> <@$sam2>',
      setUp: (r) => r.extraRoomMembers.addAll(const [
        Member(userId: other, username: 'maya.r', alias: 'Maya'),
        Member(userId: sam1, username: 'sam', alias: 'Sam'),
        Member(userId: sam2, username: 'sam.k', alias: 'Sam'),
      ]),
    );
    final message = messageNode(tester, RegExp('^Leo\\n@Maya meet @Maya'));
    // Counted by name: each Sam is told from the other Sam, not from the Mayas.
    expect(
      actionsOf(message),
      containsAll([
        'Open Maya’s profile, mention 1',
        'Open Maya’s profile, mention 2',
        'Open Sam’s profile, mention 1',
        'Open Sam’s profile, mention 2',
      ]),
    );
    await perform(tester, message, 'Open Maya’s profile, mention 2');
    expect(find.text('@maya.r'), findsOneWidget);
    await closeSheet(tester);
    await perform(tester, messageNode(tester, RegExp('^Leo\\n@Maya meet @Maya')), 'Open Maya’s profile, mention 1');
    expect(find.text('@maya'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('someone the app hasn\'t met opens by the name their mention shows, with no made-up handle', (
    tester,
  ) async {
    await openWith(tester, 'cc <@0a0a0a0a-0000-4000-8000-0000000000ff>');
    await tester.tapOnText(find.textRange.ofSubstring('@someone'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.text('Someone'), findsOneWidget);
    // No handle line: no "@…" of the profile's own.
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('@')), findsNothing);
    semantics.dispose();
  });

  testWidgets('someone named but not met here opens by their name, with no made-up handle', (tester) async {
    // A DM with Maya, who mentions Leo: Leo isn't in it, nor among the people
    // the app holds, but the app knows his name.
    await pumpApp(
      tester,
      setUp: (r) {
        r.people = [
          for (final p in FakeRepository.everyone)
            if (p.userId != _leo) p,
        ];
        r.history['c-maya'] = [FakeRepository.message('ml', author: _maya, name: 'Maya', text: 'ask <@$_leo> too')];
      },
    );
    await tester.tap(find.text('Maya').first);
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('@leo'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.text('leo'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('@')), findsNothing);
    semantics.dispose();
  });

  testWidgets('a profile from the friends list shows the bio and banner a DM\'s members carry', (tester) async {
    const banner = 'https://api.duvet.chat/attachments/0b0b0b0b-0000-4000-8000-000000000001';
    await pumpApp(
      tester,
      setUp: (r) {
        r.people = [
          for (final m in FakeRepository.everyone)
            m.userId == _maya
                ? const Member(userId: _maya, username: 'maya', alias: 'Maya', bio: 'Night runner', bannerUrl: banner)
                : m,
        ];
        r.friendsOnServer = const Friends(
          friends: [Member(userId: _maya, username: 'maya', alias: 'Maya')],
        );
      },
    );
    await tester.tap(find.bySemanticsLabel('Friends').hitTestable().first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maya').last);
    await tester.pumpAndSettle();

    expect(find.text('Night runner'), findsOneWidget);
    expect(find.text('Nothing here yet.'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage && (w.image as NetworkImage).url == banner),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('a profile counts the Spaces the person is in as Mutual Spaces', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.spaces.value = [...r.spaces.value, const Space(id: 's-runners', name: 'Night Runners')];
        r.spaceMembers['s-guild'] = {FakeRepository.me.id, _leo};
        r.spaceMembers['s-runners'] = {FakeRepository.me.id};
      },
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Leo’s profile');
    expect(find.text('MUTUAL SPACES'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('MUTUAL SPACES'), matching: find.byType(Column)).first,
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('the profile of someone who asked the user offers Accept request, which takes theirs', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.friendsOnServer = Friends(
        incoming: [
          FriendRequestItem(
            id: 'req-leo',
            person: const Member(userId: _leo, username: 'leo'),
            at: DateTime(2026, 10, 22),
          ),
        ],
      ),
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Leo’s profile');
    expect(find.bySemanticsLabel('Add friend'), findsNothing);
    await tapLabel(tester, 'Accept request');
    expect(repository.friendCalls, ['accept req-leo']);
    semantics.dispose();
  });

  testWidgets('in a Space, a bot\'s status there comes first: its members sheet and its profile', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) => r.presence.value = {
        _maya: Presence.online,
        // Offline overall, online in this Space: the shard holding it is connected.
        _leo: Presence.offline,
        '$_leo:s-guild': Presence.online,
      },
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Members'));
    await tester.pumpAndSettle();
    expect(find.text('ONLINE — 2'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^leo, Online')));
    await tester.pumpAndSettle();
    expect(find.text('Online'), findsWidgets);
    expect(find.text('Offline'), findsNothing);
    semantics.dispose();
  });

  testWidgets('friends: requests in and out, accept, decline, cancel, add by username', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.friendsOnServer = Friends(
        friends: const [Member(userId: _maya, username: 'maya', alias: 'Maya')],
        incoming: [
          FriendRequestItem(
            id: 'req-in',
            person: const Member(userId: 'u-sam', username: 'sam', alias: 'Sam'),
            at: DateTime(2026, 10, 22),
          ),
        ],
        outgoing: [
          FriendRequestItem(
            id: 'req-out',
            person: const Member(userId: 'u-theo', username: 'theo', alias: 'Theo'),
            at: DateTime(2026, 10, 21),
          ),
        ],
      ),
    );
    await tester.tap(find.bySemanticsLabel('Friends').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('WANTS TO BE FRIENDS'), findsOneWidget);
    expect(find.text('ONLINE — 1'), findsOneWidget);
    expect(find.text('Pending 1'), findsOneWidget);

    await tapLabel(tester, 'Accept');
    await tapLabel(tester, 'Decline Sam');
    await tapLabel(tester, 'Cancel request');
    expect(repository.friendCalls, ['accept req-in', 'reject req-in', 'reject req-out']);

    await tester.enterText(find.byType(EditableText), '@leo');
    await tapLabel(tester, 'Add');
    expect(repository.friendCalls.last, 'send $_leo');
    await tester.enterText(find.byType(EditableText), 'nobody');
    await tapLabel(tester, 'Add');
    expect(find.text('No one called @nobody shares a Space or a chat with you'), findsOneWidget);

    await tapLabel(tester, 'Sent 1');
    expect(find.text('WANTS TO BE FRIENDS'), findsNothing);
    expect(find.text('YOU ASKED'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('the Friends button counts the requests to the user, as the desktop\'s does', (tester) async {
    final repository = await pumpApp(tester);
    Finder count(String text) => find.descendant(of: find.byType(IconAction), matching: find.text(text));
    FriendRequestItem asks(int i) => FriendRequestItem(
      id: 'req-$i',
      person: Member(userId: 'u-$i', username: 'person$i'),
      at: DateTime(2026, 10, 22),
    );
    expect(find.bySemanticsLabel('Friends'), findsOneWidget);
    expect(count('0'), findsNothing);

    repository.friends.value = Friends(incoming: [asks(1)]);
    await tester.pump();
    expect(find.bySemanticsLabel('Friends, 1 friend request'), findsOneWidget);
    expect(count('1'), findsOneWidget);

    repository.friends.value = Friends(incoming: [for (var i = 0; i < 10; i++) asks(i)]);
    await tester.pump();
    expect(find.bySemanticsLabel('Friends, 10 friend requests'), findsOneWidget);
    expect(count('9+'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('new conversation: one person opens a DM, several a group', (tester) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) => r.friendsOnServer = const Friends(
        friends: [
          Member(userId: _maya, username: 'maya', alias: 'Maya'),
          Member(userId: _leo, username: 'leo'),
        ],
      ),
    );
    await tapLabel(tester, 'New conversation');
    expect(find.bySemanticsLabel('Start conversation'), findsOneWidget);
    await tapLabel(tester, 'Maya, @maya');
    await tapLabel(tester, 'leo, @leo');
    expect(find.text('Start group with 2 people'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'Crit crew');
    await tapLabel(tester, 'Start group with 2 people');
    expect(repository.conversationCalls.single, 'group Crit crew $_maya,$_leo');
    expect(find.text('New group'), findsWidgets);
    semantics.dispose();
  });

  // A group of the user's friends Maya and Leo; its members Gaby and Maya.
  Future<FakeRepository> openGroupInfo(WidgetTester tester, {required String owner}) async {
    final repository = await pumpApp(
      tester,
      setUp: (r) {
        r.conversations.value = [
          ConversationSummary(
            id: 'c-team',
            title: 'Design crew',
            name: 'Design crew',
            isGroup: true,
            memberCount: 2,
            ownerId: owner,
          ),
          ...r.conversations.value.where((c) => c.id != 'c-team'),
        ];
        r.friendsOnServer = const Friends(
          friends: [
            Member(userId: _maya, username: 'maya', alias: 'Maya'),
            Member(userId: _leo, username: 'leo'),
          ],
        );
      },
    );
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'More');
    await tapLabel(tester, 'Group info');
    expect(find.text('Group info'), findsOneWidget);
    return repository;
  }

  testWidgets('group info: rename, add, remove, leave', (tester) async {
    final repository = await openGroupInfo(tester, owner: FakeRepository.me.id);

    await tapLabel(tester, 'Rename group, Design crew');
    await tester.enterText(find.byType(EditableText).last, 'Crit crew');
    await tapLabel(tester, 'Save');
    await tapLabel(tester, 'Remove Maya');
    await tapLabel(tester, 'Add people');
    // The friends not in it.
    expect(find.widgetWithText(ListRow, 'leo'), findsOneWidget);
    expect(find.widgetWithText(ListRow, 'Maya'), findsNothing);
    await tapLabel(tester, RegExp('^leo'));
    await tapLabel(tester, 'Leave group');
    await tapLabel(tester, 'Leave group');
    expect(repository.conversationCalls, [
      'rename c-team Crit crew',
      'remove c-team $_maya',
      'add c-team $_leo',
      'leave c-team',
    ]);
    semantics.dispose();
  });

  testWidgets('group info loads the friends Add people offers, as the new conversation does', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.conversations.value = [
          ConversationSummary(
            id: 'c-team',
            title: 'Design crew',
            name: 'Design crew',
            isGroup: true,
            memberCount: 2,
            ownerId: FakeRepository.me.id,
          ),
          ...r.conversations.value.where((c) => c.id != 'c-team'),
        ];
        r.friendsOnServer = const Friends(
          friends: [Member(userId: _leo, username: 'leo')],
        );
      },
    );
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'More');
    await tapLabel(tester, 'Group info');
    await tapLabel(tester, 'Add people');
    expect(find.widgetWithText(ListRow, 'leo'), findsOneWidget);
    expect(find.text('No friends available to add'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Add people shows the friends that come while it\'s open', (tester) async {
    final repository = await openGroupInfo(tester, owner: FakeRepository.me.id);
    // As if the page's load hadn't answered yet.
    repository.friends.value = Friends.none;
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Add people');
    expect(find.text('No friends available to add'), findsOneWidget);

    // The page's load answers, or a FRIEND_* event loads them again.
    repository.friends.value = const Friends(
      friends: [Member(userId: _leo, username: 'leo')],
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListRow, 'leo'), findsOneWidget);
    expect(find.text('No friends available to add'), findsNothing);
    semantics.dispose();
  });

  testWidgets('group info: only its owner renames it and adds or removes people', (tester) async {
    final repository = await openGroupInfo(tester, owner: _maya);
    expect(find.bySemanticsLabel(RegExp('^Rename group')), findsNothing);
    expect(find.bySemanticsLabel('Add people'), findsNothing);
    expect(find.bySemanticsLabel('Remove Maya'), findsNothing);
    expect(find.text('Design crew'), findsWidgets);
    await tapLabel(tester, 'Leave group');
    await tapLabel(tester, 'Leave group');
    expect(repository.conversationCalls, ['leave c-team']);
    semantics.dispose();
  });

  testWidgets('a group change the server refuses says why', (tester) async {
    final repository = await openGroupInfo(tester, owner: FakeRepository.me.id);
    repository.conversationRefused = 'You must be friends with leo';
    await tapLabel(tester, 'Add people');
    await tapLabel(tester, RegExp('^leo'));
    expect(find.text('You must be friends with leo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('new conversation offers friends alone, as the API opens DMs and groups only between friends', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    await tapLabel(tester, 'New conversation');
    expect(find.text('No friends added yet'), findsOneWidget);

    // Leo shares a Space with the user, but isn\'t a friend.
    repository.friends.value = const Friends(
      friends: [Member(userId: _maya, username: 'maya', alias: 'Maya')],
    );
    await tester.pumpAndSettle();
    expect(find.text('FRIENDS'), findsOneWidget);
    expect(find.bySemanticsLabel('Maya, @maya'), findsOneWidget);
    expect(find.bySemanticsLabel('leo, @leo'), findsNothing);
    semantics.dispose();
  });
}
