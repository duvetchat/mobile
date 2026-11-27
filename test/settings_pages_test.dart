// #284: the You tab lists the desktop's settings sections (SettingsScreen.svelte), in its order, each a page of its
// own with a heading for screen readers: My account, Attachments, Security, Devices, Audio, Appearance, then Developer
// apart, and Sign out at the foot. The desktop's Activity privacy and S3 buckets have nothing on mobile to hold.
// Devices (PLAN-E2E-CLIENTES.md, Task 25) are the desktop's DevicesSettings.test.ts, on the phone.
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/data/voice_prefs.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/main.dart';
import 'package:duvet/sounds_settings.dart' show AudioPage;
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:duvet_client/duvet.dart' as duvet;
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
    final sections = [
      'My account',
      'Attachments',
      'Security',
      'Devices',
      'Audio',
      'Appearance',
      'Developer',
      'Sign out',
    ];
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
    // The card's Edit opens the same page, at the tab's top, which the way to My account scrolled from.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Friends'), const Offset(0, 600));
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
  // Devices (PLAN-E2E-CLIENTES.md, Task 25; decisions 13 and 52): the user's devices, each one's client and when it was
  // last seen, this one, those not seen in 45 days; removing another, changing the keys, and deleting this one's data,
  // each where it can be done.
  group('Devices', () {
    final now = DateTime.now();
    duvet.Device device(
      String id,
      String name,
      String client, {
      bool listed = true,
      bool current = false,
      int days = 1,
    }) => duvet.Device(
      id: id,
      name: name,
      client: client,
      listed: listed,
      current: current,
      createdAt: now.subtract(const Duration(days: 60)),
      lastSeenAt: now.subtract(Duration(days: days)),
    );
    final self = device('0193a4b2-0000-7000-8000-0000000000a1', 'Pixel 8 Pro', 'android/1.1.0', current: true);
    final computer = device(
      '0193a4b2-0000-7000-8000-0000000000a2',
      'Duvet for Windows',
      'desktop-windows/1.2.0',
      days: 50,
    );
    final browser = device('0193a4b2-0000-7000-8000-0000000000a3', 'Firefox on Linux', 'web/1.2.0', listed: false);

    Future<FakeRepository> pumpDevices(
      WidgetTester tester, {
      EngineState state = EngineState.ready,
      List<duvet.Device>? devices,
      bool failed = false,
    }) async {
      final repository = await pumpYou(tester);
      repository
        ..encryption.value = state
        ..deviceList = failed ? null : devices ?? [self, computer, browser];
      await open(tester, 'Devices');
      return repository;
    }

    Finder button(String label) => find.bySemanticsLabel(label).hitTestable();

    testWidgets('each device with its client and when it was last seen, this one and one not seen in 45 days marked', (
      tester,
    ) async {
      await pumpDevices(tester);
      headed(tester, 'Devices');
      for (final d in [self, computer, browser]) {
        expect(find.textContaining(d.name), findsOneWidget, reason: d.name);
        expect(find.textContaining(d.client), findsOneWidget, reason: d.client);
      }
      expect(find.text('This device'), findsOneWidget);
      expect(find.text(Notice.inactiveDevice.text), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(Notice.inactiveDevice.text)).dy,
        greaterThan(tester.getTopLeft(find.textContaining(computer.name)).dy),
      );
      expect(find.text('Not set up'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Not set up')).dy,
        greaterThan(tester.getTopLeft(find.textContaining(browser.name)).dy),
      );
      semantics.dispose();
    });

    testWidgets('offer to remove the other devices and to change the keys only while this one is ready', (
      tester,
    ) async {
      await pumpDevices(tester);
      expect(button('Remove ${computer.name}'), findsOneWidget);
      expect(button('Remove ${browser.name}'), findsOneWidget);
      expect(button('Remove ${self.name}'), findsNothing);
      expect(button('Change security keys'), findsOneWidget);
      semantics.dispose();
    });

    // Task 33: a ready device's encrypted backup, in the desktop's words, and nothing of it on another.
    testWidgets(
      'say how the encrypted backup is on a ready device: up to date, going up, restoring, or paused and why',
      (tester) async {
        final repository = await pumpDevices(tester);
        expect(find.text('Encrypted backup'), findsOneWidget);
        expect(find.text('Backing up…'), findsOneWidget);
        for (final (shown, words) in [
          (BackupShown.upToDate, 'Up to date'),
          (const BackupShown.restoring(12, 40), 'Restoring your messages: 12 of 40'),
          (const BackupShown.paused(BackupPause.full), 'Your encrypted backup is paused: your storage is full.'),
          (
            const BackupShown.paused(BackupPause.tooLarge),
            'Your encrypted backup is paused: a day of messages is too large to back up.',
          ),
          (BackupShown.uploading, 'Backing up…'),
        ]) {
          repository.backup.value = shown;
          await tester.pumpAndSettle();
          expect(find.text(words), findsOneWidget, reason: '$shown');
        }
        repository.encryption.value = EngineState.newDevice;
        await tester.pumpAndSettle();
        expect(find.text('Encrypted backup'), findsNothing);
        semantics.dispose();
      },
    );

    for (final (state, name) in [
      (EngineState.newDevice, 'a new device'),
      (const EngineState.rotation(), 'a rotation cut before its upload'),
    ]) {
      testWidgets('offer neither on $name', (tester) async {
        await pumpDevices(tester, state: state);
        expect(button('Remove ${computer.name}'), findsNothing);
        expect(button('Change security keys'), findsNothing);
        semantics.dispose();
      });
    }

    testWidgets('removing another device asks first, and one that was lost goes with new keys', (tester) async {
      final repository = await pumpDevices(tester);
      await tapLabel(tester, 'Remove ${computer.name}');
      expect(find.text('Remove ${computer.name}?'), findsOneWidget);
      await tapLabel(tester, 'Remove');
      expect(repository.encryptionTaps, ['removeDevice ${computer.id}']);

      await tapLabel(tester, 'Remove ${computer.name}');
      await tapLabel(tester, 'Remove and change keys');
      expect(repository.encryptionTaps.last, 'removeDevice ${computer.id}, changeKeys');

      // A device never set up holds no keys: it only goes.
      await tapLabel(tester, 'Remove ${browser.name}');
      expect(find.bySemanticsLabel('Remove and change keys'), findsNothing);
      await tapLabel(tester, 'Remove');
      expect(repository.encryptionTaps.last, 'removeDevice ${browser.id}');
      semantics.dispose();
    });

    testWidgets('changing the security keys asks first', (tester) async {
      final repository = await pumpDevices(tester);
      await tapLabel(tester, 'Change security keys');
      await tapLabel(tester, 'Cancel');
      expect(repository.encryptionTaps, isEmpty);
      await tapLabel(tester, 'Change security keys');
      await tapLabel(tester, 'Change keys');
      expect(repository.encryptionTaps, ['changeKeys']);
      semantics.dispose();
    });

    for (final (state, offered) in [
      (EngineState.ready, true),
      (EngineState.newDevice, true),
      (EngineState.unsupported, false),
      (EngineState.locked, false),
      (EngineState.starting, false),
    ]) {
      testWidgets("offer to delete this device's data where it has some: ${state.stage.name}", (tester) async {
        await pumpDevices(tester, state: state);
        expect(button(Notice.deleteDevice.text), offered ? findsOneWidget : findsNothing);
        semantics.dispose();
      });
    }

    testWidgets("deleting this device's data warns first that its history goes without the recovery key, when it's the "
        'only one', (tester) async {
      final repository = await pumpDevices(tester, devices: [self, browser]);
      await tapLabel(tester, Notice.deleteDevice.text);
      expect(find.textContaining('only device'), findsOneWidget);
      await tapLabel(tester, 'Delete');
      expect(repository.encryptionTaps, ['removeThisDevice']);
      // Signed out, with the welcome screen in front: no page of the account stays over it.
      expect(repository.profile.value, isNull);
      expect(find.text('Talk with your people.'), findsOneWidget);
      expect(find.byType(GlassTopBar), findsNothing);
      semantics.dispose();
    });

    // Review 24's I2 and M6: the question follows the devices. Every listed device's names the recovery key, as one
    // whose data went stays listed: the client can't tell a phantom from a device that holds the history.
    final unset = device(
      '0193a4b2-0000-7000-8000-0000000000a4',
      'Pixel 8 Pro',
      'android/1.1.0',
      current: true,
      listed: false,
    );
    for (final (name, state, devices, says, saysNot) in [
      (
        'the only device',
        EngineState.ready,
        [self, browser],
        ['This is your only device', 'recovery key'],
        ['stays on your device list'],
      ),
      (
        'one beside others',
        EngineState.ready,
        [self, computer, browser],
        [
          'Without your recovery key, their history is lost unless another of your devices still holds it.',
          'This device stays on your device list until you remove it on another device.',
        ],
        ['This is your only device'],
      ),
      (
        'one not set up',
        EngineState.newDevice,
        [unset, computer],
        ["Delete this device's"],
        ['recovery key', 'stays on your device list'],
      ),
      (
        'an unread list',
        EngineState.ready,
        null,
        ['This is your only device', 'recovery key'],
        ['stays on your device list'],
      ),
    ]) {
      testWidgets("deleting this device's data asks as its devices make it: $name", (tester) async {
        final repository = await pumpDevices(tester, state: state, devices: devices, failed: devices == null);
        await tapLabel(tester, Notice.deleteDevice.text);
        for (final words in says) {
          expect(find.textContaining(words), findsOneWidget, reason: words);
        }
        for (final words in saysNot) {
          expect(find.textContaining(words), findsNothing, reason: words);
        }
        await tapLabel(tester, 'Cancel');
        expect(repository.encryptionTaps, isEmpty);
        semantics.dispose();
      });
    }

    // Review 24's M1 and I1, and review 25's I1: while a key change waits, the page finishes it, the banner's ×
    // notwithstanding; one that can't finish says why, and the one way out this core leaves: this device's data
    // deleted and set up again, as another device's change of keys can't reach it (duvetchat/e2e#49).
    testWidgets("while a key change waits, Finish it here; one that can't finish says why, and that deleting this "
        "device's data gets out", (tester) async {
      final repository = await pumpDevices(tester, state: const EngineState.rotation());
      await tapLabel(tester, 'Finish changing your security keys');
      expect(repository.encryptionTaps, ['changeKeys']);
      repository.encryption.value = const EngineState.rotation(stuck: true);
      await tester.pumpAndSettle();
      expect(button('Finish changing your security keys'), findsNothing);
      expect(find.textContaining("This change of your security keys can't finish"), findsOneWidget);
      expect(find.textContaining("the recovery key it showed won't work"), findsOneWidget);
      expect(find.textContaining("delete this device's data and set it up again"), findsOneWidget);
      expect(find.textContaining('on another device'), findsNothing);
      expect(button(Notice.deleteDevice.text), findsOneWidget);
      semantics.dispose();
    });

    // Review 24's M3: a removal of this device's that the API didn't take rides along with the next list or key change,
    // which names it.
    testWidgets('a removal and a change of keys name the devices an earlier removal takes along', (tester) async {
      final repository = await pumpDevices(tester);
      await tapLabel(tester, 'Remove ${computer.name}');
      expect(find.textContaining('This also removes'), findsNothing);
      await tapLabel(tester, 'Cancel');

      repository.devicesAlongList = (unsent: [browser.id], unregistered: const []);
      final along = "This also removes ${browser.name}, whose earlier removal didn't finish.";
      await tapLabel(tester, 'Remove ${computer.name}');
      expect(find.textContaining(along), findsOneWidget);
      await tapLabel(tester, 'Cancel');
      await tapLabel(tester, 'Change security keys');
      expect(find.textContaining(along), findsOneWidget);
      await tapLabel(tester, 'Cancel');
      // Two, the second one the API's list no longer has: named by the start of its ID.
      repository.devicesAlongList = (
        unsent: [browser.id, '0193a4b2-0000-7000-8000-00000000ffff'],
        unregistered: const [],
      );
      await tapLabel(tester, 'Change security keys');
      expect(
        find.textContaining("This also removes ${browser.name} and 0193a4b2, whose earlier removal didn't finish."),
        findsOneWidget,
      );
      await tapLabel(tester, 'Cancel');
      expect(repository.encryptionTaps, isEmpty);
      semantics.dispose();
    });

    // I2 of step 4's closing review: a device the list names that the API no longer lists rides along too, which a
    // server that answers a short listing chooses: the confirmation names it, and only its yes takes it off.
    testWidgets('a removal and a change of keys name the devices the API no longer lists, and take them on the yes', (
      tester,
    ) async {
      final repository = await pumpDevices(tester);
      const unlisted = '0193a4b2-0000-7000-8000-00000000eeee';
      repository.devicesAlongList = (unsent: const [], unregistered: const [unlisted]);
      const along = "Duvet no longer lists 0193a4b2. If you didn't remove it or change your password, cancel.";
      await tapLabel(tester, 'Remove ${computer.name}');
      expect(find.textContaining(along), findsOneWidget);
      await tapLabel(tester, 'Remove');
      await tapLabel(tester, 'Change security keys');
      expect(find.textContaining(along), findsOneWidget);
      await tapLabel(tester, 'Change keys');
      expect(repository.encryptionTaps, [
        'removeDevice ${computer.id}, named $unlisted',
        'changeKeys, named $unlisted',
      ]);
      semantics.dispose();
    });

    // N-M7 of step 4's closing re-review: a device the API no longer lists is named by what this device knows of it,
    // its name, its client and when it was added, and by the start of its ID only when nothing is known; the question
    // says what's known, never why the server says it went.
    testWidgets('a device the API no longer lists is named by what this device knows of it', (tester) async {
      final repository = await pumpDevices(tester);
      const known = '0193a4b2-0000-7000-8000-00000000eeee';
      const unknown = '0193a4b2-0000-7000-8000-00000000dddd';
      repository.knownDevices[known] = (name: 'Old tablet', client: 'android/1.0.0', added: DateTime(2026, 10, 20));
      repository.devicesAlongList = (unsent: const [], unregistered: const [known, unknown]);
      await tapLabel(tester, 'Remove ${computer.name}');
      expect(
        find.textContaining(
          'Duvet no longer lists Old tablet (android/1.0.0, added 20 October 2026) and 0193a4b2. '
          "If you didn't remove them or change your password, cancel.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('password change took'), findsNothing);
      await tapLabel(tester, 'Cancel');
      expect(repository.encryptionTaps, isEmpty);
      semantics.dispose();
    });

    // Review 25's M2: the page reads the list again as the encryption's state changes, as the desktop's does: a lost
    // device goes once the change of keys that removes it is up.
    testWidgets("read again as the encryption's state changes: a lost device goes once its key change is up", (
      tester,
    ) async {
      final repository = await pumpDevices(tester, state: const EngineState.rotation());
      expect(find.textContaining(computer.name), findsOneWidget);
      // Its change of keys went up: the API took the lost device off.
      repository.deviceList = [self, browser];
      repository.encryption.value = EngineState.ready;
      await tester.pumpAndSettle();
      expect(find.textContaining(computer.name), findsNothing);
      semantics.dispose();
    });

    testWidgets("say when they're loading, and when they couldn't be read, with Try again", (tester) async {
      final repository = await pumpDevices(tester, failed: true);
      expect(find.text("Couldn't load your devices."), findsOneWidget);
      repository.deviceList = [self];
      await tapLabel(tester, 'Try again');
      expect(find.text("Couldn't load your devices."), findsNothing);
      expect(find.text('This device'), findsOneWidget);
      semantics.dispose();
    });
  });

  // Decision 13: signing out only ends the session; deleting this device's data is an act of its own, beside it.
  testWidgets("Sign out asks, and offers to remove this device and delete its data", (tester) async {
    final repository = await pumpYou(tester);
    repository.encryption.value = EngineState.ready;
    await open(tester, 'Sign out');
    expect(find.bySemanticsLabel(Notice.deleteDevice.text), findsOneWidget);
    await tapLabel(tester, 'Cancel');
    expect(repository.profile.value, isNotNull);

    await open(tester, 'Sign out');
    await tapLabel(tester, Notice.deleteDevice.text);
    // Its own question, then the data goes, and the session with it.
    await tapLabel(tester, 'Delete');
    expect(repository.encryptionTaps, ['removeThisDevice']);
    expect(repository.profile.value, isNull);
    semantics.dispose();
  });

  testWidgets('Sign out in the dialog only signs out', (tester) async {
    final repository = await pumpYou(tester);
    repository.encryption.value = EngineState.ready;
    await open(tester, 'Sign out');
    await tapLabel(tester, RegExp(r'^Sign out$'));
    expect(repository.profile.value, isNull);
    expect(repository.encryptionTaps, isEmpty);
    semantics.dispose();
  });

  testWidgets("what the engine tells of the user's devices shows over every screen", (tester) async {
    final repository = await pumpYou(tester);
    final added = Notice.deviceAdded.fill({'name': 'Pixel 8 Pro'});
    repository.deviceNoticesTold.add(added);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(added), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    semantics.dispose();
  });
}
