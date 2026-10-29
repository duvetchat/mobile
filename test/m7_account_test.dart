import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/account.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/space_admin.dart' show bannerGif, saveBannerImage, saveSquareImage;
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/fake_repository.dart';

class _Links implements DeepLinkSource {
  final controller = StreamController<Uri>.broadcast();
  @override
  Stream<Uri> get links => controller.stream;
}

/// M7 · Account.
void main() {
  late SemanticsHandle semantics;
  late _Links links;
  late Appearance appearance;
  late MemoryAppearanceStore store;
  // The app's own, before the tests swap in theirs.
  final cropSquare = saveSquareImage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  setUp(() {
    links = _Links();
    DeepLinkSource.instance = links;
    store = MemoryAppearanceStore();
    appearance = Appearance(store);
  });

  Future<FakeRepository> pumpApp(
    WidgetTester tester, {
    bool signedIn = true,
    void Function(FakeRepository r)? setUp,
  }) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository(signedIn: signedIn);
    setUp?.call(repository);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  Future<void> openYou(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
    await tester.pumpAndSettle();
  }

  test('password strength grows with length and kinds of characters', () {
    expect(passwordStrength('abc').score, lessThan(2));
    expect(passwordStrength('abc').hint, startsWith('Too short'));
    expect(passwordStrength('correct horse battery 9!').score, 4);
  });

  test('a moving GIF banner is cropped frame by frame, keeping each frame’s colours and time', () {
    // Three frames of one colour each, from a palette of its own, each shown
    // for a time of its own, as GIF makers write them.
    img.Image frame(int r, int g, int b, int ms) => img.Image(width: 100, height: 100, withPalette: true)
      ..palette!.setRgb(0, r, g, b)
      ..frameDuration = ms;
    final gif = frame(220, 30, 30, 100)
      ..addFrame(frame(30, 200, 60, 400))
      ..addFrame(frame(40, 80, 230, 700));
    final banner = img.decodeGif(bannerGif(img.encodeGif(gif), (x: 0, y: 30, w: 100, h: 40)))!;
    expect(
      [for (final f in banner.frames) (f.getPixel(300, 120).r, f.getPixel(300, 120).g, f.getPixel(300, 120).b)],
      [(220, 30, 30), (30, 200, 60), (40, 80, 230)],
    );
    expect([for (final f in banner.frames) f.frameDuration], [100, 400, 700]);
    expect((banner.width, banner.height), (600, 240));
  });

  testWidgets('sign up: fields check themselves; the account verifies by its emailed link', (tester) async {
    final repository = await pumpApp(tester, signedIn: false);
    await tapLabel(tester, 'Create an account');
    expect(find.text('Create your account'), findsOneWidget);
    final create = find.bySemanticsLabel('Create account');
    expect(tester.getSemantics(create).getSemanticsData().flagsCollection.isEnabled.toString(), contains('isFalse'));

    await tester.enterText(find.byType(EditableText).at(0), 'alex.moreno');
    await tester.enterText(find.byType(EditableText).at(1), 'alex@example.com');
    await tester.enterText(find.byType(EditableText).at(2), 'short');
    await tester.pump();
    expect(find.text('Too short: at least 8 characters'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).at(2), 'a much longer one 9!');
    await tester.pump();
    await tapLabel(tester, 'Create account');
    expect(repository.account.first, 'signup alex.moreno alex@example.com');
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('alex@example.com'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).last, 'https://duvet.chat/verify?token=abc123');
    await tapLabel(tester, 'Verify');
    expect(repository.account.last, 'verify abc123');
    expect(find.text('Check your email'), findsNothing);
    await tester.pump(const Duration(seconds: 61));
    semantics.dispose();
  });

  testWidgets('forgot password sends a link; the link opens the new-password screen', (tester) async {
    final repository = await pumpApp(tester, signedIn: false);
    await tapLabel(tester, 'Forgot password?');
    await tester.enterText(find.byType(EditableText), 'alex@example.com');
    await tapLabel(tester, 'Send reset link');
    expect(find.text('Link sent'), findsOneWidget);
    expect(repository.account, ['forgot alex@example.com']);

    links.controller.add(Uri.parse('https://duvet.chat/reset-password?token=t0k'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a new password'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'a new password 7');
    await tester.pump();
    await tapLabel(tester, 'Save password');
    expect(repository.account.last, 'reset t0k');
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('verify and change-email links work while signed in', (tester) async {
    final repository = await pumpApp(tester);
    links.controller.add(Uri.parse('https://duvet.chat/verify?token=v1'));
    await tester.pumpAndSettle();
    links.controller.add(Uri.parse('https://duvet.chat/change-email?token=c1&email=new%40example.com'));
    await tester.pumpAndSettle();
    expect(repository.account, ['verify v1', 'change c1 new@example.com']);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('You: edit the display name, change email, appearance, sign out', (tester) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    expect(find.text('@gaby'), findsWidgets);
    await tester.enterText(find.byType(EditableText).first, 'Gabriela');
    await tapLabel(tester, 'Save');
    // The bio wasn't touched: it isn't sent.
    expect(repository.account, ['alias Gabriela']);
    expect(find.text('Gabriela'), findsWidgets);

    await tapLabel(tester, 'Dark');
    expect(appearance.value, ThemeMode.dark);
    expect(store.mode, 'dark');
    expect(Theme.of(tester.element(find.text('Gabriela').first)).brightness, Brightness.dark);

    expect(appearance.replyGesture, ReplyGesture.swipeLeft);
    await tester.ensureVisible(find.text('Swipe right'));
    await tapLabel(tester, 'Swipe right');
    expect(appearance.replyGesture, ReplyGesture.swipeRight);
    expect(store.replyGesture, 'swipeRight');

    await tester.ensureVisible(find.text('Change email'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Change email');
    await tester.enterText(find.byType(EditableText), 'new@example.com');
    await tapLabel(tester, 'Send link');
    expect(repository.account.last, 'change-send new@example.com');
    expect(find.textContaining('Check new@example.com'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('edit profile: the bio counts an emoji as one, stops at 190, and saves', (tester) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    final bio = find.byType(EditableText).at(1);
    expect(find.text('0 of 190 characters'), findsOneWidget);

    // Trimmed, and by code points: 😀 is one, where its UTF-16 is two.
    await tester.enterText(bio, '  Night runner 😀 ');
    await tester.pump();
    expect(find.text('14 of 190 characters'), findsOneWidget);

    bool saveEnabled() =>
        tester.getSemantics(find.bySemanticsLabel('Save').last).flagsCollection.isEnabled.toString().contains('isTrue');
    await tester.enterText(bio, '😀' * 191);
    await tester.pump();
    expect(find.text('Too long: 191 of 190 characters'), findsOneWidget);
    expect(saveEnabled(), isFalse);
    await tester.enterText(bio, '😀' * 190);
    await tester.pump();
    expect(find.text('190 of 190 characters'), findsOneWidget);
    expect(saveEnabled(), isTrue);

    await tester.enterText(bio, '  Night runner 😀 ');
    await tapLabel(tester, 'Save');
    expect(repository.account, ['alias Gaby', 'bio Night runner 😀']);
    expect(repository.profile.value!.bio, 'Night runner 😀');

    // Cleared: an empty bio goes, as the API clears it.
    await tapLabel(tester, 'Edit');
    expect(find.text('Night runner 😀'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).at(1), ' ');
    await tapLabel(tester, 'Save');
    expect(repository.account.last, 'bio ');
    expect(repository.profile.value!.bio, isNull);
    semantics.dispose();
  });

  testWidgets('You: the status switch chooses do not disturb, and says when it can\'t', (tester) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    bool checked(String label) =>
        tester.getSemantics(find.bySemanticsLabel(label).last).flagsCollection.isChecked.toString().contains('isTrue');
    expect(checked('Online'), isTrue);

    // Shown at once, while the server takes it.
    final hold = repository.holdStatus = Completer<void>();
    await tester.tap(find.bySemanticsLabel('Do not disturb').last);
    await tester.pump();
    expect(checked('Do not disturb'), isTrue);
    hold.complete();
    await tester.pumpAndSettle();
    expect(repository.account, ['status doNotDisturb']);
    expect(repository.profile.value!.status, Presence.doNotDisturb);
    expect(checked('Do not disturb'), isTrue);

    // Refused: back to what it was, saying why.
    repository.statusRefused = 'This server can’t set a status yet: it needs the latest API';
    await tapLabel(tester, 'Online');
    expect(repository.account.last, 'status online');
    expect(checked('Do not disturb'), isTrue);
    expect(find.text('This server can’t set a status yet: it needs the latest API'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('edit profile keeps working when the keyboard changes the screen\'s padding', (tester) async {
    await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await tester.enterText(find.byType(EditableText).first, 'Gabriela');
    // The keyboard opens over the gesture bar: the bottom padding goes.
    tester.view.padding = const FakeViewPadding(bottom: 34 * 3);
    await tester.pump();
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Gabriela'), findsOneWidget);
    semantics.dispose();
  });

  // The frames cropped, each with the size of the picture made of it.
  final crops = <String>[];

  // A 400 × 200 picture, which the picker hands over; what's cropped of it is
  // saved beside it as avatar.png or banner.png.
  Future<String> pickable(WidgetTester tester) async {
    crops.clear();
    saveSquareImage = (path, crop, side) async {
      crops.add('${crop.w.round()}x${crop.h.round()} as ${side}x$side');
      return File(path).copySync(path.replaceFirst('me.png', 'avatar.png')).path;
    };
    saveBannerImage = (path, crop) async {
      crops.add('${crop.w.round()}x${crop.h.round()} as 600x240');
      return File(path).copySync(path.replaceFirst('me.png', 'banner.png')).path;
    };
    final dir = Directory.systemTemp.createTempSync('duvet_crop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/me.png';
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = const Color(0xFF2F5FE0));
      final image = await recorder.endRecording().toImage(400, 200);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(path).writeAsBytesSync(png!.buffer.asUint8List());
    });
    pickProfilePicture = () async => path;
    return path;
  }

  // Picks the picture for [label] (Change profile photo, Change banner) and
  // crops it as it opens.
  Future<void> cropPicture(WidgetTester tester, String label) async {
    await tester.tap(find.bySemanticsLabel(label));
    // The picture decodes on the real clock.
    for (var i = 0; i < 20 && find.byType(InteractiveViewer).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tapLabel(tester, 'Use');
  }

  testWidgets('a new avatar and banner, cropped to their frames, go up on Save', (tester) async {
    final repository = await pumpApp(tester);
    final path = await pickable(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    await cropPicture(tester, 'Change banner');
    // A square from the 400 × 200 picture, its full height, made 256 square;
    // a banner 5 to 2, its full width, made 600 × 240, as the desktop's.
    expect(crops, ['200x200 as 256x256', '400x160 as 600x240']);
    expect(repository.account, isEmpty);

    // The cropped pictures go up, then the rest.
    await tapLabel(tester, 'Save');
    final dir = File(path).parent.path;
    expect(repository.account, ['avatar $dir/avatar.png', 'banner $dir/banner.png', 'alias Gaby']);
    expect(find.text('Edit profile'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Cancel drops the pictures picked: nothing goes up', (tester) async {
    final repository = await pumpApp(tester);
    await pickable(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    await tapLabel(tester, 'Cancel');
    expect(find.text('Edit profile'), findsNothing);
    expect(repository.account, isEmpty);
    semantics.dispose();
  });

  testWidgets('a picture the server refuses says why, and stays to try again', (tester) async {
    final repository = await pumpApp(tester);
    final path = await pickable(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    repository.pictureRefused = 'File is too large';
    await tapLabel(tester, 'Save');
    expect(find.text('File is too large'), findsOneWidget);
    expect(find.text('Edit profile'), findsOneWidget);
    expect(repository.account, isEmpty);

    repository.pictureRefused = null;
    await tester.pump(const Duration(seconds: 4));
    await tapLabel(tester, 'Save');
    expect(repository.account, ['avatar ${File(path).parent.path}/avatar.png', 'alias Gaby']);
    semantics.dispose();
  });

  testWidgets('a picture going up shows how far it is', (tester) async {
    final repository = await pumpApp(tester);
    await pickable(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    repository.holdUploads = Completer();
    await tapLabel(tester, 'Save');
    expect(find.text('Uploading · 0%'), findsOneWidget);
    repository.lastUpload!(0.42);
    await tester.pump();
    expect(find.text('Uploading · 42%'), findsOneWidget);
    repository.holdUploads!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Edit profile'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a photo cropped again shows its new crop, not the last one', (tester) async {
    await pumpApp(tester);
    final blue = await pickable(tester);
    // The pictures' paths as the platform writes them: the app takes a
    // picture's name from its path.
    final sep = Platform.pathSeparator;
    pickProfilePicture = () async => '${File(blue).parent.path}${sep}me.png';
    // Cropped and saved by the app, in a temporary folder of the test's.
    final temp = Directory.systemTemp.createTempSync('duvet_temp');
    addTearDown(() => temp.deleteSync(recursive: true));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null));
    final saved = <String>[];
    saveSquareImage = (path, crop, side) async {
      final square = await cropSquare(path, crop, side);
      saved.add(square);
      return square;
    };
    // Another photo of the same name, as the picker names a copy of one
    // photo picked twice: red where the first is blue.
    final red = '${Directory.systemTemp.createTempSync('duvet_crop').path}${sep}me.png';
    addTearDown(() => File(red).parent.deleteSync(recursive: true));
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 200), Paint()..color = const Color(0xFFE02F2F));
      final image = await recorder.endRecording().toImage(400, 200);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(red).writeAsBytesSync(png!.buffer.asUint8List());
    });

    // The page's photo of the crop saved last: its picture, once read on the
    // real clock, and its middle pixel's colour.
    ui.Image? shown() {
      final raw = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is Image && w.image is FileImage && (w.image as FileImage).file.path == saved.last,
        ),
        matching: find.byType(RawImage),
      );
      return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
    }

    Future<void> realClockUntil(bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    Future<(int, int, int)> middle() async {
      await realClockUntil(() => shown() != null);
      final image = shown()!;
      final pixels = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      final at = 4 * (image.width * (image.height ~/ 2) + image.width ~/ 2);
      return (pixels.getUint8(at), pixels.getUint8(at + 1), pixels.getUint8(at + 2));
    }

    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    await realClockUntil(() => saved.length == 1);
    expect(await middle(), (0x2F, 0x5F, 0xE0));

    pickProfilePicture = () async => red;
    await cropPicture(tester, 'Change profile photo');
    await realClockUntil(() => saved.length == 2);
    expect(await middle(), (0xE0, 0x2F, 0x2F));
    semantics.dispose();
  });

  testWidgets('the display name takes 32 characters at most, as the API does', (tester) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    bool saveEnabled() =>
        tester.getSemantics(find.bySemanticsLabel('Save').last).flagsCollection.isEnabled.toString().contains('isTrue');
    final name = find.byType(EditableText).first;

    await tester.enterText(name, 'a' * 33);
    await tester.pump();
    expect(find.text('Too long: 33 of 32 characters'), findsOneWidget);
    expect(saveEnabled(), isFalse);
    // Trimmed, and by code points: 😀 is one.
    await tester.enterText(name, '  ${'😀' * 32}  ');
    await tester.pump();
    expect(find.textContaining('Too long'), findsNothing);
    expect(saveEnabled(), isTrue);

    // The API's own reason, should it refuse anyway.
    repository.profileRefused = 'Display name must be at most 32 characters';
    await tapLabel(tester, 'Save');
    expect(find.text('Display name must be at most 32 characters'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  testWidgets('with a bucket of their own active, storage shows it, then the default storage and every bucket', (
    tester,
  ) async {
    // Before the app starts: the You tab reads the storage once, as it's built.
    await pumpApp(
      tester,
      setUp: (r) => r.usage = const StorageInfo(
        used: 0,
        max: 5 * 1024 * 1024 * 1024,
        buckets: [
          (name: 'Backblaze', used: 3 * 1024 * 1024, max: null, active: true),
          (name: 'Old R2', used: 1024 * 1024, max: 10 * 1024 * 1024, active: false),
        ],
      ),
    );
    await openYou(tester);
    // Below the fold, so maybe not built yet: scrolled into view.
    await tester.scrollUntilVisible(find.byType(BucketMeter), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.byType(StorageMeter), findsNothing, reason: 'the active bucket keeps the uploads');
    expect(find.bySemanticsLabel('Your own storage, Backblaze: 3.0 MB used · no quota'), findsOneWidget);

    await tester.tap(find.byType(BucketMeter));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Default storage: 0 B of 5\.0 GB used')), findsOneWidget);
    expect(find.text('Your buckets'), findsOneWidget);
    expect(find.text('3.0 MB used · Active'), findsOneWidget);
    expect(find.text('1.0 MB of 10.0 MB · Off'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('my files: storage by kind, filters, delete', (tester) async {
    final repository = await pumpApp(tester);
    repository.files = [
      MyFile(
        id: 'f1',
        name: 'room.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 3 * 1024 * 1024,
        createdAt: DateTime(2026, 10, 1),
        url: 'https://x/room.jpg',
      ),
      MyFile(
        id: 'f2',
        name: 'voice-note.ogg',
        contentType: 'audio/ogg',
        sizeBytes: 200 * 1024,
        createdAt: DateTime(2026, 10, 2),
        url: 'https://x/v.ogg',
      ),
    ];
    repository.usage = const StorageInfo(used: 3 * 1024 * 1024 + 200 * 1024, max: 5 * 1024 * 1024 * 1024);
    await openYou(tester);
    // Below the fold, so maybe not built yet: scrolled into view.
    await tester.scrollUntilVisible(find.byType(StorageMeter), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(StorageMeter));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^3\.2 MB of 5\.0 GB used: images 3\.0 MB')), findsOneWidget);
    await tester.ensureVisible(find.text('Voice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('room.jpg'), findsNothing);
    await tester.ensureVisible(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Delete room.jpg');
    await tapLabel(tester, 'Delete file');
    expect(repository.account, ['delete f1']);
    expect(find.text('room.jpg'), findsNothing);
    semantics.dispose();
  });
}
