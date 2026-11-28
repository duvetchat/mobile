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
}
