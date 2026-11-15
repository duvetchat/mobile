import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/bot_ui.dart';
import 'package:duvet/widgets/link_embeds.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:duvet/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_repository.dart';
import 'support/fonts.dart';

/// A player that never finishes loading: nothing reaches a host or the
/// platform.
class _Pending extends VideoPlayerController {
  _Pending(super.url) : super.networkUrl();

  @override
  Future<void> initialize() => Completer<void>().future;
}

/// A player whose video won't load.
class _Failing extends VideoPlayerController {
  _Failing(super.url) : super.networkUrl();

  @override
  Future<void> initialize() => Future.error(StateError('no such video'));
}

/// A player with its first frame there.
class _Ready extends VideoPlayerController {
  _Ready(super.url) : super.networkUrl();

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true, size: const Size(16, 9), duration: const Duration(seconds: 3));
  }
}

/// Pictures, videos and cards in messages while they load, and what they
/// fetch before anyone plays them.
void main() {
  setUpAll(loadAppFonts);

  Widget themed(Widget child) => MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(
      data: Duvet.theme(Brightness.light),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  // Uploaded videos, one tile each, by id. The tiles' slots are shared by the
  // whole file: each test's ids are its own.
  Widget tiles(List<String> ids) => themed(
    SingleChildScrollView(
      child: Column(
        children: [
          for (final id in ids)
            VideoTile(
              key: ValueKey(id),
              attachment: MessageAttachment(
                id: id,
                filename: '$id.mp4',
                contentType: 'video/mp4',
                url: 'https://cdn.invalid/$id.mp4',
              ),
            ),
        ],
      ),
    ),
  );
  Finder within(String id, Type type) => find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(type));

  // Every player made, by its link.
  late List<Uri> made;
  List<String> paths() => [for (final u in made) u.path];
  void players(VideoPlayerController Function(Uri url) build) {
    final original = VideoPage.controllerFor;
    VideoPage.controllerFor = (url) {
      made.add(url);
      return build(url);
    };
    addTearDown(() => VideoPage.controllerFor = original);
  }

  setUp(() {
    made = [];
    players(_Pending.new);
  });

  testWidgets('an embed\'s video reaches its host only once someone plays it (#172)', (tester) async {
    const clip = 'https://videos.example/clip.mp4';
    // No picture to stand in for it: its first frame would have been loaded.
    await tester.pumpWidget(
      themed(
        const EmbedCard(
          embed: MessageEmbed(title: 'Clip', videoUrl: clip, videoContentType: 'video/mp4'),
        ),
      ),
    );
    await tester.pump();
    expect(made, isEmpty);
    expect(find.byType(PlayMark), findsOneWidget);
    // Nothing's on its way: no pulse.
    expect(find.byType(SkeletonBox), findsNothing);

    await tester.tap(find.byType(VideoTile));
    await tester.pump();
    expect(made, [Uri.parse(clip)]);
    // Not settled: the player's spinner turns while it loads.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('uploaded videos past the third wait their turn, pulsing, and take the next slot that frees', (
    tester,
  ) async {
    await tester.pumpWidget(tiles(['q0', 'q1', 'q2', 'q3', 'q4']));
    expect(paths(), ['/q0.mp4', '/q1.mp4', '/q2.mp4']);
    // None is an empty box meanwhile.
    expect(find.byType(SkeletonBox), findsNWidgets(5));
    expect(find.byType(PlayMark), findsNWidgets(5));

    await tester.pumpWidget(tiles(['q1', 'q2', 'q3', 'q4']));
    expect(paths(), ['/q0.mp4', '/q1.mp4', '/q2.mp4', '/q3.mp4']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a video whose frame won\'t load frees its slot and shows the play mark alone', (tester) async {
    players((url) => url.path.contains('broken') ? _Failing(url) : _Pending(url));
    await tester.pumpWidget(tiles(['broken', 'f1', 'f2', 'f3']));
    await tester.pump();
    expect(paths(), ['/broken.mp4', '/f1.mp4', '/f2.mp4', '/f3.mp4']);
    expect(within('broken', SkeletonBox), findsNothing);
    expect(within('broken', PlayMark), findsOneWidget);
    expect(within('f3', SkeletonBox), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a video sent from here loads its first frame once it\'s uploaded, not before', (tester) async {
    MessageAttachment video({required bool local}) => MessageAttachment(
      id: local ? 'local-s0' : 's0',
      filename: 's0.mp4',
      contentType: 'video/mp4',
      url: local ? '/data/user/0/s0.mp4' : 'https://cdn.invalid/s0.mp4',
      local: local,
    );
    // Its message keeps its tile as the send confirms.
    await tester.pumpWidget(themed(VideoTile(key: const ValueKey('s0'), attachment: video(local: true))));
    expect(made, isEmpty);
    expect(find.byType(SkeletonBox), findsNothing);

    await tester.pumpWidget(themed(VideoTile(key: const ValueKey('s0'), attachment: video(local: false))));
    expect(paths(), ['/s0.mp4']);
    expect(find.byType(SkeletonBox), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a picture pulses in its own box until it shows', (tester) async {
    await tester.pumpWidget(
      themed(
        const MessageAttachments(
          attachments: [
            MessageAttachment(
              id: 'p',
              filename: 'wide.png',
              contentType: 'image/png',
              url: 'https://cdn.invalid/wide-loading.png',
              width: 400,
              height: 200,
            ),
          ],
          maxWidth: 260,
        ),
      ),
    );
    final pulse = find.descendant(of: find.byType(MessageAttachments), matching: find.byType(SkeletonBox));
    expect(pulse, findsOneWidget);
    expect(tester.getSize(pulse), const Size(260, 130));
  });

  testWidgets('an invite card and a bot\'s pulse at the size they land at', (tester) async {
    final repository = FakeRepository()
      ..invites['paper'] = const InvitePreview(
        code: 'paper',
        spaceId: 's-paper',
        spaceName: 'Fieldwork',
        memberCount: 412,
      );
    // In a scroll, as in a chat: each card as high as its own content.
    Widget scoped(Widget card) => RepositoryScope(
      repository: repository,
      child: themed(SingleChildScrollView(child: card)),
    );

    await tester.pumpWidget(scoped(InviteCard(code: 'paper', onOpenSpace: (_) {})));
    expect(find.byType(InviteCardSkeleton), findsOneWidget);
    final invite = tester.getSize(find.byType(InviteCard));
    expect(invite.height, lessThan(200));
    // The fake's answer takes a moment.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('412 members'), findsOneWidget);
    expect(tester.getSize(find.byType(InviteCard)).width, invite.width);
    expect(tester.getSize(find.byType(InviteCard)).height, closeTo(invite.height, 1));

    await tester.pumpWidget(scoped(const BotInviteCard(botId: 'b-ballot')));
    expect(find.byType(InviteCardSkeleton), findsOneWidget);
    final bot = tester.getSize(find.byType(BotInviteCard));
    expect(bot.height, lessThan(200));
    await tester.pump();
    expect(find.text('Ballot'), findsOneWidget);
    expect(tester.getSize(find.byType(BotInviteCard)).width, bot.width);
    expect(tester.getSize(find.byType(BotInviteCard)).height, closeTo(bot.height, 1));
  });

  // Last: the frame it keeps stays kept for the file's other tests.
  testWidgets('a video\'s frame is kept as its tile scrolls away, and shown again without loading anew', (
    tester,
  ) async {
    players(_Ready.new);
    await tester.pumpWidget(tiles(['k0']));
    await tester.pump();
    expect(paths(), ['/k0.mp4']);
    expect(within('k0', VideoPlayer), findsOneWidget);
    expect(within('k0', SkeletonBox), findsNothing);

    await tester.pumpWidget(tiles([]));
    await tester.pumpWidget(tiles(['k0']));
    expect(paths(), ['/k0.mp4']);
    expect(within('k0', VideoPlayer), findsOneWidget);
    expect(within('k0', SkeletonBox), findsNothing);
  });
}
