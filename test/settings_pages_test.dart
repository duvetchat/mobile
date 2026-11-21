// #284: the You tab lists the desktop's settings sections (SettingsScreen.svelte), in its order, each a page of its
// own with a heading for screen readers: My account, Attachments, Security, Audio, Appearance, then Developer apart,
// and Sign out at the foot. The desktop's Activity privacy and S3 buckets have nothing on mobile to hold.
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/data/voice_prefs.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/sounds_settings.dart' show AudioPage;
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _Player implements SoundPlayer {
  @override
  Future<void> play(Sound sound, double gain, {bool loop = false, bool aloud = false, VoidCallback? onDone}) async {}

  @override
  Future<void> stop(Sound sound) async {}

  @override
  Future<void> dispose() async {}
}

class _Ringer implements RingerMode {
  @override
  Future<bool> quiet() async => false;
}

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

void main() {
  late SemanticsHandle semantics;
  late Appearance appearance;
  late VoicePrefs prefs;

  setUpAll(() => DeepLinkSource.instance = _NoLinks());
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<FakeRepository> pumpYou(WidgetTester tester, {bool verified = true}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    appearance = Appearance(MemoryAppearanceStore());
    prefs = VoicePrefs();
    await tester.pumpWidget(
      DuvetApp(
        repository: repository,
        appearance: appearance,
        voicePrefs: prefs,
        sounds: Sounds(player: _Player(), ringer: _Ringer()),
      ),
    );
    await tester.pumpAndSettle();
    if (!verified) {
      final me = repository.profile.value!;
      repository.profile.value = Profile(id: me.id, username: me.username, alias: me.alias, emailVerified: false);
    }
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  // A section's row on the You tab, then its page.
  Future<void> open(WidgetTester tester, String section) async {
    final row = find.text(section);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  // The page's title, a heading for screen readers.
  void headed(WidgetTester tester, String title) => expect(
    tester.getSemantics(find.descendant(of: find.byType(GlassTopBar), matching: find.text(title))),
    isSemantics(label: title, isHeader: true),
  );

  Finder switchFor(String label) => find.byWidgetPredicate((w) => w is DuvetSwitch && w.label == label);

  testWidgets('You lists the sections in the desktop\'s order, then Developer apart, then Sign out', (tester) async {
    await pumpYou(tester);
    final sections = ['My account', 'Attachments', 'Security', 'Audio', 'Appearance', 'Developer', 'Sign out'];
    final tops = [for (final s in sections) tester.getTopLeft(find.text(s)).dy];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '${sections[i]} under ${sections[i - 1]}');
    }
    // Their settings are on their pages, not on the tab.
    for (final moved in ['Code theme', 'Faces in voice', 'Noise suppression', 'Change email', 'Reset password']) {
      expect(find.text(moved), findsNothing, reason: moved);
    }
    // Who the user is, how they show and their friends stay at the top.
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    expect(find.bySemanticsLabel('Do not disturb'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('My account: the profile, as the desktop\'s', (tester) async {
    await pumpYou(tester);
    await open(tester, 'My account');
    headed(tester, 'My account');
    expect(find.text('PROFILE'), findsOneWidget);
    for (final field in ['Display name', 'About me', 'Username']) {
      expect(find.text(field), findsOneWidget, reason: field);
    }
    expect(find.bySemanticsLabel('Change profile photo'), findsOneWidget);
    // The card's Edit opens the same page.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    headed(tester, 'My account');
    semantics.dispose();
  });

  testWidgets('Attachments: the storage and the files', (tester) async {
    await pumpYou(tester);
    await open(tester, 'Attachments');
    headed(tester, 'Attachments');
    expect(find.textContaining('of 5.0 GB used'), findsOneWidget);
    expect(find.bySemanticsLabel('Largest'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Security: the email, then signing in: the password and the email', (tester) async {
    final repository = await pumpYou(tester, verified: false);
    // Said on the way to it.
    expect(find.text('Email not verified'), findsOneWidget);
    await open(tester, 'Security');
    headed(tester, 'Security');
    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.text('SIGN-IN'), findsOneWidget);

    await tapLabel(tester, 'Reset password');
    await tapLabel(tester, 'Send link');
    expect(repository.account, ['send reset password']);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    await tapLabel(tester, 'Change email');
    expect(find.text('Send link'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Audio: every sound\'s volume, and noise suppression', (tester) async {
    await pumpYou(tester);
    await open(tester, 'Audio');
    headed(tester, 'Audio');
    expect(find.text('ALL SOUNDS'), findsOneWidget);
    expect(find.text('EACH SOUND'), findsOneWidget);
    for (final sound in ['Master volume', 'Notifications', 'Join voice', 'Leave voice', 'Incoming call']) {
      expect(find.bySemanticsLabel(RegExp('^$sound')), findsWidgets, reason: sound);
    }
    // After every sound's volume, in a group of its own.
    final noise = switchFor('Noise suppression');
    await tester.scrollUntilVisible(
      noise,
      200,
      scrollable: find.descendant(of: find.byType(AudioPage), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('VOICE'), findsOneWidget);
    expect(prefs.noiseSuppression, isTrue);
    await tester.tap(noise);
    await tester.pumpAndSettle();
    expect(prefs.noiseSuppression, isFalse);
    semantics.dispose();
  });

  testWidgets('Appearance: the theme, messages, replies, code blocks and faces in voice', (tester) async {
    await pumpYou(tester);
    await open(tester, 'Appearance');
    headed(tester, 'Appearance');
    for (final group in ['THEME', 'MESSAGES', 'REPLY TO A MESSAGE', 'CODE BLOCKS', 'VOICE']) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    await tapLabel(tester, 'Dark');
    expect(appearance.value, ThemeMode.dark);
    await tapLabel(tester, 'Flat rows');
    expect(appearance.messageLayout, MessageLayout.flat);
    await tapLabel(tester, 'Double tap');
    expect(appearance.replyGesture, ReplyGesture.doubleTap);
    expect(find.bySemanticsLabel(RegExp('^Code theme')), findsOneWidget);
    final faces = switchFor('Faces in voice');
    await tester.ensureVisible(faces);
    await tester.pumpAndSettle();
    await tester.tap(faces);
    await tester.pumpAndSettle();
    expect(prefs.facesInVoice, isTrue);
    semantics.dispose();
  });

  testWidgets('Developer: the portal, apart', (tester) async {
    await pumpYou(tester);
    await open(tester, 'Developer');
    headed(tester, 'Developer');
    expect(find.bySemanticsLabel('New team'), findsOneWidget);
    semantics.dispose();
  });
}
