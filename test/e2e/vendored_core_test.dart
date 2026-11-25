import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// The core's plugin the app carries (PLAN-E2E-CLIENTES.md, Ruling 3): what tool/vendor_core.sh copied from the core's
// commit and its release, byte for byte, as packages/duvet_e2e/SOURCE.json records it. .gitattributes keeps a
// Windows checkout from changing its line endings.
const package = 'packages/duvet_e2e';

void main() {
  final source = jsonDecode(File('$package/SOURCE.json').readAsStringSync()) as Map<String, dynamic>;
  final files = (source['files'] as Map).cast<String, String>();

  test("each file is the one SOURCE.json records, and the checkout has no other", () {
    expect(source['repository'], 'duvetchat/e2e');
    expect(source['commit'], matches(RegExp(r'^[0-9a-f]{40}$')));
    // What the checkout carries: a pub get or an IDE's files in the folder aren't the vendored package's.
    final tracked = (Process.runSync('git', ['ls-files', package]).stdout as String).split('\n')
      ..removeWhere((path) => path.isEmpty || path == '$package/SOURCE.json')
      ..sort();
    expect(tracked, [...files.keys]..sort());
    for (final MapEntry(key: path, value: hash) in files.entries) {
      expect(sha256.convert(File(path).readAsBytesSync()).toString(), hash, reason: path);
    }
  });

  test("it's built for Android alone, from the core's library, with nothing that compiles Rust", () {
    expect(files.keys, containsAll(['$package/android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so']));
    // Neither cargokit nor the crate (flutter_rust_bridge's Dart is in lib/src/rust).
    expect(files.keys.where((path) => path.contains('cargokit') || path.startsWith('$package/rust/')), isEmpty);
    expect(File('$package/android/build.gradle').readAsStringSync(), isNot(contains('cargokit')));
    final platforms = File('$package/pubspec.yaml').readAsStringSync().split('platforms:\n').last;
    expect(platforms.trim(), 'android:\n        ffiPlugin: true');
  });
}
