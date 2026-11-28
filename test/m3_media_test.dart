import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:crypto/crypto.dart';
import 'package:duvet/chat_view.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/data/gifs.dart';
import 'package:duvet/data/links.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_emoji.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/apng.dart';
import 'package:duvet/widgets/attachment_link.dart';
import 'package:duvet/widgets/link_embeds.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/media_actions.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:duvet/widgets/playback_bar.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:duvet/widgets/sealed_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
const _space = '5a5a5a5a-0000-4000-8000-000000000001';
const _room = '5a5a5a5a-0000-4000-8000-000000000002';
const _linked = '5a5a5a5a-0000-4000-8000-000000000003';

class _Playback implements AudioPlayback {
  final played = <(String, String)>[];
  final calls = <String>[];
  final _state = ValueNotifier(PlaybackState.idle);
  @override
  ValueListenable<PlaybackState> get state => _state;

  /// The file the phone couldn't play, as a test says.
  final failedNow = ValueNotifier<String?>(null);
  @override
  ValueListenable<String?> get failed => failedNow;

  @override
  Future<void> play(
    String id,
    String url, {
    required String title,
    String? artist,
    String? artUrl,
    LinkSource? link,
  }) async {
    played.add((id, link == null ? url : await link()));
    _state.value = PlaybackState(
      id: id,
      title: title,
      artist: artist,
      playing: true,
      duration: const Duration(seconds: 14),
    );
  }

  void _playing(bool playing) {
    final s = _state.value;
    _state.value = PlaybackState(id: s.id, title: s.title, artist: s.artist, playing: playing, duration: s.duration);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing(false);
  }

  @override
  Future<void> seek(String id, Duration position) async {}

  final _speeds = ValueNotifier(const <String, double>{});
  @override
  ValueListenable<Map<String, double>> get speeds => _speeds;

  @override
  Future<void> setSpeed(String id, double speed) async => _speeds.value = {..._speeds.value, id: speed};

  @override
  Future<void> resume() async {
    calls.add('resume');
    _playing(true);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _state.value = PlaybackState.idle;
  }
}

class _Recorder implements VoiceRecorder {
  _Recorder() {
    last = this;
  }

  static int started = 0;
  static int cancelled = 0;

  /// The recorder the chat made last, whose levels a test plays.
  static _Recorder? last;
  final _levels = StreamController<double>.broadcast();

  /// The microphone's level, from 0 to 1, as the take goes on.
  void say(double level) => _levels.add(level);

  @override
  Future<bool> start() async {
    started++;
    return true;
  }

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<Recording?> stop() async => (bytes: [1, 2, 3], format: 'ogg', length: const Duration(seconds: 3));

  @override
  Future<void> cancel() async => cancelled++;
}

class _Actions extends MediaActions {
  final calls = <String>[];
  @override
  Future<bool> open(String url) async {
    calls.add('open $url');
    return true;
  }

  @override
  Future<bool> saveToGallery(String url, String name) async {
    calls.add('save $name');
    return true;
  }

  @override
  Future<void> share(String url, String name, String contentType) async => calls.add('share $name');

  /// The copies each Save and Share of a decrypted file was handed, by their paths.
  final paths = <String>[];

  @override
  Future<bool> saveFile(String path, String name, String type) async {
    calls.add('saveFile $name $type');
    paths.add(path);
    return true;
  }

  @override
  Future<void> shareFile(String path, String name, String type) async {
    calls.add('shareFile $name $type');
    paths.add(path);
  }
}

/// An opener of a conversation's files with no core and no API: each file opens to its own bytes ([plain], by ID), its
/// download held, after [progress] of it, while [hold] is set.
class _SealedOpener implements FileOpener {
  final plain = <String, Uint8List>{};
  Completer<void>? hold;
  double progress = 0;

  @override
  Future<Uint8List> download(String id, String url, int most, void Function(int received)? progress) async {
    if (hold case final held?) {
      progress?.call((most * this.progress).floor());
      await held.future;
    }
    return Uint8List(most);
  }

  @override
  Future<Uint8List> open(String key, String id, Uint8List sealed, void Function(int done)? progress) async =>
      plain[id]!;

  @override
  void failed() {}
}

/// A player that never finishes loading: its slot stays taken.
class _PendingVideo extends VideoPlayerController {
  _PendingVideo(super.url) : super.networkUrl();

  @override
  Future<void> initialize() => Completer<void>().future;
}

/// A video that loads at once and plays without a platform.
class _PlayingVideo extends VideoPlayerController {
  _PlayingVideo(super.url) : super.networkUrl();

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true, size: const Size(16, 9), duration: const Duration(seconds: 3));
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
}

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

class _Gifs implements GifSource {
  final searched = <String>[];
  static const party = Gif(
    id: 'g1',
    url: 'https://static.klipy.com/party.gif',
    preview: 'https://static.klipy.com/party-tiny.gif',
    width: 200,
    height: 150,
    description: 'party',
  );

  @override
  String get attribution => 'GIFs from KLIPY';

  /// The GIFs whose bytes were asked for: an encrypted conversation sends them sealed.
  final fetched = <String>[];

  @override
  Future<Uint8List?> bytes(String url) async {
    fetched.add(url);
    return Uint8List.fromList([...ascii.encode('GIF89a'), ...List.filled(64, 1)]);
  }

  List<Gif> trend = const [party];

  @override
  Future<List<Gif>> trending() async => trend;

  @override
  Future<List<Gif>> search(String query) async {
    searched.add(query);
    return const [party];
  }
}

/// M3 · Media.
void main() {
  late SemanticsHandle semantics;
  late _Playback playback;
  late _Actions actions;

  // On the real clock, before any chat starts loading it on the fake one.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  setUp(() {
    playback = _Playback();
    AudioPlayback.instance = playback;
    actions = _Actions();
    MediaActions.instance = actions;
    VoiceRecorder.create = _Recorder.new;
    _Recorder.started = 0;
    _Recorder.cancelled = 0;
    ChatView.debugPickMedia = null;
    ChatView.debugPickFiles = null;
  });

  Future<FakeRepository> pumpApp(WidgetTester tester, {ReplyGesture reply = ReplyGesture.swipeLeft}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    final appearance = Appearance(MemoryAppearanceStore()..replyGesture = reply.name);
    await appearance.load();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<FakeRepository> openMaya(
    WidgetTester tester, {
    void Function(FakeRepository r)? setUp,
    ReplyGesture reply = ReplyGesture.swipeLeft,
  }) async {
    final repository = await pumpApp(tester, reply: reply);
    setUp?.call(repository);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
  }

  /// What the chat sends once the file its GIF went to is written, on the real clock.
  Future<void> sentOnRealClock(WidgetTester tester, FakeRepository repository) async {
    for (var i = 0; i < 50 && repository.sent.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  ChatMessage withFiles(String id, List<MessageAttachment> files, {bool voice = false}) => ChatMessage(
    id: id,
    authorId: _maya,
    authorName: 'Maya',
    content: '',
    createdAt: DateTime(2026, 10, 23, 10),
    attachments: files,
    isVoice: voice,
  );

  test('an APNG decodes to its frames, each at most the box wide, with its delay; a still PNG to none', () {
    final animated = img.Image(width: 8, height: 4)
      ..frameDuration = 40
      ..addFrame(img.Image(width: 8, height: 4)..frameDuration = 0)
      ..loopCount = 0;
    final frames = ApngImage.decode(img.PngEncoder().encode(animated), 4)!;
    expect(frames.length, 2);
    expect((frames[0].width, frames[0].height), (4, 2));
    expect(frames[0].rgba.length, 4 * 2 * 4);
    expect((frames[0].ms, frames[1].ms), (40, 100));
    expect(ApngImage.decode(img.encodePng(img.Image(width: 2, height: 2)), 4), isNull);
    expect(const MessageAttachment(id: 'a', filename: 'a.apng', contentType: 'image/apng', url: 'x').isGif, isTrue);
  });

  testWidgets('an APNG attachment plays: fetched, decoded off the UI thread, its frames turned by a ticker', (
    tester,
  ) async {
    final red = img.Image(width: 4, height: 4)..frameDuration = 50;
    img.fill(red, color: img.ColorRgb8(255, 0, 0));
    final blue = img.Image(width: 4, height: 4)..frameDuration = 50;
    img.fill(blue, color: img.ColorRgb8(0, 0, 255));
    final bytes = img.PngEncoder().encode(red..addFrame(blue));
    final fetched = <String>[];
    ApngImage.fetch = (url, local) async {
      fetched.add('$url:$local');
      return bytes;
    };
    const a = MessageAttachment(
      id: 'a',
      filename: 'wave.apng',
      contentType: 'image/apng',
      url: 'https://cdn.invalid/wave.apng',
      width: 4,
      height: 4,
    );
    // A decoded frame on screen (the still's own RawImage holds no image yet).
    final frame = find.byWidgetPredicate((w) => w is RawImage && w.image != null);
    // The fetch and the isolate's decode run in real time, not the test clock.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Duvet.material(Brightness.light),
          home: FTheme(
            data: Duvet.theme(Brightness.light),
            child: const Scaffold(
              body: MessageAttachments(attachments: [a], maxWidth: 200, messageId: 'm'),
            ),
          ),
        ),
      );
      expect(find.text('GIF'), findsOneWidget);
      expect(find.byType(ApngImage), findsOneWidget);
      expect(frame, findsNothing);
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();
    expect(fetched, ['https://cdn.invalid/wave.apng:false']);
    final first = tester.widget<RawImage>(frame).image;
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<RawImage>(frame).image, isNot(same(first)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<RawImage>(frame).image, same(first));
  });

  testWidgets('a WebP is a picture, not a file tile, at its own ratio', (tester) async {
    const a = MessageAttachment(
      id: 'w',
      filename: 'tall.webp',
      contentType: 'image/webp',
      url: 'https://cdn.invalid/tall.webp',
      width: 100,
      height: 400,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: const Scaffold(
            body: MessageAttachments(attachments: [a], maxWidth: 200, messageId: 'm'),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('^Photo, tall.webp')), findsOneWidget);
    // 4:1 tall: 320 high, 80 wide, so nothing of it is cropped.
    expect(tester.getSize(find.byType(Image)), const Size(80, 320));
  });

  testWidgets('at most 3 videos load their first frame at once; a tile gone frees its slot', (tester) async {
    var made = 0;
    final build = VideoPage.controllerFor;
    VideoPage.controllerFor = (url) {
      made++;
      // One that failed would free its slot for the next.
      return _PendingVideo(url);
    };
    addTearDown(() => VideoPage.controllerFor = build);
    Widget tiles(int count) => MaterialApp(
      theme: Duvet.material(Brightness.light),
      home: FTheme(
        data: Duvet.theme(Brightness.light),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < count; i++)
                  VideoTile(
                    attachment: MessageAttachment(
                      id: 'v$i',
                      filename: 'v$i.mp4',
                      contentType: 'video/mp4',
                      url: 'https://x/v$i.mp4',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(tiles(5));
    expect(find.byType(VideoTile), findsNWidgets(5));
    expect(find.byType(PlayMark), findsNWidgets(5));
    expect(made, 3);
    await tester.pumpWidget(tiles(0));
    await tester.pumpWidget(tiles(5));
    expect(made, 6);
  });

  group('links', () {
    test('message links, invites and deep links, as desktop reads them', () {
      final room = parseMessageLink('https://duvet.chat/channels/$_space/$_room/$_linked')!;
      expect((room.spaceId, room.roomId, room.messageId), (_space, _room, _linked));
      final dm = parseMessageLink('duvet://conversations/$_room/$_linked')!;
      expect((dm.conversationId, dm.messageId), (_room, _linked));
      expect(parseMessageLink('https://duvet.chat/channels/a/b/c'), isNull);
      // A copied link reads back to its message.
      final copied = parseMessageLink(messageLink(const RoomTarget(spaceId: _space, roomId: _room), _linked))!;
      expect((copied.spaceId, copied.roomId, copied.messageId), (_space, _room, _linked));
      expect(parseMessageLink(messageLink(const ConversationTarget(_room), _linked))!.conversationId, _room);
      expect(parseMessageLink('https://evil.example/channels/$_space/$_room/$_linked'), isNull);

      expect(parseInviteCode('https://duvet.chat/invite?code=paper-club'), 'paper-club');
      expect(parseInviteCode('https://duvet.chat/invite/paper-club'), 'paper-club');
      expect(parseInviteCode('duvet://invite/paper-club'), 'paper-club');
      expect(parseInviteCode('https://duvet.chat/invite'), isNull);
      expect(parseDeepLink('duvet://invite/x'), isA<OpenInvite>());
      expect(parseDeepLink('https://example.com'), isNull);
    });

    // #234: the closing markers of emphasis around a link were the card's, which asked for invite `abc**`.
    test('a card names the link the text shows, emphasis around it or not', () {
      const invite = 'https://duvet.chat/invite/abc';
      for (final text in [
        '**$invite**',
        '*$invite*',
        '__${invite}__',
        '_${invite}_',
        '~~$invite~~',
        '***$invite***',
        '**join us: $invite**',
        '**$invite**.',
        '**$invite**!',
        '(**$invite**)',
        '**$invite.**',
        '[join us]($invite)',
        '[$invite](https://example.org)',
        '`$invite`',
        '**_${invite}_**',
        '~~**$invite**~~',
      ]) {
        expect(duvetLinksIn(text), [invite], reason: text);
      }
      const bot = 'https://duvet.chat/invite?bot=$_room';
      expect(duvetLinksIn('_${bot}_'), [bot]);
      const message = 'https://duvet.chat/channels/$_space/$_room/$_linked';
      expect(duvetLinksIn('~~$message~~ and **$bot**'), [message, bot]);
      // A URL's own * and _, which nothing before it opens, stay.
      expect(duvetLinksIn('**https://duvet.chat/invite/a_b**'), ['https://duvet.chat/invite/a_b']);
      expect(duvetLinksIn('see https://duvet.chat/invite/a*b*'), ['https://duvet.chat/invite/a*b*']);
      expect(duvetLinksIn('see https://duvet.chat/invite/x**'), ['https://duvet.chat/invite/x**']);
      expect(duvetLinksIn('snake_https://duvet.chat/invite/y_'), ['https://duvet.chat/invite/y_']);
    });

    test('KLIPY results, upload shares, fallback waveforms', () {
      final gifs = KlipyGifs.parse({
        'result': true,
        'data': {
          'data': [
            {
              'id': 7,
              'type': 'gif',
              'title': 'cat dance',
              'file': {
                'md': {
                  'gif': {'url': 'https://k/g.gif', 'width': 400, 'height': 300},
                },
                'sm': {
                  'gif': {'url': 'https://k/small.gif', 'width': 200, 'height': 150},
                },
              },
            },
            {'id': 8, 'type': 'ad'},
          ],
        },
      });
      expect(
        (gifs.single.url, gifs.single.preview, gifs.single.width),
        ('https://k/g.gif', 'https://k/small.gif', 200),
      );

      const files = [
        MessageAttachment(id: 'a', filename: 'a', contentType: 'image/png', url: '', sizeBytes: 100),
        MessageAttachment(id: 'b', filename: 'b', contentType: 'image/png', url: '', sizeBytes: 300),
      ];
      expect(fileProgress(files, 0, 0.5), 1);
      expect(fileProgress(files, 1, 0.5), closeTo(1 / 3, 0.001));
      expect(uploadingIndex(files, 0.5), 1);

      expect(fallbackBars('abc', 5), fallbackBars('abc', 5));
      expect(fallbackBars('abc', 30).every((b) => b >= 0.15 && b <= 1), isTrue);
    });
  });

  testWidgets('a voice note plays from its bubble', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('v', const [
          MessageAttachment(
            id: 'att-v',
            filename: 'voice-note.webm',
            contentType: 'audio/webm',
            url: 'https://x/v.webm',
          ),
        ], voice: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^Voice note from Maya')), findsOneWidget);
    await tapLabel(tester, 'Play voice note');
    expect(playback.played.single, ('att-v', 'https://x/v.webm'));
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a voice note\'s speed steps as the desktop\'s, and comes back round', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('v', const [
          MessageAttachment(
            id: 'att-v',
            filename: 'voice-note.webm',
            contentType: 'audio/webm',
            url: 'https://x/v.webm',
          ),
        ], voice: true),
      ),
    );
    await tester.pumpAndSettle();
    final seen = <String>[];
    for (var i = 0; i < AudioPlayback.speedSteps.length; i++) {
      await tapLabel(tester, RegExp(r'^Speed, '));
      seen.add(playback.speeds.value['att-v']!.toString());
    }
    expect(seen, ['1.25', '1.5', '1.75', '2.0', '0.5', '0.75', '1.0']);
    expect(find.bySemanticsLabel('Speed, 1×'), findsOneWidget);
    semantics.dispose();
  });

  // A file's link expires a day after the API signed it (#182).
  group('file links', () {
    String signed(String id, Duration left) =>
        'https://x/attachments/$id?sig=old&exp=${DateTime.now().add(left).millisecondsSinceEpoch ~/ 1000}';
    const fresh = 'https://x/attachments/p-1?sig=new&exp=4102444800';
    MessageAttachment picture(String url) =>
        MessageAttachment(id: 'p-1', filename: 'cat.png', contentType: 'image/png', url: url, width: 100, height: 100);
    List<String> loaded(WidgetTester tester) => [
      for (final image in tester.widgetList<Image>(find.byType(Image)))
        if (switch (image.image) {
              ResizeImage(:final imageProvider) => imageProvider,
              final provider => provider,
            }
            case NetworkImage(:final url))
          url,
    ];

    testWidgets('a picture whose link is about to expire loads from a new one; one with time left as it is', (
      tester,
    ) async {
      final repository = await openMaya(tester);
      repository.renewedLinks['p-1'] = fresh;
      final soon = signed('p-1', const Duration(minutes: 5));
      repository.push('c-maya', MessageCreated(withFiles('m-p', [picture(soon)])));
      await tester.pumpAndSettle();
      expect(repository.linksAsked, [(id: 'p-1', refused: false)]);
      expect(loaded(tester), contains(fresh));
      expect(loaded(tester), isNot(contains(soon)));

      final later = signed('p-2', const Duration(hours: 5));
      repository.push('c-maya', MessageCreated(withFiles('m-q', [picture(later)])));
      await tester.pumpAndSettle();
      expect(repository.linksAsked, hasLength(1));
      expect(loaded(tester), contains(later));
      semantics.dispose();
    });

    testWidgets('a link that fails to load is asked for anew, once', (tester) async {
      final repository = FakeRepository()..renewedLinks['p-1'] = fresh;
      final file = picture(signed('p-1', const Duration(hours: 5)));
      final urls = <String>[];
      late VoidCallback refuse;
      await tester.pumpWidget(
        RepositoryScope(
          repository: repository,
          child: AttachmentLinkBuilder(
            attachment: file,
            builder: (_, url, refused) {
              urls.add(url);
              refuse = refused;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(urls.last, file.url);
      refuse();
      refuse();
      await tester.pumpAndSettle();
      expect(urls.last, fresh);
      expect(repository.linksAsked, [(id: 'p-1', refused: true)]);
    });

    testWidgets('a voice note whose link is about to expire plays from a new one', (tester) async {
      final repository = await openMaya(tester);
      const renewed = 'https://x/attachments/att-v?sig=new&exp=4102444800';
      repository.renewedLinks['att-v'] = renewed;
      final note = MessageAttachment(
        id: 'att-v',
        filename: 'voice-note.webm',
        contentType: 'audio/webm',
        url: signed('att-v', const Duration(minutes: 5)),
      );
      repository.push('c-maya', MessageCreated(withFiles('v', [note], voice: true)));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Play voice note');
      expect(playback.played.single, ('att-v', renewed));
      semantics.dispose();
    });
  });

  testWidgets('the playback bar over the tabs: what plays, pause, play, and stop and close', (tester) async {
    await pumpApp(tester);
    final bar = find.byType(MediaPlaybackBar);
    expect(bar, findsNothing);
    await playback.play('n', 'https://x/n.ogg', title: 'Voice message', artist: 'Maya');
    await tester.pumpAndSettle();
    expect(find.descendant(of: bar, matching: find.text('Voice message')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('Maya · 0:00 / 0:14')), findsOneWidget);
    // Centred in the bar, clear of the progress line along its top.
    expect(tester.getTopLeft(find.text('Voice message')).dy - tester.getTopLeft(bar).dy, greaterThan(6));

    await tapLabel(tester, 'Pause');
    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    await tapLabel(tester, 'Play');
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    await tapLabel(tester, 'Stop and close');
    expect(playback.calls, ['pause', 'resume', 'stop']);
    expect(bar, findsNothing);
    semantics.dispose();
  });

  test('a voice note that won\'t load leaves the playback bar', () async {
    // just_audio's channels, as a phone that can't load the note answers them.
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.allMessagesHandler = (channel, handler, message) async {
      if (!channel.startsWith('com.ryanheise.just_audio.')) return handler?.call(message);
      if (codec.decodeMethodCall(message).method == 'load') {
        return codec.encodeErrorEnvelope(code: '0', message: 'Source error');
      }
      return codec.encodeSuccessEnvelope(<String, Object?>{});
    };
    addTearDown(() => messenger.allMessagesHandler = null);
    final player = JustAudioPlayback();
    await player.play('n', 'https://x/n.ogg', title: 'Voice message', artist: 'Maya');
    expect(player.state.value.id, isNull);
  });

  testWidgets('voice notes record from the + menu, locked, and send', (tester) async {
    final repository = await openMaya(tester);
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Voice note');
    expect(_Recorder.started, 1);
    expect(find.bySemanticsLabel(RegExp(r'^Recording voice note, \d+ seconds$')), findsOneWidget);
    expect(repository.recordings, isNotEmpty);
    // Cancel is the mic's opposite, in the destructive red.
    final cancel = tester.widget<Icon>(
      find.descendant(of: find.bySemanticsLabel('Cancel recording'), matching: find.byType(Icon)),
    );
    expect(cancel.icon, FLucideIcons.micOff);
    expect(cancel.color, Duvet.theme(Brightness.light).colors.destructive);

    await tester.pump(const Duration(seconds: 2));
    await tapLabel(tester, 'Send voice note');
    expect(repository.voiceNotes.single.$1, [1, 2, 3]);
    expect(repository.voiceNotes.single.$2, 'ogg');
    expect(find.bySemanticsLabel(RegExp('^Your voice note')), findsOneWidget);
    semantics.dispose();
  });

  // Task 19's review, Missing 1: the peaks are the voice note's convention in an encrypted conversation, and they go
  // with the note.
  testWidgets("a conversation's recorded voice note goes with its 64 peaks and its length", (tester) async {
    final repository = await openMaya(tester);
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Voice note');
    for (final level in [0.1, 0.5, 0.9, 0.3]) {
      _Recorder.last!.say(level);
    }
    await tester.pump(const Duration(seconds: 2));
    await tapLabel(tester, 'Send voice note');
    final peaks = repository.voiceWaveforms.single;
    expect(peaks, hasLength(64));
    expect(peaks!.reduce(max), 230);
    expect(repository.voiceLengths.single, const Duration(seconds: 3));
    semantics.dispose();
  });

  testWidgets('holding the mic records; sliding left cancels', (tester) async {
    final repository = await openMaya(tester);
    final send = find.bySemanticsLabel(RegExp('^Voice note, touch and hold'));
    final hold = await tester.startGesture(tester.getCenter(send));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await tester.pump();
    expect(_Recorder.started, 1);
    expect(find.textContaining('Slide to cancel'), findsOneWidget);
    await hold.moveBy(const Offset(-140, 0));
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();
    expect(_Recorder.cancelled, 1);
    expect(repository.voiceNotes, isEmpty);
    semantics.dispose();
  });

  testWidgets('audio files and videos play inline; other files open, share', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('f', const [
          MessageAttachment(id: 'au', filename: 'talk.mp3', contentType: 'audio/mpeg', url: 'https://x/talk.mp3'),
          MessageAttachment(id: 'vi', filename: 'tour.mp4', contentType: 'video/mp4', url: 'https://x/tour.mp4'),
          MessageAttachment(
            id: 'pd',
            filename: 'report.pdf',
            contentType: 'application/pdf',
            url: 'https://x/report.pdf',
            sizeBytes: 2400000,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^Audio file talk.mp3')), findsOneWidget);
    expect(find.bySemanticsLabel('Video, tour.mp4. Play'), findsOneWidget);
    await tapLabel(tester, 'Play talk.mp3');
    expect(playback.played.single.$1, 'au');

    await tapLabel(tester, RegExp('^PDF, report.pdf'));
    await tapLabel(tester, 'Share');
    expect(actions.calls, ['share report.pdf']);
    await tapLabel(tester, RegExp('^PDF, report.pdf'));
    await tapLabel(tester, 'Open');
    expect(actions.calls.last, 'open https://x/report.pdf');
    semantics.dispose();
  });

  testWidgets('any file attaches from the + menu', (tester) async {
    final repository = await openMaya(tester);
    ChatView.debugPickFiles = () async => const [
      OutgoingFile(path: '/tmp/notes.pdf', name: 'notes.pdf', contentType: 'application/pdf', sizeBytes: 1000),
    ];
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'File');
    expect(find.bySemanticsLabel('File, notes.pdf'), findsOneWidget);
    await tapLabel(tester, 'Send');
    expect(repository.sent.last.files.single.name, 'notes.pdf');
    semantics.dispose();
  });

  testWidgets('GIFs: a tab in the picker; a pick in a conversation sends it sealed', (tester) async {
    DeepLinkSource.instance = _NoLinks();
    final gifs = _Gifs();
    GifSource.instance = gifs;
    final media = Directory.systemTemp.createTempSync('duvet-media-test-');
    addTearDown(() => media.deleteSync(recursive: true));
    DecryptedFiles.instance = DecryptedFiles(folder: () async => media);
    final repository = await openMaya(tester);
    await tapLabel(tester, 'Emoji and stickers');
    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    expect(find.text('GIFs from KLIPY'), findsOneWidget);
    await tester.tap(find.text('Celebrate'));
    await tester.pumpAndSettle();
    expect(gifs.searched, ['Celebrate']);
    // A conversation's goes as a sealed file of its bytes, never its link (Ruling 12).
    await tapLabel(tester, 'GIF, party');
    await sentOnRealClock(tester, repository);
    expect(gifs.fetched, [_Gifs.party.url]);
    expect(repository.sent.last.content, isEmpty);
    expect([for (final f in repository.sent.last.files) (f.name, f.contentType)], [('party.gif', 'image/gif')]);
    // Its copy is in the folder the engine's start empties, not left in the cache for good (task 19's review, M5).
    expect(repository.sent.last.files.single.path, startsWith('${media.path}/gif/'));
    semantics.dispose();
  });

  testWidgets('GIFs: one the provider sizes 0 wide shows square, not a crash', (tester) async {
    DeepLinkSource.instance = _NoLinks();
    final gifs = _Gifs()
      ..trend = const [Gif(id: 'g2', url: 'https://static.klipy.com/flat.gif', preview: 'p', width: 0, height: 150)];
    GifSource.instance = gifs;
    final media = Directory.systemTemp.createTempSync('duvet-media-test-');
    addTearDown(() => media.deleteSync(recursive: true));
    DecryptedFiles.instance = DecryptedFiles(folder: () async => media);
    final repository = await openMaya(tester);
    await tapLabel(tester, 'Emoji and stickers');
    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final tile = tester.getSize(find.bySemanticsLabel('GIF'));
    expect(tile.width, tile.height);
    await tapLabel(tester, 'GIF');
    await sentOnRealClock(tester, repository);
    expect(repository.sent.last.files.single.name, 'flat.gif');
    semantics.dispose();
  });

  // Step 5's review, I1 (mobile#365): a picker writes what it hands the app to send under the app's cache folder, the
  // file in the clear, which in a conversation only the core's database may keep. A camera's photo has no other copy.
  group("a conversation's picked files", () {
    late Directory cache;
    late DecryptedFiles before;
    setUp(() {
      // Nothing of the platform's answers while a test lets the real clock run.
      DeepLinkSource.instance = _NoLinks();
      cache = Directory.systemTemp.createTempSync('duvet-cache-');
      before = DecryptedFiles.instance;
    });
    tearDown(() {
      DecryptedFiles.instance = before;
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    /// The app's folders under [cache], as path_provider names it, and its engine's start, which empties the decrypted
    /// files' folder there.
    Future<void> started(WidgetTester tester) async {
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => cache.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      DecryptedFiles.instance = DecryptedFiles();
      await tester.runAsync(DecryptedFiles.instance.emptyAtStart);
    }

    /// The camera's photo as image_picker hands it over: scaled to its quality, a file of its own in the cache folder.
    void camera() => ChatView.debugPickMedia = (source) async {
      expect(source, ImageSource.camera);
      final photo = File('${cache.path}/scaled_${DateTime.now().microsecondsSinceEpoch}.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 8)));
      return [OutgoingFile(path: photo.path, name: 'photo.jpg', contentType: 'image/jpeg', sizeBytes: 100)];
    };

    List<String> filesInCache() => [
      for (final entry in cache.listSync(recursive: true))
        if (entry is File) entry.path,
    ];

    /// A photo taken and in the tray, on the real clock: a conversation's moves as it's picked.
    Future<void> takePhoto(WidgetTester tester) async {
      await tapLabel(tester, 'Add photos, a sticker or a mention');
      await tapLabel(tester, 'Camera');
      final inTray = find.bySemanticsLabel('Photo, photo.jpg');
      for (var i = 0; i < 100 && inTray.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(inTray, findsOneWidget);
    }

    testWidgets('a camera photo sent in a DM leaves no file under the cache once sent', (tester) async {
      await started(tester);
      camera();
      final repository = await openMaya(tester);
      await takePhoto(tester);
      // In the folder the engine's start empties, as it's picked: a kill before its send settles leaves it there.
      expect(filesInCache(), [startsWith('${cache.path}/e2e-media/picked/')]);
      await tapLabel(tester, 'Send');
      expect(repository.sent.last.files.single.name, 'photo.jpg');
      expect(filesInCache(), isEmpty);
      semantics.dispose();
    });

    testWidgets('a failed send keeps its photo for a Retry, and its Delete takes it', (tester) async {
      await started(tester);
      camera();
      final repository = await openMaya(tester);
      repository.failSends = true;
      await takePhoto(tester);
      await tapLabel(tester, 'Send');
      expect(find.bySemanticsLabel('Retry'), findsOneWidget);
      expect(filesInCache(), hasLength(1));
      await tapLabel(tester, 'Delete');
      expect(filesInCache(), isEmpty);
      semantics.dispose();
    });

    testWidgets('a photo taken out of the tray goes', (tester) async {
      await started(tester);
      camera();
      await openMaya(tester);
      await takePhoto(tester);
      await tapLabel(tester, 'Remove photo.jpg');
      expect(filesInCache(), isEmpty);
      semantics.dispose();
    });

    testWidgets("a room's camera photo stays where the picker put it, as rooms aren't encrypted", (tester) async {
      await started(tester);
      camera();
      final repository = await pumpApp(tester);
      for (final place in [find.text('Spaces').last, find.text('Design Guild'), find.text('# general')]) {
        await tester.tap(place);
        await tester.pumpAndSettle();
      }
      await takePhoto(tester);
      final picked = filesInCache();
      expect(picked, [startsWith('${cache.path}/scaled_')]);
      await tapLabel(tester, 'Send');
      expect(repository.sent.last.target, isA<RoomTarget>());
      expect(filesInCache(), picked);
      semantics.dispose();
    });
  });

  testWidgets('GIFs: typing searches once it pauses, and a topic drops the search that waited', (tester) async {
    final gifs = _Gifs();
    GifSource.instance = gifs;
    await openMaya(tester);
    await tapLabel(tester, 'Emoji and stickers');
    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    final field = find.descendant(of: find.byType(SearchField), matching: find.byType(EditableText));
    for (final typed in ['c', 'ca', 'cat']) {
      await tester.enterText(field, typed);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(gifs.searched, isEmpty, reason: 'nothing while the typing goes on');
    await tester.pump(const Duration(milliseconds: 300));
    expect(gifs.searched, ['cat']);

    await tester.enterText(field, 'dog');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Celebrate'));
    await tester.pumpAndSettle();
    expect(gifs.searched, ['cat', 'Celebrate']);
    semantics.dispose();
  });

  testWidgets('Recently used: a long press takes an emoji out, in the store too', (tester) async {
    final store = MemoryRecentEmojiStore();
    RecentEmoji.instance = RecentEmoji(store);
    addTearDown(() => RecentEmoji.instance = RecentEmoji(MemoryRecentEmojiStore()));
    EmojiCatalog.used('😀');
    // A Space's emoji: any chat's, a DM's too, recent and in its Space's section.
    EmojiCatalog.used(FakeRepository.party.code);
    await openMaya(tester);
    await tapLabel(tester, 'Emoji and stickers');
    expect(find.text('RECENTLY USED'), findsOneWidget);
    expect(find.bySemanticsLabel('party'), findsNWidgets(2));

    // The first is the recent one; the second sits in its category.
    await tester.longPress(find.bySemanticsLabel('grinning').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from recently used'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('grinning'), findsOneWidget);
    expect(find.bySemanticsLabel('party'), findsNWidgets(2));
    expect(RecentEmoji.instance.ranked, [FakeRepository.party.code]);
    expect(store.uses, isNot(contains('😀')));
    expect(store.uses, contains(FakeRepository.party.code));
    semantics.dispose();
  });

  testWidgets('a picture alone: a long press opens its actions, a double tap replies, a tap opens it', (tester) async {
    final repository = await openMaya(tester, reply: ReplyGesture.doubleTap);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('p', const [
          MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final photo = find.bySemanticsLabel('Photo, room.jpg');
    final viewer = find.byType(ImageViewer);

    await tester.longPress(photo);
    await tester.pumpAndSettle();
    expect(viewer, findsNothing, reason: 'a long press is the message\'s');
    await tapLabel(tester, 'Reply');
    expect(find.textContaining('Replying to Maya'), findsOneWidget);
    await tapLabel(tester, 'Cancel reply');
    expect(find.textContaining('Replying to Maya'), findsNothing);

    await tester.tap(photo);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(photo);
    await tester.pumpAndSettle();
    expect(find.textContaining('Replying to Maya'), findsOneWidget);
    expect(viewer, findsNothing);

    await tester.tap(photo);
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(viewer, findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the image viewer saves, shares, and closes on a swipe down', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('p', const [
          MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Photo, room.jpg'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    await tapLabel(tester, 'Save');
    await tapLabel(tester, 'Share');
    expect(actions.calls, ['save room.jpg', 'share room.jpg']);

    await tester.drag(find.byType(PageView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    semantics.dispose();
  });

  testWidgets('the image viewer zooms on a pinch anywhere; zoomed, a drag pans and doesn\'t close', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('p', const [
          MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Photo, room.jpg'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();

    // Away from the photo, in the empty part of the screen.
    final page = tester.getRect(find.byType(PageView));
    final at = Offset(page.center.dx, page.top + page.height * 0.3);
    // How far the photo is zoomed: its width on the screen against the page's.
    double zoom() =>
        tester.getRect(find.descendant(of: find.byType(ImageViewer), matching: find.byType(Hero))).width / page.width;
    Future<void> doubleTap() async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    // One finger held still and the other moving, as a thumb pinches: up and
    // down the swipe that closes the viewer mustn't take it, and sideways the
    // swipe to the next photo mustn't.
    for (final way in const [Offset(0, 5), Offset(5, 0)]) {
      final a = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 40));
      final b = await tester.startGesture(at + way * 8);
      for (var i = 0; i < 10; i++) {
        await b.moveBy(way);
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsOneWidget);
      expect(zoom(), greaterThan(1.2), reason: 'pinched along $way');
      await doubleTap();
      expect(zoom(), 1);
    }

    // The first finger drifts far enough to start the swipe before the second
    // lands, as a sloppy pinch does: it still zooms.
    final first = await tester.startGesture(at);
    for (var i = 0; i < 3; i++) {
      await first.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    final second = await tester.startGesture(at + const Offset(0, 80));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await second.moveBy(const Offset(0, 8));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(zoom(), greaterThan(1.2), reason: 'a pinch after the swipe began');
    await doubleTap();
    expect(zoom(), 1);

    // Both fingers moving, staggered, then zoomed: a drag pans and doesn't close.
    final a = await tester.startGesture(at - const Offset(0, 20));
    await a.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 40));
    final b = await tester.startGesture(at + const Offset(0, 20));
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(0, -10));
      await b.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(zoom(), greaterThan(1));
    await tester.drag(find.byType(PageView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);

    // Pinched past 5×, it settles back to 5×.
    final c = await tester.startGesture(at - const Offset(0, 10));
    final d = await tester.startGesture(at + const Offset(0, 10));
    for (var i = 0; i < 20; i++) {
      await c.moveBy(const Offset(0, -15));
      await d.moveBy(const Offset(0, 15));
      await tester.pump();
    }
    await c.up();
    await d.up();
    await tester.pumpAndSettle();
    expect(zoom(), moreOrLessEquals(5));

    // A double tap zooms back out, another in to 2.5×, and a third out again.
    await doubleTap();
    expect(zoom(), 1);
    await doubleTap();
    expect(zoom(), moreOrLessEquals(2.5));
    await doubleTap();

    // Let go short of closing, it springs back.
    await tester.drag(find.byType(PageView), const Offset(30, 60));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(tester.getRect(find.byType(PageView)), page);
    await tester.drag(find.byType(PageView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    semantics.dispose();
  });

  testWidgets('swiping the photo: a quick flick closes, a second finger doesn\'t throw it, and it buzzes', (
    tester,
  ) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('p', const [
          MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final buzzes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') buzzes.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    Future<void> open() async {
      await tester.tap(find.bySemanticsLabel('Photo, room.jpg'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
    }

    // Picked up, then a second finger lands far away and moves: the photo
    // isn't thrown to it, it goes back, as that's a pinch now.
    await open();
    final start = tester.getCenter(find.byType(PageView));
    final a = await tester.startGesture(start);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    expect(buzzes, ['HapticFeedbackType.mediumImpact']);
    final b = await tester.startGesture(start + const Offset(150, 250));
    await tester.pump();
    await b.moveBy(const Offset(0, 5));
    await tester.pump();
    await b.up();
    await a.up();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(tester.getCenter(find.byType(PageView)), start);

    // Past the point where letting go closes it: a click, and it closes.
    final c = await tester.startGesture(start);
    for (var i = 0; i < 18; i++) {
      await c.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    expect(buzzes.last, 'HapticFeedbackType.selectionClick');
    await c.up();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);

    // Dragged down, then flicked back up: it goes back, it doesn't close.
    await open();
    final back = await tester.startGesture(start);
    for (var i = 0; i < 10; i++) {
      await back.moveBy(const Offset(0, 10), timeStamp: Duration(milliseconds: 100 * i));
      await tester.pump();
    }
    await back.moveBy(const Offset(0, -40), timeStamp: const Duration(milliseconds: 1010));
    await back.moveBy(const Offset(0, -40), timeStamp: const Duration(milliseconds: 1020));
    await back.up(timeStamp: const Duration(milliseconds: 1025));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);

    // Past where letting go closes it, then the system cancels the touch (the
    // notification shade): it goes back.
    final held = await tester.startGesture(start);
    for (var i = 0; i < 18; i++) {
      await held.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await held.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(tester.getCenter(find.byType(PageView)), start);

    // A quick flick, its first move already past the viewer's own pan slop.
    final flick = await tester.startGesture(start);
    await flick.moveBy(const Offset(0, 60), timeStamp: const Duration(milliseconds: 16));
    await flick.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
    await flick.up(timeStamp: const Duration(milliseconds: 40));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    semantics.dispose();
  });

  // The system bars hidden with the controls, and back: each SystemChrome mode set, in order.
  List<String> systemModes(WidgetTester tester) {
    final modes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') modes.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return modes;
  }

  const hide = 'SystemUiMode.immersive';
  const show = 'SystemUiMode.edgeToEdge';

  testWidgets('a tap hides the image viewer\'s bars and the system\'s, and another brings them back', (tester) async {
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('p', const [
          MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
          MessageAttachment(id: 'pi', filename: 'porch.jpg', contentType: 'image/jpeg', url: 'https://x/porch.jpg'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final modes = systemModes(tester);
    Future<void> open() async {
      await tester.tap(find.bySemanticsLabel('Photo, room.jpg'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsOneWidget);
    }

    final page = find.byType(PageView);
    await open();
    // Away from the photo: here it doesn't load, and its middle is Try again.
    final rect = tester.getRect(page);
    final at = Offset(rect.center.dx, rect.top + rect.height * 0.3);
    Future<void> tap([Offset? where]) async {
      await tester.tapAt(where ?? at);
      // A single tap waits out a double tap's second.
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
    }

    Future<void> doubleTap() async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    void shown(bool shown) {
      for (final label in ['Close', 'Rotate', 'Save', 'Share', 'Copy link']) {
        expect(find.semantics.byLabel(label), shown ? findsOne : findsNothing, reason: label);
      }
    }

    shown(true);
    final save = tester.getCenter(find.bySemanticsLabel('Save'));
    await tap();
    shown(false);
    expect(modes, [hide]);

    // They stay hidden for the next photo, and through a zoom and a pinch.
    await tester.drag(page, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    shown(false);
    await doubleTap();
    shown(false);
    await doubleTap();
    // One finger held still and the other moving, as a thumb pinches: the
    // still one lifted isn't a tap.
    final a = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 40));
    final b = await tester.startGesture(at + const Offset(0, 40));
    for (var i = 0; i < 10; i++) {
      await b.moveBy(const Offset(0, 5));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    shown(false);
    expect(modes, [hide]);
    await doubleTap();

    // Where Save was, hidden: the tap brings the bars back, it doesn't save.
    await tap(save);
    shown(true);
    expect(actions.calls, isEmpty);
    expect(modes, [hide, show]);

    // Android's bars swiped back in: the controls come back with them.
    await tap();
    expect(modes, [hide, show, hide]);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.platform.name,
      SystemChannels.platform.codec.encodeMethodCall(const MethodCall('SystemChrome.systemUIChange', [true])),
      (_) {},
    );
    await tester.pumpAndSettle();
    shown(true);
    expect(modes, [hide, show, hide, show]);

    // Swiped away hidden: the system's bars come back as it fades, once.
    await tap();
    expect(modes, [hide, show, hide, show, hide]);
    await tester.drag(page, const Offset(0, 300));
    await tester.pump();
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(modes, [hide, show, hide, show, hide, show]);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    expect(modes, [hide, show, hide, show, hide, show]);

    // A screen reader's taps couldn't bring them back: they stay.
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      accessibleNavigation: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await open();
    await tap();
    shown(true);
    expect(modes, [hide, show, hide, show, hide, show]);
    semantics.dispose();
  });

  for (final theme in Brightness.values) {
    testWidgets('the image viewer\'s light status bar icons go with it, in the ${theme.name} theme', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = theme;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = await openMaya(tester);
      repository.push(
        'c-maya',
        MessageCreated(
          withFiles('p', const [
            MessageAttachment(id: 'ph', filename: 'room.jpg', contentType: 'image/jpeg', url: 'https://x/room.jpg'),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      // iOS reads the bar's background: light means dark icons.
      Brightness? bar() => SystemChrome.latestStyle?.statusBarBrightness;
      expect(bar(), theme);

      await tester.tap(find.bySemanticsLabel('Photo, room.jpg'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(bar(), Brightness.dark);
      expect(SystemChrome.latestStyle?.systemNavigationBarColor, isNull, reason: 'Android\'s bar keeps its colour');

      await tapLabel(tester, 'Close');
      expect(find.byType(ImageViewer), findsNothing);
      expect(bar(), theme);
      semantics.dispose();
    });
  }

  testWidgets('a tap hides the video\'s controls and the system\'s bars; Play and Pause are the button\'s', (
    tester,
  ) async {
    final build = VideoPage.controllerFor;
    late _PlayingVideo video;
    VideoPage.controllerFor = (url) => video = _PlayingVideo(url);
    addTearDown(() => VideoPage.controllerFor = build);
    final repository = await openMaya(tester);
    repository.push(
      'c-maya',
      MessageCreated(
        withFiles('v', const [
          MessageAttachment(id: 'vi', filename: 'tour.mp4', contentType: 'video/mp4', url: 'https://x/tour.mp4'),
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final modes = systemModes(tester);
    await tapLabel(tester, 'Video, tour.mp4. Play');
    expect(find.byType(VideoPage), findsOneWidget);
    // The page's, not the tile's first frame under it.
    final player = find.descendant(of: find.byType(VideoPage), matching: find.byType(VideoPlayer));
    expect(video.value.isPlaying, isTrue);
    void shown(bool shown) {
      for (final label in ['Close', 'Pause']) {
        expect(find.semantics.byLabel(label), shown ? findsOne : findsNothing, reason: label);
      }
    }

    // On the video: the controls go, and it plays on.
    shown(true);
    await tester.tapAt(tester.getCenter(player));
    await tester.pumpAndSettle();
    shown(false);
    expect(video.value.isPlaying, isTrue);
    expect(modes, [hide]);

    // On the black above it: they come back.
    await tester.tapAt(const Offset(200, 120));
    await tester.pumpAndSettle();
    shown(true);
    expect(modes, [hide, show]);

    await tapLabel(tester, 'Pause');
    expect(video.value.isPlaying, isFalse);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);

    // Swiped away hidden: the system's bars come back.
    await tester.tapAt(tester.getCenter(player));
    await tester.pumpAndSettle();
    await tester.dragFrom(tester.getCenter(player), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(VideoPage), findsNothing);
    expect(modes, [hide, show, hide, show]);
    semantics.dispose();
  });

  test('a zoomed photo stops at its edges, and is centred where it\'s narrower than the screen', () {
    const view = Size(400, 800);
    // A wide photo, letterboxed: 400×200 in the middle of the screen.
    const photo = Rect.fromLTWH(0, 300, 400, 200);
    final kept = clampToPhoto(2, const Offset(500, -2000), view, photo);
    // 800×400 at 2×: its left edge stays at the screen's, and it's centred up and down.
    expect(kept.dx, 0);
    expect(kept.dy, (800 - 400) / 2 - 300 * 2);
    // 1000 high at 5×: its top stays at the screen's.
    expect(clampToPhoto(5, Offset.zero, view, photo).dy, -300 * 5);
  });

  testWidgets('uploads show their progress and can be cancelled; large files are refused', (tester) async {
    final repository = await openMaya(tester);
    repository.limit = 25 * 1024 * 1024;
    ChatView.debugPickMedia = (_) async => const [
      OutgoingFile(path: '/tmp/a.jpg', name: 'a.jpg', contentType: 'image/jpeg', sizeBytes: 1000),
      OutgoingFile(path: '/tmp/b.jpg', name: 'b.jpg', contentType: 'image/jpeg', sizeBytes: 1000),
    ];
    repository.holdSends = Completer();
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Photos & GIFs');
    await tapLabel(tester, 'Send');
    repository.lastUpload!(0.75);
    await tester.pump();
    expect(find.text('Uploading 2 of 2 · 75%'), findsOneWidget);

    await tapLabel(tester, 'Cancel upload');
    expect(find.textContaining('Uploading'), findsNothing);
    // The files are back in the tray.
    expect(find.bySemanticsLabel('Photo, a.jpg'), findsOneWidget);
    repository.holdSends!.complete();
    await tester.pumpAndSettle();

    // Every byte up: the API may post it whatever the app does, so no Cancel
    // until it answers (#180).
    repository
      ..cancelled = false
      ..holdSends = Completer();
    await tapLabel(tester, 'Send');
    repository.lastUpload!(0.99);
    await tester.pump();
    expect(find.bySemanticsLabel('Cancel upload'), findsOneWidget);
    repository.lastUpload!(1);
    await tester.pump();
    expect(find.text('Uploading 2 of 2 · 100%'), findsOneWidget);
    expect(find.bySemanticsLabel('Cancel upload'), findsNothing);
    repository.holdSends!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Uploading'), findsNothing);
    expect(find.bySemanticsLabel('Retry'), findsNothing);
    expect(repository.cancelled, isFalse);

    // Over the limit: kept back, with the reason.
    ChatView.debugPickMedia = (_) async => const [
      OutgoingFile(path: '/tmp/big.mov', name: 'big.mov', contentType: 'video/quicktime', sizeBytes: 30 * 1024 * 1024),
    ];
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Photos & GIFs');
    final sent = repository.sent.length;
    await tapLabel(tester, 'Send');
    expect(repository.sent.length, sent);
    expect(find.text('big.mov is over your 25 MB upload limit'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a cancelled upload gives back its text and reply while the composer has neither', (tester) async {
    final repository = await openMaya(tester);
    ChatView.debugPickMedia = (_) async => const [
      OutgoingFile(path: '/tmp/a.jpg', name: 'a.jpg', contentType: 'image/jpeg', sizeBytes: 1000),
    ];
    repository.holdSends = Completer();
    String typed() => tester.widget<EditableText>(find.byType(EditableText)).controller.text;
    const strip = 'Replying to Maya — Hey! Did you see the new tab bar?';
    Future<void> sendWithReply() async {
      await tester.drag(find.text('Hey! Did you see the new tab bar?').first, const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'Here it is');
      await tapLabel(tester, 'Add photos, a sticker or a mention');
      await tapLabel(tester, 'Photos & GIFs');
      await tapLabel(tester, 'Send');
      expect((typed(), find.text(strip).evaluate().length), ('', 0));
    }

    // Nothing typed since: the text, the reply and the file come back.
    await sendWithReply();
    await tapLabel(tester, 'Cancel upload');
    expect(typed(), 'Here it is');
    expect(find.text(strip), findsOneWidget);
    expect(find.bySemanticsLabel('Photo, a.jpg'), findsOneWidget);

    // Something typed since: it stays, and only the file comes back.
    await tapLabel(tester, 'Cancel reply');
    await tester.enterText(find.byType(EditableText), '');
    await tapLabel(tester, 'Remove a.jpg');
    await sendWithReply();
    await tester.enterText(find.byType(EditableText), 'wait');
    await tester.pump();
    await tapLabel(tester, 'Cancel upload');
    expect(typed(), 'wait');
    expect(find.text(strip), findsNothing);
    expect(find.bySemanticsLabel('Photo, a.jpg'), findsOneWidget);
    repository.holdSends!.complete();
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('a file the server finds too large says so, with no Retry', (tester) async {
    final repository = await openMaya(tester);
    repository.tooLarge = true;
    ChatView.debugPickMedia = (_) async => const [
      OutgoingFile(path: '/tmp/a.jpg', name: 'a.jpg', contentType: 'image/jpeg'),
    ];
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Photos & GIFs');
    await tapLabel(tester, 'Send');
    expect(find.text('Too large to send'), findsOneWidget);
    expect(find.bySemanticsLabel('Retry'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Duvet links show as cards: a quoted message, an invite to join', (tester) async {
    final repository = await openMaya(
      tester,
      setUp: (r) {
        r.spaces.value = [
          ...r.spaces.value,
          const Space(
            id: _space,
            name: 'Paper Club',
            sections: [
              RoomSection(
                name: null,
                rooms: [Room(id: _room, spaceId: _space, name: 'books', kind: RoomKind.text, position: 0)],
              ),
            ],
          ),
        ];
        r.history[_room] = [
          FakeRepository.message(_linked, author: FakeRepository.leo, name: 'Leo', text: 'Chapter 4'),
        ];
        r.invites['paper'] = const InvitePreview(
          code: 'paper',
          spaceId: 's-paper',
          spaceName: 'Fieldwork',
          memberCount: 412,
        );
      },
    );
    repository.push(
      'c-maya',
      MessageCreated(
        FakeRepository.message(
          'l',
          author: _maya,
          name: 'Maya',
          text: 'see https://duvet.chat/channels/$_space/$_room/$_linked and https://duvet.chat/invite?code=paper',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Linked message from Leo in # books · Paper Club. Jump to message'), findsOneWidget);
    expect(find.text('Chapter 4'), findsOneWidget);
    expect(find.text('412 members'), findsOneWidget);
    await tapLabel(tester, 'Join Fieldwork');
    expect(repository.joined, ['paper']);
    expect(find.bySemanticsLabel('Open Fieldwork'), findsOneWidget);

    await tapLabel(tester, RegExp('^Linked message from Leo'));
    expect(find.text('# books'), findsWidgets);
    // The toast's timer runs out.
    await tester.pump(const Duration(seconds: 4));
    semantics.dispose();
  });

  test('the message text hook opens links', () {
    expect(MessageText.openLink, isNotNull);
  });

  testWidgets('pictures come from the gallery as before', (tester) async {
    ChatView.debugPickMedia = (source) async {
      expect(source, ImageSource.gallery);
      return const [];
    };
    await openMaya(tester);
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Photos & GIFs');
    semantics.dispose();
  });

  // An encrypted conversation's files (PLAN-E2E-CLIENTES.md, Task 19): drawn from their decrypted copies, by their
  // bytes; anything the app doesn't draw saved as bytes or shared, never opened; a video only after its tap.
  group("an encrypted conversation's files", () {
    late Directory media;
    late _SealedOpener opener;
    setUp(() {
      // Nothing of the platform's answers while a test lets the real clock run (its files' copies are written there).
      DeepLinkSource.instance = _NoLinks();
      media = Directory.systemTemp.createTempSync('duvet-media-test-');
      opener = _SealedOpener();
      DecryptedFiles.instance = DecryptedFiles(folder: () async => media)..useOpener(opener);
    });
    tearDown(() {
      DecryptedFiles.instance.useOpener(null);
      VideoPage.controllerFor = VideoPage.defaultController;
      if (media.existsSync()) media.deleteSync(recursive: true);
    });

    /// A file of a message of Maya's, sealed: [plain] its bytes, [name] and [said] what its envelope says of it.
    MessageAttachment sealedFile(
      String id,
      List<int> plain,
      String name,
      String said, {
      int? durationMs,
      String? waveform,
      int? width,
      int? height,
      String? thumbnail,
      FileRef? thumbnailRef,
    }) {
      final bytes = Uint8List.fromList(plain);
      opener.plain[id] = bytes;
      return MessageAttachment(
        id: id,
        filename: name,
        contentType: said,
        url: 'https://api.duvet.test/attachments/$id?sig=test&exp=4102444800',
        sizeBytes: bytes.length,
        thumbnailUrl: thumbnailRef == null
            ? null
            : 'https://api.duvet.test/attachments/${thumbnailRef.id}?sig=test&exp=4102444800',
        sealed: ShownFile(
          id: id,
          key: 'a2V5',
          sha256: base64Encode(sha256.convert(bytes).bytes),
          size: bytes.length,
          name: name,
          said: said,
          durationMs: durationMs,
          waveform: waveform,
          width: width,
          height: height,
          thumbnail: thumbnail,
          thumbnailRef: thumbnailRef,
        ),
      );
    }

    /// A thumbnail drawn from these bytes, inside its message.
    Finder thumbnailOf(List<int> bytes) => find.byWidgetPredicate((w) {
      final image = w is Image ? w.image : null;
      final inside = image is ResizeImage ? image.imageProvider : image;
      return inside is MemoryImage && listEquals(inside.bytes, bytes);
    });

    /// Lets what a tap started on the real clock end (a copy to share is written there), until [done].
    Future<void> onRealClock(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    /// Lets a file the view asked for come down and open on the real clock, as its copy is written.
    Future<FileReady> comeDown(WidgetTester tester, MessageAttachment a) async {
      for (var i = 0; i < 100 && DecryptedFiles.instance.state(a.sealed!, a.url) is! FileReady; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return DecryptedFiles.instance.state(a.sealed!, a.url)! as FileReady;
    }

    /// The file opened beforehand, as the chat would as it shows it: on the real clock, as its copy is written.
    Future<FileState> opened(WidgetTester tester, MessageAttachment a, String message) async =>
        (await tester.runAsync(() => DecryptedFiles.instance.open(a.sealed!, a.url, message)))!;

    Finder copyDrawn(String path) => find.byWidgetPredicate((w) {
      final image = w is Image ? w.image : null;
      final file = image is ResizeImage ? image.imageProvider : image;
      return file is FileImage && file.file.path == path;
    });

    testWidgets('an encrypted picture is drawn from its decrypted copy', (tester) async {
      final a = sealedFile('p1', img.encodePng(img.Image(width: 4, height: 4)), 'cat.png', 'image/png');
      final ready = await opened(tester, a, 'e1') as FileReady;
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e1', [a])));
      await tester.pumpAndSettle();
      expect(copyDrawn(ready.path), findsOneWidget);
      semantics.dispose();
    });

    testWidgets("a decrypted file the app doesn't draw is saved as bytes or shared, never opened", (tester) async {
      final a = sealedFile('h1', utf8.encode('<!doctype html><script>alert(1)</script>'), 'cat.png', 'image/png');
      final ready = await opened(tester, a, 'e2') as FileReady;
      expect(ready.type, 'application/octet-stream');
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e2', [a])));
      await tester.pumpAndSettle();
      // Not a picture, whatever it says: nothing draws its copy, and nothing opens it.
      expect(copyDrawn(ready.path), findsNothing);
      await tapLabel(tester, Notice.fileSaveNamed.fill({'name': 'cat.png'}));
      await tapLabel(tester, 'Share cat.png');
      await onRealClock(tester, () => actions.calls.length == 2);
      expect(actions.calls, [
        'saveFile cat.png application/octet-stream',
        'shareFile cat.png application/octet-stream',
      ]);
      // Saved from its copy; shared from a copy under its cleaned name, which the engine's start empties with the rest
      // (task 19's review, M1).
      expect(actions.paths.first, ready.path);
      expect(Uri.file(actions.paths.last).pathSegments.last, 'cat.png');
      expect(actions.paths.last, startsWith('${media.path}/share/'));
      semantics.dispose();
    });

    testWidgets('an encrypted video plays only after its tap, downloaded whole with its progress', (tester) async {
      final played = <Uri>[];
      VideoPage.controllerFor = (url) {
        played.add(url);
        return _PlayingVideo(url);
      };
      final a = sealedFile(
        'v1',
        [0, 0, 0, 0x20, ...ascii.encode('ftypisom'), ...List.filled(500, 0)],
        'tour.mp4',
        'video/mp4',
      );
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e3', [a])));
      await tester.pumpAndSettle();
      // Nothing comes down until it's tapped.
      expect(DecryptedFiles.instance.state(a.sealed!, a.url), isNull);
      opener
        ..hold = Completer<void>()
        ..progress = 0.5;
      await tapLabel(tester, RegExp('^Video, tour.mp4'));
      expect(find.textContaining('Downloading · '), findsOneWidget);
      expect(played, isEmpty);
      opener.hold!.complete();
      for (var i = 0; i < 50 && DecryptedFiles.instance.state(a.sealed!, a.url) is! FileReady; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pumpAndSettle();
      final ready = DecryptedFiles.instance.state(a.sealed!, a.url)! as FileReady;
      expect(played, [Uri.file(ready.path)]);
      expect(find.byType(VideoPage), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an encrypted voice note plays from its decrypted copy', (tester) async {
      final waveform = base64Encode(List.generate(64, (i) => i * 4));
      final a = sealedFile(
        'n1',
        [...ascii.encode('OggS'), ...List.filled(300, 1)],
        'voice-note.ogg',
        'audio/ogg',
        durationMs: 2300,
        waveform: waveform,
      );
      final ready = await opened(tester, a, 'e4') as FileReady;
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e4', [a], voice: true)));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Play voice note');
      expect(playback.played.single, ('n1', Uri.file(ready.path).toString()));
      semantics.dispose();
    });

    // Step 5's review, M2 (mobile#356): a decrypted audio file's name, its sender's word, was the title of the system's
    // media session, which the lock screen, Bluetooth devices and other apps read.
    testWidgets("a decrypted audio file plays under the app's own title, never its name", (tester) async {
      final a = sealedFile('s1', [...ascii.encode('OggS'), ...List.filled(300, 1)], 'plans.ogg', 'audio/ogg');
      await opened(tester, a, 'e5');
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e5', [a])));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Play plans.ogg');
      expect(playback.state.value.title, 'Audio file');
      semantics.dispose();
    });

    // M3: a picture's or a video's box is drawn from the sides its sender says, before its bytes are here, and any
    // from 1 to 65535 kept their ratio: 65535 × 1 was a box a fraction of a pixel tall, which nothing showed in or a
    // tap hit.
    testWidgets("a conversation's picture or video keeps a box to see and tap, whatever sides its sender says", (
      tester,
    ) async {
      final repository = await openMaya(tester);
      var n = 0;
      final files = [
        for (final said in ['image/png', 'video/mp4'])
          for (final (width, height) in [(65535, 1), (1, 65535), (640, 480)])
            sealedFile('b${++n}', List.filled(10, 1), 'shape.bin', said, width: width, height: height),
      ];
      repository.push('c-maya', MessageCreated(withFiles('e-box', files)));
      await tester.pumpAndSettle();
      for (final a in files) {
        final shape = '${a.sealed!.said} ${a.sealed!.width} × ${a.sealed!.height}';
        final view = find.byWidgetPredicate((w) => w is SealedFileView && w.attachment.id == a.id);
        final size = tester.getSize(view);
        final most = tester.widget<SealedFileView>(view).width;
        expect(size.shortestSide, greaterThanOrEqualTo(48), reason: shape);
        expect((size.width <= most, size.height <= 320), (true, true), reason: shape);
        // A plain shape keeps its own.
        if (a.sealed!.width == 640) expect(size.width / size.height, closeTo(640 / 480, 0.01), reason: shape);
      }
      semantics.dispose();
    });

    // M4: a thumbnail of its own came down whatever its file was laid out as, a file only saved on a tap among them,
    // and was never drawn there.
    testWidgets('a thumbnail of its own is fetched only for a file laid out as a picture or a video', (tester) async {
      final repository = await openMaya(tester);
      const kept = FileRef(id: '0193a4b2-0000-7000-8000-0000000000d1', key: 'a2V5', sha256: 'aGFzaA==', size: 100);
      const fetched = FileRef(id: '0193a4b2-0000-7000-8000-0000000000d2', key: 'a2V5', sha256: 'aGFzaA==', size: 100);
      final saved = sealedFile('t1', List.filled(10, 1), 'notes.pdf', 'application/pdf', thumbnailRef: kept);
      final picture = sealedFile('t2', List.filled(10, 1), 'cat.png', 'image/png', thumbnailRef: fetched);
      repository.push('c-maya', MessageCreated(withFiles('e6', [saved, picture])));
      await tester.pumpAndSettle();
      expect(DecryptedFiles.instance.state(kept, saved.thumbnailUrl), isNull);
      expect(DecryptedFiles.instance.state(fetched, picture.thumbnailUrl), isNotNull);
      semantics.dispose();
    });

    testWidgets('a waiting row whose files went with the app says so at once, with Dismiss', (tester) async {
      await openMaya(
        tester,
        setUp: (r) => r.history['c-maya']!.add(
          ChatMessage(
            id: 'pending:n1',
            authorId: FakeRepository.me.id,
            authorName: FakeRepository.me.displayName,
            content: 'with a file',
            createdAt: DateTime(2026, 10, 23, 10),
            nonce: 'n1',
            pending: true,
            filesGone: true,
          ),
        ),
      );
      expect(find.text(Notice.filesGone.text), findsOneWidget);
      expect(find.bySemanticsLabel('Retry'), findsNothing);
      expect(find.bySemanticsLabel('Delete'), findsOneWidget);
      semantics.dispose();
    });

    // Task 19's review, Missing 2: «Ver: primero la miniatura».
    testWidgets('a picture on its way is its box, its thumbnail and its progress; let go of, a tap asks again', (
      tester,
    ) async {
      final thumbnail = img.encodePng(img.Image(width: 32, height: 24));
      final a = sealedFile(
        'p4',
        img.encodePng(img.Image(width: 8, height: 6)),
        'view.png',
        'image/png',
        width: 1600,
        height: 1200,
        thumbnail: base64Encode(thumbnail),
      );
      // Room for this picture alone: another file lets it go.
      DecryptedFiles.instance = DecryptedFiles(limit: a.sealed!.size, folder: () async => media)..useOpener(opener);
      opener
        ..hold = Completer<void>()
        ..progress = 0.5;
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e10', [a])));
      await tester.pumpAndSettle();
      // As large as the picture will be, with its thumbnail and how far it came.
      final box = find.bySemanticsLabel(RegExp(r'^Downloading · \d+%, view.png$'));
      expect(box, findsOneWidget);
      expect(thumbnailOf(thumbnail), findsOneWidget);
      final size = tester.getSize(box);
      expect(size.width / size.height, closeTo(4 / 3, 0.01));
      opener.hold!.complete();
      opener.hold = null;
      expect(copyDrawn((await comeDown(tester, a)).path), findsOneWidget);
      final other = sealedFile('o1', List.filled(200, 7), 'other.bin', 'application/octet-stream');
      await opened(tester, other, 'e11');
      await tester.pumpAndSettle();
      expect(DecryptedFiles.instance.state(a.sealed!, a.url), isA<FileGone>());
      await tapLabel(tester, 'Photo, view.png. ${Notice.fileShow.text}');
      expect(copyDrawn((await comeDown(tester, a)).path), findsOneWidget);
      semantics.dispose();
    });

    // Task 19's review, I3: what a sender writes of a thumbnail is theirs, its header's size too.
    testWidgets("a thumbnail whose header says it's past 320 px isn't drawn; the rest is decoded at its box's size", (
      tester,
    ) async {
      final huge = base64Decode('/9j/wAARCC7gLuADASIAAhEBAxEB');
      final small = img.encodePng(img.Image(width: 32, height: 18));
      final video = sealedFile(
        'v3',
        [0, 0, 0, 0x20, ...ascii.encode('ftypisom'), ...List.filled(500, 0)],
        'big.mp4',
        'video/mp4',
        thumbnail: base64Encode(huge),
      );
      final picture = sealedFile(
        'p6',
        img.encodePng(img.Image(width: 8, height: 6)),
        'small.png',
        'image/png',
        width: 320,
        height: 180,
        thumbnail: base64Encode(small),
      );
      opener.hold = Completer<void>();
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e12', [video, picture])));
      await tester.pumpAndSettle();
      expect(thumbnailOf(huge), findsNothing);
      final drawn = tester.widget<Image>(thumbnailOf(small));
      final box = tester.getSize(find.bySemanticsLabel(RegExp(r'small.png$')));
      expect((drawn.image as ResizeImage).width, (box.width * tester.view.devicePixelRatio).round());
      opener.hold!.complete();
      semantics.dispose();
    });

    // Task 19's review, M1 and M8: a drawn picture's viewer works from its copy, under its cleaned name, with no link.
    testWidgets("a decrypted picture's viewer saves and shares its copy, and has no link to copy", (tester) async {
      final a = sealedFile('p2', img.encodePng(img.Image(width: 4, height: 4)), 'cat.png', 'image/png');
      await opened(tester, a, 'e7');
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e7', [a])));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Photo, cat.png');
      expect(find.bySemanticsLabel('Copy link'), findsNothing);
      await tapLabel(tester, 'Share');
      await onRealClock(tester, () => actions.paths.isNotEmpty);
      expect(Uri.file(actions.paths.single).pathSegments.last, 'cat.png');
      expect(actions.paths.single, startsWith('${media.path}/share/'));
      await tapLabel(tester, 'Save');
      expect(actions.calls.last, 'save cat.png');
      semantics.dispose();
    });

    // Task 19's review, M2: a reply's original, shown on its own, opens its files as its message's.
    testWidgets("a reply's original shown on its own has its files go with that message's deletion", (tester) async {
      final a = sealedFile('p3', img.encodePng(img.Image(width: 4, height: 4)), 'old.png', 'image/png');
      await openMaya(
        tester,
        setUp: (r) {
          r.older['c-maya'] = [
            withFiles('m0', [a]),
          ];
          r.history['c-maya']!.add(
            ChatMessage(
              id: 'm5',
              authorId: _maya,
              authorName: 'Maya',
              content: 'About that',
              createdAt: DateTime(2026, 10, 23, 10, 5),
              reply: const MessageReply(messageId: 'm0', authorId: _maya, authorName: 'Maya', content: 'Look'),
            ),
          );
        },
      );
      await tapLabel(tester, RegExp('^Replying to Maya: Look'));
      expect(find.bySemanticsLabel('Original message'), findsOneWidget);
      final ready = await comeDown(tester, a);
      DecryptedFiles.instance.forgetMessage('m0');
      expect(DecryptedFiles.instance.state(a.sealed!, a.url), isNull);
      expect(File(ready.path).existsSync(), isFalse);
      semantics.dispose();
    });

    // Task 19's review, M3: rule 10's Save, for a sound the phone plays or doesn't.
    testWidgets("a decrypted audio file saves and shares from its tile, and one that won't play is a card", (
      tester,
    ) async {
      final a = sealedFile('s1', [...ascii.encode('OggS'), ...List.filled(300, 2)], 'song.ogg', 'audio/ogg');
      final ready = await opened(tester, a, 'e8') as FileReady;
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e8', [a])));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^Audio file song.ogg')), findsOneWidget);
      await tapLabel(tester, Notice.fileSaveNamed.fill({'name': 'song.ogg'}));
      await tapLabel(tester, 'Share song.ogg');
      await onRealClock(tester, () => actions.calls.length == 2);
      expect(actions.calls, ['saveFile song.ogg audio/ogg', 'shareFile song.ogg audio/ogg']);
      expect(actions.paths.first, ready.path);
      playback.failedNow.value = 's1';
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^Audio file song.ogg')), findsNothing);
      expect(find.bySemanticsLabel(Notice.fileNamed.fill({'name': 'song.ogg', 'status': '304 B'})), findsOneWidget);
      semantics.dispose();
    });

    // Task 19's review, M10: rule 9, never under a spoiler.
    testWidgets('a video under a spoiler: its first tap shows it, the next asks for it', (tester) async {
      VideoPage.controllerFor = _PlayingVideo.new;
      final a = sealedFile(
        'v2',
        [0, 0, 0, 0x20, ...ascii.encode('ftypisom'), ...List.filled(500, 0)],
        'SPOILER_clip.mp4',
        'video/mp4',
      );
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(withFiles('e9', [a])));
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp('^Video, SPOILER_clip.mp4'));
      expect(DecryptedFiles.instance.state(a.sealed!, a.url), isNull);
      await tapLabel(tester, RegExp('^Video, SPOILER_clip.mp4'));
      await comeDown(tester, a);
      expect(find.byType(VideoPage), findsOneWidget);
      semantics.dispose();
    });

    // Task 19's review, a nit: the rooms' words, as no notice names the request's 32 MB.
    testWidgets("a conversation's files over 32 MB together stay in the tray, too large to send", (tester) async {
      final repository = await openMaya(tester);
      ChatView.debugPickFiles = () async => const [
        OutgoingFile(path: '/tmp/a.bin', name: 'a.bin', contentType: 'application/octet-stream', sizeBytes: 17 << 20),
        OutgoingFile(path: '/tmp/b.bin', name: 'b.bin', contentType: 'application/octet-stream', sizeBytes: 17 << 20),
      ];
      await tapLabel(tester, 'Add photos, a sticker or a mention');
      await tapLabel(tester, 'File');
      await tapLabel(tester, 'Send');
      expect(find.text('Too large to send'), findsOneWidget);
      expect(repository.sent, isEmpty);
      expect(find.bySemanticsLabel('File, a.bin'), findsOneWidget);
      semantics.dispose();
    });
  });
}
