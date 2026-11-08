import 'dart:async';
import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';
import 'support/fonts.dart';

/// An HTTP client whose requests never answer: images stay loading.
class _NeverAnswers implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) => Completer<HttpClientRequest>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Found on the phone: embed titles cut short, and images blank while they
/// load.
void main() {
  setUpAll(loadAppFonts);

  Widget themed(Widget child) => MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(
      data: Duvet.theme(Brightness.light),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  /// Runs [body] with every network image loading for good.
  Future<void> loading(Future<void> Function() body) async {
    debugNetworkImageHttpClientProvider = _NeverAnswers.new;
    try {
      await body();
    } finally {
      debugNetworkImageHttpClientProvider = null;
    }
  }

  // Base-sunken, as the design system names Duvet.light.secondary.
  Finder sunken({required Finder within}) => find.descendant(
    of: within,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          (w.color == Duvet.light.secondary ||
              w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == Duvet.light.secondary),
    ),
  );

  testWidgets('an embed\'s title runs long enough to end with how a GitHub run went', (tester) async {
    const title = '[duvetchat/desktop-electrobun] Workflow run completed: Deploy (completed/success)';
    await tester.pumpWidget(
      themed(
        const EmbedCard(
          embed: MessageEmbed(
            title: title,
            url: 'https://github.com/duvetchat/desktop-electrobun/actions/runs/1',
            provider: 'GitHub',
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('a GIF link\'s embed is its picture alone, at its own ratio; a card keeps its thumbnail small', (
    tester,
  ) async {
    await tester.pumpWidget(
      themed(
        const EmbedCard(
          embed: MessageEmbed(
            url: 'https://example.invalid/wave.gif',
            imageUrl: 'https://example.invalid/wave.gif',
            imageWidth: 400,
            imageHeight: 200,
          ),
        ),
      ),
    );
    expect(find.byType(Container), findsNothing);
    expect(tester.getSize(find.byType(Image)), const Size(260, 130));

    await tester.pumpWidget(
      themed(
        const EmbedCard(
          embed: MessageEmbed(
            title: 'A page',
            url: 'javascript:alert(1)',
            thumbnailUrl: 'https://example.invalid/logo.png',
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Image)), const Size(64, 64));
    expect(tester.widget<GestureDetector>(find.byType(GestureDetector)).onTap, isNull);
  });

  testWidgets('a sticker is a base-sunken square until it loads', (tester) async {
    await loading(() async {
      await tester.pumpWidget(themed(const StickerView(url: 'https://example.invalid/wave-loading.png', name: 'wave')));
      final placeholder = sunken(within: find.byType(StickerView));
      expect(placeholder, findsOneWidget);
      expect(tester.getSize(placeholder), const Size(160, 160));
      expect(find.bySemanticsLabel('Sticker, wave'), findsOneWidget);
    });
  });

  testWidgets('an avatar is a base-sunken circle while it loads, and its facehash if it never does', (tester) async {
    await loading(() async {
      await tester.pumpWidget(themed(const UserAvatar(name: 'maya', url: 'https://example.invalid/maya-loading.png')));
      expect(sunken(within: find.byType(UserAvatar)), findsOneWidget);
      expect(find.byType(Facehash), findsNothing);
    });

    // The test binding's own client refuses every request.
    await tester.pumpWidget(themed(const UserAvatar(name: 'maya', url: 'https://example.invalid/maya-broken.png')));
    for (var i = 0; i < 10 && find.byType(Facehash).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(Facehash), findsOneWidget);
    expect(sunken(within: find.byType(UserAvatar)), findsNothing);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('the viewer turns a photo a quarter at a time, and loads a broken one again on a tap', (tester) async {
    const photo = MessageAttachment(
      id: 'ph',
      filename: 'wide.png',
      contentType: 'image/png',
      url: 'https://example.invalid/wide-broken.png',
      width: 400,
      height: 200,
    );
    await tester.pumpWidget(themed(const ImageViewer(gallery: [photo])));
    // The test binding's own client refuses every request.
    Future<void> untilBroken() async {
      for (var i = 0; i < 10 && find.text('Tap to try again').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    await untilBroken();
    expect(find.text('Tap to try again'), findsOneWidget);
    await tester.tap(find.text('Tap to try again'));
    await tester.pump(kDoubleTapTimeout);
    expect(find.text('Tap to try again'), findsNothing, reason: 'it loads anew');
    await untilBroken();
    expect(find.text('Tap to try again'), findsOneWidget);

    RotatedBox turned() => tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(turned().quarterTurns, 0);
    for (final turns in [1, 2, 3, 0]) {
      await tester.tap(find.bySemanticsLabel('Rotate'));
      await tester.pump();
      expect(turned().quarterTurns, turns);
    }
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('a sticker in a message opens full screen on a tap; elsewhere it doesn\'t', (tester) async {
    await loading(() async {
      await tester.pumpWidget(themed(const StickerView(url: 'https://example.invalid/wave.png', name: 'wave')));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Sticker, wave')).getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );

      await tester.pumpWidget(
        themed(const StickerView(url: 'https://example.invalid/wave.png', name: 'wave', zoomable: true)),
      );
      await tester.tap(find.bySemanticsLabel('Sticker, wave'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsOneWidget);
      expect(find.text('wave'), findsOneWidget);
    });
  });

  testWidgets('a custom emoji\'s reaction shows its name until the image arrives', (tester) async {
    await loading(() async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repository = FakeRepository();
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pumpAndSettle();
      repository.history['r-general']!.add(
        FakeRepository.message(
          'm-party',
          author: FakeRepository.maya,
          name: 'Maya',
          text: 'shipped',
          reactions: [
            Reaction(emoji: FakeRepository.party.name, emojiId: FakeRepository.party.id, users: {FakeRepository.maya}),
          ],
        ),
      );
      await tester.tap(find.text('Spaces').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Design Guild'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('# general'));
      await tester.pumpAndSettle();

      // The pill's image is on its way: the name stands in for it, not a gap.
      final image = find.ancestor(of: find.text(':party:'), matching: find.byType(Image));
      expect(image, findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
    });
  });
}
