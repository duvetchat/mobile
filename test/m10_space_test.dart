import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/account.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/people.dart' show RoleChip;
import 'package:duvet/space_admin.dart';
import 'package:duvet/spaces.dart' show pickSpaceIcon;
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/glass.dart' show GlassRow;
import 'package:duvet/widgets/rows.dart' show DuvetChip, DuvetTextField, OwnerCrown;
import 'package:duvet/widgets/picture_edit.dart' show takePhoto;
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

  // A choice on the room permissions card shown, its card scrolled to it.
  Future<void> onCard(WidgetTester tester, String row, String choice) async {
    final found = find.descendant(of: find.bySemanticsLabel(row), matching: find.text(choice)).hitTestable();
    await tester.dragUntilVisible(found, find.byType(PageView), const Offset(0, -150));
    await tester.pumpAndSettle();
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

  testWidgets('members: below Roles; a member\'s roles change; a bot is removed; no kick or ban', (tester) async {
    const helper = Member(userId: 'u-helper', username: 'helper', alias: 'Helper', isBot: true);
    final repository = await pumpSettings(tester, setUp: (r) => r.extraRoomMembers.add(helper));
    final rows = [for (final w in tester.widgetList<GlassRow>(find.byType(GlassRow))) w.label];
    expect(rows.indexOf('Members'), rows.indexOf('Roles') + 1);
    await tapLabel(tester, RegExp(r'^Members'));
    expect(find.text('Helper'), findsOneWidget);
    expect(find.textContaining('No roles'), findsWidgets);
    expect(find.byType(OwnerCrown), findsOneWidget, reason: 'Maya owns the Space');
    expect(find.bySemanticsLabel(RegExp(r'^Maya, .*owner')), findsOneWidget);

    await tester.enterText(find.byType(EditableText).first, 'may');
    await tester.pumpAndSettle();
    expect(find.text('Helper'), findsNothing);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(find.text(FakeRepository.maya), findsOneWidget, reason: 'the ID shows');
    expect(find.bySemanticsLabel('Remove from Space'), findsNothing, reason: 'Maya is no bot');
    expect(find.bySemanticsLabel(RegExp('Kick|Ban')), findsNothing);
    await tapLabel(tester, 'Moderator');
    expect(repository.admin, ['give role-mod Maya']);
    await tapLabel(tester, 'Back');
    expect(find.textContaining('Moderator'), findsOneWidget, reason: 'her row shows the role');

    await tester.enterText(find.byType(EditableText).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Helper'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Remove from Space');
    await tapLabel(tester, 'Remove from Space');
    expect(repository.botsRemoved, [('s-guild', 'u-helper')]);
    expect(find.text('Members'), findsWidgets, reason: 'back on the list');
    expect(find.text('Helper'), findsNothing);
    semantics.dispose();
  });

  testWidgets('members: without Manage roles, roles show but don\'t change', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.manageBots,
    );
    expect(find.bySemanticsLabel(RegExp(r'^Roles')), findsNothing);
    await tapLabel(tester, RegExp(r'^Members'));
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Moderator').last);
    await tester.pumpAndSettle();
    expect(repository.admin, isEmpty);
    semantics.dispose();
  });

  // Maya's profile, from # general's members sheet.
  Future<FakeRepository> pumpMayaProfile(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    setUp?.call(repository);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Members').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maya').hitTestable().last);
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('a member\'s profile gives and takes a role at once', (tester) async {
    final repository = await pumpMayaProfile(tester);
    final moderator = find.widgetWithText(RoleChip, 'Moderator');
    expect(tester.widget<RoleChip>(moderator).held, isFalse, reason: 'a role Maya lacks shows grey');
    await reveal(tester, moderator);
    await tester.tap(moderator);
    await tester.pumpAndSettle();
    expect(repository.admin, ['give role-mod Maya']);
    expect(tester.widget<RoleChip>(moderator).held, isTrue, reason: 'it shows live');
    await tester.tap(moderator);
    await tester.pumpAndSettle();
    expect(repository.admin, ['give role-mod Maya', 'take role-mod Maya']);
    expect(tester.widget<RoleChip>(moderator).held, isFalse);
    semantics.dispose();
  });

  testWidgets('without Manage roles, a member\'s profile has no Roles to change', (tester) async {
    await pumpMayaProfile(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.all & ~Perm.manageRoles & ~Perm.administrator,
    );
    expect(find.text('ROLES IN DESIGN GUILD'), findsNothing);
    expect(find.byType(RoleChip), findsNothing);
    semantics.dispose();
  });

  testWidgets('on a member\'s profile, a role above the user\'s highest shows but doesn\'t change', (tester) async {
    final repository = await pumpMayaProfile(
      tester,
      setUp: (r) => r
        ..spaceOwner = false
        ..spacePerms = Perm.all & ~Perm.administrator,
    );
    expect(find.text('ROLES IN DESIGN GUILD'), findsOneWidget);
    final moderator = find.widgetWithText(RoleChip, 'Moderator');
    expect(tester.widget<RoleChip>(moderator).onTap, isNull, reason: 'the user has no role above it');
    await reveal(tester, moderator);
    await tester.tap(moderator);
    await tester.pumpAndSettle();
    expect(repository.admin, isEmpty);
    semantics.dispose();
  });

  testWidgets('overview: rename the Space', (tester) async {
    final repository = await pumpSettings(tester);
    expect(find.textContaining('you own it'), findsOneWidget);
    await tapLabel(tester, RegExp(r'^Overview'));
    await tester.enterText(find.byType(EditableText).first, 'Design Guild 2');
    await tester.pump();
    await tapLabel(tester, 'Save');
    expect(repository.admin, ['space name=Design Guild 2']);
    expect(find.text('Design Guild 2'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('overview: set the locale', (tester) async {
    final repository = await pumpSettings(tester);
    final locale = find.descendant(
      of: find.widgetWithText(DuvetTextField, 'Locale'),
      matching: find.byType(EditableText),
    );
    await tapLabel(tester, RegExp(r'^Overview'));
    await reveal(tester, locale);
    await tester.enterText(locale, 'fr');
    await tester.pump();
    await tapLabel(tester, 'Save');
    expect(repository.admin, ['space locale=fr']);

    // Shown when the page opens again; cleared, it is sent empty.
    await tapLabel(tester, RegExp(r'^Overview'));
    await reveal(tester, locale);
    expect(tester.widget<EditableText>(locale).controller.text, 'fr');
    await tester.enterText(locale, '');
    await tester.pump();
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space locale=');
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
    await tapLabel(tester, RegExp(r'^Banner'));
    await tester.tap(find.bySemanticsLabel('Choose photo'));
    await useCrop(tester);
    // The 400x200 picture's full width, 5:2: 160 high, from its middle.
    final crop = crops.single;
    for (final (got, want) in [(crop.x, 0.0), (crop.y, 20.0), (crop.w, 400.0), (crop.h, 160.0)]) {
      expect(got, closeTo(want, 0.01));
    }
    expect(find.bySemanticsLabel(RegExp(r'^Banner, Change or remove')), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space banner=/banners/new.png');
    expect(repository.spaces.value.single.bannerUrl, isNotNull);

    await tapLabel(tester, RegExp(r'^Overview'));
    expect(find.bySemanticsLabel(RegExp(r'^Banner, Change or remove')), findsOneWidget);
    await tapLabel(tester, RegExp(r'^Banner'));
    await tapLabel(tester, 'Remove banner');
    expect(find.bySemanticsLabel(RegExp(r'^Banner, Not set')), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space banner=none');
    expect(repository.spaces.value.single.bannerUrl, isNull);
    semantics.dispose();
  });

  testWidgets('overview: an icon, cropped square at 256 px as the desktop does; its upload shows how far it is', (
    tester,
  ) async {
    final path = await picture(tester);
    pickSpaceIcon = () async => path;
    final squares = <(CropRect, int)>[];
    saveSquareImage = (path, crop, side) async {
      squares.add((crop, side));
      return '/icons/new.png';
    };
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Overview'));
    await tapLabel(tester, RegExp(r'^Icon'));
    await tester.tap(find.bySemanticsLabel('Choose photo'));
    await useCrop(tester);
    // A square of the picture's full height, from its middle.
    final (crop, side) = squares.single;
    expect([crop.x, crop.y, crop.w, crop.h, side].map((v) => v.round()), [100, 0, 200, 200, 256]);
    expect(find.bySemanticsLabel(RegExp(r'^Icon, Change or remove')), findsOneWidget);

    repository.holdUploads = Completer();
    await tapLabel(tester, 'Save');
    repository.lastUpload!(0.5);
    await tester.pump();
    expect(find.text('Uploading · 50%'), findsOneWidget);
    repository.holdUploads!.complete();
    await tester.pumpAndSettle();
    expect(repository.admin.last, 'space icon=/icons/new.png');

    // Taken with the camera, not the gallery; then taken away.
    pickSpaceIcon = () async => null;
    takePhoto = () async => path;
    await tapLabel(tester, RegExp(r'^Overview'));
    await tapLabel(tester, RegExp(r'^Icon'));
    await tester.tap(find.bySemanticsLabel('Take photo'));
    await useCrop(tester);
    expect(squares, hasLength(2));
    await tapLabel(tester, RegExp(r'^Icon'));
    await tapLabel(tester, 'Remove icon');
    expect(find.bySemanticsLabel(RegExp(r'^Icon, Not set')), findsOneWidget);
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'space icon=none');
    expect(repository.spaces.value.single.iconUrl, isNull);
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

  testWidgets('rooms: create, rename, permissions, delete', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Rooms'));
    await tapLabel(tester, 'Create room');
    await tapLabel(tester, RegExp(r'^Text room'));
    await typeName(tester, 'crit');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'room+ crit text');

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
    await tester.tap(find.widgetWithText(DuvetChip, 'Moderator'));
    await tester.pumpAndSettle();
    // On the card shown: scrolling one beside it into view would turn back to it.
    await onCard(tester, 'Pin messages', 'Allow');
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

  group('rooms, for screen readers: each room and category one stop, with its moves (#60)', () {
    void twoAndTwo(FakeRepository r) => r.adminRoomList['s-guild'] = [
      const AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text),
      const AdminRoom(id: 'r-lobby', name: 'lobby', kind: AdminRoomKind.text, position: 1),
      const AdminRoom(id: 'r-crit', name: 'crit', kind: AdminRoomKind.text, parentId: 'c-work'),
      const AdminRoom(id: 'c-work', name: 'Work', kind: AdminRoomKind.category, position: 1),
      const AdminRoom(id: 'c-fun', name: 'Fun', kind: AdminRoomKind.category, position: 2),
    ];

    List<String> moves(SemanticsNode node) => [
      for (final id in node.getSemanticsData().customSemanticsActionIds ?? const <int>[])
        ?CustomSemanticsAction.getAction(id)?.label,
    ];

    SemanticsNode nodeOf(WidgetTester tester, Pattern label) => tester.getSemantics(find.bySemanticsLabel(label).last);

    // The moves on [label]'s node, and none on the node around it, where the
    // list offered them before. (Further up, a room's category has its own.)
    List<String> movesOn(WidgetTester tester, Pattern label) {
      final node = nodeOf(tester, label);
      expect(moves(node.parent!), isEmpty, reason: 'offered again around $label');
      return moves(node);
    }

    testWidgets('named, tapped and moved on the one node, never twice', (tester) async {
      await pumpSettings(tester, setUp: twoAndTwo);
      await tapLabel(tester, RegExp(r'^Rooms'));
      expect(movesOn(tester, 'Category Work'), ['Move down', 'Move to the end']);
      expect(movesOn(tester, 'Category Fun'), ['Move to the start', 'Move up']);
      expect(movesOn(tester, RegExp(r'^# general')), ['Move down', 'Move to the end']);
      expect(movesOn(tester, RegExp(r'^# lobby')), ['Move to the start', 'Move up']);
      for (final label in ['Category Work', RegExp(r'^# general')]) {
        expect(nodeOf(tester, label).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
      semantics.dispose();
    });

    testWidgets('the hint says it moves; a room alone in its category has nowhere to go', (tester) async {
      await pumpSettings(tester, setUp: twoAndTwo);
      await tapLabel(tester, RegExp(r'^Rooms'));
      expect(
        nodeOf(tester, 'Category Work').getSemanticsData().hint,
        'Double tap for options, or use actions to move it with its rooms',
      );
      expect(find.bySemanticsLabel('# general, Double tap for options, or use actions to move it'), findsOneWidget);
      expect(find.bySemanticsLabel('# crit, Double tap for options'), findsOneWidget);
      expect(movesOn(tester, RegExp(r'^# crit')), isEmpty);
      semantics.dispose();
    });

    testWidgets('an empty category\'s note is its own, not the category\'s name', (tester) async {
      await pumpSettings(tester, setUp: twoAndTwo);
      await tapLabel(tester, RegExp(r'^Rooms'));
      final note = nodeOf(tester, 'No rooms. Move one here from its options.');
      expect(moves(note), isEmpty);
      expect(note.parent!.getSemanticsData().label, 'Category Fun');
      semantics.dispose();
    });

    testWidgets('a move by its actions goes as a drag would', (tester) async {
      final repository = await pumpSettings(tester, setUp: twoAndTwo);
      await tapLabel(tester, RegExp(r'^Rooms'));
      final node = nodeOf(tester, RegExp(r'^# lobby'));
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move up')),
      );
      await tester.pumpAndSettle();
      expect(repository.admin.last, 'room> r-lobby - 0');
      semantics.dispose();
    });

    testWidgets('a move the user may not make says why, and asks the API nothing', (tester) async {
      final repository = await pumpSettings(
        tester,
        setUp: (r) {
          twoAndTwo(r);
          r
            ..spaceOwner = false
            ..spacePerms = Perm.manageChannels
            ..deniedInRoom['r-general'] = Perm.manageChannels;
        },
      );
      await tapLabel(tester, RegExp(r'^Rooms'));
      final asked = repository.admin.length;
      tester.takeAnnouncements();
      final node = nodeOf(tester, RegExp(r'^# general'));
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move down')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeAnnouncements().map((a) => a.message), ['You can’t move #general']);
      expect(repository.admin.length, asked);
      semantics.dispose();
    });
  });

  // A screen reader's move on [label], as it offers it in place of a drag.
  Future<void> readerMove(WidgetTester tester, Pattern label, String action) async {
    final id = CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: action));
    var node = tester.getSemantics(find.bySemanticsLabel(label).last);
    while (!(node.getSemanticsData().customSemanticsActionIds?.contains(id) ?? false)) {
      node = node.parent!;
    }
    node.owner!.performAction(node.id, SemanticsAction.customAction, id);
    await tester.pumpAndSettle();
  }

  void threeRooms(FakeRepository r) => r.adminRoomList['s-guild'] = [
    for (final (i, name) in ['general', 'lobby', 'memes'].indexed)
      AdminRoom(id: 'r-$name', name: name, kind: AdminRoomKind.text, position: i),
  ];

  testWidgets('rooms: a drag cancelled leaves its room alone; a screen reader\'s next move takes its own', (
    tester,
  ) async {
    final repository = await pumpSettings(tester, setUp: threeRooms);
    await tapLabel(tester, RegExp(r'^Rooms'));
    final drag = await tester.startGesture(tester.getCenter(find.text('# general', findRichText: true)));
    await tester.pump(const Duration(seconds: 1));
    await drag.moveBy(const Offset(0, 30));
    await tester.pump();
    // A system gesture takes the pointer.
    await drag.cancel();
    await tester.pumpAndSettle();
    final asked = repository.admin.length;
    await readerMove(tester, RegExp(r'^# memes'), 'Move up');
    expect(repository.admin.length, asked + 1);
    expect(repository.admin.last, startsWith('room> r-memes '));
    semantics.dispose();
  });

  testWidgets('rooms: a drag dropped where it began moves nothing, and leaves the next move its own', (tester) async {
    final repository = await pumpSettings(tester, setUp: threeRooms);
    await tapLabel(tester, RegExp(r'^Rooms'));
    final asked = repository.admin.length;
    final drag = await tester.startGesture(tester.getCenter(find.text('# general', findRichText: true)));
    await tester.pump(const Duration(seconds: 1));
    await drag.moveBy(const Offset(0, 4));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(repository.admin.length, asked);
    await readerMove(tester, RegExp(r'^# memes'), 'Move up');
    expect(repository.admin.last, startsWith('room> r-memes '));
    semantics.dispose();
  });

  testWidgets('rooms: a held drag moves its own room when another takes its place meanwhile (#58)', (tester) async {
    final repository = await pumpSettings(tester, setUp: threeRooms);
    await tapLabel(tester, RegExp(r'^Rooms'));
    final drag = await tester.startGesture(tester.getCenter(find.text('# lobby', findRichText: true)));
    await tester.pump(const Duration(seconds: 1));
    await drag.moveBy(const Offset(0, 10));
    await tester.pump();
    // Another admin moves general below lobby while it's held: lobby's
    // index now holds general.
    repository.adminRoomList['s-guild'] = [
      const AdminRoom(id: 'r-lobby', name: 'lobby', kind: AdminRoomKind.text, position: 0),
      const AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text, position: 1),
      const AdminRoom(id: 'r-memes', name: 'memes', kind: AdminRoomKind.text, position: 2),
    ];
    repository.spaces.value = [...repository.spaces.value];
    await tester.pump();
    await drag.moveBy(const Offset(0, 200));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(repository.admin.last, startsWith('room> r-lobby '));
    semantics.dispose();
  });

  testWidgets('rooms: a drag held past its category\'s end stays in it, and drops there', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.adminRoomList['s-guild'] = [
        const AdminRoom(id: 'c-work', name: 'Work', kind: AdminRoomKind.category),
        for (var i = 0; i < 20; i++)
          AdminRoom(id: 'r-$i', name: 'room$i', kind: AdminRoomKind.text, parentId: 'c-work', position: i),
        for (var c = 1; c <= 10; c++) ...[
          AdminRoom(id: 'c-$c', name: 'More $c', kind: AdminRoomKind.category, position: c),
          for (var i = 0; i < 5; i++)
            AdminRoom(id: 'r-$c-$i', name: 'more$c-$i', kind: AdminRoomKind.text, parentId: 'c-$c', position: i),
        ],
      ],
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    final drag = await tester.startGesture(tester.getCenter(find.text('# room0', findRichText: true)));
    await tester.pump(const Duration(seconds: 1));
    // Held at the bottom edge long enough to scroll well past Work.
    await drag.moveTo(Offset(200, tester.getSize(find.byType(MaterialApp)).height - 4));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await drag.up();
    await tester.pumpAndSettle();
    expect(repository.admin.last, matches(RegExp(r'^room> r-0 c-work \d+$')));
    semantics.dispose();
  });

  testWidgets('rooms: a room dragged to the screen\'s edge in a tall category scrolls the page (#57)', (tester) async {
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.adminRoomList['s-guild'] = [
        const AdminRoom(id: 'c-work', name: 'Work', kind: AdminRoomKind.category),
        for (var i = 0; i < 40; i++)
          AdminRoom(id: 'r-$i', name: 'room$i', kind: AdminRoomKind.text, parentId: 'c-work', position: i),
      ],
    );
    await tapLabel(tester, RegExp(r'^Rooms'));
    final page = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(page.pixels, 0);
    final drag = await tester.startGesture(tester.getCenter(find.text('# room0', findRichText: true)));
    await tester.pump(const Duration(seconds: 1));
    // Held at the bottom edge: the page scrolls under it.
    await drag.moveTo(Offset(200, tester.getSize(find.byType(MaterialApp)).height - 4));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(page.pixels, greaterThan(0));
    await drag.up();
    await tester.pumpAndSettle();
    // Dropped far down, past where the screen first ended.
    final dropped = RegExp(r'^room> r-0 c-work (\d+)$').firstMatch(repository.admin.last);
    expect(int.parse(dropped!.group(1)!), greaterThan(10));
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
    await tapLabel(tester, 'Solid');
    await tapLabel(tester, '#30A46C');
    await tapLabel(tester, 'Done');
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

  testWidgets('a role\'s Save is greyed out until something changes', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    await tapLabel(tester, RegExp(r'^Moderator'));
    bool saveEnabled() =>
        tester.getSemantics(find.bySemanticsLabel('Save').last).flagsCollection.isEnabled.toString().contains('isTrue');
    expect(saveEnabled(), isFalse);

    await tester.enterText(find.byType(EditableText).first, 'Mods');
    await tester.pumpAndSettle();
    expect(saveEnabled(), isTrue);

    // Back to how it was: nothing to save again.
    await tester.enterText(find.byType(EditableText).first, 'Moderator');
    await tester.pumpAndSettle();
    expect(saveEnabled(), isFalse);
    expect(repository.admin.where((a) => a.startsWith('role~')), isEmpty);
    semantics.dispose();
  });

  testWidgets('leaving an edited role asks first: Discard drops the edit, nothing saved', (tester) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    await tapLabel(tester, RegExp(r'^Moderator'));
    expect(find.text('Edit role'), findsOneWidget);
    // Untouched, back leaves at once.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Edit role'), findsNothing);

    await tapLabel(tester, RegExp(r'^Moderator'));
    await tester.enterText(find.byType(EditableText).first, 'Mods');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tapLabel(tester, 'Keep editing');
    expect(find.text('Edit role'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Discard');
    expect(find.text('Edit role'), findsNothing);
    expect(repository.admin.where((a) => a.startsWith('role~')), isEmpty);
    expect(find.text('Moderator'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a role\'s name color can be a gradient: from its color to another, a middle stop optional', (
    tester,
  ) async {
    final repository = await pumpSettings(tester);
    await tapLabel(tester, RegExp(r'^Roles'));
    await tapLabel(tester, RegExp(r'^Moderator'));
    await tapLabel(tester, 'Name color: #30A46C');
    await tapLabel(tester, 'Gradient');
    expect(find.bySemanticsLabel('Preview: Moderator, gradient, #30A46C to #0090FF'), findsOneWidget);
    await tapLabel(tester, 'Middle');
    await tapLabel(tester, '#D6A400');
    await tapLabel(tester, 'Done');
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'role~ role-mod color=30a46c..d6a400..90ff');

    // Back to one color: all three go, the gradient's stops cleared.
    await tapLabel(tester, RegExp(r'^Moderator'));
    await tapLabel(tester, RegExp(r'^Name color: gradient'));
    await tapLabel(tester, 'Solid');
    await tapLabel(tester, 'Done');
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'role~ role-mod color=30a46c');
    semantics.dispose();
  });

  group('roles, in order', () {
    // Highest first; [gap] spaces the positions out, as deleted roles leave them.
    void four(FakeRepository r, {int gap = 1}) => r.roleList['s-guild'] = [
      SpaceRole(id: 'role-helpers', name: 'Helpers', position: 3 * gap),
      SpaceRole(id: 'role-mod', name: 'Moderator', perms: Perm.manageChannels, position: 2 * gap),
      SpaceRole(id: 'role-admins', name: 'Admins', perms: Perm.administrator, position: gap, hoisted: true),
      const SpaceRole(id: 's-guild', name: '@everyone', everyone: true),
    ];

    List<String> order(WidgetTester tester) => [
      for (final name in ['Helpers', 'Moderator', 'Admins', '@everyone'])
        if (find.text(name).evaluate().isNotEmpty) name,
    ]..sort((a, b) => tester.getTopLeft(find.text(a)).dy.compareTo(tester.getTopLeft(find.text(b)).dy));

    testWidgets('a role dragged by its edge goes to the place of the role it lands by', (tester) async {
      final repository = await pumpSettings(tester, setUp: four);
      await tapLabel(tester, RegExp(r'^Roles'));
      expect(order(tester), ['Helpers', 'Moderator', 'Admins', '@everyone']);
      expect(find.text('Administrator'), findsNothing, reason: 'said under the name, with its members');
      expect(find.textContaining('Administrator'), findsOneWidget);

      // Admins, by a screen reader's move, up one: to Moderator's place.
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Admins, ')).last);
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move up')),
      );
      await tester.pumpAndSettle();
      expect(repository.admin.last, 'role^ role-admins 2');
      expect(order(tester), ['Helpers', 'Admins', 'Moderator', '@everyone']);

      // Helpers, down to the bottom: to the place of the one it lands under.
      final helpers = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Helpers')).last);
      helpers.owner!.performAction(
        helpers.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move to the end')),
      );
      await tester.pumpAndSettle();
      expect(repository.admin.last, 'role^ role-helpers 1');
      expect(order(tester), ['Admins', 'Moderator', 'Helpers', '@everyone']);
      semantics.dispose();
    });

    testWidgets('a drop into a gap the API would clamp lays the roles out again instead', (tester) async {
      final repository = await pumpSettings(tester, setUp: (r) => four(r, gap: 2));
      await tapLabel(tester, RegExp(r'^Roles'));
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Admins, ')).last);
      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move up')),
      );
      await tester.pumpAndSettle();
      // Moderator's 4 is past 3, the count less one: each to the bottom, top first.
      expect(repository.admin.where((a) => a.startsWith('role^')), [
        'role^ role-helpers 1',
        'role^ role-admins 1',
        'role^ role-mod 1',
      ]);
      expect(order(tester), ['Helpers', 'Admins', 'Moderator', '@everyone']);
      semantics.dispose();
    });

    testWidgets('Admins first: Administrator on top, then managers, the rest after, gaps and all', (tester) async {
      // Past what the API takes (it clamps to the count less one): each goes
      // to the bottom instead, top first.
      final repository = await pumpSettings(tester, setUp: (r) => four(r, gap: 2));
      await tapLabel(tester, RegExp(r'^Roles'));
      await tapLabel(tester, 'Admins first');
      await tapLabel(tester, 'Reorder');
      expect(repository.admin.where((a) => a.startsWith('role^')), [
        'role^ role-admins 1',
        'role^ role-mod 1',
        'role^ role-helpers 1',
      ]);
      expect(order(tester), ['Admins', 'Moderator', 'Helpers', '@everyone']);
      expect(find.bySemanticsLabel('Admins first'), findsNothing, reason: 'nothing left to sort');
      semantics.dispose();
    });

    testWidgets('roles at or above the user\'s highest are locked, and nothing goes above it', (tester) async {
      final repository = await pumpSettings(
        tester,
        setUp: (r) {
          four(r);
          r.spaceOwner = false;
          r.roleTags[r.profile.value!.id] = [const RoleTag('Moderator', id: 'role-mod', position: 2)];
        },
      );
      await tapLabel(tester, RegExp(r'^Roles'));
      final helpers = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Helpers')).last);
      expect(helpers.getSemanticsData().label, isNot(contains('use actions to move it')));
      final admins = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Admins, ')).last);
      expect(admins.getSemanticsData().label, contains('use actions to move it'));
      admins.owner!.performAction(
        admins.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Move up')),
      );
      await tester.pumpAndSettle();
      expect(repository.admin.where((a) => a.startsWith('role^')), isEmpty);
      expect(find.text('Roles can only go below your highest role'), findsOneWidget);

      // Opened, a locked role is there to read: nothing to save or delete.
      await tapLabel(tester, RegExp(r'^Helpers, '));
      expect(find.textContaining('only those above it change it'), findsOneWidget);
      expect(find.bySemanticsLabel('Save'), findsNothing);
      expect(find.text('Delete role'), findsNothing);
      semantics.dispose();
    });
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
    // The sheet gone, the list says how far the upload is.
    repository.holdUploads = Completer();
    await tapLabel(tester, 'Add');
    repository.lastUpload!(0.25);
    await tester.pump();
    expect(find.text('Uploading · 25%'), findsOneWidget);
    repository.holdUploads!.complete();
    await tester.pumpAndSettle();
    repository.holdUploads = null;
    expect(find.textContaining('Uploading'), findsNothing);
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

  testWidgets('room permissions: a page per role, swiped between, the role chips following', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(
      RepositoryScope(
        repository: repository,
        child: MaterialApp(
          theme: Duvet.material(Brightness.light),
          home: FTheme(
            data: Duvet.theme(Brightness.light),
            child: const RoomPermissionsPage(
              spaceId: 's-guild',
              room: AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text, position: 0),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> allowPins() => onCard(tester, 'Pin messages', 'Allow');

    // @everyone's first; a swipe to the right brings the role before it.
    await allowPins();
    expect(repository.admin.last, startsWith('overwrite r-general s-guild +${Perm.pinMessages}'));
    await tester.fling(find.byType(PageView), const Offset(120, 0), 600);
    await tester.pumpAndSettle();
    await allowPins();
    expect(repository.admin.last, startsWith('overwrite r-general role-mod +${Perm.pinMessages}'));

    // A chip turns to its page.
    await tester.tap(find.widgetWithText(DuvetChip, '@everyone'));
    await tester.pumpAndSettle();
    await onCard(tester, 'Pin messages', 'Deny');
    expect(repository.admin.last, startsWith('overwrite r-general s-guild +0 -${Perm.pinMessages}'));

    // The card peeking in at the side turns to the front when tapped.
    await tester.tapAt(Offset(8, tester.getCenter(find.byType(PageView)).dy));
    await tester.pumpAndSettle();
    await allowPins();
    expect(repository.admin.last, startsWith('overwrite r-general role-mod'));
  });

  testWidgets('room permissions: a member of their own, added, set, and removed', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(
      RepositoryScope(
        repository: repository,
        child: MaterialApp(
          theme: Duvet.material(Brightness.light),
          home: FTheme(
            data: Duvet.theme(Brightness.light),
            child: const RoomPermissionsPage(
              spaceId: 's-guild',
              room: AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text, position: 0),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Every room permission, Video and managing the room among them.
    expect(find.text('Manage the room'), findsWidgets);
    expect(find.text('Video'), findsWidgets);

    await tester.tap(find.widgetWithText(DuvetChip, 'Add member'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maya').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(DuvetChip, 'Maya'), findsOneWidget);
    expect(find.text('Theirs alone, over what their roles say'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.bySemanticsLabel('Send messages'), matching: find.text('Deny')).hitTestable(),
    );
    await tester.pumpAndSettle();
    const maya = FakeRepository.maya;
    expect(repository.admin.last, 'overwrite r-general $maya +0 -${Perm.sendMessages}');
    expect(repository.overwrites('s-guild', 'r-general').single.targetType, 1);

    await tester.tap(find.bySemanticsLabel('Remove Maya’s own permissions'));
    await tester.pumpAndSettle();
    expect(repository.admin.last, 'overwrite r-general $maya +0 -0');
    expect(find.widgetWithText(DuvetChip, 'Maya'), findsNothing);
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

  testWidgets('a GIF too large to go up as it is is cropped, saying so', (tester) async {
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
    expect(find.text('This GIF is over 256 KiB or 512 px, so it goes up cropped and resized'), findsOneWidget);
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
    // It's cropped as a picture, nothing to say.
    expect(find.textContaining('cropped and resized'), findsNothing);
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

  testWidgets('webhooks: renamed, given a picture cropped round, and the picture removed', (tester) async {
    final path = await picture(tester);
    pickSpaceIcon = () async => path;
    final squares = <int>[];
    saveSquareImage = (path, crop, side) async {
      squares.add(side);
      return '/squares/$side.png';
    };
    final repository = await pumpSettings(
      tester,
      setUp: (r) => r.webhookList = [
        SpaceWebhook(id: 'w-ci', roomId: 'r-general', roomName: 'general', name: 'CI', createdAt: DateTime(2026)),
      ],
    );
    await tapLabel(tester, RegExp(r'^Webhooks'));
    await tapLabel(tester, RegExp(r'^CI'));
    await tapLabel(tester, 'Rename');
    await tester.enterText(find.byType(EditableText).last, 'Builds');
    await tester.pump();
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'hook* w-ci name=Builds');
    expect(find.text('Builds'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Builds'));
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Add a picture')).last);
    await useCrop(tester);
    expect(squares, [256]);
    expect(repository.admin.last, 'hook* w-ci avatar');

    await tapLabel(tester, RegExp(r'^Builds'));
    await tapLabel(tester, 'Remove picture');
    expect(repository.admin.last, 'hook* w-ci noavatar');
    semantics.dispose();
  });

  testWidgets('a member who runs nothing sees the emojis and stickers, to look at only', (tester) async {
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
    await tester.tap(find.bySemanticsLabel('Design Guild, Space menu').last);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Space settings'), findsNothing);
    await tapLabel(tester, 'Emojis and stickers');
    expect(find.text('Emojis and stickers'), findsOneWidget);
    expect(find.bySemanticsLabel('Add emoji'), findsNothing);
    expect(find.textContaining('Those who manage emojis add and change them'), findsOneWidget);
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
