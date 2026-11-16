import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/members_sheet.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';

/// M1 · Layout to spec: the screens against the wireframes.
void main() {
  // The wireframes' 390 × 844pt phone.
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<FakeRepository> pumpApp(WidgetTester tester, [FakeRepository? repository]) async {
    phone(tester);
    repository ??= FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  test('emoji are Twemoji, but Apple Color Emoji on iOS, which draws none of Twemoji\'s COLR glyphs (#265)', () {
    expect(DuvetType.emoji, 'Twemoji');
    expect(DuvetType.fallback, ['Twemoji']);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(DuvetType.emoji, 'Apple Color Emoji');
    expect(DuvetType.fallback, ['Apple Color Emoji']);
  });

  test('the type ramp: Fraunces for smaller headlines, Inter for page titles, numbers and the interface, Roboto for '
      'messages', () {
    expect(
      (DuvetType.largeTitle.fontFamily, DuvetType.title.fontFamily, DuvetType.navTitle.fontFamily),
      ('Inter', 'Fraunces', 'Fraunces'),
    );
    expect(
      (DuvetType.largeTitle.fontSize, DuvetType.largeTitle.height, DuvetType.largeTitle.fontWeight),
      (36, 1.1, FontWeight.w700),
    );
    expect((DuvetType.titleSans.fontFamily, DuvetType.titleSans.fontSize), ('Inter', 22));
    // The variable font defaults to Black and wonky: every headline pins its cut.
    for (final style in [DuvetType.title, DuvetType.navTitle]) {
      final axes = {for (final v in style.fontVariations!) v.axis: v.value};
      expect(axes['wght'], style.fontWeight!.value);
      expect((axes['SOFT'], axes['WONK']), (50, 0));
    }
    expect((DuvetType.navTitle.fontSize, DuvetType.title.fontSize), (20, 22));
    expect(
      (DuvetType.body.fontFamily, DuvetType.snippet.fontFamily, DuvetType.label.fontFamily),
      ('Roboto', 'Roboto', 'Inter'),
    );
    expect((DuvetType.body.fontSize, DuvetType.body.height, DuvetType.body.fontWeight), (16, 1.4, FontWeight.w400));
    expect(DuvetType.rowTitle.fontWeight, FontWeight.w500);
    expect(DuvetType.rowTitleUnread.fontWeight, FontWeight.w700);
    expect((DuvetType.snippet.fontSize, DuvetType.caption.fontSize), (15, 13));
    expect((DuvetType.overline.fontSize, DuvetType.tabLabel.fontSize), (12, 11));
    // forui's own widgets read the same face.
    final theme = Duvet.theme(Brightness.light);
    expect(theme.typography.body.fontFamily, 'Inter');
    expect(theme.typography.body.sm.fontSize, 16);
  });

  testWidgets('glass saturates what it blurs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: const GlassSurface(child: SizedBox.square(dimension: 40)),
        ),
      ),
    );
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
    expect(filter.toString(), allOf(contains('matrix'), contains('blur')));
  });

  testWidgets('the tab bar is glass, 56pt, and its pill moves to the active tab', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    final bar = find.byType(DuvetTabBar);
    expect(tester.getSize(bar).height, 56);
    expect(find.descendant(of: bar, matching: find.byType(BackdropFilter)), findsOneWidget);

    double pillLeft() => tester.getTopLeft(find.descendant(of: bar, matching: find.byType(AnimatedPositioned))).dx;
    // Centered in the first of four 97.5pt columns.
    expect(pillLeft(), closeTo(97.5 / 2 - 28, 0.01));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Chats').last).getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );

    await tab(tester, 'Spaces');
    expect(pillLeft(), closeTo(97.5 * 1.5 - 28, 0.01));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Spaces').last).getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
  });

  testWidgets('chat rows: 72pt, no dividers, "# room · Space", unread in weight and ink', (tester) async {
    final repository = await pumpApp(tester);
    repository.opened(
      const RoomTarget(spaceId: 's-guild', roomId: 'r-general'),
      '# general',
      latest: repository.history['r-general']!.single,
    );
    await tester.pumpAndSettle();

    expect(find.byType(FTileGroup), findsNothing);
    expect(find.byType(Divider), findsNothing);
    final rows = find.byType(ListRow);
    for (final row in tester.widgetList<ListRow>(rows)) {
      expect(tester.getSize(find.byWidget(row)).height, greaterThanOrEqualTo(72));
    }

    final colors = Duvet.theme(Brightness.light).colors;
    // Maya's DM is unread: bold name, ink snippet. The room is read.
    expect(tester.widget<Text>(find.text('Maya')).style?.fontWeight, FontWeight.w700);
    final room = tester.widget<Text>(find.text('# general · Design Guild'));
    expect(room.style?.fontWeight, FontWeight.w500);
    final spaceSpan = (room.textSpan! as TextSpan).children!.last as TextSpan;
    expect((spaceSpan.text, spaceSpan.style?.color), (' · Design Guild', colors.mutedForeground));
    expect(tester.widget<Text>(find.text('Leo: Pushed the new type ramp')).style?.color, colors.mutedForeground);

    // A 48pt rounded-square Space icon for the room, a circle for a person.
    expect(tester.getSize(find.byType(SpaceIcon)), const Size(48, 48));
  });

  testWidgets('the Launchpad is a two-column grid of 173 × 160 Space cards', (tester) async {
    await pumpApp(tester);
    await tab(tester, 'Spaces');
    final card = find.byType(SpaceCard);
    expect(tester.getSize(card), const Size(173, 160));
    expect(tester.getTopLeft(card).dx, 16);
    expect(find.text('1 online'), findsOneWidget);
    expect(find.byType(FTile), findsNothing);
  });

  testWidgets('the Space Directory previews each room and follows new messages', (tester) async {
    final repository = await pumpApp(tester);
    await tab(tester, 'Spaces');
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();

    expect(repository.latestLoads, ['r-general']);
    expect(find.text('Leo: Pushed the new type ramp'), findsOneWidget);
    // No accent `#` icons: the `#` is ink-secondary text.
    expect(find.byIcon(FLucideIcons.hash), findsNothing);
    // The tab bar stays, with Spaces active.
    expect(find.byType(DuvetTabBar), findsOneWidget);

    repository.push(
      'r-general',
      MessageCreated(FakeRepository.message('m7', author: FakeRepository.maya, name: 'Maya', text: 'Coffee?')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Maya: Coffee?'), findsOneWidget);
    // Unread: bold.
    expect(tester.widget<Text>(find.text('# general')).style?.fontWeight, FontWeight.w700);
  });

  testWidgets('a large title scrolls away and a glass bar fades in', (tester) async {
    final repository = await pumpApp(tester);
    repository.conversations.value = [
      for (var i = 0; i < 30; i++) ConversationSummary(id: 'c-$i', title: 'Person $i', isGroup: false),
    ];
    await tester.pumpAndSettle();

    double barOpacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: find.byType(GlassTopBar), matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;
    expect(barOpacity(), 0);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(barOpacity(), 1);
  });

  group('chat view', () {
    Future<FakeRepository> openMaya(WidgetTester tester) async {
      final repository = await pumpApp(tester);
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('the composer holds its four controls in one radius-20 field; empty, Send is a voice note', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openMaya(tester);
      final field = find.ancestor(of: find.byType(EditableText), matching: find.byType(Container)).first;
      final decoration = tester.widget<Container>(field).decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(20));
      const voice = 'Voice note, touch and hold to record';
      for (final label in ['Add photos, a sticker or a mention', 'Emoji and stickers', voice]) {
        expect(
          find.descendant(of: field, matching: find.bySemanticsLabel(label)),
          findsOneWidget,
          reason: label,
        );
      }
      // Nothing to send: the Send slot is the mic, and no fifth control.
      expect(find.descendant(of: field, matching: find.byIcon(FLucideIcons.mic)), findsOneWidget);
      expect(find.descendant(of: field, matching: find.byIcon(FLucideIcons.arrowUp)), findsNothing);

      await tester.enterText(find.byType(EditableText), 'hi');
      await tester.pump();
      expect(find.bySemanticsLabel(voice), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Send')).getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(find.descendant(of: field, matching: find.byIcon(FLucideIcons.arrowUp)), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the time sits under the last bubble of a run, after a day separator', (tester) async {
      final repository = await openMaya(tester);
      final at = repository.history['c-maya']!.last.createdAt;
      for (final (i, minutes) in [1, 2].indexed) {
        repository.push(
          'c-maya',
          MessageCreated(
            ChatMessage(
              id: 'run-$i',
              authorId: FakeRepository.maya,
              authorName: 'Maya',
              content: 'run $i',
              createdAt: at.add(Duration(minutes: minutes)),
            ),
          ),
        );
      }
      await tester.pumpAndSettle();
      // One separator for the one day.
      expect(find.text(dayLabel(at, DateTime.now())), findsOneWidget);
      // run 0 and run 1 are one run: the time under run 1 only, below it.
      expect(find.text('09:01'), findsNothing);
      final time = find.text('09:02');
      expect(time, findsOneWidget);
      expect(tester.getTopLeft(time).dy, greaterThan(tester.getBottomLeft(find.text('run 1')).dy));
      // Maya's name over her run's first bubble.
      expect(find.text('Maya'), findsWidgets);
    });

    test('day separators read Today, Yesterday, then dates', () {
      final now = DateTime(2026, 10, 23, 18);
      expect(dayLabel(DateTime(2026, 10, 23, 1), now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 22, 23), now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 10, 19), now), 'Monday, 19 October');
      expect(dayLabel(DateTime(2025, 12, 31), now), '31 December 2025');
    });

    testWidgets('member rows: 48pt avatars and the status as a caption', (tester) async {
      final semantics = tester.ensureSemantics();
      await openMaya(tester);
      await tester.tap(find.bySemanticsLabel('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Members'));
      await tester.pumpAndSettle();
      expect(find.text('Online · @maya'), findsOneWidget);
      expect(tester.getSize(find.byType(PresenceAvatar).first), const Size(48, 48));
      semantics.dispose();
    });
  });
}
