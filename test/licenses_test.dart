import 'dart:convert';
import 'dart:io';

import 'package:duvet/licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// What the licence page shows (#401): the notices Flutter's build gathers by itself, each Dart package's LICENSE, and
// those the app adds, which the build leaves out. A Windows checkout has CRLF: texts are compared with LF.
String _lf(String text) => text.replaceAll('\r\n', '\n');

// A package's root as the package config pins it: a git package's is a file URI, a relative one is the config's own.
Uri _root(String name) {
  final config = File('.dart_tool/package_config.json');
  final package = ((jsonDecode(config.readAsStringSync()) as Map<String, dynamic>)['packages'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == name);
  return config.absolute.uri.resolve('${package['rootUri']}/');
}

// #403: the two lists the release build writes into the APK's assets, in licensee's shape and the Google notices
// task's: Gradle's libraries with the licences their POMs name, and the notices Google's AARs embed, each text once.
const _libraries = '''[
  {"groupId": "androidx.core", "artifactId": "core", "version": "1.16.0", "spdxLicenses": [
    {"identifier": "Apache-2.0", "name": "Apache License 2.0", "url": "https://www.apache.org/licenses/LICENSE-2.0"}]},
  {"groupId": "androidx.camera", "artifactId": "camera-core", "version": "1.6.1", "spdxLicenses": [
    {"identifier": "Apache-2.0", "name": "Apache License 2.0", "url": "https://www.apache.org/licenses/LICENSE-2.0"},
    {"identifier": "BSD-3-Clause", "name": "BSD 3-Clause", "url": "https://opensource.org/licenses/BSD-3-Clause"}]},
  {"groupId": "com.example", "artifactId": "dual", "version": "1.0", "spdxLicenses": [
    {"identifier": "GPL-2.0-only", "name": "GNU General Public License v2.0 only", "url": "https://www.gnu.org/licenses/old-licenses/gpl-2.0-standalone.html"},
    {"identifier": "BSD-3-Clause", "name": "BSD 3-Clause", "url": "https://opensource.org/licenses/BSD-3-Clause"}]},
  {"groupId": "com.google.android.gms", "artifactId": "play-services-base", "version": "18.9.0", "unknownLicenses": [
    {"name": "Android Software Development Kit License", "url": "https://developer.android.com/studio/terms.html"}]},
  {"groupId": "com.google.mlkit", "artifactId": "barcode-scanning", "version": "17.3.0", "unknownLicenses": [
    {"name": "ML Kit Terms of Service", "url": "https://developers.google.com/ml-kit/terms"}]},
  {"groupId": "io.github.webrtc-sdk", "artifactId": "android", "version": "150.7871.04", "unknownLicenses": [
    {"name": "The 3-Clause BSD License", "url": "https://opensource.org/license/bsd-3-clause/"}]},
  {"groupId": "com.github.davidliu", "artifactId": "audioswitch", "version": "039a35aefab7747c557242fa216c9ea11743b604",
    "unknownLicenses": [{"name": "Apache 2.0", "url": "https://github.com/twilio/audioswitch/blob/master/LICENSE.txt"}]},
  {"groupId": "com.example", "artifactId": "unnamed", "version": "1.0"}
]''';
const _google = '''[
  {"parts": ["Abseil", "JSR 305"], "text": "Abseil's notice"},
  {"parts": ["Kotlin"], "text": "one"},
  {"parts": ["Kotlin"], "text": "another"}
]''';

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
    String copy(String name) =>
        _lf(File(bundledLicenses.singleWhere((license) => license.$1.contains(name)).$2).readAsStringSync());
    expect(copy('flutter_webrtc'), _lf(File.fromUri(_root('flutter_webrtc').resolve('NOTICE')).readAsStringSync()));
    final flutter = Platform.environment['FLUTTER_ROOT']!;
    expect(
      copy('Material Icons'),
      _lf(File('$flutter/bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt').readAsStringSync()),
    );
  });

  test("Gradle's libraries, each under its own notices or every licence its POM names that the build accepts", () {
    const android = 'assets/licenses/android';
    expect(librariesByText(_libraries), {
      '$android/Apache-2.0.txt': [
        'androidx.core:core',
        'androidx.camera:camera-core',
        'com.github.davidliu:audioswitch',
      ],
      '$android/BSD-3-Clause.txt': ['androidx.camera:camera-core', 'com.example:dual'],
      '$android/android-sdk-license.txt': ['com.google.android.gms:play-services-base'],
      '$android/ml-kit-terms.txt': ['com.google.mlkit:barcode-scanning'],
      '$android/libwebrtc.txt': ['io.github.webrtc-sdk:android'],
      null: ['com.example:unnamed'],
    });
  });

  test('on Android the page shows them, from what MainActivity reads in the APK, each licence with its text', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final asked = <Object?>[];
    messenger.setMockMethodCallHandler(nativeLicenses, (call) async {
      asked.add(call.arguments);
      return {'licenses/artifacts.json': _libraries, 'licenses/google.json': _google}[call.arguments];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(nativeLicenses, null));
    final shown = <String, List<String>>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        (shown[package] ??= []).add(entry.paragraphs.map((paragraph) => paragraph.text).join('\n'));
      }
    }
    expect(asked, ['licenses/artifacts.json', 'licenses/google.json']);
    expect(shown['androidx.core:core']!.single, contains('Apache License'));
    expect(shown['com.github.davidliu:audioswitch'], shown['androidx.core:core']);
    expect(shown['androidx.camera:camera-core'], [shown['androidx.core:core']!.single, contains('Redistribution')]);
    expect(
      shown['com.google.android.gms:play-services-base']!.single,
      contains('Android Software Development Kit License Agreement'),
    );
    expect(shown['com.google.mlkit:barcode-scanning']!.single, contains('ML KIT Terms of Service'));
    expect(shown['io.github.webrtc-sdk:android']!.single, startsWith('libwebrtc '));
    expect(shown['com.example:unnamed'], [licenceTextMissing]);
    expect(shown['JSR 305'], ["Abseil's notice"]);
    expect(shown['Kotlin'], ['one', 'another']);
    expect(shown['Android libraries'], isNull);
  });

  test("a build that didn't write them says so", () {
    expect(registry['Android libraries'], [gradleNoticesMissing]);
  });

  test('every licence the build accepts has its text, the page has no other, and none is the GPL, LGPL or AGPL', () {
    final gradle = _lf(File('android/app/build.gradle.kts').readAsStringSync());
    final accepted = {
      for (final match in RegExp(r'^\s*allow(?:Url)?\("([^"]+)"\)', multiLine: true).allMatches(gradle)) match[1]!,
    };
    expect(accepted, isNotEmpty);
    expect(acceptedLicences.keys.toSet(), accepted);
    expect(accepted.where((licence) => licence.contains('GPL')), isEmpty);
    // A library let through by its coordinates would come with no licence the page has a text for.
    expect(gradle, isNot(contains('allowDependency(')));
    for (final asset in {...acceptedLicences.values, ...ownNotices.values}) {
      expect(File(asset).readAsStringSync().trim(), isNotEmpty, reason: asset);
    }
  });

  test("libwebrtc's notices are those of the version the flutter_webrtc fork builds with", () {
    final gradle = File.fromUri(_root('flutter_webrtc').resolve('android/build.gradle')).readAsStringSync();
    final version = RegExp(r'io\.github\.webrtc-sdk:android:([\w.]+)').firstMatch(gradle)![1];
    final notices = File(ownNotices['io.github.webrtc-sdk:android']!).readAsStringSync();
    expect(notices, startsWith('libwebrtc $version, '), reason: 'tool/libwebrtc_notices.py writes them for a version');
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
