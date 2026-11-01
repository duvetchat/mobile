import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/duvet_mascot.dart';
import 'package:duvet/widgets/ghost_art.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// The ghost in the screens: Welcome, the empty DM, the typing line.
void main() {
  Future<FakeRepository> pumpApp(WidgetTester tester, {bool signedIn = true}) async {
    final repository = FakeRepository(signedIn: signedIn);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('Welcome opens either form, and the forms trade places so Back always lands on Welcome', (tester) async {
    await pumpApp(tester, signedIn: false);
    expect(find.text('Talk with your people.'), findsOneWidget);

    await tap(tester, 'Sign in');
    expect(find.text('Sign in to Duvet'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Talk with your people.'), findsOneWidget);

    await tap(tester, 'Create account');
    expect(find.text('Create your account'), findsOneWidget);
    // Sign up's "Sign in" swaps in the sign-in form; Back skips past both.
    await tap(tester, 'Sign in');
    expect(find.text('Sign in to Duvet'), findsOneWidget);
    await tap(tester, 'Create an account');
    expect(find.text('Create your account'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Talk with your people.'), findsOneWidget);
  });

  testWidgets('a new DM shows the ghost tucked in; a quick line fills the composer without sending', (tester) async {
    final repository = await pumpApp(tester);
    await tap(tester, 'Leo');

    expect(find.text('Just you and Leo'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is DuvetMascot && w.state == MascotState.underDuvet), findsOneWidget);

    await tap(tester, 'How’s it going?');
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'How’s it going?');
    expect(repository.sent, isEmpty);
  });

  testWidgets('a group conversation with no messages is tucked in too, under its name', (tester) async {
    final repository = await pumpApp(tester);
    repository.history['c-team'] = [];
    await tap(tester, 'Design crew');
    expect(find.text('Just you and Design crew'), findsOneWidget);
  });

  testWidgets('someone typing shows the ghost and its dots beside the sentence', (tester) async {
    final repository = await pumpApp(tester);
    await tap(tester, 'Maya');
    repository.pushTyping('c-maya', const TypingUser(userId: FakeRepository.maya, name: 'Maya'));
    // A broadcast stream delivers in a microtask, after the first frame.
    await tester.pump();
    await tester.pump();
    expect(find.text('Maya is typing…'), findsOneWidget);
    expect(find.byType(GhostMark), findsOneWidget);
    expect(find.byType(TypingDots), findsOneWidget);
    // Gone when they stop, so nothing keeps animating.
    await tester.pump(const Duration(seconds: 7));
    expect(find.byType(TypingDots), findsNothing);
  });

  testWidgets('the typing dots hold still when the system asks for less motion', (tester) async {
    Widget dots({required bool reduce}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: const Center(child: TypingDots(color: Color(0xFF6A58D6))),
      ),
    );
    await tester.pumpWidget(dots(reduce: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(dots(reduce: false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('the ghost shrinks instead of overflowing when an empty state is short', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 200,
              child: EmptyState(mascot: MascotState.oops, text: 'Couldn’t load messages'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // FittedBox scales the art as it paints, so its box is what shrinks.
    final box = find.ancestor(of: find.byType(DuvetMascot), matching: find.byType(FittedBox)).first;
    expect(tester.getSize(box).height, lessThan(160));
  });
}
