import 'dart:async';

import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/tabs.dart' show SpaceDirectory;
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// Members come only once [hold], when set, completes.
class _HeldMembers extends FakeRepository {
  Completer<void>? hold;

  @override
  Future<List<Member>> members(ChatTarget target, {bool refresh = false}) async {
    await hold?.future;
    return super.members(target, refresh: refresh);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  // A small phone: a skeleton mustn't overflow it.
  Future<void> pumpSmall(WidgetTester tester, FakeRepository repository) async {
    tester.view.physicalSize = const Size(320 * 3, 568 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text(name)));
    // While connecting, the title's spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the Spaces tab draws its tiles while the first READY comes, not a spinner', (tester) async {
    final semantics = tester.ensureSemantics();
    final repository = FakeRepository();
    await pumpSmall(tester, repository);
    final spaces = repository.spaces.value;
    repository
      ..spaces.value = const []
      ..status.value = LiveStatus.connecting;
    await openTab(tester, 'Spaces');

    expect(find.bySemanticsLabel('Loading spaces'), findsOneWidget);
    expect(find.text('You’re not in any spaces'), findsNothing);
    // Shapes only: nothing of the placeholders is read out or takes a tap.
    expect(find.bySemanticsLabel(RegExp('Lorem')), findsNothing);
    expect(find.text('Lorem ipsum'), findsOneWidget);
    expect(find.text('Lorem ipsum').hitTestable(), findsNothing);
    await tester.tap(find.text('Lorem ipsum'), warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SpaceDirectory), findsNothing);
    expect(tester.takeException(), isNull);

    repository
      ..spaces.value = spaces
      ..status.value = LiveStatus.online;
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Loading spaces'), findsNothing);
    expect(find.text('Lorem ipsum'), findsNothing);
    expect(find.text('Design Guild'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('Chats draws rows while it connects with nothing saved, then says there are none', (tester) async {
    final semantics = tester.ensureSemantics();
    final repository = FakeRepository();
    await pumpSmall(tester, repository);
    repository
      ..conversations.value = const []
      ..status.value = LiveStatus.connecting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.bySemanticsLabel('Loading chats'), findsOneWidget);
    expect(find.text('No conversations yet'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Lorem')), findsNothing);
    expect(tester.takeException(), isNull);

    repository.status.value = LiveStatus.online;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.bySemanticsLabel('Loading chats'), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the members sheet draws its rows while the members come', (tester) async {
    final semantics = tester.ensureSemantics();
    final repository = _HeldMembers();
    await pumpSmall(tester, repository);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    final hold = repository.hold = Completer<void>();
    await tester.tap(find.bySemanticsLabel('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Members').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.bySemanticsLabel('Loading members'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Lorem')), findsNothing);
    expect(find.text('Lorem ipsum').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);

    hold.complete();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Loading members'), findsNothing);
    expect(find.text('Lorem ipsum'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^Leo')), findsWidgets);
    semantics.dispose();
  });

  testWidgets('an invite shows its card\'s shape while its preview comes', (tester) async {
    final semantics = tester.ensureSemantics();
    final repository = FakeRepository()
      ..invites['k7Qe2m'] = const InvitePreview(code: 'k7Qe2m', spaceId: 's-x', spaceName: 'Fieldwork');
    await pumpSmall(tester, repository);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Join or create a Space').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Join with an invite').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'k7Qe2m');
    // The typing settles; the preview is asked for, and takes 100ms.
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();

    expect(find.bySemanticsLabel('Loading the invite'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Lorem')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Loading the invite'), findsNothing);
    expect(find.bySemanticsLabel('Join Fieldwork'), findsOneWidget);
    semantics.dispose();
  });
}
