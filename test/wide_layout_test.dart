import 'package:duvet/chat_view.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/members_sheet.dart';
import 'package:duvet/people.dart';
import 'package:duvet/shell.dart';
import 'package:duvet/tabs.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
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

  testWidgets('a thread opens in the pane over its chat, with a way back to it', (tester) async {
    await pumpApp(tester, tablet);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ChatView));
    Navigator.of(
      context,
    ).push(ChatRoute(target: tester.widget<ChatView>(find.byType(ChatView)).target, title: 'Maya', threadOf: 'm1'));
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsOneWidget);
    expect(find.byType(ChatsTab), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsNothing);
    expect(find.byType(ChatView), findsOneWidget);
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
