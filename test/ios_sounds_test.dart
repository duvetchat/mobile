import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:video_player/video_player.dart';

/// A video that loads at once and plays without a platform.
class _Video extends VideoPlayerController {
  _Video(super.url) : super.networkUrl();

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true, size: const Size(16, 9), duration: const Duration(seconds: 3));
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
}

/// #228 · The sounds on iOS: each platform's own files, and the player over ios/Runner/Sounds.swift.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chat.duvet/sounds');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  Object? failure;

  setUp(() {
    calls = [];
    failure = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failure case final e?) throw e;
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  // What ios/Runner/Sounds.swift sends when a play ends by itself.
  Future<void> done(int id) => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('done', id)),
    (_) {},
  );

  Map<Object?, Object?> args(MethodCall call) => call.arguments as Map<Object?, Object?>;

  test('Android keeps the .ogg and iOS takes the .m4a, and both are there for every sound', () {
    for (final sound in Sound.values) {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(sound.asset, 'assets/sounds/${sound.file}.ogg');
      expect(File(sound.asset).existsSync(), isTrue, reason: sound.asset);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(sound.asset, 'assets/sounds/ios/${sound.file}.m4a');
      // An MPEG-4 file: "ftyp" after the box's size.
      expect(String.fromCharCodes(File(sound.asset).readAsBytesSync().sublist(4, 8)), 'ftyp', reason: sound.asset);
    }
  });

  test("each platform's build takes only its own files", () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('    - path: assets/sounds/\n      platforms: [android]\n'));
    expect(pubspec, contains('    - path: assets/sounds/ios/\n      platforms: [ios]\n'));
    expect(Directory('assets/sounds').listSync().whereType<File>().every((f) => f.path.endsWith('.ogg')), isTrue);
    expect(Directory('assets/sounds/ios').listSync().whereType<File>().every((f) => f.path.endsWith('.m4a')), isTrue);
  });

  test('a play sends the asset, the gain, the loop and whether the audio is busy', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var busy = false;
    final player = IosSoundPlayer(busy: () => busy);
    await player.play(Sound.mention, 0.25);
    busy = true;
    await player.play(Sound.incomingCall, 0.5, loop: true);

    expect(calls.map((c) => c.method), ['play', 'play']);
    expect(args(calls[0]), {
      'id': 1,
      'asset': 'assets/sounds/ios/message_notification.m4a',
      'gain': 0.25,
      'loop': false,
      'aloud': false,
      'busy': false,
    });
    expect(args(calls[1]), {
      'id': 2,
      'asset': 'assets/sounds/ios/voice_calling.m4a',
      'gain': 0.5,
      'loop': true,
      'aloud': false,
      'busy': true,
    });
  });

  test('onDone runs when the play ends by itself, once', () async {
    final player = IosSoundPlayer();
    var ended = 0;
    await player.play(Sound.mention, 1, onDone: () => ended++);
    expect(ended, 0);
    await done(1);
    expect(ended, 1);
    await done(1);
    expect(ended, 1);
    // Nothing left to stop.
    await player.stop(Sound.mention);
    expect(calls.map((c) => c.method), ['play']);
    expect(ended, 1);
  });

  test('a stop stops that asset and ends the play', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final player = IosSoundPlayer();
    var ended = 0;
    await player.play(Sound.incomingCall, 1, loop: true, onDone: () => ended++);
    await player.stop(Sound.incomingCall);
    expect(calls.last.method, 'stop');
    expect(args(calls.last), {'asset': 'assets/sounds/ios/voice_calling.m4a'});
    expect(ended, 1);
  });

  test("playing a sound again ends its earlier play, whose late end isn't the new one's", () async {
    final player = IosSoundPlayer();
    final ended = <int>[];
    await player.play(Sound.voiceJoin, 1, onDone: () => ended.add(1));
    await player.play(Sound.voiceJoin, 1, onDone: () => ended.add(2));
    expect(ended, [1]);
    await done(1);
    expect(ended, [1]);
    await done(2);
    expect(ended, [1, 2]);
  });

  test("a play that fails throws and isn't playing", () async {
    final player = IosSoundPlayer();
    var ended = 0;
    failure = PlatformException(code: 'sounds');
    await expectLater(player.play(Sound.mention, 1, onDone: () => ended++), throwsA(isA<PlatformException>()));
    failure = null;
    await done(1);
    await player.stop(Sound.mention);
    expect(ended, 0);
    expect(calls.map((c) => c.method), ['play']);
  });

  test('dispose stops everything, and failing to is no error', () async {
    final player = IosSoundPlayer();
    var ended = 0;
    await player.play(Sound.mention, 1, onDone: () => ended++);
    failure = PlatformException(code: 'sounds');
    await player.dispose();
    expect(calls.last.method, 'dispose');
    await done(1);
    expect(ended, 0);
  });

  test('on iOS the sounds play through it, with the app saying when its audio is busy', () async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var busy = true;
    final sounds = Sounds(busy: () => busy);
    await sounds.play(Sound.voiceJoin);
    busy = false;
    await sounds.startRing();
    await sounds.stopRing();

    expect(calls.map((c) => c.method), ['play', 'play', 'stop']);
    expect(args(calls[0]), {
      'id': 1,
      'asset': 'assets/sounds/ios/join_vc.m4a',
      'gain': 0.25,
      'loop': false,
      'aloud': false,
      'busy': true,
    });
    expect(args(calls[1])['loop'], isTrue);
    expect(args(calls[1])['busy'], isFalse);
    // iOS doesn't say whether it wants quiet: the session's category does the muting.
    expect(await const PlatformRingerMode().quiet(), isFalse);
    sounds.dispose();
  });

  test('only a preview plays aloud on iOS: the user asked to hear it, switch on silent or not', () async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sounds = Sounds();
    await sounds.play(Sound.mention);
    await sounds.startRing();
    await sounds.preview(Sound.voiceLeave);

    expect(
      [for (final c in calls.where((c) => c.method == 'play')) (args(c)['asset'], args(c)['aloud'])],
      [
        ('assets/sounds/ios/message_notification.m4a', false),
        ('assets/sounds/ios/voice_calling.m4a', false),
        ('assets/sounds/ios/leave_vc.m4a', true),
      ],
    );
    sounds.dispose();
  });

  testWidgets('a video is playing from its start to its pause or its page closing', (tester) async {
    final build = VideoPage.controllerFor;
    late _Video video;
    VideoPage.controllerFor = (url) => video = _Video(url);
    addTearDown(() => VideoPage.controllerFor = build);
    Widget page(Widget child) => MaterialApp(
      theme: Duvet.material(Brightness.light),
      home: FTheme(data: Duvet.theme(Brightness.light), child: child),
    );
    const clip = MessageAttachment(id: 'v', filename: 'v.mp4', contentType: 'video/mp4', url: 'https://x/v.mp4');

    expect(VideoPage.playing, isFalse);
    await tester.pumpWidget(page(const VideoPage(attachment: clip)));
    await tester.pump();
    expect(VideoPage.playing, isTrue);
    await video.pause();
    expect(VideoPage.playing, isFalse);
    await video.play();
    expect(VideoPage.playing, isTrue);
    await tester.pumpWidget(page(const SizedBox()));
    expect(VideoPage.playing, isFalse);
  });

  group('the recorder', () {
    const record = MethodChannel('com.llfbandit.record/messages');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    Object? refused;

    setUp(() {
      refused = null;
      messenger.setMockMethodCallHandler(paths, (_) async => Directory.systemTemp.path);
      messenger.setMockMethodCallHandler(record, (call) async {
        if (call.method == 'start' && refused != null) throw refused!;
        return switch (call.method) {
          'hasPermission' => true,
          'isEncoderSupported' || 'isRecording' => false,
          _ => null,
        };
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(record, null);
    });

    test('is recording from a take\'s start to its stop or its cancel, however many end', () async {
      expect(RecordVoiceRecorder.recording, isFalse);
      final first = RecordVoiceRecorder();
      expect(await first.start(), isTrue);
      expect(RecordVoiceRecorder.recording, isTrue);
      await first.cancel();
      expect(RecordVoiceRecorder.recording, isFalse);
      // Ended twice: counted once.
      await first.cancel();
      expect(RecordVoiceRecorder.recording, isFalse);

      final second = RecordVoiceRecorder();
      await second.start();
      expect(RecordVoiceRecorder.recording, isTrue);
      // No file to read back: the take is over all the same.
      await expectLater(second.stop(), throwsA(isA<FileSystemException>()));
      expect(RecordVoiceRecorder.recording, isFalse);
    });

    test("a take that won't start isn't recording", () async {
      refused = PlatformException(code: 'record');
      await expectLater(RecordVoiceRecorder().start(), throwsA(isA<PlatformException>()));
      expect(RecordVoiceRecorder.recording, isFalse);
    });
  });

  test("a sound that can't play on iOS is no error", () async {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    failure = PlatformException(code: 'sounds');
    final sounds = Sounds();
    await sounds.play(Sound.mention);
    await sounds.preview(Sound.mention);
    expect(sounds.previewing.value, isNull);
    sounds.dispose();
  });
}
