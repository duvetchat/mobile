import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Android's engine inflates a deflated font whole, on the main thread, at the first text that names its family,
  // which is the first frame's; a stored one it maps (android/app/build.gradle.kts).
  test('the APK stores each of the app\'s fonts as it is', () {
    final gradle = File('android/app/build.gradle.kts').readAsLinesSync();
    final start = gradle.indexWhere((l) => l.trim().startsWith('noCompress +='));
    expect(start, isNot(-1));
    // What the list names, a commented line aside.
    final stored = [
      for (final line in gradle.skip(start).takeWhile((l) => l.trim() != ')'))
        if (RegExp(r'^\s*"([^"]+)",').firstMatch(line) case final m?) m[1]!,
    ];
    final fonts = RegExp(
      r'^\s+- asset: (\S+)$',
      multiLine: true,
    ).allMatches(File('pubspec.yaml').readAsStringSync()).map((m) => m[1]!).toList();
    expect(fonts, isNotEmpty);
    // A font added to pubspec.yaml and not here would be deflated.
    expect(stored, containsAll(fonts));
  });
}
