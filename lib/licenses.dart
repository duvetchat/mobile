import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the app ships whose notices Flutter's build leaves out of the licence registry, which gathers each Dart
/// package's LICENSE (or NOTICES) file by itself (#401). Each is a text asset, by the names the licence page lists it
/// under.
const bundledLicenses = <(List<String>, String)>[
  // pubspec.yaml's fonts: the SIL OFL asks for its licence to go with the fonts, and Twemoji's art (CC BY 4.0) for
  // credit.
  (['Fraunces'], 'assets/fonts/Fraunces-OFL.txt'),
  (['Inter'], 'assets/fonts/Inter-OFL.txt'),
  (['Roboto'], 'assets/fonts/Roboto-OFL.txt'),
  (['Fira Mono'], 'assets/fonts/FiraMono-OFL.txt'),
  (['Twemoji'], 'assets/fonts/Twemoji-LICENSE.md'),
  // The font uses-material-design bundles, Flutter's copy, under CC BY 4.0.
  (['Material Icons'], 'assets/licenses/MaterialIcons-LICENSE.txt'),
  // lib/widgets/facehash.dart ports it.
  (['facehash-sv'], 'assets/licenses/facehash-sv-LICENSE.txt'),
  // assets/emoji.json is made from it.
  (['emoji-datasource'], 'assets/licenses/emoji-datasource-LICENSE.txt'),
  // The notices of the code its Android and iOS sides adapted: a NOTICE beside its LICENSE, which the build skips.
  (['flutter_webrtc'], 'assets/licenses/flutter_webrtc-NOTICE.txt'),
];

/// The encryption core's third-party notices (SQLCipher, OpenSSL, OpenMLS, hpke-rs and the rest), which
/// tool/vendor_core.sh brings with its libraries, under the core's name.
const coreNotices = 'packages/duvet_e2e/THIRD-PARTY-NOTICES.txt';

/// What the page says in their place while the vendored core has none (its releases until artifacts-b7fc99e), which
/// test/licenses_test.dart fails on.
const coreNoticesMissing = "This build doesn't have the encryption core's third-party notices.";

/// What Gradle brings into the Android app (#403), which Flutter's registry doesn't know either. The release build
/// checks each library's licence against those android/app/build.gradle.kts accepts, and writes into the APK's assets
/// the libraries it checked, with the licences their POMs name (licensee's licenses/artifacts.json), and the notices
/// Google's AARs embed, each text once with the parts that have it (licenses/google.json), which MainActivity reads.
const nativeLicenses = MethodChannel('chat.duvet/licenses');

/// Each licence the build accepts, by the SPDX ID or the URL licensee reports it by, and its text, which the page shows
/// once with every library under it (test/licenses_test.dart holds the list to build.gradle.kts's).
const acceptedLicences = <String, String>{
  // apache.org's LICENSE-2.0.txt, and SPDX's text of the list licensee 1.14.1 matches by (3.27).
  'Apache-2.0': 'assets/licenses/android/Apache-2.0.txt',
  'BSD-3-Clause': 'assets/licenses/android/BSD-3-Clause.txt',
  // Each page's text as of 2026-11-28: the agreement's of April 28, 2026, and ML Kit's of May 14, 2025.
  'https://developer.android.com/studio/terms.html': 'assets/licenses/android/android-sdk-license.txt',
  'https://developers.google.com/ml-kit/terms': 'assets/licenses/android/ml-kit-terms.txt',
  'https://opensource.org/license/bsd-3-clause/': 'assets/licenses/android/BSD-3-Clause.txt',
  'https://github.com/twilio/audioswitch/blob/master/LICENSE.txt': 'assets/licenses/android/Apache-2.0.txt',
};

/// The libraries whose own notices the page shows in place of their licence's text: libwebrtc's, with what it builds
/// in (tool/libwebrtc_notices.py).
const ownNotices = {'io.github.webrtc-sdk:android': 'assets/licenses/android/libwebrtc.txt'};

/// What the page says in their place in a build that didn't write them.
const gradleNoticesMissing = "This build doesn't have the notices of the Android libraries it ships.";

/// What it says of a library whose licence it has no text for, which a build that checked them doesn't ship.
const licenceTextMissing = "This build doesn't have this library's licence.";

/// Each library in [libraries], licensee's list, as group:artifact, by the texts the page shows it under: its own
/// notices, else every licence its POM names that the build accepts. A POM that names two may mean both, as CameraX's
/// does for the native code beside its Java. Null holds those with neither.
Map<String?, List<String>> librariesByText(String libraries) {
  final byText = <String?, List<String>>{};
  for (final library in (jsonDecode(libraries) as List).cast<Map<String, dynamic>>()) {
    final name = '${library['groupId']}:${library['artifactId']}';
    final named = [
      for (final licence in library['spdxLicenses'] as List? ?? const []) (licence as Map)['identifier'],
      for (final licence in library['unknownLicenses'] as List? ?? const []) (licence as Map)['url'],
    ];
    final own = ownNotices[name];
    final texts = own != null ? {own} : {...named.map((licence) => acceptedLicences[licence]).nonNulls};
    for (final text in texts.isEmpty ? const <String?>{null} : texts) {
      (byText[text] ??= []).add(name);
    }
  }
  return byText;
}

/// Adds them to the registry, which reads them only as the licence page opens.
void addBundledLicenses() => LicenseRegistry.addLicense(_bundled);

Stream<LicenseEntry> _bundled() async* {
  for (final (packages, asset) in bundledLicenses) {
    yield LicenseEntryWithLineBreaks(packages, await rootBundle.loadString(asset, cache: false));
  }
  String core;
  try {
    core = await rootBundle.loadString(coreNotices, cache: false);
  } on FlutterError {
    core = coreNoticesMissing;
  }
  yield LicenseEntryWithLineBreaks(const ['duvet_e2e'], core);
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) yield* _gradle();
}

Stream<LicenseEntry> _gradle() async* {
  String? libraries, google;
  try {
    libraries = await nativeLicenses.invokeMethod<String>('read', 'licenses/artifacts.json');
    google = await nativeLicenses.invokeMethod<String>('read', 'licenses/google.json');
  } on MissingPluginException {
    // No activity to ask, as in a test.
  }
  if (libraries == null || google == null) {
    yield const LicenseEntryWithLineBreaks(['Android libraries'], gradleNoticesMissing);
    return;
  }
  for (final MapEntry(key: asset, value: names) in librariesByText(libraries).entries) {
    yield LicenseEntryWithLineBreaks(
      names,
      asset == null ? licenceTextMissing : await rootBundle.loadString(asset, cache: false),
    );
  }
  for (final notice in (jsonDecode(google) as List).cast<Map<String, dynamic>>()) {
    yield LicenseEntryWithLineBreaks((notice['parts'] as List).cast<String>(), notice['text'] as String);
  }
}
