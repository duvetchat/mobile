import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/account.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/space_admin.dart' show framedGif, saveBannerImage, saveSquareImage;
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/color_picker.dart' show ColorPick;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'support/fake_repository.dart';

// A dark VS Code theme, comments and trailing commas and all.
const _codeTheme = '''{
  // Cut down.
  "type": "dark",
  "colors": {"editor.foreground": "#ABB2BF"},
  "tokenColors": [
    {"scope": "keyword", "settings": {"foreground": "#C678DD"}},
  ],
}''';

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

  test('a moving GIF banner is cropped frame by frame and keeps moving', () {
    final gif = img.Image(width: 100, height: 100)..frameDuration = 100;
    gif.addFrame(img.Image(width: 100, height: 100)..frameDuration = 100);
    final banner = img.decodeGif(framedGif(img.encodeGif(gif), (x: 0, y: 30, w: 100, h: 40), 600, 240))!;
    expect(banner.numFrames, 2);
    expect((banner.width, banner.height), (600, 240));
  });

  testWidgets('a moving GIF cropped square keeps moving, as a GIF', (tester) async {
    final temp = Directory.systemTemp.createTempSync('duvet_temp');
    addTearDown(() => temp.deleteSync(recursive: true));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null));
    final gif = img.Image(width: 100, height: 60)..frameDuration = 100;
    gif.addFrame(img.Image(width: 100, height: 60)..frameDuration = 100);
    final path = '${temp.path}${Platform.pathSeparator}dance.gif';
    final square = await tester.runAsync(() async {
      await File(path).writeAsBytes(img.encodeGif(gif));
      final saved = await cropSquare(path, (x: 20, y: 0, w: 60, h: 60), 256);
      expect(saved, endsWith('dance.gif'));
      return img.decodeGif(await File(saved).readAsBytes())!;
    });
    expect((square!.numFrames, square.width, square.height), (2, 256, 256));
  });

  test('a moving GIF banner keeps each frame’s colours and time', () {
    // Three frames of one colour each, from a palette of its own, each shown
    // for a time of its own, as GIF makers write them.
    img.Image frame(int r, int g, int b, int ms) => img.Image(width: 100, height: 100, withPalette: true)
      ..palette!.setRgb(0, r, g, b)
      ..frameDuration = ms;
    final gif = frame(220, 30, 30, 100)
      ..addFrame(frame(30, 200, 60, 400))
      ..addFrame(frame(40, 80, 230, 700));
    final banner = img.decodeGif(framedGif(img.encodeGif(gif), (x: 0, y: 30, w: 100, h: 40), 600, 240))!;
    expect(
      [for (final f in banner.frames) (f.getPixel(300, 120).r, f.getPixel(300, 120).g, f.getPixel(300, 120).b)],
      [(220, 30, 30), (30, 200, 60), (40, 80, 230)],
    );
    expect([for (final f in banner.frames) f.frameDuration], [100, 400, 700]);
  });

  testWidgets('sign up: fields check themselves; the account verifies by its emailed link', (tester) async {
    final repository = await pumpApp(tester, signedIn: false);
    await tapLabel(tester, 'Create account');
    expect(find.text('Create your account'), findsOneWidget);
    final create = find.bySemanticsLabel('Create account');
    bool createEnabled() =>
        tester.getSemantics(create).getSemanticsData().flagsCollection.isEnabled.toString().contains('isTrue');
    // The button is past the screen's end: built, and in the semantics tree, once scrolled to.
    await tester.scrollUntilVisible(create, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(createEnabled(), isFalse);

    // Display name, username, email, password, and the password again.
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'Alex');
    await tester.enterText(fields.at(1), 'alex.moreno');
    await tester.enterText(fields.at(2), 'alex@example.com');
    await tester.enterText(fields.at(3), 'short');
    await tester.pump();
    expect(find.text('Too short: at least 8 characters'), findsOneWidget);
    await tester.enterText(fields.at(3), 'a much longer one 9!');
    await tester.enterText(fields.at(4), 'a much longer one 8!');
    await tester.pump();
    expect(find.text('Passwords don’t match'), findsOneWidget);
    await tester.enterText(fields.at(4), 'a much longer one 9!');
    await tester.pump();
    expect(find.text('Passwords don’t match'), findsNothing);
    // Not until the terms are accepted, which say what they are.
    expect(createEnabled(), isFalse);
    await tester.ensureVisible(find.bySemanticsLabel('Terms of use'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Terms of use');
    expect(find.textContaining('use Duvet respectfully'), findsOneWidget);
    await tapLabel(tester, 'Close');
    await tapLabel(tester, 'I agree to the Terms of use');
    expect(createEnabled(), isTrue);

    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Create account');
    expect(repository.account.first, 'signup alex.moreno alex@example.com Alex');
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('alex@example.com'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).last, 'https://duvet.chat/verify?token=abc123');
    await tapLabel(tester, 'Verify');
    expect(repository.account.last, 'verify abc123');
    expect(find.text('Check your email'), findsNothing);
    await tester.pump(const Duration(seconds: 61));
    semantics.dispose();
  });

  testWidgets('sign up takes any username the API takes: 32 characters at most; its refusal says why', (tester) async {
    final repository = await pumpApp(tester, signedIn: false, setUp: (r) => r.signUpRefused = 'That username is taken');
    await tapLabel(tester, 'Create account');
    final create = find.bySemanticsLabel('Create account');
    bool createEnabled() =>
        tester.getSemantics(create).getSemanticsData().flagsCollection.isEnabled.toString().contains('isTrue');
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(1), 'a' * 33);
    await tester.enterText(fields.at(2), 'alex@example.com');
    await tester.enterText(fields.at(3), 'a much longer one 9!');
    await tester.enterText(fields.at(4), 'a much longer one 9!');
    await tester.pump();
    await tester.ensureVisible(find.bySemanticsLabel('I agree to the Terms of use'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'I agree to the Terms of use');
    expect(find.text('Too long: 33 of 32 characters'), findsOneWidget);
    expect(createEnabled(), isFalse);

    // Spaces, a hyphen and an accent: the app's old rule refused them, the API doesn't. Trimmed, as the API trims it.
    await tester.enterText(fields.at(1), '  Álex-M 😀  ');
    await tester.pump();
    expect(find.textContaining('Too long'), findsNothing);
    expect(createEnabled(), isTrue);
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Create account');
    expect(find.text('That username is taken'), findsOneWidget);

    repository.signUpRefused = null;
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Create account');
    expect(repository.account.first, 'signup Álex-M 😀 alex@example.com');
    await tester.pump(const Duration(seconds: 61));
    semantics.dispose();
  });

  testWidgets('forgot password sends a link; the link opens the new-password screen', (tester) async {
    final repository = await pumpApp(tester, signedIn: false);
    await tapLabel(tester, 'Sign in');
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
    await tester.pump();
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

  testWidgets('You: a code theme from a link, applied once, then back to the default', (tester) async {
    final asked = <Uri>[];
    appearance = Appearance(
      store,
      () => MockClient((request) async {
        asked.add(request.url);
        return http.Response(request.url.path == '/theme.json' ? _codeTheme : '<html></html>', 200);
      }),
    );
    await pumpApp(tester);
    await openYou(tester);
    // Centered: aligned to the top, the row would sit under the collapsed title bar.
    await Scrollable.ensureVisible(tester.element(find.text('Code theme')), alignment: 0.5);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Code theme, GitHub');

    // Not a theme: said inline, and nothing changes.
    await tester.enterText(find.byType(EditableText).last, 'https://example.com/page');
    await tapLabel(tester, 'Apply');
    expect(find.text('Couldn’t read a VS Code theme there'), findsOneWidget);
    expect(appearance.codeTheme, isNull);
    expect(store.codeTheme, isNull);

    await tester.enterText(find.byType(EditableText).last, 'https://example.com/theme.json');
    await tapLabel(tester, 'Apply');
    expect(find.text('Couldn’t read a VS Code theme there'), findsNothing);
    expect(appearance.codeTheme?.dark, isTrue);
    expect(appearance.codeTheme?.styles['keyword']?.color, const Color(0xFFC678DD));
    expect(store.codeTheme?.url, 'https://example.com/theme.json');
    expect(store.codeTheme?.json, _codeTheme);
    // Azure bubbles are dark too.
    expect(find.text('Used in dark mode and on your bubbles'), findsOneWidget);
    expect(asked, hasLength(2));

    await tapLabel(tester, 'Use the default');
    expect(appearance.codeTheme, isNull);
    expect(store.codeTheme, isNull);
    expect(asked, hasLength(2), reason: 'the default needs no fetch');
    semantics.dispose();
  });

  testWidgets('You: reset password emails a link, and says why when refused', (tester) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await Scrollable.ensureVisible(tester.element(find.text('Reset password')), alignment: 0.5);
    await tester.pumpAndSettle();
    // It asks first: Cancel sends nothing.
    await tapLabel(tester, 'Reset password');
    expect(find.text('Reset your password?'), findsOneWidget);
    await tapLabel(tester, 'Cancel');
    expect(repository.account, isEmpty);

    await tapLabel(tester, 'Reset password');
    await tapLabel(tester, 'Send link');
    expect(repository.account, ['send reset password']);
    expect(find.text('We emailed you a link to set a new password'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    repository.resetPasswordRefused = 'Too many emails, try again later';
    await tapLabel(tester, 'Reset password');
    await tapLabel(tester, 'Send link');
    expect(repository.account, ['send reset password'], reason: 'nothing sent');
    expect(find.text('Too many emails, try again later'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('You: your bubbles take a swatch; a pale one gets dark ink', (tester) async {
    await pumpApp(tester);
    await openYou(tester);
    // Mid-screen: the Voice section above pushes the swatches down to the tab bar's glass.
    await Scrollable.ensureVisible(tester.element(find.bySemanticsLabel('Yellow')), alignment: 0.5);
    await tester.pumpAndSettle();
    Color? ink() => tester.widget<Text>(find.text('Looks good to me')).style?.color;
    expect(ink(), const Color(0xFFFFFFFF));

    await tapLabel(tester, 'Yellow');
    expect(appearance.bubbleColor, 0xD6A400);
    expect(store.bubbleColor, '${0xD6A400}');
    expect(ink(), bubbleDarkInk);

    await tapLabel(tester, 'Azure');
    expect(appearance.bubbleColor, isNull);
    expect(store.bubbleColor, isNull);
    expect(ink(), const Color(0xFFFFFFFF));
    semantics.dispose();
  });

  testWidgets('You: your bubbles take any color, typed as #RRGGBB', (tester) async {
    await pumpApp(tester);
    await openYou(tester);
    await Scrollable.ensureVisible(tester.element(find.bySemanticsLabel('Custom color')), alignment: 0.5);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Custom color');
    await tester.enterText(find.descendant(of: find.byType(ColorPick), matching: find.byType(EditableText)), '#F0F0F0');
    await tester.pumpAndSettle();
    expect(appearance.bubbleColor, 0xF0F0F0);
    expect(store.bubbleColor, '${0xF0F0F0}');
    expect(tester.widget<Text>(find.text('Looks good to me')).style?.color, bubbleDarkInk);
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
    await tester.pump();
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
    // The field, and the card above it showing the name as typed.
    expect(find.text('Gabriela'), findsNWidgets(2));
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

  // Picks the picture for [label] (Change profile photo, Change banner) from
  // its sheet and crops it as it opens.
  Future<void> cropPicture(WidgetTester tester, String label) async {
    await tapLabel(tester, label);
    await tester.tap(find.bySemanticsLabel('Choose photo'));
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

  testWidgets('Cancel asks first, then drops the pictures picked: nothing goes up', (tester) async {
    final repository = await pumpApp(tester);
    await pickable(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await cropPicture(tester, 'Change profile photo');
    await tapLabel(tester, 'Cancel');
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tapLabel(tester, 'Discard');
    expect(find.text('Edit profile'), findsNothing);
    expect(repository.account, isEmpty);
    semantics.dispose();
  });

  // Signed in with an avatar of their own: after the sign-in, which sets the
  // profile.
  Future<FakeRepository> pumpWithAvatar(WidgetTester tester) async {
    final repository = await pumpApp(tester);
    repository.profile.value = Profile(
      id: FakeRepository.me.id,
      username: 'gaby',
      alias: 'Gaby',
      avatarUrl: 'https://example.invalid/me.png',
    );
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('a removed avatar goes on Save, before the rest', (tester) async {
    final repository = await pumpWithAvatar(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    // No banner: its sheet has none to remove.
    await tapLabel(tester, 'Change banner');
    expect(find.bySemanticsLabel('Remove banner'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Change profile photo');
    await tapLabel(tester, 'Remove profile photo');
    await tapLabel(tester, 'Change profile photo');
    expect(find.bySemanticsLabel('Remove profile photo'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(repository.account, isEmpty);

    await tapLabel(tester, 'Save');
    expect(repository.account, ['remove avatar', 'alias Gaby']);
    expect(repository.profile.value!.avatarUrl, isNull);
    expect(find.text('Edit profile'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a removal Cancel discards takes nothing away', (tester) async {
    final repository = await pumpWithAvatar(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await tapLabel(tester, 'Change profile photo');
    await tapLabel(tester, 'Remove profile photo');
    await tapLabel(tester, 'Cancel');
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tapLabel(tester, 'Discard');
    expect(find.text('Edit profile'), findsNothing);
    expect(repository.account, isEmpty);
    expect(repository.profile.value!.avatarUrl, isNotNull);
    semantics.dispose();
  });

  testWidgets('leaving an edited profile asks first; Keep editing keeps the edit, unedited leaves at once', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    await tapLabel(tester, 'Cancel');
    expect(find.text('Unsaved changes'), findsNothing);
    expect(find.text('Edit profile'), findsNothing);

    await tapLabel(tester, 'Edit');
    await tester.enterText(find.byType(EditableText).first, 'Gabriela');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tapLabel(tester, 'Keep editing');
    expect(find.text('Edit profile'), findsOneWidget);
    // The field, and the card above it showing the name as typed.
    expect(find.text('Gabriela'), findsNWidgets(2));
    await tapLabel(tester, 'Save');
    expect(repository.account, ['alias Gabriela']);
    expect(find.text('Edit profile'), findsNothing);
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

  testWidgets('edit profile changes the username: 32 characters at most, as the API takes it; a taken one says so', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    await openYou(tester);
    await tapLabel(tester, 'Edit');
    bool saveEnabled() =>
        tester.getSemantics(find.bySemanticsLabel('Save').last).flagsCollection.isEnabled.toString().contains('isTrue');
    // Display name, about me, username.
    final name = find.byType(EditableText).at(2);
    await tester.ensureVisible(name);
    await tester.pumpAndSettle();

    await tester.enterText(name, 'g' * 33);
    await tester.pump();
    expect(find.text('Too long: 33 of 32 characters'), findsOneWidget);
    expect(saveEnabled(), isFalse);
    // Empty keeps the one there: nothing to save.
    await tester.enterText(name, '  ');
    await tester.pump();
    expect(saveEnabled(), isFalse);

    // Any the API takes, trimmed; the preview shows it before Save.
    await tester.enterText(name, '  Gaby R.  ');
    await tester.pump();
    expect(find.text('@Gaby R.'), findsOneWidget);
    repository.profileRefused = 'That username is taken';
    await tapLabel(tester, 'Save');
    expect(find.text('That username is taken'), findsOneWidget);
    repository.profileRefused = null;
    // The toast gone, Save is there to tap again.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Save');
    expect(repository.account, ['alias Gaby', 'username Gaby R.']);
    expect(repository.profile.value!.username, 'Gaby R.');
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
    await tester.ensureVisible(find.byType(BucketMeter));
    await tester.pumpAndSettle();
    expect(find.byType(StorageMeter), findsNothing, reason: 'the active bucket keeps the uploads');
    expect(find.bySemanticsLabel('Your own storage, Backblaze: 3.0 MB used · no quota'), findsOneWidget);

    await tester.tap(find.byType(BucketMeter));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Default storage: 0 B of 5\.0 GB used')), findsOneWidget);
    expect(find.text('YOUR BUCKETS'), findsOneWidget);
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
    await tester.ensureVisible(find.byType(StorageMeter));
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
