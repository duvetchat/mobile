import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:video_player/video_player.dart';

/// A player that never finishes loading: nothing reaches a host or the
/// platform.
class _Pending extends VideoPlayerController {
  _Pending(super.url) : super.networkUrl();

  @override
  Future<void> initialize() => Completer<void>().future;
}

/// Pictures, videos and cards in messages while they load, and what they
/// fetch before anyone plays them.
void main() {
  Widget themed(Widget child) => MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(
      data: Duvet.theme(Brightness.light),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  // Every player made, by its link.
  late List<Uri> made;
  setUp(() {
    made = [];
    final build = VideoPage.controllerFor;
    VideoPage.controllerFor = (url) {
      made.add(url);
      return _Pending(url);
    };
    addTearDown(() => VideoPage.controllerFor = build);
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

    await tester.tap(find.byType(VideoTile));
    await tester.pump();
    expect(made, [Uri.parse(clip)]);
    // Not settled: the player's spinner turns while it loads.
    await tester.pump(const Duration(seconds: 1));
  });
}
