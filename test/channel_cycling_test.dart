import 'package:duvet/chat_view.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

const _general = RoomTarget(spaceId: 's-guild', roomId: 'r-general');
const _random = RoomTarget(spaceId: 's-guild', roomId: 'r-random');

/// Going back and forth between two rooms, by their mentions' notices and by the Channel Switcher: Back retraces
/// the way, and never stays in the room it leaves.
void main() {
  const phone = Size(390, 844);
  const tablet = Size(1194, 834);
  late SemanticsHandle semantics;

  setUpAll(() => DeepLinkSource.instance = _NoLinks());

  // The semantics handle goes before the test's end checks look for one left open.
  void testRooms(String description, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(description, (tester) async {
        try {
          await body(tester);
        } finally {
          semantics.dispose();
        }
      });

  // Design Guild with a second text room, #random.
  Future<FakeRepository> pumpApp(WidgetTester tester, Size size) async {
    semantics = tester.ensureSemantics();
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = size * 2;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    final guild = repository.spaces.value.single;
    repository.spaces.value = [
      Space(
        id: guild.id,
        name: guild.name,
        onlineCount: guild.onlineCount,
        ownerId: guild.ownerId,
        sections: [
          RoomSection(
            name: null,
            rooms: [
              ...guild.sections.first.rooms,
              const Room(id: 'r-random', spaceId: 's-guild', name: 'random', kind: RoomKind.text, position: 1),
            ],
          ),
          ...guild.sections.skip(1),
        ],
      ),
    ];
    repository.history['r-random'] = [
      FakeRepository.message('m-r1', author: FakeRepository.maya, name: 'Maya', text: 'Anyone for lunch?'),
    ];
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  // The chats on screen, and all of them, those under the one on top too.
  List<String> shown() => [for (final c in find.byType(ChatView).evaluate()) (c.widget as ChatView).target.id];
  int stacked() => find.byType(ChatView, skipOffstage: false).evaluate().length;

  var mentions = 0;
  // Someone mentions the user in [room], and they tap its notice.
  Future<void> tapMention(WidgetTester tester, FakeRepository repository, RoomTarget room) async {
    final name = room == _general ? 'general' : 'random';
    final id = 'mention-${mentions++}';
    repository.history[room.id]!.add(
      FakeRepository.message(id, author: FakeRepository.leo, name: 'Leo', text: 'Ping $id'),
    );
    repository.mentionNotices.value = [
      MentionNotice(
        messageId: id,
        target: room,
        title: '# $name',
        authorName: 'Leo',
        where: 'in #$name · Design Guild',
        text: 'Ping $id',
      ),
    ];
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Leo mentioned you in #$name · Design Guild: Ping $id'));
    await tester.pumpAndSettle();
    // The message's flash.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  // The room [name] picked in the Channel Switcher, opened from the title of the chat on top.
  Future<void> switchTo(WidgetTester tester, String name) async {
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Channel .*switch channel$')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^# $name')).last);
    await tester.pumpAndSettle();
  }

  // Back, from the chat's own button, as many times as it takes to leave the chats: what each one showed.
  // Or the system's ([system]): Android's Back.
  Future<List<String>> backOut(WidgetTester tester, {bool system = false}) async {
    final way = <String>[];
    for (var i = 0; i < 10 && shown().isNotEmpty; i++) {
      if (system) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.bySemanticsLabel('Back').last);
      }
      await tester.pumpAndSettle();
      way.add(shown().lastOrNull ?? 'home');
    }
    return way;
  }

  testRooms('the room a notice opened over switched back to the one under it: one Back leaves it', (tester) async {
    final repository = await pumpApp(tester, phone);
    await openGeneral(tester);
    await tapMention(tester, repository, _random);
    expect(shown(), [_random.id]);
    expect(stacked(), 2);

    await switchTo(tester, 'general');
    expect(shown(), [_general.id]);
    // The #general under it, not a second one over it, on screen again: its mentions show no notice.
    expect(stacked(), 1);
    await tester.pump();
    expect(repository.onScreen, (chatId: _general.id, threadOf: null));
    expect(await backOut(tester), ['home']);
    expect(find.text('# general'), findsOneWidget);
  });

  testRooms('two rooms switched back and forth after a mention: Back never stays in the room it leaves', (
    tester,
  ) async {
    final repository = await pumpApp(tester, phone);
    await openGeneral(tester);
    await tapMention(tester, repository, _random);
    for (final name in ['general', 'random', 'general', 'random', 'general']) {
      await switchTo(tester, name);
      expect(shown(), ['r-$name']);
      expect(stacked(), 1);
    }
    expect(await backOut(tester, system: true), ['home']);
  });

  testRooms('switching from a room opened over a different one swaps only it', (tester) async {
    final repository = await pumpApp(tester, phone);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tapMention(tester, repository, _random);
    await switchTo(tester, 'general');
    expect(shown(), [_general.id]);
    expect(stacked(), 2);
    expect(await backOut(tester), ['c-maya', 'home']);
  });

  testRooms('mentions in two rooms tapped in turn: Back retraces the way, one room at a time', (tester) async {
    final repository = await pumpApp(tester, phone);
    await openGeneral(tester);
    for (final room in [_random, _general, _random]) {
      await tapMention(tester, repository, room);
      expect(shown(), [room.id]);
    }
    expect(stacked(), 4);
    expect(await backOut(tester), [_general.id, _random.id, _general.id, 'home']);
  });

  testRooms('mentions and switches mixed: Back never stays in the room it leaves', (tester) async {
    final repository = await pumpApp(tester, phone);
    await openGeneral(tester);
    await tapMention(tester, repository, _random); // general, random
    await tapMention(tester, repository, _general); // general, random, general
    await switchTo(tester, 'random'); // general, random
    expect(stacked(), 2);
    await tapMention(tester, repository, _general); // general, random, general
    await switchTo(tester, 'random'); // general, random
    await switchTo(tester, 'general'); // general
    expect(stacked(), 1);
    expect(await backOut(tester), ['home']);
  });

  testRooms('a mention tapped over the switcher\'s sheet: Back goes back to it, and its pick swaps the room under it', (
    tester,
  ) async {
    final repository = await pumpApp(tester, phone);
    await openGeneral(tester);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Channel general.*switch channel$')).last);
    await tester.pumpAndSettle();
    // Over the sheet, which stays under it.
    await tapMention(tester, repository, _random);
    expect(shown(), [_random.id]);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^# random')).last);
    await tester.pumpAndSettle();
    expect(shown(), [_random.id]);
    expect(stacked(), 1);
    expect(await backOut(tester), ['home']);
  });

  testRooms('in the pane, a room opened over another and switched back to it closes onto it', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.byType(RailButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    // As a link in one of its messages opens another room's message, in the pane over it.
    Navigator.of(tester.element(find.byType(ChatView))).push(ChatRoute(target: _random, title: '# random'));
    await tester.pumpAndSettle();
    expect(stacked(), 2);

    await switchTo(tester, 'general');
    expect(shown(), [_general.id]);
    expect(stacked(), 1);
    // The pane's own chat: nothing under it to go back to.
    expect(
      find.descendant(
        of: find.byType(ChatView),
        matching: find.byWidgetPredicate((w) => w is IconAction && w.label == 'Back'),
      ),
      findsNothing,
    );
  });
}
