import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/members_sheet.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/depth.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:duvet/widgets/rows.dart';
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

  test('the type ramp is Fira Sans, headlines at 1.1 and text at 1.4', () {
    expect(DuvetType.largeTitle.fontFamily, 'Fira Sans');
    expect(
      (DuvetType.largeTitle.fontSize, DuvetType.largeTitle.height, DuvetType.largeTitle.fontWeight),
      (34, 1.1, FontWeight.w700),
    );
    expect((DuvetType.navTitle.fontSize, DuvetType.title.fontSize), (17, 20));
    expect((DuvetType.body.fontSize, DuvetType.body.height, DuvetType.body.fontWeight), (16, 1.4, FontWeight.w400));
    expect(DuvetType.rowTitle.fontWeight, FontWeight.w500);
    expect(DuvetType.rowTitleUnread.fontWeight, FontWeight.w700);
    expect((DuvetType.snippet.fontSize, DuvetType.caption.fontSize), (15, 13));
    expect((DuvetType.overline.fontSize, DuvetType.tabLabel.fontSize), (14, 11));
    // Headers as written, never in tracked capitals.
    expect(DuvetType.overline.letterSpacing, isNull);
    // forui's own widgets read the same face.
    final theme = Duvet.theme(Brightness.light);
    expect(theme.typography.body.fontFamily, 'Fira Sans');
    expect(theme.typography.body.sm.fontSize, 16);
  });

  testWidgets('a floating surface is a cushion, not glass; only a picture is frosted', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: const GlassSurface(child: SizedBox.square(dimension: 40)),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    final cushion = tester.widget<InsetShadow>(find.byType(InsetShadow));
    expect(cushion.shadows, DuvetTokens.light.cushion);
    // The image viewer's bars still frost the picture under them.
    expect(glassBackdrop(16).toString(), allOf(contains('matrix'), contains('blur')));
  });

  testWidgets('the tab bar floats, a 60pt cushion, and its pill moves to the active tab', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    final bar = find.byType(DuvetTabBar);
    // 60 tall, 12 off the bottom with no safe area there.
    expect(tester.getSize(bar).height, 72);
    expect(find.descendant(of: bar, matching: find.byType(BackdropFilter)), findsNothing);

    double pillLeft() => tester.getTopLeft(find.descendant(of: bar, matching: find.byType(AnimatedPositioned))).dx;
    // 12 in from the screen's edge and 6 inside the bar: the first of four
    // 88.5pt columns.
    expect(pillLeft(), closeTo(12 + 6, 0.01));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Chats').last).getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );

    await tab(tester, 'Spaces');
    expect(pillLeft(), closeTo(12 + 6 + 88.5, 0.01));
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

    testWidgets('the composer holds its four controls in one round cushion; empty, Send is a voice note', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openMaya(tester);
      final field = find.ancestor(of: find.byType(EditableText), matching: find.byType(Container)).first;
      final decoration = tester.widget<Container>(field).decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(24));
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
