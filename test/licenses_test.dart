import 'dart:convert';
import 'dart:io';

import 'package:duvet/licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// What the licence page shows (#401): the notices Flutter's build gathers by itself, each Dart package's LICENSE, and
// those the app adds, which the build leaves out. A Windows checkout has CRLF: texts are compared with LF.
String _lf(String text) => text.replaceAll('\r\n', '\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Every licence the app adds to the registry, by each name the page lists it under. In real time, not a widget
  // test's fake time: a text over 50 KiB (the core's notices) is decoded in another isolate.
  final registry = <String, List<String>>{};
  setUpAll(() async {
    addBundledLicenses();
    await for (final entry in LicenseRegistry.licenses) {
      final text = entry.paragraphs.map((paragraph) => paragraph.text).join('\n');
      for (final package in entry.packages) {
        (registry[package] ??= []).add(text);
      }
    }
  });

  // A test's binding leaves the build's own out of the registry, but flutter test writes them all the same: the
  // NOTICES file the app reads them from, each licence after the names it's listed under.
  test("the build's own: every Dart package's licence, the git dependencies' among them", () async {
    final notices = utf8.decode(gzip.decode((await rootBundle.load('NOTICES.Z')).buffer.asUint8List()));
    final names = {
      for (final license in notices.split('\n${'-' * 80}\n'))
        if (license.indexOf('\n\n') case final split when split >= 0) ...license.substring(0, split).split('\n'),
    };
    expect(names, containsAll(['flutter', 'duvet_client', 'flutter_webrtc']));
  });

  test('what the app adds is in the registry, each from a file the app bundles', () async {
    for (final (packages, asset) in bundledLicenses) {
      expect((await rootBundle.loadString(asset)).trim(), isNotEmpty, reason: asset);
      for (final package in packages) {
        expect(registry[package], isNotNull, reason: package);
      }
    }
  });

  test('every font the app bundles has its licence there, Material Icons too', () {
    final pubspec = _lf(File('pubspec.yaml').readAsStringSync());
    final families = RegExp(r'^    - family: (.+)$', multiLine: true).allMatches(pubspec).map((m) => m.group(1)!);
    expect(families, containsAll(['Fraunces', 'Inter', 'Roboto', 'Fira Mono', 'Twemoji']));
    expect(pubspec, contains('uses-material-design: true'));
    final named = {for (final (packages, _) in bundledLicenses) ...packages};
    expect(named, containsAll([...families, 'Material Icons']));
  });

  test('the copies are the notices they copy: flutter_webrtc as pinned, Material Icons as Flutter bundles it', () {
    final config = File('.dart_tool/package_config.json');
    final webrtc = ((jsonDecode(config.readAsStringSync()) as Map<String, dynamic>)['packages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((package) => package['name'] == 'flutter_webrtc');
    // A git package's root is a file URI; a relative one is the package config's own.
    final root = config.absolute.uri.resolve('${webrtc['rootUri']}/');
    String copy(String name) =>
        _lf(File(bundledLicenses.singleWhere((license) => license.$1.contains(name)).$2).readAsStringSync());
    expect(copy('flutter_webrtc'), _lf(File.fromUri(root.resolve('NOTICE')).readAsStringSync()));
    final flutter = Platform.environment['FLUTTER_ROOT']!;
    expect(
      copy('Material Icons'),
      _lf(File('$flutter/bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt').readAsStringSync()),
    );
  });

  // Its release carries THIRD-PARTY-NOTICES.txt, which tool/vendor_core.sh brings with its libraries: until then the
  // page says they're missing, and this fails.
  test("the encryption core's third-party notices, under the core's name", () {
    final core = registry['duvet_e2e'];
    expect(core, isNotNull);
    expect(core!.single, isNot(coreNoticesMissing));
    expect(core.single.toLowerCase(), allOf(contains('openmls'), contains('sqlcipher')));
  });
}
