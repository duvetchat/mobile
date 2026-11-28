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

  test("it's built for Android and iOS, from the core's libraries, with nothing that compiles Rust", () {
    const framework = '$package/ios/duvet_e2e/Frameworks/duvet_e2e.xcframework';
    expect(
      files.keys,
      containsAll([
        '$package/android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so',
        // A phone's framework and a simulator's, which flutter_rust_bridge opens by their name.
        '$framework/Info.plist',
        '$framework/ios-arm64/duvet_e2e.framework/duvet_e2e',
        '$framework/ios-arm64-simulator/duvet_e2e.framework/duvet_e2e',
        '$package/ios/duvet_e2e/Package.swift',
      ]),
    );
    // Neither cargokit, nor the crate (flutter_rust_bridge's Dart is in lib/src/rust), nor a podspec that builds it.
    expect(
      files.keys.where(
        (path) => path.contains('cargokit') || path.startsWith('$package/rust/') || path.endsWith('.podspec'),
      ),
      isEmpty,
    );
    expect(File('$package/android/build.gradle').readAsStringSync(), isNot(contains('cargokit')));
    // The Swift package Flutter adds to the app: the framework as a binary target, under the product name Flutter
    // looks for, and no target Xcode would compile.
    final manifest = File('$package/ios/duvet_e2e/Package.swift').readAsStringSync();
    expect(manifest, contains('.library(name: "duvet-e2e", targets: ["duvet_e2e"])'));
    expect(manifest, contains('.binaryTarget(name: "duvet_e2e", path: "Frameworks/duvet_e2e.xcframework")'));
    expect(manifest, isNot(contains('.target(')));
    final platforms = File('$package/pubspec.yaml').readAsStringSync().split('platforms:\n').last;
    expect(platforms.trim(), 'android:\n        ffiPlugin: true\n      ios:\n        ffiPlugin: true');
  });

  // The notices of the code the core's libraries carry (SQLCipher, OpenSSL, OpenMLS, hpke-rs and the rest), which its
  // release has beside them: an asset of the plugin's, which the app's licence page shows (lib/licenses.dart, #401).
  test("it carries the core's third-party notices, as an asset of its own", () {
    expect(files.keys, contains('$package/THIRD-PARTY-NOTICES.txt'));
    expect(File('$package/pubspec.yaml').readAsStringSync(), contains('  assets:\n    - THIRD-PARTY-NOTICES.txt\n'));
  });
}
