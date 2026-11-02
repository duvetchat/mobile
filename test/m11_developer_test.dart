import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/account.dart' show pickProfilePicture;
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/space_admin.dart' show saveBannerImage, saveSquareImage;
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

/// M11 · Developer portal: teams, their members and invites, applications and bots.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<void> reveal(WidgetTester tester, Finder found) async {
    if (Scrollable.maybeOf(tester.element(found)) == null) return;
    await Scrollable.ensureVisible(tester.element(found), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
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

  Future<void> typeName(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(EditableText).last, name);
    await tester.pump();
  }

  /// The You tab, set up by [setUp] first; then the portal unless [open] is false.
  Future<FakeRepository> pumpPortal(
    WidgetTester tester, {
    void Function(FakeRepository r)? setUp,
    bool open = true,
  }) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
    await tester.pumpAndSettle();
    if (open) await tapLabel(tester, RegExp(r'^Developer portal'));
    return repository;
  }

  // A 400 × 200 picture on disk, for the crop page to open.
  Future<String> picture(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('duvet_bot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/bot.png';
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = const Color(0xFF0000FF));
      final image = await recorder.endRecording().toImage(400, 200);
      File(path).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
    return path;
  }

  Future<void> useCrop(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 20 && find.byType(InteractiveViewer).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tapLabel(tester, 'Use');
  }

  String? copied;
  void catchClipboard(WidgetTester tester) {
    copied = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  testWidgets('a team, an application and its bot: the token shown once, reset, and all deleted', (tester) async {
    catchClipboard(tester);
    final repository = await pumpPortal(tester);
    expect(find.textContaining('No teams yet'), findsOneWidget);

    await tapLabel(tester, 'New team');
    await typeName(tester, 'Acme');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'team+ Acme');
    expect(find.text('Admin'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^New application'));
    await typeName(tester, 'Helper');
    await tapLabel(tester, 'Create');
    expect(repository.admin.last, 'app+ t-Acme Helper');

    await tapLabel(tester, RegExp(r'^Create bot'));
    expect(repository.admin.last, 'bot+ a-Helper');
    expect(find.textContaining('won’t be shown again'), findsOneWidget);
    await tapLabel(tester, 'Copy token');
    expect(copied, 'bot-token-1');
    expect(find.text('@helper-bot'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Copy invite link'));
    expect(copied, 'https://duvet.chat/invite?bot=b-a-Helper');

    await tapLabel(tester, RegExp(r'^Reset token'));
    await tapLabel(tester, 'Reset token');
    expect(repository.admin.last, 'bot~ a-Helper');
    await tapLabel(tester, 'Copy token');
    expect(copied, 'bot-token-2');

    await tapLabel(tester, 'Public');
    expect(repository.admin.last, 'app* a-Helper public=true');
    expect(find.text('Anyone can add its bot'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Delete bot'));
    await tapLabel(tester, 'Delete bot');
    expect(repository.admin.last, 'bot- a-Helper');
    expect(find.bySemanticsLabel(RegExp(r'^Create bot')), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Delete application'));
    await tapLabel(tester, 'Delete application');
    expect(repository.admin.last, 'app- a-Helper');
    expect(find.bySemanticsLabel(RegExp(r'^Helper')), findsNothing);

    await tapLabel(tester, 'Team options');
    await tapLabel(tester, RegExp(r'^Delete team'));
    await tapLabel(tester, 'Delete team');
    expect(repository.admin.last, 'team- t-Acme');
    expect(find.textContaining('No teams yet'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('team invites: counted on the You tab, live, accepted and declined', (tester) async {
    final repository = await pumpPortal(
      tester,
      open: false,
      setUp: (r) => r.teamInvites.value = const [TeamInvite(id: 'i1', teamName: 'Acme', invitedBy: 'maya')],
    );
    expect(find.bySemanticsLabel(RegExp(r'^Developer portal.*1 invite')), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Developer portal'));
    expect(find.text('Invited by maya'), findsOneWidget);

    // TEAM_INVITE_CREATE while the page is open.
    repository.teamInvites.value = [
      ...repository.teamInvites.value,
      const TeamInvite(id: 'i2', teamName: 'Globex', invitedBy: 'leo'),
    ];
    await tester.pumpAndSettle();
    expect(find.text('Invited by leo'), findsOneWidget);

    repository.teamList = [const DevTeam(id: 't-acme', name: 'Acme', ownerId: FakeRepository.maya)];
    await tester.tap(find.text('Accept').first);
    await tester.pumpAndSettle();
    expect(repository.admin.last, 'team accept i1');
    expect(find.text('You joined Acme'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Acme')), findsWidgets);

    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(repository.admin.last, 'team decline i2');
    expect(find.text('Team invites'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a member who isn\'t the owner sees the team, to look at only, and can copy its bot\'s link', (
    tester,
  ) async {
    catchClipboard(tester);
    final repository = await pumpPortal(
      tester,
      setUp: (r) {
        r.teamList = [const DevTeam(id: 't-acme', name: 'Acme', ownerId: FakeRepository.maya)];
        r.teamMemberList['t-acme'] = [
          const Member(userId: FakeRepository.maya, username: 'maya', alias: 'Maya'),
          FakeRepository.everyone.first,
        ];
        r.appList['t-acme'] = [
          const DevApp(id: 'a-1', teamId: 't-acme', name: 'Helper', description: 'Helps', botUserId: 'b-1'),
        ];
      },
    );
    await tapLabel(tester, RegExp(r'^Acme'));
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Helper'), findsOneWidget);
    for (final change in ['Team options', 'Invite by email', 'New application']) {
      expect(find.bySemanticsLabel(RegExp('^$change')), findsNothing, reason: change);
    }
    expect(find.bySemanticsLabel(RegExp('Double tap to remove')), findsNothing);
    await tester.tap(find.text('Helper'));
    await tester.pumpAndSettle();
    expect(copied, 'https://duvet.chat/invite?bot=b-1');
    expect(find.text('Invite link copied'), findsOneWidget);
    expect(repository.admin, isEmpty);
    semantics.dispose();
  });

  testWidgets('the owner invites by email, removes a member, and hears the server\'s refusals', (tester) async {
    final repository = await pumpPortal(
      tester,
      setUp: (r) {
        r.teamList = [DevTeam(id: 't-acme', name: 'Acme', ownerId: FakeRepository.me.id)];
        r.teamMemberList['t-acme'] = [
          FakeRepository.everyone.first,
          const Member(userId: FakeRepository.leo, username: 'leo'),
        ];
        r.refusals['inviteToTeam'] = 'Verify your email first';
      },
    );
    await tapLabel(tester, RegExp(r'^Acme'));
    await tapLabel(tester, RegExp(r'^Invite by email'));
    await typeName(tester, 'leo@example.com');
    await tapLabel(tester, 'Invite');
    expect(repository.admin.last, 'team invite t-acme leo@example.com');
    expect(find.text('Verify your email first'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^leo'));
    await tapLabel(tester, 'Remove');
    expect(repository.admin.last, 'team kick t-acme ${FakeRepository.leo}');
    expect(find.text('leo'), findsNothing);
    semantics.dispose();
  });

  testWidgets('the bot\'s username, display name, picture and banner', (tester) async {
    final repository = await pumpPortal(
      tester,
      setUp: (r) {
        r.teamList = [DevTeam(id: 't-acme', name: 'Acme', ownerId: FakeRepository.me.id)];
        r.teamMemberList['t-acme'] = [FakeRepository.everyone.first];
        r.appList['t-acme'] = [const DevApp(id: 'a-1', teamId: 't-acme', name: 'Helper', botUserId: 'b-1')];
        r.botList['b-1'] = const Member(
          userId: 'b-1',
          username: 'helper',
          alias: 'Helpy',
          avatarUrl: 'https://example.invalid/a.png',
          bannerUrl: 'https://example.invalid/b.png',
          isBot: true,
        );
      },
    );
    await tapLabel(tester, RegExp(r'^Acme'));
    await tapLabel(tester, RegExp(r'^Helper'));

    await tapLabel(tester, RegExp(r'^Username'));
    await typeName(tester, 'helper2');
    await tapLabel(tester, 'Save');
    expect(repository.admin.last, 'bot* a-1 username=helper2');
    expect(find.text('@helper2'), findsOneWidget);

    await tapLabel(tester, RegExp(r'^Remove display name'));
    expect(repository.admin.last, 'bot* a-1 noalias');
    expect(find.bySemanticsLabel(RegExp(r'^Remove display name')), findsNothing);

    await tapLabel(tester, RegExp(r'^Remove picture'));
    expect(repository.admin.last, 'bot* a-1 noavatar');
    await tapLabel(tester, RegExp(r'^Remove banner'));
    expect(repository.admin.last, 'bot* a-1 nobanner');
    expect(find.bySemanticsLabel(RegExp(r'^Add a picture')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Add a banner')), findsOneWidget);

    // New ones: picked, cropped here, and sent.
    final path = await picture(tester);
    pickProfilePicture = () async => path;
    final saved = <String>[];
    saveSquareImage = (path, crop, side) async {
      saved.add('square $side');
      return '${File(path).parent.path}/square.png';
    };
    saveBannerImage = (path, crop) async {
      saved.add('banner');
      return '${File(path).parent.path}/banner.png';
    };
    await reveal(tester, find.bySemanticsLabel(RegExp(r'^Add a picture')).last);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Add a picture')).last);
    await useCrop(tester);
    expect(saved, ['square 256']);
    expect(repository.admin.last, 'bot* a-1 avatar');
    await reveal(tester, find.bySemanticsLabel(RegExp(r'^Add a banner')).last);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Add a banner')).last);
    await useCrop(tester);
    expect(saved, ['square 256', 'banner']);
    expect(repository.admin.last, 'bot* a-1 banner');
    expect(find.bySemanticsLabel(RegExp(r'^Change picture')), findsOneWidget);

    repository.refusals['updateBot'] = 'That username is taken';
    await tapLabel(tester, RegExp(r'^Username'));
    await typeName(tester, 'taken');
    await tapLabel(tester, 'Save');
    expect(find.text('That username is taken'), findsOneWidget);
    semantics.dispose();
  });
}
