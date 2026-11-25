import 'dart:async';

import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/change_refusals.dart';
import 'package:duvet/main.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../support/fake_repository.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  // M3 of task 17's review: the notice is the app shell's, over every screen: here the app as it opens, no chat shown.
  testWidgets('the_app_tells_a_change_refused_for_good_over_every_screen', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    repository.changeRefusals.add(const ChangeRefused('c-maya', 'm1', deletion: true));
    await tester.pumpAndSettle();
    expect(find.text(Notice.deleteRefused.text), findsOneWidget);
    // The toast's timer runs out.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  // M3 of task 17's review: an edit or a deletion the server refused for good is told wherever the person is, in the
  // words both apps share (the desktop's e2e_edit_refused and e2e_delete_refused).
  testWidgets('a_change_refused_for_good_is_told_wherever_the_person_is', (tester) async {
    final refusals = StreamController<ChangeRefused>();
    addTearDown(refusals.close);
    await tester.pumpWidget(
      MaterialApp(
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: FToaster(
            child: ChangeRefusals(refusals: refusals.stream, child: const SizedBox.expand()),
          ),
        ),
      ),
    );
    refusals.add(const ChangeRefused('c', 'm', deletion: false));
    await tester.pumpAndSettle();
    expect(find.text(Notice.editRefused.text), findsOneWidget);
    refusals.add(const ChangeRefused('c', 'm', deletion: true));
    await tester.pumpAndSettle();
    expect(find.text(Notice.deleteRefused.text), findsOneWidget);
    // The toasts' timers run out.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
