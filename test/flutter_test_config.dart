import 'dart:async';

import 'package:duvet/data/recent_emoji.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test starts with no recently used emoji, kept in memory: one test's
/// picks would otherwise reorder the next one's quick reactions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => RecentEmoji.instance = RecentEmoji(MemoryRecentEmojiStore()));
  await testMain();
}
