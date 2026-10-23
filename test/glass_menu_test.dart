import 'package:duvet/theme.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets('a menu follows its trigger when the keyboard closes', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    // The keyboard is up: 300pt of the bottom.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                Builder(
                  builder: (anchor) => TextButton(
                    onPressed: () => showGlassMenu(
                      anchor,
                      items: const [GlassMenuItem(icon: Icons.photo, label: 'Photos', value: 'photos')],
                    ),
                    child: const Text('+'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();
    double gap() => tester.getTopLeft(find.text('+')).dy - tester.getBottomLeft(find.byType(GlassSurface)).dy;
    final before = gap();
    expect(before, inInclusiveRange(0, 40));

    // The keyboard goes: the trigger drops 300pt, and the menu with it.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('+')).dy, greaterThan(700));
    expect(gap(), closeTo(before, 1));
  });
}
