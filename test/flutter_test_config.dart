import 'dart:async';

import 'package:duvet/data/images.dart';
import 'package:duvet/data/recent_emoji.dart';
import 'package:duvet/widgets/skeleton.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test starts with no recently used emoji, kept in memory: one test's
/// picks would otherwise reorder the next one's quick reactions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A skeleton's pulse never settles: still here, so `pumpAndSettle` ends on a screen that's loading.
  DuvetSkeleton.animate = false;
  // No disk cache: its plugins aren't here. Pictures load as NetworkImage.
  imageStore = null;
  setUp(() => RecentEmoji.instance = RecentEmoji(MemoryRecentEmojiStore()));
  await testMain();
}
