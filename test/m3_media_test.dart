import 'dart:async';

import 'package:duvet/chat_view.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/gifs.dart';
import 'package:duvet/data/links.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/apng.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/media_actions.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
const _space = '5a5a5a5a-0000-4000-8000-000000000001';
const _room = '5a5a5a5a-0000-4000-8000-000000000002';
const _linked = '5a5a5a5a-0000-4000-8000-000000000003';

class _Playback implements AudioPlayback {
  final played = <(String, String)>[];
  final _state = ValueNotifier(PlaybackState.idle);
  @override
  ValueListenable<PlaybackState> get state => _state;

  @override
  Future<void> play(String id, String url) async {
    played.add((id, url));
    _state.value = PlaybackState(id: id, playing: true, duration: const Duration(seconds: 14));
  }

  @override
  Future<void> pause() async => _state.value = PlaybackState(id: _state.value.id, duration: _state.value.duration);

  @override
  Future<void> seek(String id, Duration position) async {}
}

class _Recorder implements VoiceRecorder {
  static int started = 0;
  static int cancelled = 0;
  final _levels = StreamController<double>.broadcast();

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

  @override
  Future<List<Gif>> trending() async => const [party];

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

  Future<FakeRepository> openMaya(
    WidgetTester tester, {
    void Function(FakeRepository r)? setUp,
    ReplyGesture reply = ReplyGesture.swipeLeft,
  }) async {
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
    setUp?.call(repository);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
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
            child: const Scaffold(body: MessageAttachments(attachments: [a], maxWidth: 200)),
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
          child: const Scaffold(body: MessageAttachments(attachments: [a], maxWidth: 200)),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('^Photo, tall.webp')), findsOneWidget);
    // 4:1 tall: 320 high, 80 wide, so nothing of it is cropped.
    expect(tester.getSize(find.byType(Image)), const Size(80, 320));
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

  testWidgets('GIFs: a tab in the picker; a pick sends its link', (tester) async {
    final gifs = _Gifs();
    GifSource.instance = gifs;
    final repository = await openMaya(tester);
    await tapLabel(tester, 'Emoji and stickers');
    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    expect(find.text('GIFs from KLIPY'), findsOneWidget);
    await tester.tap(find.text('Celebrate'));
    await tester.pumpAndSettle();
    expect(gifs.searched, ['Celebrate']);
    await tapLabel(tester, 'GIF, party');
    expect(repository.sent.last.content, _Gifs.party.url);
    semantics.dispose();
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
    await open();
    final flick = await tester.startGesture(start);
    await flick.moveBy(const Offset(0, 60), timeStamp: const Duration(milliseconds: 16));
    await flick.moveBy(const Offset(0, 40), timeStamp: const Duration(milliseconds: 32));
    await flick.up(timeStamp: const Duration(milliseconds: 40));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
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

    // Over the limit: kept back, with the reason.
    ChatView.debugPickMedia = (_) async => const [
      OutgoingFile(path: '/tmp/big.mov', name: 'big.mov', contentType: 'video/quicktime', sizeBytes: 30 * 1024 * 1024),
    ];
    await tapLabel(tester, 'Remove a.jpg');
    await tapLabel(tester, 'Remove b.jpg');
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Photos & GIFs');
    final sent = repository.sent.length;
    await tapLabel(tester, 'Send');
    expect(repository.sent.length, sent);
    expect(find.text('big.mov is over your 25 MB upload limit'), findsOneWidget);
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
}
