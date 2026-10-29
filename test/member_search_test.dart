import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';
import 'support/no_links.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  testWidgets('searching members narrows the list', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Members').last);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Leo')), findsWidgets);

    await tester.tap(find.byType(SearchField));
    await tester.enterText(find.descendant(of: find.byType(SearchField), matching: find.byType(EditableText)), 'may');
    // The keyboard comes up.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Maya, ')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Leo, ')), findsNothing);
    semantics.dispose();
  });
}
