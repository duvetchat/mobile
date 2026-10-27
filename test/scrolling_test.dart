import 'dart:math' as math;

import 'package:duvet/widgets/scrolling.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SmoothTestBinding extends AutomatedTestWidgetsFlutterBinding with SmoothWheelBinding {}

void main() {
  _SmoothTestBinding();

  Future<ScrollController> pumpList(WidgetTester tester, {int items = 100, ScrollPhysics? physics}) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const DuvetScrollBehavior(),
        home: ListView.builder(
          controller: controller,
          physics: physics,
          itemCount: items,
          itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
        ),
      ),
    );
    return controller;
  }

  Future<void> wheel(WidgetTester tester, double dy, {PointerDeviceKind kind = PointerDeviceKind.mouse}) => tester
      .sendEventToBinding(PointerScrollEvent(kind: kind, position: const Offset(400, 300), scrollDelta: Offset(0, dy)));

  testWidgets('lists bounce past their ends without a stretch or glow', (tester) async {
    final controller = await pumpList(tester);
    final drag = await tester.startGesture(const Offset(400, 300));
    await drag.moveBy(const Offset(0, 50));
    await drag.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(controller.position.pixels, lessThan(0));
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    await drag.up();
    await tester.pumpAndSettle();
    expect(controller.position.pixels, 0);
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.linux}));

  testWidgets('explicit physics keep their say over the bounce', (tester) async {
    final always = await pumpList(tester, items: 3, physics: const AlwaysScrollableScrollPhysics());
    expect(always.position.physics.parent, isA<BouncingScrollPhysics>());
    final drag = await tester.startGesture(const Offset(400, 300));
    await drag.moveBy(const Offset(0, 50));
    await drag.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(always.position.pixels, lessThan(0));
    await drag.up();
    await tester.pumpAndSettle();

    final never = await pumpList(tester, physics: const NeverScrollableScrollPhysics());
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(never.position.pixels, 0);
  });

  testWidgets('a mouse wheel tick glides to its target', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 100);
    final first = controller.offset;
    expect(first, greaterThan(0));
    expect(first, lessThan(100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, greaterThan(first));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(100, 0.01));
  });

  testWidgets('quick ticks add up', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(200, 0.01));
  });

  testWidgets('a tick near the end stops there, and the next one back moves at once', (tester) async {
    final controller = await pumpList(tester);
    final max = controller.position.maxScrollExtent;
    controller.jumpTo(max - 30);
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, max);
    await wheel(tester, -100);
    expect(controller.offset, lessThan(max));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(max - 100, 0.01));
  });

  testWidgets('a tick the other way drops what was left', (tester) async {
    final controller = await pumpList(tester);
    controller.jumpTo(500);
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    final turned = controller.offset;
    await wheel(tester, -100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(turned - 100, 0.01));
  });

  testWidgets('trackpad scrolls pass straight through', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 100, kind: PointerDeviceKind.trackpad);
    expect(controller.offset, 100);
  });

  testWidgets('an inertia cancel stops the glide', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.sendEventToBinding(const PointerScrollInertiaCancelEvent(position: Offset(400, 300)));
    final stopped = controller.offset;
    await tester.pumpAndSettle();
    expect(controller.offset, stopped);
  });

  testWidgets('wheel zoom reaches the same scale in slices', (tester) async {
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: InteractiveViewer(transformationController: transform, child: const SizedBox.expand()),
      ),
    );
    await wheel(tester, -100);
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(math.exp(0.5), 1e-6));
  });

  testWidgets('with reduce motion on, a tick steps at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final controller = await pumpList(tester);
    await wheel(tester, 100);
    expect(controller.offset, 100);
  });
}
