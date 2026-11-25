import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/change_refusals.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
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
