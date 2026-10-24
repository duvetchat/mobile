import 'dart:async';
import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';

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
  setUpAll(() async {
    // The app's own face, so lines wrap where they do on a phone.
    final sans = FontLoader('Fira Sans');
    for (final w in ['Regular', 'Medium', 'Bold']) {
      sans.addFont(rootBundle.load('assets/fonts/FiraSans-$w.ttf'));
    }
    await sans.load();
  });

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
