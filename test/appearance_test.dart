import 'dart:async';
import 'dart:ui' show Brightness;

import 'package:duvet/data/appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// A store that tells what was read, in order, and holds the reply gesture's read until the test lets it go.
class _OrderedStore extends MemoryAppearanceStore {
  final reads = <String>[];
  final gestureHeld = Completer<void>();
  bool modeFails = false;

  @override
  Future<String?> read() {
    reads.add('mode');
    if (modeFails) throw StateError('no keystore');
    return super.read();
  }

  @override
  Future<String?> readReplyGesture() async {
    reads.add('gesture');
    await gestureHeld.future;
    return super.readReplyGesture();
  }

  @override
  Future<String?> readBubbleColor() {
    reads.add('bubble');
    return super.readBubbleColor();
  }

  @override
  Future<({String url, String json})?> readCodeTheme() {
    reads.add('code theme');
    return super.readCodeTheme();
  }
}

void main() {
  // The app's start waits for the mode alone (main): the whole app draws by it.
  test('the mode is read first, and is in before the rest is', () async {
    final store = _OrderedStore()
      ..mode = 'dark'
      ..replyGesture = 'doubleTap'
      ..bubbleColor = '${0xD6A400}';
    final appearance = Appearance(store);
    addTearDown(appearance.dispose);
    final loaded = appearance.load();
    expect(store.reads, ['mode'], reason: 'asked for before anything else, as load() is called');

    await appearance.modeLoaded;
    expect(appearance.value.name, 'dark');
    expect(appearance.resolve(Brightness.light), Brightness.dark);
    expect(appearance.replyGesture, ReplyGesture.swipeLeft, reason: 'the rest is still on its way');
    expect(appearance.bubbleColor, isNull);

    store.gestureHeld.complete();
    await loaded;
    expect(store.reads, ['mode', 'gesture', 'bubble', 'code theme']);
    expect(appearance.value.name, 'dark');
    expect(appearance.replyGesture, ReplyGesture.doubleTap);
    expect(appearance.bubbleColor, 0xD6A400);
  });

  test("a mode that can't be read holds nothing: the system's stays, and the rest loads", () async {
    final store = _OrderedStore()
      ..modeFails = true
      ..replyGesture = 'swipeRight';
    store.gestureHeld.complete();
    final appearance = Appearance(store);
    addTearDown(appearance.dispose);
    final loaded = appearance.load();
    await appearance.modeLoaded;
    expect(appearance.value.name, 'system');
    await loaded;
    expect(appearance.replyGesture, ReplyGesture.swipeRight);
  });

  test('loaded again, the mode is read again, first', () async {
    final store = _OrderedStore()..mode = 'light';
    store.gestureHeld.complete();
    final appearance = Appearance(store);
    addTearDown(appearance.dispose);
    await appearance.load();
    expect(appearance.value.name, 'light');
    store
      ..mode = 'dark'
      ..reads.clear();
    await appearance.load();
    expect(store.reads.first, 'mode');
    expect(appearance.value.name, 'dark');
  });
}
