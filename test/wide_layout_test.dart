import 'package:duvet/chat_view.dart';
import 'package:duvet/data/links.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/members_sheet.dart';
import 'package:duvet/people.dart';
import 'package:duvet/shell.dart';
import 'package:duvet/tabs.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/ghost_art.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// The wide layout (#133): the desktop's rail, list and chat pane where the window is wide, the phone's tabs
/// where it isn't, and the open chat kept across the two.
void main() {
  const phone = Size(390, 844);
  const tabletUpright = Size(834, 1194);
  const tablet = Size(1194, 834);
  const phoneOnItsSide = Size(874, 402);

  setUpAll(() => DeepLinkSource.instance = _NoLinks());

  void window(WidgetTester tester, Size size, {FakeViewPadding padding = FakeViewPadding.zero}) {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = size * 2;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
  }

  Future<FakeRepository> pumpApp(
    WidgetTester tester,
    Size size, {
    FakeViewPadding padding = FakeViewPadding.zero,
  }) async {
    window(tester, size, padding: padding);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * 2;
    await tester.pumpAndSettle();
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await tester.tap(find.byType(RailButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  // Maya's conversation under IDs a link can name, with more messages than a screen shows: the first is off screen
  // as it opens.
  const longChat = ConversationTarget('01920000-0000-7000-8000-000000000001');
  String messageId(int i) => '01920000-0000-7000-8000-${i.toString().padLeft(12, '0')}';

  Future<FakeRepository> pumpLongChat(WidgetTester tester, Size size) async {
    final repository = await pumpApp(tester, size);
    repository.conversations.value = [
      ConversationSummary(id: longChat.id, title: 'Maya', isGroup: false, otherUserId: FakeRepository.maya),
      ...repository.conversations.value.skip(1),
    ];
    repository.history[longChat.id] = [
      for (var i = 0; i < 60; i++)
        FakeRepository.message(messageId(i), author: FakeRepository.maya, name: 'Maya', text: 'Message $i'),
    ];
    await tester.pumpAndSettle();
    return repository;
  }

  Future<FakeRepository> openLongChat(WidgetTester tester, Size size) async {
    final repository = await pumpLongChat(tester, size);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
  }

  test('the size classes go by width', () {
    expect(SizeClass.of(390), SizeClass.compact);
    expect(SizeClass.of(719), SizeClass.compact);
    expect(SizeClass.of(720), SizeClass.medium);
    expect(SizeClass.of(834), SizeClass.medium);
    expect(SizeClass.of(1194), SizeClass.expanded);
    expect(SizeClass.compact.wide, isFalse);
    expect(SizeClass.medium.wide, isTrue);
  });

  testWidgets('a phone keeps its tab bar, and a chat covers it', (tester) async {
    await pumpApp(tester, phone);
    expect(find.byType(DuvetTabBar), findsOneWidget);
    expect(find.byType(DuvetNavRail), findsNothing);
    expect(find.byType(PaneEmpty), findsNothing);

    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(DuvetTabBar), findsNothing);
    expect(tester.getSize(find.byType(ChatView)).width, phone.width);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
  });

  testWidgets('a tablet upright shows the rail, the list and the pane; a chat opens in the pane', (tester) async {
    await pumpApp(tester, tabletUpright);
    expect(find.byType(DuvetTabBar), findsNothing);
    expect(find.byType(DuvetNavRail), findsOneWidget);
    expect(find.byType(ChatsTab), findsOneWidget);
    expect(find.text('Pick a chat to open it here'), findsOneWidget);
    expect(tester.getSize(find.byType(DuvetNavRail)).width, ShellSizes.rail);
    expect(tester.getSize(find.byType(ChatsTab)).width, ShellSizes.list(tabletUpright.width));

    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    // Beside the list, which stays, and with nothing to go back to.
    expect(find.byType(ChatsTab), findsOneWidget);
    expect(find.byType(DuvetNavRail), findsOneWidget);
    expect(find.text('Pick a chat to open it here'), findsNothing);
    final chat = tester.getRect(find.byType(ChatView));
    expect(chat.left, ShellSizes.rail + ShellSizes.list(tabletUpright.width) + 2);
    expect(chat.right, tabletUpright.width);
    expect(find.bySemanticsLabel('Back'), findsNothing);
    // Not enough room for the members here.
    expect(find.byType(MembersPanel), findsNothing);

    // Another chat takes its place.
    await tester.tap(find.text('Leo'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsOneWidget);
    expect(tester.widget<ChatView>(find.byType(ChatView)).target.id, 'c-leo');
    expect(find.bySemanticsLabel('Back'), findsNothing);
  });

  testWidgets('the rail opens a Space\'s rooms in the list, and its room in the pane with its members beside it', (
    tester,
  ) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.byType(RailButton).first);
    await tester.pumpAndSettle();
    expect(find.byType(SpaceDirectory), findsOneWidget);
    expect(tester.getSize(find.byType(SpaceDirectory)).width, ShellSizes.list(tablet.width));
    expect(tester.widget<RailButton>(find.byType(RailButton).first).selected, isTrue);

    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    expect(find.byType(SpaceDirectory), findsOneWidget);
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(MembersPanel), findsOneWidget);
    expect(tester.getSize(find.byType(MembersPanel)).width, ShellSizes.members);
    expect(tester.getRect(find.byType(MembersPanel)).right, tablet.width);

    // The chat's menu hides them, and shows them again.
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide members'));
    await tester.pumpAndSettle();
    expect(find.byType(MembersPanel), findsNothing);
    expect(tester.getRect(find.byType(ChatView)).right, tablet.width);
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    expect(find.text('Show members'), findsOneWidget);

    // A DM has none to show: its menu opens the sheet as on a phone.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Chats').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    expect(find.text('Members'), findsOneWidget);
  });

  testWidgets('the Spaces destination goes back to the Launchpad from a Space', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.byType(RailButton).first);
    await tester.pumpAndSettle();
    expect(find.byType(SpaceDirectory), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Spaces'));
    await tester.pumpAndSettle();
    expect(find.byType(SpaceDirectory), findsNothing);
    expect(find.byType(SpacesTab), findsOneWidget);
    expect(tester.widget<RailButton>(find.byType(RailButton).first).selected, isFalse);
  });

  testWidgets('a long phone on its side takes the two panes, clear of the notch', (tester) async {
    await pumpApp(tester, phoneOnItsSide, padding: const FakeViewPadding(left: 124, right: 124, bottom: 42));
    expect(find.byType(DuvetNavRail), findsOneWidget);
    expect(find.byType(DuvetTabBar), findsNothing);
    expect(tester.getRect(find.byType(DuvetNavRail)).left, 62);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ChatView)).right, phoneOnItsSide.width - 62);
    expect(find.byType(MembersPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short phone on its side keeps the tabs, clear of the notch', (tester) async {
    await pumpApp(tester, const Size(667, 375), padding: const FakeViewPadding(left: 88, right: 88));
    expect(find.byType(DuvetTabBar), findsOneWidget);
    final bar = tester.getRect(find.byType(DuvetTabBar));
    expect(bar.left, 44);
    expect(bar.right, 667 - 44);
  });

  testWidgets('a chat open in the pane stays open, as it was, when the window narrows; Back leaves it', (tester) async {
    await pumpApp(tester, tablet);
    await openGeneral(tester);
    // The composer's, before the members' search.
    await tester.enterText(find.byType(EditableText).first, 'half a thought');
    final state = tester.state(find.byType(ChatView));

    await resize(tester, phone);
    expect(find.byType(DuvetNavRail), findsNothing);
    expect(find.byType(ChatView), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), same(state));
    expect(tester.getSize(find.byType(ChatView)), phone);
    expect(find.text('half a thought'), findsOneWidget);
    expect(find.byType(MembersPanel), findsNothing);
    // Over the tabs now, with a way back to them.
    expect(find.byType(DuvetTabBar), findsNothing);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsNothing);
    expect(find.byType(DuvetTabBar), findsOneWidget);
    // The tab it was opened from is still the one showing, in its Space.
    expect(find.byType(SpaceDirectory), findsOneWidget);
  });

  testWidgets('a chat open over the tabs moves into the pane, as it was, when the window widens', (tester) async {
    await pumpApp(tester, phone);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'half a thought');
    final state = tester.state(find.byType(ChatView));

    await resize(tester, tablet);
    expect(find.byType(DuvetNavRail), findsOneWidget);
    expect(find.byType(ChatsTab), findsOneWidget);
    expect(find.byType(ChatView), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), same(state));
    expect(find.text('half a thought'), findsOneWidget);
    expect(tester.getRect(find.byType(ChatView)).left, ShellSizes.rail + ShellSizes.list(tablet.width) + 2);
    expect(find.bySemanticsLabel('Back'), findsNothing);

    // And back, through a rotation or two.
    await resize(tester, phone);
    await resize(tester, tabletUpright);
    expect(tester.state(find.byType(ChatView)), same(state));
    expect(find.byType(DuvetNavRail), findsOneWidget);
  });

  testWidgets('the pane empties when its conversation is left', (tester) async {
    final repository = await pumpApp(tester, tablet);
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsOneWidget);
    repository.conversations.value = repository.conversations.value.where((c) => c.id != 'c-team').toList();
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsNothing);
    expect(find.text('Pick a chat to open it here'), findsOneWidget);
  });

  Future<FakeRepository> openThread(WidgetTester tester) async {
    final repository = await pumpApp(tester, tablet);
    repository.threads['m3'] = [
      repository.history['r-general']!.single,
      FakeRepository.message('t1', author: FakeRepository.maya, name: 'Maya', text: 'Looks great'),
    ];
    await openGeneral(tester);
    await tester.longPress(find.text('Pushed the new type ramp'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('View thread').hitTestable().last);
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('a thread opens in the pane over its chat, with a way back to it', (tester) async {
    await openThread(tester);
    expect(find.text('Thread'), findsOneWidget);
    expect(find.text('Looks great'), findsOneWidget);
    // Beside the list, not over it.
    expect(find.byType(SpaceDirectory), findsOneWidget);
    expect(tester.getRect(find.byType(ChatView).last).left, ShellSizes.rail + ShellSizes.list(tablet.width) + 2);
    // The thread's own, not the Space's in the list.
    await tester.tap(find.descendant(of: find.byType(ChatView).last, matching: find.bySemanticsLabel('Back')));
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsNothing);
    expect(find.byType(ChatView), findsOneWidget);
  });

  testWidgets('the system\'s Back goes back one step: the pane\'s thread, then the list\'s Space', (tester) async {
    await openThread(tester);
    expect(find.text('Thread'), findsOneWidget);
    expect(find.byType(SpaceDirectory), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsNothing);
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(SpaceDirectory), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SpaceDirectory), findsNothing);
    expect(find.byType(SpacesTab), findsOneWidget);
    expect(find.byType(ChatView), findsOneWidget);
  });

  testWidgets('the system\'s Back leaves a Space\'s rooms alone behind another tab', (tester) async {
    await openThread(tester);
    await tester.tap(find.bySemanticsLabel('Chats').first);
    await tester.pumpAndSettle();
    expect(find.byType(ChatsTab), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsNothing);
    expect(find.byType(SpaceDirectory, skipOffstage: false), findsOneWidget);
  });

  for (final (name, size, padding, keyboard) in [
    ('a tablet', tablet, FakeViewPadding.zero, 300.0),
    ('a tablet upright', tabletUpright, FakeViewPadding.zero, 300.0),
    ('a long phone on its side', phoneOnItsSide, const FakeViewPadding(left: 124, right: 124), 200.0),
  ]) {
    testWidgets('the keyboard lifts the pane\'s composer just over it, once, on $name', (tester) async {
      await pumpApp(tester, size, padding: padding);
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      final composer = find.descendant(of: find.byType(ChatView), matching: find.byType(EditableText));
      final gap = size.height - tester.getRect(composer).bottom;

      tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // As far over the keyboard as it was over the window's edge.
      expect(tester.getRect(composer).bottom, size.height - keyboard - gap);
      // The list ends at the keyboard; the rail stays behind it.
      expect(tester.getRect(find.byType(ChatsTab)).bottom, size.height - keyboard);
      expect(tester.getRect(find.byType(DuvetNavRail)).bottom, size.height);
    });
  }

  testWidgets('a menu opens at its button in the pane', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final button = find.bySemanticsLabel('Add photos, a sticker or a mention');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Add to message'), findsOneWidget);
    final menu = tester.getRect(find.byType(GlassSurface).last);
    expect(menu.width, 248);
    expect(menu.left, tester.getRect(button).left);
    expect(menu.bottom, lessThan(tester.getRect(button).top));

    // And under More, a margin from the pane's edge as from a phone's.
    await tester.tapAt(tester.getRect(find.byType(ChatView)).center);
    await tester.pumpAndSettle();
    final more = find.bySemanticsLabel('More');
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Pinned messages'), findsOneWidget);
    final moreMenu = tester.getRect(find.byType(GlassSurface).last);
    expect(moreMenu.width, 248);
    expect(moreMenu.right, tablet.width - 16);
    expect(moreMenu.top, greaterThan(tester.getRect(more).bottom));
  });

  testWidgets('a room\'s menu opens at its row in the list beside the rail', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.byType(RailButton).first);
    await tester.pumpAndSettle();
    final row = tester.getRect(find.text('# general'));
    await tester.longPress(find.text('# general'));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(GlassSurface).last);
    // Inside the list's column, 16 from its edge, not that much further right.
    expect(menu.left, ShellSizes.rail + 1 + 16);
    expect(menu.top, greaterThan(row.top));
  });

  testWidgets('a sheet opened from the pane\'s chat stays in the pane', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pinned messages'));
    await tester.pumpAndSettle();
    final pane = tester.getRect(find.byType(ChatView));
    final sheet = tester.getRect(find.byType(GlassSurface).last);
    expect(sheet.left, greaterThanOrEqualTo(pane.left));
    expect(sheet.right, lessThanOrEqualTo(pane.right));
    expect(sheet.width, lessThanOrEqualTo(ShellSizes.sheet));
    expect(sheet.center.dx, pane.center.dx);
  });

  testWidgets('a page open over the home screen stays over the pane\'s chat when the window narrows', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ChatView));
    await tester.tap(find.bySemanticsLabel('Friends'));
    await tester.pumpAndSettle();

    await resize(tester, phone);
    expect(find.byType(FriendsPage).hitTestable(), findsOneWidget);
    expect(find.byType(ChatView).hitTestable(), findsNothing);

    // The chat is under it, over the tabs once the page closes.
    await tester.tap(find.bySemanticsLabel('Back').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.byType(FriendsPage), findsNothing);
    expect(tester.state(find.byType(ChatView)), same(state));
    expect(tester.getSize(find.byType(ChatView)), phone);
    await tester.tap(find.bySemanticsLabel('Back').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsNothing);
    expect(find.byType(DuvetTabBar), findsOneWidget);
  });

  testWidgets('a notice\'s chat leaves a sheet open under it, and goes to the pane when it closes', (tester) async {
    final repository = await pumpApp(tester, tablet);
    final context = tester.element(find.byType(ChatsTab));
    showGlassDialogSheet<void>(
      context,
      label: 'Form',
      builder: (_) => const SizedBox(height: 120, child: Text('Half filled')),
    );
    await tester.pumpAndSettle();
    openChatRoute(
      context,
      ChatRoute(target: repository.conversations.value.first.target, title: 'Maya'),
      reveal: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Half filled', skipOffstage: false), findsOneWidget);
    expect(tester.getRect(find.byType(ChatView)).left, 0);

    await tester.tap(find.bySemanticsLabel('Back').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.text('Half filled'), findsOneWidget);
  });

  testWidgets('a full-screen route still reaches the edges of a phone on its side', (tester) async {
    const size = Size(667, 375);
    await pumpApp(tester, size, padding: const FakeViewPadding(left: 88, right: 88));
    final navigator = Navigator.of(tester.element(find.byType(HomeTabs)), rootNavigator: true);
    navigator.push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => const SizedBox.expand(key: Key('video')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('video'))), Offset.zero & size);
    navigator.pop();
    await tester.pumpAndSettle();

    // A chat is between the notch's sides, as the tabs are.
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final chat = tester.getRect(find.byType(ChatView));
    expect(chat.left, 44);
    expect(chat.right, size.width - 44);
  });

  testWidgets('the title\'s night sky shows on a narrow phone, not in the wide layout\'s list', (tester) async {
    await pumpApp(tester, const Size(360, 780));
    expect(find.descendant(of: find.byType(ChatsTab), matching: find.byType(NightSky)), findsOneWidget);
    await resize(tester, tablet);
    expect(find.descendant(of: find.byType(ChatsTab), matching: find.byType(NightSky)), findsNothing);
  });

  testWidgets('a full page is centered at a width that reads, and a chat opened from it closes it', (tester) async {
    final repository = await pumpApp(tester, tablet);
    await tester.tap(find.bySemanticsLabel('Friends'));
    await tester.pumpAndSettle();
    final page = tester.getRect(find.descendant(of: find.byType(FriendsPage), matching: find.byType(Scaffold)));
    expect(page.width, ShellSizes.page);
    expect(page.center.dx, tablet.width / 2);

    openChat(tester.element(find.byType(FriendsPage)), repository.conversations.value.first.target, 'Maya');
    await tester.pumpAndSettle();
    expect(find.byType(FriendsPage), findsNothing);
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.byType(DuvetNavRail), findsOneWidget);

    // On a phone the page fills the window.
    await resize(tester, phone);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Friends'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.descendant(of: find.byType(FriendsPage), matching: find.byType(Scaffold))), phone);
  });

  testWidgets('a notice\'s chat opens in the pane, or over a page left open', (tester) async {
    final repository = await pumpApp(tester, tablet);
    final context = tester.element(find.byType(ChatsTab));
    final maya = repository.conversations.value.first.target;
    openChatRoute(context, ChatRoute(target: maya, title: 'Maya'), reveal: false);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ChatView)).left, greaterThan(ShellSizes.rail));

    await tester.tap(find.bySemanticsLabel('Friends'));
    await tester.pumpAndSettle();
    final leo = repository.conversations.value[1].target;
    openChatRoute(tester.element(find.byType(FriendsPage)), ChatRoute(target: leo, title: 'Leo'), reveal: false);
    await tester.pumpAndSettle();
    // Over the page, which is still under it.
    expect(tester.getRect(find.byType(ChatView).last).left, 0);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(FriendsPage), findsOneWidget);
  });

  testWidgets('on a phone, the chat on top opened again isn\'t stacked over itself: one Back leaves it', (
    tester,
  ) async {
    final repository = await pumpApp(tester, phone);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ChatView));

    // As Message on her profile, opened from the chat, opens it.
    openChat(tester.element(find.byType(ChatView)), repository.conversations.value.first.target, 'Maya');
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), same(state));

    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
    expect(find.byType(DuvetTabBar), findsOneWidget);
  });

  testWidgets('on a phone, a link to a message near the view of the chat on top scrolls to it: one Back leaves it', (
    tester,
  ) async {
    await openLongChat(tester, phone);
    final state = tester.state(find.byType(ChatView));
    // Just above the screen, its bubble built.
    final message = find.text('Message 42', skipOffstage: false);
    expect(tester.getCenter(message).dy, lessThan(0));

    // As a notification's tap and a link in a message's text open it.
    DeepLinkSource.tapped.add(Uri.parse(messageLink(longChat, messageId(42))));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), same(state));
    // Scrolled to, as a reply's quote scrolls to its message.
    expect(tester.getCenter(message).dy, inInclusiveRange(0, phone.height));
    // The message's flash.
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
    expect(find.byType(DuvetTabBar), findsOneWidget);
  });

  testWidgets('on a phone, a message the chat on top can\'t show where it is opens it afresh there, in its place', (
    tester,
  ) async {
    final repository = await openLongChat(tester, phone);
    final state = tester.state(find.byType(ChatView));
    expect(find.text('Message 0'), findsNothing);

    // Far up the chat.
    DeepLinkSource.tapped.add(Uri.parse(messageLink(longChat, messageId(0))));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), isNot(same(state)));
    expect(tester.getCenter(find.text('Message 0')).dy, inInclusiveRange(0, phone.height));
    await tester.pump(const Duration(seconds: 1));

    // Not in the chat yet, as a notification can come before its message does: found in the chat's list, not on its
    // own in a sheet.
    repository.history[longChat.id]!.add(
      FakeRepository.message(messageId(60), author: FakeRepository.maya, name: 'Maya', text: 'Just sent'),
    );
    DeepLinkSource.tapped.add(Uri.parse(messageLink(longChat, messageId(60))));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    expect(find.bySemanticsLabel('Original message'), findsNothing);
    expect(find.descendant(of: find.byType(ChatView), matching: find.text('Just sent')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
    expect(find.byType(DuvetTabBar), findsOneWidget);
  });

  testWidgets('on a phone, a chat still coming in gives way to itself opened at a message it can\'t show yet', (
    tester,
  ) async {
    await pumpLongChat(tester, phone);
    await tester.tap(find.text('Maya'));
    // Its first frame: the chat has only started to come in.
    await tester.pump();

    DeepLinkSource.tapped.add(Uri.parse(messageLink(longChat, messageId(0))));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    // All the way in, not stopped where the first one's transition was.
    expect(ModalRoute.of(tester.element(find.byType(ChatView)))!.animation!.isCompleted, isTrue);
    expect(tester.getCenter(find.text('Message 0')).dy, inInclusiveRange(0, phone.height));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
  });

  testWidgets('on a phone, a chat under another one opens again over it: Back retraces the way', (tester) async {
    final repository = await pumpApp(tester, phone);
    final [maya, leo, ...] = [for (final c in repository.conversations.value) c.target];
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    openChat(tester.element(find.byType(ChatView)), leo, 'Leo');
    await tester.pumpAndSettle();
    openChat(tester.element(find.byType(ChatView)), maya, 'Maya');
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNWidgets(3));
    expect(tester.widget<ChatView>(find.byType(ChatView)).target, maya);

    for (final under in [leo, maya]) {
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      expect(tester.widget<ChatView>(find.byType(ChatView)).target, under);
    }
    await tester.tap(find.bySemanticsLabel('Back').last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
  });

  testWidgets('a link to a message near the view of the pane\'s chat scrolls to it there, the chat as it was', (
    tester,
  ) async {
    await openLongChat(tester, tablet);
    final state = tester.state(find.byType(ChatView));
    final message = find.text('Message 42', skipOffstage: false);
    expect(tester.getCenter(message).dy, lessThan(0));

    DeepLinkSource.tapped.add(Uri.parse(messageLink(longChat, messageId(42))));
    await tester.pumpAndSettle();
    expect(find.byType(ChatView, skipOffstage: false), findsOneWidget);
    expect(tester.state(find.byType(ChatView)), same(state));
    expect(tester.getCenter(message).dy, inInclusiveRange(0, tablet.height));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('screen readers get the rail\'s destinations and Spaces, with a chat open too', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, tablet);
    for (final (i, label) in ['Chats', 'Spaces', 'Calls', 'You'].indexed) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label).first),
        isSemantics(
          label: label,
          hint: 'Tab ${i + 1} of 4',
          isButton: true,
          isSelected: i == 0,
          hasSelectedState: true,
        ),
      );
    }
    expect(find.bySemanticsLabel('Design Guild'), findsOneWidget);

    await openGeneral(tester);
    // The list and the rail are still reachable beside the chat.
    expect(find.bySemanticsLabel('Chats'), findsWidgets);
    expect(find.bySemanticsLabel('Design Guild'), findsWidgets);
    expect(find.bySemanticsLabel('Members'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Message')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('a sheet is no wider than reads on a wide window', (tester) async {
    window(tester, tablet);
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showGlassDialogSheet<void>(
                  context,
                  label: 'Sheet',
                  builder: (_) => const SizedBox(height: 120, child: Text('In the sheet')),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(find.byType(GlassSurface));
    expect(sheet.width, ShellSizes.sheet);
    expect(sheet.center.dx, tablet.width / 2);
  });
}
