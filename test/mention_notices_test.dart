import 'package:duvet/chat_view.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/sounds.dart';
import 'package:duvet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _Player implements SoundPlayer {
  final played = <Sound>[];

  @override
  Future<void> play(Sound sound, double gain, {bool loop = false, bool aloud = false, VoidCallback? onDone}) async =>
      played.add(sound);

  @override
  Future<void> stop(Sound sound) async {}

  @override
  Future<void> dispose() async {}
}

class _Ringer implements RingerMode {
  @override
  Future<bool> quiet() async => false;
}

const _general = RoomTarget(spaceId: 's-guild', roomId: 'r-general');
const _notice = MentionNotice(
  messageId: 'm3',
  target: _general,
  title: '# general',
  authorName: 'Leo',
  where: 'in #general · Design Guild',
  text: 'Pushed the new type ramp',
);

/// A mention of the user in a chat that isn't on screen shows a notice at the
/// top, over every screen (#80).
void main() {
  late SemanticsHandle semantics;

  Future<FakeRepository> pumpApp(WidgetTester tester) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    final appearance = Appearance(MemoryAppearanceStore());
    await appearance.load();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> openMaya(WidgetTester tester) async {
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
  }

  Finder card() => find.bySemanticsLabel('Leo mentioned you in #general · Design Guild: Pushed the new type ramp');

  testWidgets('shows over an open chat who, where and what; a tap opens the message', (tester) async {
    final repository = await pumpApp(tester);
    await openMaya(tester);
    repository.mentionNotices.value = [_notice];
    await tester.pumpAndSettle();
    expect(card(), findsOneWidget);
    expect(find.text('Pushed the new type ramp'), findsOneWidget);

    await tester.tap(card());
    await tester.pumpAndSettle();
    final opened = tester.widget<ChatView>(find.byType(ChatView).last);
    expect((opened.target, opened.title, opened.jumpTo), (_general, '# general', 'm3'));
    expect(repository.mentionNotices.value, isEmpty);
    expect(card(), findsNothing);
    // The message's flash, once there.
    await tester.pump(const Duration(seconds: 1));
    semantics.dispose();
  });

  testWidgets('touches around it reach the screen under it', (tester) async {
    final repository = await pumpApp(tester);
    repository.mentionNotices.value = [_notice];
    await tester.pumpAndSettle();
    await openMaya(tester);
    expect(tester.widget<ChatView>(find.byType(ChatView)).target, const ConversationTarget('c-maya'));
    // Another chat's notice stays.
    expect(card(), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a swipe up takes it away', (tester) async {
    final repository = await pumpApp(tester);
    repository.mentionNotices.value = [_notice];
    await tester.pumpAndSettle();
    await tester.drag(card(), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(repository.mentionNotices.value, isEmpty);
    expect(find.byType(ChatView), findsNothing);
    semantics.dispose();
  });

  testWidgets('a chat says it\'s on screen while it\'s on top, and no longer once closed', (tester) async {
    final repository = await pumpApp(tester);
    expect(repository.onScreen, isNull);
    await openMaya(tester);
    expect(repository.onScreen, (chatId: 'c-maya', threadOf: null));
    // Not with the app in the background.
    void lifecycle(List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    lifecycle([AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    expect(repository.onScreen, isNull);
    lifecycle([AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    expect(repository.onScreen, (chatId: 'c-maya', threadOf: null));

    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(repository.onScreen, isNull);
    semantics.dispose();
  });

  testWidgets('a new notice plays the mention sound once; one already shown doesn\'t again', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    final appearance = Appearance(MemoryAppearanceStore());
    await appearance.load();
    addTearDown(appearance.dispose);
    final player = _Player();
    final sounds = Sounds(player: player, ringer: _Ringer());
    addTearDown(sounds.dispose);
    await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance, sounds: sounds));
    await tester.pumpAndSettle();

    repository.mentionNotices.value = [_notice];
    await tester.pumpAndSettle();
    expect(player.played, [Sound.mention]);

    // Another change of the list with nothing new in it: no sound.
    repository.mentionNotices.value = [...repository.mentionNotices.value];
    await tester.pumpAndSettle();
    repository.dismissMentionNotice(_notice.messageId);
    await tester.pumpAndSettle();
    expect(player.played, [Sound.mention]);
  });
}
