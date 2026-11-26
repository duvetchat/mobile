import 'package:duvet/data/appearance.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/sync.dart';
import 'package:duvet/encryption/conversation_state.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../support/fake_repository.dart';

// What a conversation says over its message box of its encrypted group (PLAN-E2E-CLIENTES.md, «Avisos»): nothing while
// the group goes on; else why it can't, in the notices' words, and what the person can do about it. The desktop's
// ConversationState.test.ts, and the bar in its place in the chat.
Widget _app(Widget child) => MaterialApp(
  theme: Duvet.material(Brightness.light),
  home: FTheme(
    data: Duvet.theme(Brightness.light),
    child: Scaffold(body: child),
  ),
);

void main() {
  final taps = <String>[];

  Widget bar(ConversationState? state) => _app(
    ConversationStateBar(
      state: state,
      nameOf: (user) => const {'ana': 'Ana', 'bo': 'Bo'}[user] ?? 'Someone',
      onRestart: () async => taps.add('restart'),
      onAccept: () async => taps.add('accept'),
    ),
  );

  setUp(taps.clear);

  testWidgets('says_nothing_while_its_group_goes_on', (tester) async {
    await tester.pumpWidget(bar(null));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets(
    'a_blocked_group:_its_restart_for_whoever_may,_the_wait_for_the_others,_and_nothing_past_a_key_of_another',
    (tester) async {
      await tester.pumpWidget(bar(ConversationState.blocked(restart: Restart.mine, owner: 'ana')));
      expect(find.text(Notice.blocked.text), findsOneWidget);
      await tester.tap(find.text(Notice.blockedOwner.text));
      await tester.pumpAndSettle();
      expect(taps, ['restart']);

      await tester.pumpWidget(bar(ConversationState.blocked(restart: Restart.owner, owner: 'ana')));
      expect(find.text('${Notice.blocked.text} ${Notice.blockedWait.fill({'owner': 'Ana'})}'), findsOneWidget);
      expect(find.text(Notice.blockedOwner.text), findsNothing);

      await tester.pumpWidget(bar(ConversationState.blocked(restart: Restart.none)));
      expect(find.text(Notice.blocked.text), findsOneWidget);
      expect(find.textContaining('Waiting for'), findsNothing);
      expect(find.text(Notice.blockedOwner.text), findsNothing);
    },
  );

  testWidgets('waiting_for_the_owner,_or_for_another_member_to_let_this_device_back_in', (tester) async {
    await tester.pumpWidget(bar(ConversationState.waitOwner('ana')));
    expect(find.text(Notice.waitOwner.fill({'owner': 'Ana'})), findsOneWidget);
    await tester.pumpWidget(bar(ConversationState.waitRejoin));
    expect(find.text(Notice.waitRejoin.text), findsOneWidget);
  });

  testWidgets("members_that_changed_since_the_device_last_saw_them,_and_the_person's_yes", (tester) async {
    await tester.pumpWidget(bar(ConversationState.membersChanged));
    expect(find.text(Notice.membersChanged.text), findsOneWidget);
    await tester.tap(find.text(Notice.membersAccept.text));
    await tester.pumpAndSettle();
    expect(taps, ['accept']);
  });

  testWidgets('members_without_a_device_are_named_before_anything_is_sent', (tester) async {
    await tester.pumpWidget(bar(const ConversationState.noDevice(['ana', 'bo'])));
    expect(find.text(Notice.noDevice.fill({'name': 'Ana and Bo'})), findsOneWidget);
    await tester.pumpWidget(bar(const ConversationState.noDevice(['ana'])));
    expect(find.text(Notice.noDevice.fill({'name': 'Ana'})), findsOneWidget);
    expect(peopleNamed(['Ana', 'Bo', 'Cy']), 'Ana, Bo and Cy');
  });

  testWidgets("a_conversation's_state_shows_over_its_message_box,_and_its_restart_goes_to_the_engine", (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    final appearance = Appearance(MemoryAppearanceStore());
    await appearance.load();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    repository.conversationStates.value = {
      'c-maya': ConversationState.blocked(restart: Restart.mine, owner: FakeRepository.maya),
    };
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final notice = find.text(Notice.blocked.text);
    expect(notice, findsOneWidget);
    // Over the message box: above its field.
    expect(tester.getBottomLeft(notice).dy, lessThan(tester.getTopLeft(find.byType(EditableText).last).dy));
    await tester.tap(find.text(Notice.blockedOwner.text));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['restartGroup c-maya']);
    // Once the group goes on, nothing.
    repository.conversationStates.value = {};
    await tester.pumpAndSettle();
    expect(find.text(Notice.blocked.text), findsNothing);
  });

  // The core's #46: a restart that leaves someone out names them, and goes only on the person's yes.
  testWidgets('a_restart_that_leaves_someone_out_asks_first', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository()..restartLeavesOut = [FakeRepository.leo];
    final appearance = Appearance(MemoryAppearanceStore());
    await appearance.load();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    repository.conversationStates.value = {
      'c-maya': ConversationState.blocked(restart: Restart.mine, owner: FakeRepository.maya),
    };
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Notice.blockedOwner.text));
    await tester.pumpAndSettle();
    final leo = repository.nameOf(FakeRepository.leo)!;
    expect(find.text(Notice.restartLeavesOut.fill({'names': leo})), findsOneWidget);
    // Cancel: nothing more goes.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['restartGroup c-maya']);
    // Yes: the restart goes, leaving them out.
    await tester.tap(find.text(Notice.blockedOwner.text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Notice.blockedOwner.text).last);
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, [
      'restartGroup c-maya',
      'restartGroup c-maya',
      'restartGroup c-maya [${FakeRepository.leo}]',
    ]);
  });
}
