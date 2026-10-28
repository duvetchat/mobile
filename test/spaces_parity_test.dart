import 'dart:async';

import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/launchpad.dart';
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

const _maya = FakeRepository.maya;
const _leo = FakeRepository.leo;

// Design Guild as the gateway would have it now: #general, which says what
// it's for; Voice, with #lounge; Archive, empty; and a banner.
Space _guild({String? description = 'Crits on fridays', String? banner}) => Space(
  id: 's-guild',
  name: 'Design Guild',
  bannerUrl: banner,
  onlineCount: 1,
  sections: [
    RoomSection(
      name: null,
      rooms: [
        Room(
          id: 'r-general',
          spaceId: 's-guild',
          name: 'general',
          kind: RoomKind.text,
          position: 0,
          description: description,
        ),
      ],
    ),
    const RoomSection(
      id: 'c-voice',
      name: 'Voice',
      rooms: [Room(id: 'r-lounge', spaceId: 's-guild', name: 'lounge', kind: RoomKind.voice, position: 0)],
    ),
    const RoomSection(id: 'c-archive', name: 'Archive', rooms: []),
  ],
);

/// Issue #19: Spaces as the desktop has them.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpApp(
    WidgetTester tester, {
    void Function(FakeRepository r)? setUp,
    LaunchpadPrefs? launchpad,
  }) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository, launchpad: launchpad));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> toSpaces(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
  }

  Future<void> openGuild(WidgetTester tester) async {
    await toSpaces(tester);
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await openGuild(tester);
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  group('a room says what it\'s for, and those who run it run it from inside', () {
    testWidgets('the header shows it under the name, and reads it', (tester) async {
      await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild()]);
      await openGeneral(tester);
      expect(find.text('Crits on fridays'), findsOneWidget);
      expect(find.bySemanticsLabel('Channel general, Crits on fridays, switch channel'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('renamed and described from its menu, the header follows', (tester) async {
      final repository = await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild(description: null)]);
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Rename room');
      await tester.enterText(find.byType(EditableText).last, 'crits');
      await tester.pump();
      await tapLabel(tester, 'Save');
      expect(repository.admin.last, 'room~ r-general crits');
      expect(find.bySemanticsLabel(RegExp('^Channel crits')), findsOneWidget);

      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Edit description');
      await tester.enterText(find.byType(EditableText).last, 'Work in progress, kindly');
      await tester.pump();
      await tapLabel(tester, 'Save');
      expect(repository.admin.last, 'room¶ r-general Work in progress, kindly');
      expect(find.text('Work in progress, kindly'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a description is counted as the API\'s column counts it: an emoji\'s parts each', (tester) async {
      await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild(description: null)]);
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Edit description');
      // A family is seven code points: 36 of them, 252, fit; a 37th doesn't.
      const family = '👨‍👩‍👧‍👦';
      final field = find.byType(EditableText).last;
      await tester.enterText(field, family * 36);
      await tester.pump();
      expect(find.text('4 characters left'), findsOneWidget);
      await tester.enterText(field, family * 37);
      await tester.pump();
      expect(tester.widget<EditableText>(field).controller.text, family * 36);
      expect(find.text('4 characters left'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('deleted from its menu, after asking: the chat closes', (tester) async {
      final repository = await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild()]);
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Delete room');
      expect(find.text('Delete #general?'), findsOneWidget);
      await tapLabel(tester, 'Delete');
      expect(repository.admin.last, 'room- r-general');
      expect(find.byType(EditableText), findsNothing, reason: 'back in the Space, no composer');
      expect(find.text('# general'), findsNothing);
      semantics.dispose();
    });

    testWidgets('without ManageChannels in it, none of that', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r
          ..spaces.value = [_guild()]
          ..deniedInRoom['r-general'] = Perm.manageChannels,
      );
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      for (final label in ['Rename room', 'Edit description', 'Permissions', 'Delete room']) {
        expect(find.bySemanticsLabel(label), findsNothing, reason: label);
      }
      expect(find.bySemanticsLabel('Members'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('invites go to the room the user is in, with the desktop\'s expiries', () {
    testWidgets('from its menu: seven days unless picked otherwise, and said', (tester) async {
      final repository = await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild()]);
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Invite people');
      expect(find.text('They’ll land in #general.'), findsOneWidget);
      expect(repository.invitesMade.single, ('r-general', const Duration(days: 7)));
      expect(find.text('This link expires in 7 days.'), findsOneWidget);
      for (final label in ['30 minutes', '1 hour', '6 hours', '12 hours', '1 day', '7 days', 'Never']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('30 minutes'));
      await tester.pumpAndSettle();
      expect(repository.invitesMade.last, ('r-general', const Duration(minutes: 30)));
      expect(find.text('This link expires in 30 minutes.'), findsOneWidget);
      await tester.tap(find.text('Never'));
      await tester.pumpAndSettle();
      expect(repository.invitesMade.last, ('r-general', null));
      expect(find.text('This link never expires.'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('while the next link comes, the one shown isn\'t described as it, nor shared', (tester) async {
      final repository = await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild()]);
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Invite people');
      expect(find.text('This link expires in 7 days.'), findsOneWidget);
      final hold = repository.holdInvites = Completer<void>();
      await tester.tap(find.text('Never'));
      await tester.pump();
      expect(find.text('Making a link…'), findsOneWidget);
      expect(find.textContaining('This link'), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Copy').last).flagsCollection.isEnabled.toString(),
        contains('isFalse'),
      );
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text('This link never expires.'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Copy').last).flagsCollection.isEnabled.toString(),
        contains('isTrue'),
      );
      semantics.dispose();
    });

    testWidgets('not where the room forbids it', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r
          ..spaces.value = [_guild()]
          ..noInvites.add('r-general'),
      );
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      expect(find.bySemanticsLabel('Invite people'), findsNothing);
      semantics.dispose();
    });
  });

  group('a Space\'s rooms', () {
    testWidgets('its banner shows on top', (tester) async {
      await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild(banner: 'https://example.invalid/banner.png')]);
      await openGuild(tester);
      expect(find.byType(SpaceBanner), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(SpaceBanner)).dy,
        lessThan(tester.getTopLeft(find.widgetWithText(Overline, 'Rooms')).dy),
      );
      semantics.dispose();
    });

    testWidgets('categories show empty, and fold away and open again', (tester) async {
      final repository = await pumpApp(tester, setUp: (r) => r.spaces.value = [_guild()]);
      await openGuild(tester);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('lounge'), findsOneWidget);
      final voice = find.byKey(const ValueKey('category-c-voice'));
      expect(
        tester.getSemantics(voice),
        matchesSemantics(
          label: 'Voice',
          isHeader: true,
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
          onTapHint: 'Collapse',
        ),
      );
      await tester.tap(voice);
      await tester.pumpAndSettle();
      expect(find.text('lounge'), findsNothing);
      expect(repository.collapsedCategories.value, {'c-voice'});
      expect(tester.getSemantics(voice).flagsCollection.isExpanded.toString(), contains('isFalse'));
      await tester.tap(voice);
      await tester.pumpAndSettle();
      expect(find.text('lounge'), findsOneWidget);
      expect(repository.collapsedCategories.value, isEmpty);
      semantics.dispose();
    });

    testWidgets('folded with news in it, it says so', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r
          ..spaces.value = [
            const Space(
              id: 's-guild',
              name: 'Design Guild',
              sections: [
                RoomSection(
                  id: 'c-talk',
                  name: 'Talk',
                  rooms: [Room(id: 'r-crit', spaceId: 's-guild', name: 'crit', kind: RoomKind.text, position: 0)],
                ),
              ],
            ),
          ]
          ..unread.value = {'r-crit'}
          ..collapsedCategories.value = {'c-talk'},
      );
      await openGuild(tester);
      expect(find.text('# crit', findRichText: true), findsNothing);
      expect(find.bySemanticsLabel('Talk, unread rooms'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('one with nothing but empty categories shows them, not "No rooms here yet"', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r.spaces.value = [
          const Space(
            id: 's-guild',
            name: 'Design Guild',
            sections: [RoomSection(id: 'c-soon', name: 'Soon', rooms: [])],
          ),
        ],
      );
      await openGuild(tester);
      expect(find.text('Soon'), findsOneWidget);
      expect(find.text('No rooms here yet'), findsNothing);
      semantics.dispose();
    });
  });

  group('members by role shown apart, then Online, then Offline', () {
    Future<void> openMembers(WidgetTester tester) async {
      await openGeneral(tester);
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Members');
    }

    double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

    testWidgets('connected under their highest role shown apart, by rank', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r
          ..spaces.value = [_guild()]
          ..presence.value = {_maya: Presence.online, _leo: Presence.doNotDisturb}
          ..roleTags[_maya] = const [
            RoleTag('Mods', id: 'role-mod', position: 5, hoisted: true),
            RoleTag('Crew', id: 'role-crew', position: 2, hoisted: true),
          ]
          ..roleTags[_leo] = const [RoleTag('Crew', id: 'role-crew', position: 2, hoisted: true)]
          // Shown in its color only, not apart.
          ..roleTags[FakeRepository.me.id] = const [RoleTag('Fans', id: 'role-fan', position: 1, color: 0xFF2F9E62)]
          ..presence.value = {...r.presence.value, FakeRepository.me.id: Presence.online},
      );
      await openMembers(tester);
      expect(find.text('Mods — 1'), findsOneWidget, reason: 'Maya goes once, under her highest');
      // Leo is busy: still connected, under his role.
      expect(find.text('Crew — 1'), findsOneWidget);
      expect(find.text('Online — 1'), findsOneWidget);
      expect(find.text('Do not disturb — 1'), findsNothing);
      expect(top(tester, 'Mods — 1'), lessThan(top(tester, 'Crew — 1')));
      expect(top(tester, 'Crew — 1'), lessThan(top(tester, 'Online — 1')));
      semantics.dispose();
    });

    testWidgets('away, a role shown apart doesn\'t hold them: Offline', (tester) async {
      await pumpApp(
        tester,
        setUp: (r) => r
          ..spaces.value = [_guild()]
          ..presence.value = {_maya: Presence.offline, _leo: Presence.offline, FakeRepository.me.id: Presence.offline}
          ..roleTags[_maya] = const [RoleTag('Mods', id: 'role-mod', position: 5, hoisted: true)],
      );
      await openMembers(tester);
      expect(find.text('Mods — 1'), findsNothing);
      expect(find.text('Offline — 3'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('the Spaces tab: the gateway\'s order or by name; grid, list or cards', () {
    void two(FakeRepository r) => r.spaces.value = [
      const Space(id: 's-zeta', name: 'Zeta Club'),
      _guild(banner: 'https://example.invalid/banner.png'),
    ];

    testWidgets('in the gateway\'s order unless asked by name; kept on the device', (tester) async {
      final store = MemoryLaunchpadStore();
      await pumpApp(tester, setUp: two, launchpad: LaunchpadPrefs(store));
      await toSpaces(tester);
      expect(tester.getTopLeft(find.text('Zeta Club')).dx, lessThan(tester.getTopLeft(find.text('Design Guild')).dx));

      await tapLabel(tester, 'View and sort Spaces');
      await tapLabel(tester, 'By name');
      expect(store.choice, 'grid alphabetical');
      Navigator.of(tester.element(find.text('View and sort'))).pop();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Design Guild')).dx, lessThan(tester.getTopLeft(find.text('Zeta Club')).dx));
      semantics.dispose();
    });

    testWidgets('as a list, and as cards with their banners', (tester) async {
      final store = MemoryLaunchpadStore();
      await pumpApp(tester, setUp: two, launchpad: LaunchpadPrefs(store));
      await toSpaces(tester);
      expect(find.byType(SpaceCard), findsNWidgets(2));

      await tapLabel(tester, 'View and sort Spaces');
      await tapLabel(tester, 'List');
      expect(store.choice, 'list gateway');
      Navigator.of(tester.element(find.text('View and sort'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SpaceCard), findsNothing);
      expect(find.byType(ListRow), findsNWidgets(2));
      expect(tester.getTopLeft(find.text('Zeta Club')).dy, lessThan(tester.getTopLeft(find.text('Design Guild')).dy));
      expect(find.bySemanticsLabel('Design Guild, 1 online'), findsOneWidget);

      await tapLabel(tester, 'View and sort Spaces');
      await tapLabel(tester, 'Cards');
      Navigator.of(tester.element(find.text('View and sort'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SpaceWideCard), findsNWidgets(2));
      expect(find.byType(SpaceBanner), findsOneWidget, reason: 'Design Guild has one, Zeta Club none');
      await tapLabel(tester, 'Design Guild, 1 online');
      expect(find.bySemanticsLabel('Design Guild, Space menu'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the choice kept opens as it was', (tester) async {
      final prefs = LaunchpadPrefs(MemoryLaunchpadStore('list alphabetical'));
      await prefs.load();
      await pumpApp(tester, setUp: two, launchpad: prefs);
      await toSpaces(tester);
      expect(find.byType(ListRow), findsNWidgets(2));
      expect(tester.getTopLeft(find.text('Design Guild')).dy, lessThan(tester.getTopLeft(find.text('Zeta Club')).dy));
      semantics.dispose();
    });

    test('an unknown choice kept falls back to the grid, in the gateway\'s order', () async {
      final prefs = LaunchpadPrefs(MemoryLaunchpadStore('mosaic sideways'));
      await prefs.load();
      expect(prefs.value, (view: SpaceView.grid, sort: SpaceSort.gateway));
    });
  });
}
