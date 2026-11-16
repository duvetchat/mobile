// Run with: flutter test benchmark/message_boundary.dart
import 'dart:math';

import 'package:duvet/chat_view.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_repository.dart';
import '../test/support/fonts.dart';

/// What the [RepaintBoundary] each message has of its own (for the picture a
/// delete breaks into dust) costs in a long chat: the same chat, scrolled the
/// same way, with it and without. Not a `_test.dart` file, so `flutter test`
/// alone doesn't run it.
///
/// It runs in the test binding: a debug build on the Dart VM, asserts on, and
/// no GPU. The times compare the two with each other, they aren't a phone's;
/// and what the rasterizer keeps for a layer (textures, a raster cache) can't
/// be seen from here at all.
void main() {
  const sizes = [300, 1000, 3000];
  const rounds = 6;
  const frames = 240;
  // A quick drag: about 2200 px a second at 60 Hz.
  const step = 37.0;

  setUpAll(loadAppFonts);
  tearDown(() => ChatView.debugMessageBoundary = true);

  testWidgets('a message’s own RepaintBoundary, in a long chat', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final out = StringBuffer();
    for (final size in sizes) {
      final runs = {true: <_Run>[], false: <_Run>[]};
      // One round to warm the VM up, thrown away; then the two take turns.
      for (var round = 0; round <= rounds; round++) {
        for (final boundary in round.isEven ? const [true, false] : const [false, true]) {
          final run = await _scroll(tester, size, boundary: boundary, frames: frames, step: step);
          if (round > 0) runs[boundary]!.add(run);
        }
      }
      out.writeln(
        '\n$size messages, $frames frames of ${step.round()} px, $rounds runs each (the median run, and the fastest and slowest)',
      );
      out.writeln('| | with | without | difference |');
      out.writeln('|---|---|---|---|');
      // Times with the fastest and slowest run beside the median one: a difference inside that spread is noise.
      void row(String name, num Function(_Run r) of, {bool time = false}) {
        final with_ = [for (final r in runs[true]!) of(r)]..sort();
        final without = [for (final r in runs[false]!) of(r)]..sort();
        String cell(List<num> v) =>
            time ? '${v[v.length ~/ 2].round()} µs (${v.first.round()}–${v.last.round()})' : '${v[v.length ~/ 2]}';
        final a = with_[with_.length ~/ 2], b = without[without.length ~/ 2];
        final change = b == 0 ? '' : ' (${((a - b) / b * 100).toStringAsFixed(1)}%)';
        out.writeln(
          '| $name | ${cell(with_)} | ${cell(without)} | ${a >= b ? '+' : ''}${(a - b).round()}${time ? ' µs' : ''}$change |',
        );
      }

      row('messages built (seen and cached)', (r) => r.built);
      row('layers, all', (r) => r.layers.values.fold(0, (a, b) => a + b));
      for (final type in {...runs[true]!.first.layers.keys, ...runs[false]!.first.layers.keys}) {
        row('layers, $type', (r) => r.layers[type] ?? 0);
      }
      row('repaint boundaries in the list', (r) => r.boundaries);
      row('build', (r) => r.build.median, time: true);
      row('layout (builds the rows scrolled in)', (r) => r.layout.median, time: true);
      row('paint', (r) => r.paint.median, time: true);
      row('composite (the scene, built)', (r) => r.composite.median, time: true);
      row('frame, median', (r) => r.total.median, time: true);
      row('frame, mean', (r) => r.total.mean, time: true);
      row('frame, 90th percentile', (r) => r.total.p90, time: true);
      row('frame, worst', (r) => r.total.worst, time: true);
    }
    // ignore: avoid_print
    print(out);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// The times of one phase, a frame each, in microseconds.
class _Times {
  final values = <int>[];
  late final sorted = [...values]..sort();
  double get median => sorted[sorted.length ~/ 2].toDouble();
  double get p90 => sorted[sorted.length * 9 ~/ 10].toDouble();
  double get worst => sorted.last.toDouble();
  double get mean => values.reduce((a, b) => a + b) / values.length;
}

class _Run {
  /// Before the scroll, the chat at its end.
  late final Map<String, int> layers;
  late final int boundaries;
  late final int built;
  final build = _Times();
  final layout = _Times();
  final paint = _Times();
  final composite = _Times();
  final total = _Times();
}

/// A long conversation of two: runs of one author, short lines and long ones,
/// some answered, some reacted to.
List<ChatMessage> _chat(int count) {
  final random = Random(64);
  const words = [
    'duvet',
    'tab bar',
    'pushed',
    'the',
    'new',
    'type ramp',
    'tomorrow',
    'looks',
    'good',
    'to',
    'me',
    'ok',
  ];
  final start = DateTime(2026, 10, 1, 9);
  var mine = false;
  return [
    for (var i = 0; i < count; i++)
      () {
        if (random.nextInt(3) == 0) mine = !mine;
        final text = [
          for (var w = 0, n = 1 + random.nextInt(random.nextInt(4) == 0 ? 40 : 8); w < n; w++)
            words[random.nextInt(words.length)],
        ].join(' ');
        return FakeRepository.message(
          'b$i',
          author: mine ? FakeRepository.me.id : FakeRepository.maya,
          name: mine ? FakeRepository.me.displayName : 'Maya',
          text: '$text $i',
          at: start.add(Duration(minutes: 2 * i)),
          reply: i > 0 && random.nextInt(12) == 0
              ? MessageReply(
                  messageId: 'b${i - 1}',
                  authorId: FakeRepository.maya,
                  authorName: 'Maya',
                  content: 'earlier',
                )
              : null,
          reactions: random.nextInt(10) == 0
              ? [
                  Reaction(emoji: '👍', users: {FakeRepository.maya}),
                ]
              : const [],
        );
      }(),
  ];
}

/// Opens the chat, [size] messages long, and scrolls back through it, timing
/// each phase of each frame.
Future<_Run> _scroll(
  WidgetTester tester,
  int size, {
  required bool boundary,
  required int frames,
  required double step,
}) async {
  ChatView.debugMessageBoundary = boundary;
  final repository = FakeRepository();
  await tester.pumpWidget(DuvetApp(key: UniqueKey(), repository: repository));
  await tester.pumpAndSettle();
  repository.history['c-maya'] = _chat(size);
  await tester.tap(find.text('Maya'));
  await tester.pumpAndSettle();
  final messages = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Vanish');
  final list = find.ancestor(of: messages.first, matching: find.byType(Scrollable)).first;
  final position = tester.state<ScrollableState>(list).position;
  expect(position.maxScrollExtent, greaterThan(frames * step + 1000), reason: 'the chat is shorter than the scroll');

  final run = _Run();
  run.layers = _layers(tester.binding.renderViews.first.debugLayer!);
  run.boundaries = find.descendant(of: list, matching: find.byType(RepaintBoundary)).evaluate().length;
  run.built = messages.evaluate().length;

  final binding = tester.binding;
  final watch = Stopwatch();
  for (var f = 0; f < frames; f++) {
    position.jumpTo(position.pixels + step);
    // The frame's phases, as `drawFrame` runs them, one at a time.
    watch
      ..reset()
      ..start();
    binding.buildOwner!.buildScope(binding.rootElement!);
    final built = watch.elapsedMicroseconds;
    binding.rootPipelineOwner.flushLayout();
    final laidOut = watch.elapsedMicroseconds;
    binding.rootPipelineOwner
      ..flushCompositingBits()
      ..flushPaint();
    final painted = watch.elapsedMicroseconds;
    for (final view in binding.renderViews) {
      view.compositeFrame();
    }
    final composited = watch.elapsedMicroseconds;
    watch.stop();
    run.build.values.add(built);
    run.layout.values.add(laidOut - built);
    run.paint.values.add(painted - laidOut);
    run.composite.values.add(composited - painted);
    run.total.values.add(composited);
    // What's left of the frame: its callbacks, and the rows scrolled out.
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  return run;
}

/// How many layers of each kind are in the tree under [root].
Map<String, int> _layers(Layer root) {
  final counts = <String, int>{};
  void visit(Layer layer) {
    counts.update('${layer.runtimeType}', (n) => n + 1, ifAbsent: () => 1);
    if (layer is ContainerLayer) {
      for (var child = layer.firstChild; child != null; child = child.nextSibling) {
        visit(child);
      }
    }
  }

  visit(root);
  return counts;
}
