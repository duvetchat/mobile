import 'dart:async';
import 'dart:convert';

import 'package:duvet/data/sounds.dart';
import 'package:duvet/sounds_settings.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

class _Player implements SoundPlayer {
  final played = <(Sound, double, bool)>[];
  final stopped = <Sound>[];
  bool disposed = false;

  @override
  Future<void> play(Sound sound, double gain, {bool loop = false}) async => played.add((sound, gain, loop));

  @override
  Future<void> stop(Sound sound) async => stopped.add(sound);

  @override
  Future<void> dispose() async => disposed = true;
}

class _Ringer implements RingerMode {
  bool isQuiet = false;

  /// While set, [quiet] waits on it: a ring stopped mid-check.
  Completer<void>? hold;

  @override
  Future<bool> quiet() async {
    await hold?.future;
    return isQuiet;
  }
}

/// M13 · Sounds.
void main() {
  late _Player player;
  late _Ringer ringer;
  late Sounds sounds;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    player = _Player();
    ringer = _Ringer();
    sounds = Sounds(player: player, ringer: ringer);
  });

  test('every volume starts at 100, a quarter of full gain as on the desktop', () {
    expect(sounds.master, 100);
    for (final s in Sound.values) {
      expect(sounds.volume(s), 100);
      expect(sounds.gain(s), 0.25);
    }
  });

  test('the gain is master/200 times volume/200', () async {
    await sounds.setMaster(200);
    await sounds.setVolume(Sound.mention, 200);
    await sounds.setVolume(Sound.voiceJoin, 100);
    expect(sounds.gain(Sound.mention), 1.0);
    expect(sounds.gain(Sound.voiceJoin), 0.5);
  });

  test('volumes stay within 0 and 200', () async {
    await sounds.setMaster(500);
    await sounds.setVolume(Sound.voiceLeave, -3);
    expect(sounds.master, 200);
    expect(sounds.volume(Sound.voiceLeave), 0);
  });

  test('a sound at zero, or everything at zero, plays nothing', () async {
    await sounds.setVolume(Sound.mention, 0);
    await sounds.setVolume(Sound.incomingCall, 0);
    await sounds.play(Sound.mention);
    await sounds.startRing();
    expect(player.played, isEmpty);
    await sounds.setVolume(Sound.incomingCall, 100);
    await sounds.setMaster(0);
    await sounds.play(Sound.voiceJoin);
    await sounds.startRing();
    expect(player.played, isEmpty);
  });

  test('a sound plays once at its gain', () async {
    await sounds.play(Sound.voiceJoin);
    expect(player.played, [(Sound.voiceJoin, 0.25, false)]);
  });

  test('volumes are kept on the device', () async {
    await sounds.setMaster(150);
    await sounds.setVolume(Sound.screenShareOn, 40);
    final again = Sounds(player: _Player(), ringer: ringer);
    await again.load();
    expect(again.master, 150);
    expect(again.volume(Sound.screenShareOn), 40);
    expect(again.volume(Sound.mention), 100);
  });

  test('missing, corrupt or out of range values load as the defaults or the bounds', () async {
    FlutterSecureStorage.setMockInitialValues({'duvet.sounds': '{not json'});
    final corrupt = Sounds(player: player, ringer: ringer);
    await corrupt.load();
    expect(corrupt.master, 100);

    FlutterSecureStorage.setMockInitialValues({
      'duvet.sounds': jsonEncode({'master': 999, 'mention': -5, 'voiceJoin': 'loud'}),
    });
    final odd = Sounds(player: player, ringer: ringer);
    await odd.load();
    expect(odd.master, 200);
    expect(odd.volume(Sound.mention), 0);
    expect(odd.volume(Sound.voiceJoin), 100);
    expect(odd.volume(Sound.voiceLeave), 100);
  });

  test('in Do not disturb or on silent nothing plays or rings, but a preview does', () async {
    ringer.isQuiet = true;
    await sounds.play(Sound.mention);
    await sounds.startRing();
    expect(player.played, isEmpty);
    await sounds.preview(Sound.incomingCall);
    expect(player.played, [(Sound.incomingCall, 0.25, false)]);
  });

  test('the ring loops once until stopped, and stopping twice or without a ring is safe', () async {
    await sounds.stopRing();
    expect(player.stopped, isEmpty);
    await sounds.startRing();
    await sounds.startRing();
    expect(player.played, [(Sound.incomingCall, 0.25, true)]);
    await sounds.stopRing();
    await sounds.stopRing();
    expect(player.stopped, [Sound.incomingCall]);
    // It can ring again after.
    await sounds.startRing();
    expect(player.played, hasLength(2));
  });

  test('a ring stopped while checking the ringer never starts', () async {
    ringer.hold = Completer();
    final start = sounds.startRing();
    final second = sounds.startRing();
    await sounds.stopRing();
    ringer.hold!.complete();
    await (start, second).wait;
    expect(player.played, isEmpty);
  });

  test('disposing stops the player', () {
    sounds.dispose();
    expect(player.disposed, isTrue);
  });

  testWidgets('the page moves the volumes and plays a preview', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: SoundsPage(sounds: sounds),
        ),
      ),
    );
    for (final label in ['Master Volume', 'Mentions', 'Join Voice', 'Leave Voice', 'Incoming Call']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.bySemanticsLabel('Play Master Volume'), findsNothing);

    final master = find.byType(Slider).first;
    await tester.drag(master, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(sounds.master, 200);
    expect(find.text('200%'), findsOneWidget);

    final mentions = find.byType(Slider).at(1);
    await tester.drag(mentions, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(sounds.volume(Sound.mention), 0);
    expect(find.text('Off'), findsOneWidget);

    ringer.isQuiet = true;
    await tester.tap(find.bySemanticsLabel('Play Join Voice'));
    await tester.pumpAndSettle();
    expect(player.played, [(Sound.voiceJoin, 0.5, false)]);
    semantics.dispose();
  });
}
