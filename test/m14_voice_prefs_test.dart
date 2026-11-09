import 'dart:async';
import 'dart:convert';

import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/data/voice_prefs.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/sounds_settings.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// Secure storage whose reads wait on [gate]: a load still out when the user
/// changes something.
class _SlowStorage extends FlutterSecureStorage {
  final gate = Completer<void>();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = await super.read(key: key);
    await gate.future;
    return value;
  }
}

class _Player implements SoundPlayer {
  @override
  Future<void> play(Sound sound, double gain, {bool loop = false}) async {}

  @override
  Future<void> stop(Sound sound) async {}

  @override
  Future<void> dispose() async {}
}

class _Ringer implements RingerMode {
  @override
  Future<bool> quiet() async => false;
}

class _Links implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

Future<Map<String, dynamic>> _stored() async =>
    jsonDecode((await const FlutterSecureStorage().read(key: 'duvet.voice_prefs'))!) as Map<String, dynamic>;

/// M14 · Voice prefs.
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('faces are off and noise suppression on until the user says otherwise', () async {
    final prefs = VoicePrefs();
    await prefs.load();
    expect(prefs.facesInVoice, isFalse);
    expect(prefs.noiseSuppression, isTrue);
  });

  test('both are kept on the device', () async {
    final prefs = VoicePrefs();
    await prefs.setFacesInVoice(true);
    await prefs.setNoiseSuppression(false);
    expect(await _stored(), {'facesInVoice': true, 'noiseSuppression': false});

    final again = VoicePrefs();
    var notified = 0;
    again.addListener(() => notified++);
    await again.load();
    expect((again.facesInVoice, again.noiseSuppression, notified), (true, false, 1));
  });

  test('a corrupt or foreign value reads as the defaults', () async {
    for (final raw in ['{not json', '[]', '{"facesInVoice": "yes", "noiseSuppression": 0}']) {
      FlutterSecureStorage.setMockInitialValues({'duvet.voice_prefs': raw});
      final prefs = VoicePrefs();
      await prefs.load();
      expect((prefs.facesInVoice, prefs.noiseSuppression), (false, true), reason: raw);
    }
  });

  test('a load landing after a change keeps the change, and the rest of what was stored', () async {
    FlutterSecureStorage.setMockInitialValues({
      'duvet.voice_prefs': jsonEncode({'facesInVoice': true, 'noiseSuppression': false}),
    });
    final storage = _SlowStorage();
    final prefs = VoicePrefs(storage: storage);
    final loading = prefs.load();
    await prefs.setFacesInVoice(false);
    storage.gate.complete();
    await loading;
    expect((prefs.facesInVoice, prefs.noiseSuppression), (false, false));
    expect(await _stored(), {'facesInVoice': false, 'noiseSuppression': false});
  });

  group('the Voice section', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      EmojiCatalog.debugUse(await EmojiCatalog.load());
    });

    Future<(VoicePrefs, Sounds)> pumpYou(WidgetTester tester) async {
      DeepLinkSource.instance = _Links();
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final prefs = VoicePrefs();
      final sounds = Sounds(player: _Player(), ringer: _Ringer());
      await tester.pumpWidget(
        VoicePrefsScope(
          prefs: prefs,
          child: SoundsScope(
            sounds: sounds,
            child: DuvetApp(repository: FakeRepository(), appearance: Appearance(MemoryAppearanceStore())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
      await tester.pumpAndSettle();
      return (prefs, sounds);
    }

    Finder switchFor(String label) => find.byWidgetPredicate((w) => w is DuvetSwitch && w.label == label);

    testWidgets('its switches turn faces and noise suppression on and off', (tester) async {
      final (prefs, _) = await pumpYou(tester);
      expect(find.text('Voice tiles show everyone’s animated face instead of their picture'), findsOneWidget);
      expect(find.text('Filters background noise from your microphone'), findsOneWidget);

      await tester.ensureVisible(switchFor('Faces in voice'));
      await tester.pumpAndSettle();
      await tester.tap(switchFor('Faces in voice'));
      await tester.pumpAndSettle();
      expect(prefs.facesInVoice, isTrue);
      expect(tester.widget<DuvetSwitch>(switchFor('Faces in voice')).value, isTrue);

      await tester.tap(switchFor('Noise suppression'));
      await tester.pumpAndSettle();
      expect(prefs.noiseSuppression, isFalse);
      expect(tester.widget<DuvetSwitch>(switchFor('Noise suppression')).value, isFalse);
    });

    testWidgets('Sounds opens the sounds page', (tester) async {
      final (_, sounds) = await pumpYou(tester);
      final row = find.text('Sounds');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.widget<SoundsPage>(find.byType(SoundsPage)).sounds, same(sounds));
    });
  });

  group('VoiceFace', () {
    Future<void> pumpFace(WidgetTester tester, double level, {bool reduce = false}) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: VoiceFace(name: 'Ada', level: level),
          ),
        ),
      ),
    );

    double mouth(WidgetTester tester) => tester.widget<Facehash>(find.byType(Facehash)).mouthOpen;

    testWidgets('a circle named for the person, its mouth easing open with their level', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFace(tester, 0);
      expect(find.bySemanticsLabel('Ada'), findsOneWidget);
      expect(tester.getSize(find.byType(VoiceFace)), const Size(72, 72));
      expect(find.byType(ClipOval), findsOneWidget);
      expect(mouth(tester), 0);

      await pumpFace(tester, 0.8);
      await tester.pump(const Duration(milliseconds: 50));
      expect(mouth(tester), inExclusiveRange(0, 0.8));
      await tester.pumpAndSettle();
      expect(mouth(tester), closeTo(0.8, 1e-9));

      await pumpFace(tester, 3);
      await tester.pumpAndSettle();
      expect(mouth(tester), 1);
      semantics.dispose();
    });

    testWidgets('with animations off the mouth follows the level at once', (tester) async {
      await pumpFace(tester, 0, reduce: true);
      await pumpFace(tester, 0.5, reduce: true);
      await tester.pump();
      expect(mouth(tester), 0.5);
    });
  });
}
