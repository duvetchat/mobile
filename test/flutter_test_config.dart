import 'dart:async';

import 'package:duvet/data/images.dart';
import 'package:duvet/data/recent_emoji.dart';
import 'package:duvet/widgets/skeleton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test starts with no recently used emoji, kept in memory: one test's
/// picks would otherwise reorder the next one's quick reactions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A skeleton's pulse never settles: still here, so `pumpAndSettle` ends on a screen that's loading.
  DuvetSkeleton.animate = false;
  // No disk cache: its plugins aren't here. Pictures load as NetworkImage.
  imageStore = null;
  setUp(() => RecentEmoji.instance = RecentEmoji(MemoryRecentEmojiStore()));
  // The test window is 800 wide, which the app lays out as a tablet (lib/shell.dart). The tests are of the phone's
  // layout unless they size the window themselves: just under the wide layout's width, as tall as it was.
  setUp(() {
    if (BindingBase.debugBindingType() == null) return;
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    view.physicalSize = compactTestWindow * view.devicePixelRatio;
    addTearDown(view.resetPhysicalSize);
  });
  await testMain();
}

/// The window the tests run in by default.
const compactTestWindow = Size(700, 600);
