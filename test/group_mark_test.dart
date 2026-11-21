// #288: a group has no picture, and a face made from its name, as a person
// without one gets, would read as someone's. Wherever a group shows in a
// person's place it has the desktop's group mark (desktop#376: lucide's
// users-round), never a face; a DM still shows the other person.
import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/call_presence.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FLucideIcons;

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

class _App {
  final repository = FakeRepository();
  final engine = FakeVoiceEngine();
  late final voice = VoiceController(
    repository: repository,
    engine: engine,
    historyStore: MemoryCallHistoryStore(),
    clock: () => DateTime(2026, 10, 23, 10),
  );

  FakeVoiceSignaling get gateway => repository.voiceSignaling;
}

void main() {
  late SemanticsHandle semantics;

  Future<_App> pumpApp(WidgetTester tester) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final app = _App();
    await tester.pumpWidget(DuvetApp(repository: app.repository, voice: app.voice));
    await tester.pumpAndSettle();
    return app;
  }

  // A call's screens tick: settle by time, not by frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Unmounts the app, then ends voice: no timer outlives the test.
  Future<void> finish(WidgetTester tester, _App app) async {
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    app.voice.dispose();
  }

  final mark = find.byIcon(FLucideIcons.usersRound);

  // The group's mark under [where], and no face.
  void marked(Finder where) {
    expect(find.descendant(of: where, matching: mark), findsOneWidget);
    expect(find.descendant(of: where, matching: find.byType(Facehash)), findsNothing);
  }

  Finder rowOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListRow)).first;

  testWidgets('a group\'s row in the chats has its mark; a DM\'s shows the other person', (tester) async {
    final app = await pumpApp(tester);
    marked(rowOf('Design crew'));
    expect(find.descendant(of: rowOf('Maya'), matching: mark), findsNothing);
    expect(find.descendant(of: rowOf('Maya'), matching: find.byType(Facehash)), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('a call going on in a group has its mark above the chats', (tester) async {
    final app = await pumpApp(tester);
    app.gateway.push(
      const duvet.CallOngoingPayloadEvent(
        duvet.CallOngoingEvent(
          conversationId: 'c-team',
          initiatorId: FakeRepository.leo,
          voiceStates: [duvet.CallVoiceState(userId: FakeRepository.leo, version: 1)],
        ),
      ),
    );
    await settle(tester);
    marked(find.byType(CallPresenceCard));
    await finish(tester, app);
  });

  testWidgets('a call to a group shows its mark while it rings out', (tester) async {
    final app = await pumpApp(tester);
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Call'));
    await settle(tester);
    expect(find.text('Calling…'), findsWidgets);
    expect(mark, findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Facehash && w.name == 'Design crew'), findsNothing);
    await finish(tester, app);
  });

  testWidgets('a group\'s call in the Calls tab has its mark; a DM\'s, the other person', (tester) async {
    final app = await pumpApp(tester);
    for (final (id, caller) in [('c-team', FakeRepository.leo), ('c-maya', FakeRepository.maya)]) {
      app.gateway.push(
        duvet.CallIncomingPayloadEvent(
          duvet.CallIncomingEvent(conversationId: id, initiatorId: caller, initiatorName: 'x'),
        ),
      );
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Decline the call'));
      await settle(tester);
      app.gateway.push(duvet.CallEndedPayloadEvent(duvet.CallEndedEvent(conversationId: id)));
      await settle(tester);
    }
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Calls')));
    await settle(tester);
    marked(rowOf('Design crew'));
    expect(find.descendant(of: rowOf('Maya'), matching: mark), findsNothing);
    expect(find.descendant(of: rowOf('Maya'), matching: find.byType(Facehash)), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('a group\'s info has its mark over its name, not its people\'s faces stacked', (tester) async {
    final app = await pumpApp(tester);
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Group info'));
    await tester.pumpAndSettle();
    expect(find.text('Group info'), findsOneWidget);
    expect(mark, findsOneWidget);
    // The people are listed under it, each with their own face, at the list's size.
    expect(find.byWidgetPredicate((w) => w is UserAvatar && w.size != 40), findsNothing);
    await finish(tester, app);
  });
}
