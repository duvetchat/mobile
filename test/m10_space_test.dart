import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/space_admin.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// M10 · Space administration.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpSettings(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Design Guild, Space menu').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Space settings').last);
    await tester.pumpAndSettle();
    return repository;
  }

  // Scrolled to the middle, clear of the glass bars.
  Future<void> reveal(WidgetTester tester, Finder found) async {
    if (Scrollable.maybeOf(tester.element(found)) == null) return;
    await Scrollable.ensureVisible(tester.element(found), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    // Lists build lazily: scroll until it's built.
    if (find.bySemanticsLabel(label).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.bySemanticsLabel(label),
        200,
        scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first,
      );
    }
    final found = find.bySemanticsLabel(label).last;
    await reveal(tester, found);
    await tester.tap(found);
    await tester.pumpAndSettle();
  }

  // A choice in a row of choices, scrolled into view.
  Future<void> choose(WidgetTester tester, String row, String choice) async {
    final found = find.descendant(of: find.bySemanticsLabel(row).last, matching: find.text(choice));
    await reveal(tester, found);
    await tester.tap(found);
    await tester.pumpAndSettle();
  }

  Future<void> typeName(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(EditableText).last, name);
    await tester.pump();
  }

  test('role colors stay readable on both themes', () {
    for (final b in Brightness.values) {
      final background = Duvet.theme(b).colors.background;
      final card = Duvet.theme(b).colors.card;
      for (final rgb in roleSwatches) {
        for (final on in [background, card]) {
          expect(
            contrastOf(readableOn(Color(0xFF000000 | rgb), on), on),
            greaterThanOrEqualTo(4.5),
            reason: '$rgb on $on',
          );
        }
      }
    }
    // A color already readable keeps itself.
    expect(readableOn(const Color(0xFF000000), const Color(0xFFFFFFFF)), const Color(0xFF000000));
  });

  test('overwrites: allow, deny, or as the role says', () {
    const none = RoomOverwrite(targetId: 'r');
    final denied = none.withState(Perm.sendMessages, false);
    expect(denied.stateOf(Perm.sendMessages), isFalse);
    final allowed = denied.withState(Perm.sendMessages, true);
    expect((allowed.allow, allowed.deny), (Perm.sendMessages, 0));
    expect(allowed.withState(Perm.sendMessages, null).isEmpty, isTrue);
  });

  testWidgets('only those who help run a Space see its settings', (tester) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository()
      ..spaceOwner = false
      ..spacePerms = Perm.viewChannels | Perm.sendMessages;
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Design Guild, Space menu');
    expect(find.bySemanticsLabel('Space settings'), findsNothing);
    semantics.dispose();
  });

  testWidgets('settings: grouped rows by what the user may change', (tester) async {
    await pumpSettings(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.manageRoles | Perm.manageInvites,
    );
    expect(find.text('Space settings'), findsOneWidget);
    expect(find.textContaining('you help run it'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Roles')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Invites')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Rooms')), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Webhooks')), findsNothing);
    semantics.dispose();
  });

  testWidgets('overview: rename the Space', (tester) async {
    final repository = await pumpSettings(tester);
    expect(find.textContaining('you own it'), findsOneWidget);
    await tapLabel(tester, RegExp(r'^Overview'));
    await tester.enterText(find.byType(EditableText).first, 'Design Guild 2');
    await tapLabel(tester, 'Save');
    expect(repository.admin, ['space name=Design Guild 2']);
    expect(find.text('Design Guild 2'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('rooms: create, rename, move, permissions, delete', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, 'New room');
    await typeName(tester, 'crit');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'room+ crit text');

    await tapLabel(tester, RegExp(r'^# crit'));
    await tapLabel(tester, 'Move up');
    // The room above's place.
    expect(repository.admin.last, 'room> r-crit 1');

    await tapLabel(tester, RegExp(r'^# crit'));
    await tapLabel(tester, 'Rename');
    await typeName(tester, 'design-crit');
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'room~ r-crit design-crit');

    await tapLabel(tester, RegExp(r'^# design-crit'));
    await tapLabel(tester, 'Permissions');
    expect(find.text('#design-crit'), findsOneWidget);
    // For @everyone, the last role: no sending here.
    await choose(tester, 'Send messages', 'Deny');
    expect(repository.admin.last, 'overwrite r-crit s-guild +0 -${Perm.sendMessages}');
    await tester.tap(find.text('Moderator'));
    await tester.pumpAndSettle();
    await choose(tester, 'Pin messages', 'Allow');
    expect(repository.admin.last, 'overwrite r-crit role-mod +${Perm.pinMessages} -0');
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();

    await tapLabel(tester, RegExp(r'^# design-crit'));
    await tapLabel(tester, 'Delete');
    await tapLabel(tester, 'Delete');
    expect(repository.admin.last, 'room- r-crit');
    expect(find.text('design-crit'), findsNothing);
    semantics.dispose();
  });

  testWidgets('rooms: down goes one past the room below, as the API takes it; into a category and out', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.adminRoomList['s-guild'] = [
        const AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text),
        const AdminRoom(id: 'r-crit', name: 'crit', kind: AdminRoomKind.text, position: 1),
        const AdminRoom(id: 'c-talk', name: 'Talk', kind: AdminRoomKind.category, position: 2),
        const AdminRoom(id: 'r-lounge', name: 'lounge', kind: AdminRoomKind.voice, parentId: 'c-talk'),
      ],
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, RegExp(r'^# general'));
    await tapLabel(tester, 'Move down');
    expect(repository.admin.last, 'room> r-general 2');

    await tapLabel(tester, RegExp(r'^# crit'));
    await tapLabel(tester, RegExp(r'^Category, No category'));
    await tapLabel(tester, 'Talk');
    expect(repository.admin.last, 'room^ r-crit c-talk');

    await tapLabel(tester, RegExp(r'^# crit'));
    await tapLabel(tester, RegExp(r'^Category, Talk'));
    await tapLabel(tester, 'No category');
    expect(repository.admin.last, 'room^ r-crit none');
    semantics.dispose();
  });

  testWidgets('roles: create, color, members, permissions, save; delete', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.text('@everyone'), findsOneWidget);

    await tapLabel(tester, 'New role');
    await typeName(tester, 'Hosts');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'role+ Hosts');
    expect(find.text('Edit role'), findsOneWidget);

    await tapLabel(tester, 'Name color: default');
    await tapLabel(tester, '#30A46C');
    await tapLabel(tester, RegExp(r'^0 members'));
    await tapLabel(tester, 'Maya');
    expect(repository.admin.last, 'give role-Hosts Maya');
    await tester.tapAt(const Offset(195, 60));
    await tester.pumpAndSettle();
    expect(find.text('1 member'), findsOneWidget);

    final pin = find.bySemanticsLabel('Pin messages').last;
    expect(tester.getSemantics(pin).flagsCollection.isToggled.toString(), contains('isFalse'));
    await tapLabel(tester, 'Pin messages');
    expect(tester.getSemantics(pin).flagsCollection.isToggled.toString(), contains('isTrue'));
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'role~ role-Hosts color=30a46c perms=${Perm.pinMessages}');
    expect(find.text('Hosts'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Hosts'));
    await tapLabel(tester, 'Delete role');
    await tapLabel(tester, 'Delete role');
    expect(repository.admin.last, 'role- role-Hosts');
    expect(find.text('Hosts'), findsNothing);
    semantics.dispose();
  });

  testWidgets('an administrator role has every permission: the rest are on and fixed', (tester) async {
    await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    await tapLabel(tester, RegExp(r'^Moderator'));
    await tapLabel(tester, 'Administrator');
    await tester.scrollUntilVisible(
      find.bySemanticsLabel('Send messages'),
      -200,
      scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first,
    );
    final send = tester.getSemantics(find.bySemanticsLabel('Send messages').last).flagsCollection;
    expect(send.isToggled.toString(), contains('isTrue'));
    expect(send.isEnabled.toString(), contains('isFalse'));
    semantics.dispose();
  });

  testWidgets('invites: listed with where and until when; revoke', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.inviteList = [
        SpaceInvite(
          id: 'i1',
          code: 'crit-night',
          roomName: 'general',
          createdBy: 'Maya',
          createdAt: DateTime(2026, 10, 20),
        ),
      ],
    );
    await tapLabel(tester, RegExp(r'^Invites, 1 active'));
    expect(find.text('#general · Maya · never expires'), findsOneWidget);
    await tapLabel(tester, RegExp(r'^crit-night'));
    await tapLabel(tester, 'Revoke link');
    expect(repository.admin, ['revoke i1']);
    expect(find.text('No invite links'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('emojis and stickers: add with a clean name, rename, delete', (tester) async {
    pickSpaceImage = () async => '/tmp/party.png';
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    expect(find.text('No emojis yet'), findsOneWidget);
    await tapLabel(tester, 'Add emoji');
    await typeName(tester, 'party time');
    await tapLabel(tester, 'Add');
    expect(repository.admin.last, 'emoji+ party_time /tmp/party.png');
    await tapLabel(tester, ':party_time:');
    await tapLabel(tester, 'Delete');
    await tapLabel(tester, 'Delete emoji');
    expect(repository.admin.last, 'emoji- emoji-party_time');

    await tester.tap(find.text('Stickers'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Add sticker');
    await typeName(tester, 'Wave');
    await tapLabel(tester, 'Add');
    expect(repository.admin.last, 'sticker+ Wave /tmp/party.png');
    semantics.dispose();
  });

  testWidgets('webhooks: the URL is shown once, to copy; reset; delete', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Webhooks'));
    await tapLabel(tester, 'New webhook');
    await typeName(tester, 'CI');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'hook+ r-general CI');
    expect(find.textContaining('won’t be shown again'), findsOneWidget);
    await tapLabel(tester, 'Copy URL');
    expect(copied, 'https://api.duvet.chat/api/webhooks/w-CI/secret');
    expect(find.text('Posts in #general'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^CI'));
    await tapLabel(tester, RegExp(r'^New URL'));
    expect(repository.admin.last, 'hook~ w-CI');
    await tapLabel(tester, 'Copy URL');
    await tapLabel(tester, RegExp(r'^CI'));
    await tapLabel(tester, 'Delete');
    await tapLabel(tester, 'Delete webhook');
    expect(repository.admin.last, 'hook- w-CI');
    semantics.dispose();
  });

  testWidgets('storage: what the files take, where they are kept, the largest', (tester) async {
    await pumpSettings(
      tester,
      setUp: (r) => r.storageOfSpace = SpaceStorage(
        used: 3 * 1024 * 1024,
        buckets: const [(name: 'Guild bucket', used: 3 * 1024 * 1024, max: 50 * 1024 * 1024 * 1024, active: true)],
        files: [
          (name: 'poster.png', contentType: 'image/png', size: 3 * 1024 * 1024, createdAt: DateTime(2026, 10, 1)),
        ],
      ),
    );
    await tapLabel(tester, RegExp(r'^Storage, 3\.0 MB used'));
    expect(find.bySemanticsLabel('3.0 MB used by 1 files'), findsOneWidget);
    expect(find.text('3.0 MB of 50.0 GB'), findsOneWidget);
    expect(find.text('poster.png'), findsOneWidget);
    semantics.dispose();
  });
}
