import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/account.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/space_admin.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart' show SpaceBanner;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

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

  // A 400 × 200 picture on disk: blue on its left half, red on its right.
  Future<String> picture(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('duvet_square');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/two halves.png';
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(const Rect.fromLTWH(0, 0, 200, 200), Paint()..color = const Color(0xFF0000FF))
        ..drawRect(const Rect.fromLTWH(200, 0, 200, 200), Paint()..color = const Color(0xFFFF0000));
      final image = await recorder.endRecording().toImage(400, 200);
      File(path).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
    return path;
  }

  // A GIF of [frames] one-pixel frames on a [width] × [height] screen: the
  // size the API reads from its header.
  String gif({required int width, required int height, int frames = 2}) {
    final dir = Directory.systemTemp.createTempSync('duvet_gif');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/dance.gif';
    File(path).writeAsBytesSync([
      ...'GIF89a'.codeUnits,
      width & 0xff, width >> 8, height & 0xff, height >> 8,
      // Two colors.
      0x80, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff,
      // It loops.
      0x21, 0xff, 0x0b, ...'NETSCAPE2.0'.codeUnits, 0x03, 0x01, 0x00, 0x00, 0x00,
      for (var i = 0; i < frames; i++) ...[
        // 100 ms each, a pixel at the corner.
        0x21, 0xf9, 0x04, 0x00, 0x0a, 0x00, 0x00, 0x00,
        0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0,
        0x02, 0x02, 0x44, 0x01, 0x00,
      ],
      0x3b,
    ]);
    return path;
  }

  // Pumps until [found] shows: the picture is read on the real clock.
  Future<void> waitFor(WidgetTester tester, Finder found) async {
    await tester.pump();
    for (var i = 0; i < 20 && found.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  // The crop page, once its picture decodes (on the real clock; its spinner
  // never settles before): Use.
  Future<void> useCrop(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 20 && find.byType(InteractiveViewer).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tapLabel(tester, 'Use');
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

  testWidgets('overview: a banner, cropped 5:2 as the desktop does, shown; then removed', (tester) async {
    final path = await picture(tester);
    pickSpaceImage = () async => path;
    final crops = <CropRect>[];
    saveBannerImage = (path, crop) async {
      crops.add(crop);
      return '/banners/new.png';
    };
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Overview'));
    // The cropper's spinner never settles: tapped, then waited for.
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Banner')).last);
    await useCrop(tester);
    // The 400x200 picture's full width, 5:2: 160 high, from its middle.
    final crop = crops.single;
    for (final (got, want) in [(crop.x, 0.0), (crop.y, 20.0), (crop.w, 400.0), (crop.h, 160.0)]) {
      expect(got, closeTo(want, 0.01));
    }
    expect(find.bySemanticsLabel(RegExp(r'^Banner, New one chosen')), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space banner=/banners/new.png');
    expect(repository.spaces.value.single.bannerUrl, isNotNull);

    await tapLabel(tester, RegExp(r'^Overview'));
    expect(find.byType(SpaceBanner), findsOneWidget);
    await tapLabel(tester, 'Remove banner');
    expect(find.byType(SpaceBanner), findsNothing);
    expect(find.bySemanticsLabel('Remove banner'), findsNothing);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space banner=none');
    expect(repository.spaces.value.single.bannerUrl, isNull);
    semantics.dispose();
  });

  testWidgets('rooms: what a room is for, set and cleared; categories have none', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.adminRoomList['s-guild'] = [
        const AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text),
        const AdminRoom(id: 'c-talk', name: 'Talk', kind: AdminRoomKind.category, position: 1),
      ],
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, RegExp(r'^# general'));
    expect(find.bySemanticsLabel(RegExp(r'^Edit description, None')), findsOneWidget);
    await tapLabel(tester, RegExp(r'^Edit description'));
    await tester.enterText(find.byType(EditableText).last, '  crits on fridays ');
    await tester.pump();
    expect(find.text('237 characters left'), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'room¶ r-general crits on fridays');

    await tapLabel(tester, RegExp(r'^# general'));
    expect(find.bySemanticsLabel(RegExp(r'^Edit description, crits on fridays')), findsOneWidget);
    await tapLabel(tester, RegExp(r'^Edit description'));
    await tester.enterText(find.byType(EditableText).last, '');
    await tester.pump();
    expect(find.text('Leave it empty to clear it.'), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'room¶ r-general -');

    await tapLabel(tester, 'Category Talk');
    expect(find.bySemanticsLabel(RegExp(r'^Edit description')), findsNothing);
    semantics.dispose();
  });

  testWidgets('rooms: invite people to any room the user may, a voice room too, as the desktop does', (tester) async {
    final repository = await pumpSettings(tester, setUp: (r) => r.noInvites.add('r-general'));
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, RegExp(r'^lounge'));
    await tapLabel(tester, RegExp(r'^Invite people'));
    expect(find.text('They’ll land in #lounge.'), findsOneWidget);
    expect(repository.invitesMade.single, ('r-lounge', const Duration(days: 7)));
    Navigator.of(tester.element(find.text('They’ll land in #lounge.'))).pop();
    await tester.pumpAndSettle();
    // Not where the room forbids it.
    await tapLabel(tester, RegExp(r'^# general'));
    expect(find.bySemanticsLabel(RegExp(r'^Invite people')), findsNothing);
    semantics.dispose();
  });

  testWidgets('rooms: create, rename, move, permissions, delete', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, 'Create room');
    await tapLabel(tester, RegExp(r'^Text room'));
    await typeName(tester, 'crit');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'room+ crit text');

    // Dragged by its grip to the top: before #general.
    await tester.drag(find.byKey(const ValueKey('grip')).last, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(repository.admin.last, 'room> r-crit - 0');
    expect(repository.adminRooms('s-guild').first.id, 'r-crit');

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

  testWidgets('rooms: a category moves with its rooms; a room moves to another', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.adminRoomList['s-guild'] = [
        const AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text),
        const AdminRoom(id: 'r-crit', name: 'crit', kind: AdminRoomKind.text, parentId: 'c-work'),
        const AdminRoom(id: 'r-games', name: 'games', kind: AdminRoomKind.text, parentId: 'c-fun'),
        const AdminRoom(id: 'c-work', name: 'Work', kind: AdminRoomKind.category, position: 1),
        const AdminRoom(id: 'c-fun', name: 'Fun', kind: AdminRoomKind.category, position: 2),
      ],
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    List<String> order() => [
      for (final r in repository.adminRooms('s-guild')) '${r.id}@${r.parentId ?? '-'}:${r.position}',
    ];

    // What a screen reader offers in place of a drag.
    Future<void> move(Pattern label, String action) async {
      final id = CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: action));
      var node = tester.getSemantics(find.bySemanticsLabel(label).last);
      while (!(node.getSemanticsData().customSemanticsActionIds?.contains(id) ?? false)) {
        node = node.parent!;
      }
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
      await tester.pumpAndSettle();
    }

    // Fun goes up over Work, its room with it.
    await move('Category Fun', 'Move up');
    expect(repository.admin.last, 'room> c-fun - 1');
    expect(order(), containsAll(['c-fun@-:1', 'c-work@-:2', 'r-games@c-fun:0']));
    expect(
      tester.getTopLeft(find.text('# games', findRichText: true)).dy,
      lessThan(tester.getTopLeft(find.text('# crit', findRichText: true)).dy),
    );

    // Into Work from its options: first there, as the desktop drops one in.
    await tapLabel(tester, RegExp(r'^# general'));
    await tapLabel(tester, 'Move to…');
    await tapLabel(tester, 'Work');
    expect(repository.admin.last, 'room> r-general c-work 0');
    expect(order(), containsAll(['r-general@c-work:0', 'r-crit@c-work:1']));

    // Down within Work: past the last, as the API takes it.
    await move(RegExp(r'^# general'), 'Move down');
    expect(repository.admin.last, 'room> r-general c-work 2');
    expect(order(), containsAll(['r-crit@c-work:0', 'r-general@c-work:1']));

    // Out of any category: after the rooms outside one (none left here).
    await tapLabel(tester, RegExp(r'^# general'));
    await tapLabel(tester, 'Move to…');
    await tapLabel(tester, 'No category');
    expect(repository.admin.last, 'room> r-general - 0');
    semantics.dispose();
  });

  testWidgets('rooms: ManageChannels counts in each room; making one takes it in the Space', (tester) async {
    await pumpSettings(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.manageChannels
        // An overwrite takes it away in #lounge.
        ..deniedInRoom['r-lounge'] = Perm.manageChannels,
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    expect(find.bySemanticsLabel('Create room'), findsOneWidget);
    expect(find.bySemanticsLabel('lounge, Voice room'), findsOneWidget);
    await tapLabel(tester, 'lounge, Voice room');
    expect(find.bySemanticsLabel('Rename'), findsNothing);
    await tapLabel(tester, RegExp(r'^# general, Double tap for options'));
    expect(find.bySemanticsLabel('Rename'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('rooms: a room\'s overwrite alone opens Space settings, for that room', (tester) async {
    await pumpSettings(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.viewChannels | Perm.sendMessages
        ..managesRooms = true
        ..deniedInRoom['r-lounge'] = Perm.manageChannels,
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    expect(find.bySemanticsLabel('Create room'), findsNothing);
    await tapLabel(tester, RegExp(r'^# general'));
    expect(find.bySemanticsLabel('Rename'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('roles: shown apart in the member list, as the desktop\'s "Display separately"', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    await tapLabel(tester, RegExp(r'^Moderator'));
    final shown = find.bySemanticsLabel('Show members separately').last;
    expect(tester.getSemantics(shown).flagsCollection.isToggled.toString(), contains('isFalse'));
    await tester.tap(shown);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'role~ role-mod hoisted=true');

    // Everyone has @everyone: there's no showing its members apart.
    await tapLabel(tester, RegExp(r'^@everyone'));
    expect(find.bySemanticsLabel('Show members separately'), findsNothing);
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

  testWidgets('emojis and stickers: cropped square, 128 and 320 px as the desktop makes them; named as typed', (
    tester,
  ) async {
    final path = await picture(tester);
    pickAssetImage = () async => path;
    final squares = <(String, CropRect, int)>[];
    saveSquareImage = (path, crop, side) async {
      squares.add((path, crop, side));
      return '/squares/$side.png';
    };
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    expect(find.text('No emojis yet'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Add emoji').last);
    await useCrop(tester);
    await typeName(tester, 'party time!');
    await tapLabel(tester, 'Add');
    // A square of the picture's full height, from its middle.
    final (picked, crop, side) = squares.single;
    expect((picked, side), (path, 128));
    expect([crop.x, crop.y, crop.w, crop.h].map((v) => v.round()), [100, 0, 200, 200]);
    expect(repository.admin.last, 'emoji+ party time! /squares/128.png');
    await tapLabel(tester, ':party time!:');
    await tapLabel(tester, 'Rename');
    await typeName(tester, 'fiesta-time');
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'emoji~ emoji-party time! fiesta-time');
    await tapLabel(tester, ':fiesta-time:');
    await tapLabel(tester, 'Delete');
    await tapLabel(tester, 'Delete emoji');
    expect(repository.admin.last, 'emoji- emoji-party time!');

    await tester.tap(find.text('Stickers'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Add sticker').last);
    await useCrop(tester);
    await typeName(tester, 'Wave');
    await tapLabel(tester, 'Add');
    expect(squares.last.$3, 320);
    expect(repository.admin.last, 'sticker+ Wave /squares/320.png');
    semantics.dispose();
  });

  testWidgets('the cropper starts centered, as the desktop\'s: a square, a banner', (tester) async {
    final path = await picture(tester);
    final crops = <double, CropRect?>{};
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  for (final aspect in [1.0, 3.0])
                    TextButton(
                      onPressed: () async => crops[aspect] = await Navigator.of(context).push<CropRect>(
                        MaterialPageRoute(
                          builder: (_) => CropPage(path: path, aspect: aspect),
                        ),
                      ),
                      child: Text('Crop $aspect'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (final aspect in [1.0, 3.0]) {
      await tester.tap(find.text('Crop $aspect'));
      await useCrop(tester);
    }
    List<int> rounded(CropRect? c) => [c!.x, c.y, c.w, c.h].map((v) => v.round()).toList();
    // 400 × 200: the middle square, and the middle third of its height.
    expect(rounded(crops[1.0]), [100, 0, 200, 200]);
    expect(rounded(crops[3.0]), [0, 33, 400, 133]);
  });

  testWidgets('a square is what the frame shows, drawn at its size', (tester) async {
    final path = await picture(tester);
    await tester.runAsync(() async {
      // The red half, as an emoji.
      final png = await squarePng(path, (x: 200, y: 0, w: 200, h: 200), emojiSide);
      final square = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
      expect((square.width, square.height), (128, 128));
      final rgba = (await square.toByteData())!;
      for (final at in [0, (64 * 128 + 64) * 4, rgba.lengthInBytes - 4]) {
        expect([for (var i = 0; i < 4; i++) rgba.getUint8(at + i)], [255, 0, 0, 255]);
      }
    });
  });

  testWidgets('a GIF the API takes as it is goes up unchanged, still moving', (tester) async {
    final squares = <int>[];
    saveSquareImage = (path, crop, side) async {
      squares.add(side);
      return '/squares/$side.png';
    };
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    final small = gif(width: 64, height: 64);
    pickAssetImage = () async => small;
    await tester.tap(find.bySemanticsLabel('Add emoji').last);
    await waitFor(tester, find.text('Name the emoji'));
    expect(find.byType(InteractiveViewer), findsNothing);
    await typeName(tester, 'dance');
    await tapLabel(tester, 'Add');
    expect(repository.admin.last, 'emoji+ dance $small');

    // Too large for an emoji, not for a sticker.
    await tester.tap(find.text('Stickers'));
    await tester.pumpAndSettle();
    final large = gif(width: 600, height: 600);
    pickAssetImage = () async => large;
    await tester.tap(find.bySemanticsLabel('Add sticker').last);
    await waitFor(tester, find.text('Name the sticker'));
    await typeName(tester, 'party');
    await tapLabel(tester, 'Add');
    expect(repository.admin.last, 'sticker+ party $large');
    expect(squares, isEmpty);
    semantics.dispose();
  });

  testWidgets('a GIF too large to go up as it is goes up still, saying its animation is lost', (tester) async {
    final squares = <int>[];
    saveSquareImage = (path, crop, side) async {
      squares.add(side);
      return '/squares/$side.png';
    };
    final large = gif(width: 600, height: 600);
    pickAssetImage = () async => large;
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    await tester.tap(find.bySemanticsLabel('Add emoji').last);
    await waitFor(tester, find.byType(InteractiveViewer));
    // Said under the frame while it's cropped.
    expect(find.text('This GIF is over 256 KiB or 512 px, so it goes up still: its animation is lost'), findsOneWidget);
    await tapLabel(tester, 'Use');
    await typeName(tester, 'dance');
    await tapLabel(tester, 'Add');
    expect(squares, [128]);
    expect(repository.admin.last, 'emoji+ dance /squares/128.png');
    semantics.dispose();
  });

  testWidgets('a still GIF is cropped as any picture is, though the API would take it as it is', (tester) async {
    final squares = <int>[];
    saveSquareImage = (path, crop, side) async {
      squares.add(side);
      return '/squares/$side.png';
    };
    final still = gif(width: 64, height: 64, frames: 1);
    pickAssetImage = () async => still;
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    await tester.tap(find.bySemanticsLabel('Add emoji').last);
    await waitFor(tester, find.byType(InteractiveViewer));
    // It has no animation to lose.
    expect(find.textContaining('animation is lost'), findsNothing);
    await tapLabel(tester, 'Use');
    await typeName(tester, 'dot');
    await tapLabel(tester, 'Add');
    expect(squares, [128]);
    expect(repository.admin.last, 'emoji+ dot /squares/128.png');
    semantics.dispose();
  });

  testWidgets('a GIF that can\'t be read says so, instead of a cropper that closes without a word', (tester) async {
    final dir = Directory.systemTemp.createTempSync('duvet_gif');
    addTearDown(() => dir.deleteSync(recursive: true));
    final broken = '${dir.path}/broken.gif';
    // A GIF's header and screen, then nothing a decoder can read.
    File(broken).writeAsBytesSync([...'GIF89a'.codeUnits, 64, 0, 64, 0, 1, 2, 3]);
    pickAssetImage = () async => broken;
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    await tester.tap(find.bySemanticsLabel('Add emoji').last);
    await waitFor(tester, find.text('Couldn’t read this GIF'));
    expect(find.text('Couldn’t read this GIF'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(repository.admin.where((a) => a.startsWith('emoji+')), isEmpty);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('emojis and stickers: each kind by its own permission', (tester) async {
    pickAssetImage = () async => '/tmp/party.png';
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.manageStickers
        ..assetList[AssetKind.emoji]!.add(const SpaceAsset(id: 'e-1', name: 'party', url: 'https://x/party.png')),
    );
    await tapLabel(tester, RegExp(r'^Emojis and stickers'));
    // Stickers first, the kind the user may change.
    expect(find.bySemanticsLabel('Add sticker'), findsOneWidget);
    await tester.tap(find.text('Emojis'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add emoji'), findsNothing);
    // Listed, but without options.
    await tester.tap(find.bySemanticsLabel(':party:').last);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Rename'), findsNothing);
    expect(repository.admin, isEmpty);
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

  testWidgets('webhooks: a refusal says the API\'s reason', (tester) async {
    await pumpSettings(
      tester,
      setUp: (r) => r
        ..refusals['createWebhook'] = 'Webhooks can only be created on text rooms'
        ..refusals['resetWebhook'] = 'Webhook not found'
        ..webhookList = [
          SpaceWebhook(id: 'w-ci', roomId: 'r-general', roomName: 'general', name: 'CI', createdAt: DateTime(2026, 10)),
        ],
    );
    await tapLabel(tester, RegExp(r'^Webhooks'));
    await tapLabel(tester, 'New webhook');
    await typeName(tester, 'Deploys');
    await tapLabel(tester, 'Create');
    expect(find.text('Webhooks can only be created on text rooms'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tapLabel(tester, RegExp(r'^CI'));
    await tapLabel(tester, RegExp(r'^New URL'));
    expect(find.text('Webhook not found'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
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
