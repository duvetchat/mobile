/// What the app tells the API (X-Duvet-Client, on every request) and the gateway (an identify's client) it is
/// (PLAN-E2E-CLIENTES.md, its versions): `<platform>/<version>`, which the API holds to E2E_MIN_CLIENTS. Not a secret:
/// the API knows both.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appBuildName;

/// The app as the API names it: `android/<version>`, the pubspec's version without its build number (Flutter's
/// [appBuildName]); `ios/<version>` on iOS, which the API answers with its 426 until it has encryption. Null elsewhere
/// (the web build, a computer), which says nothing: a client without encryption.
String? duvetClient({TargetPlatform? platform, bool web = kIsWeb, String? version = appBuildName}) {
  if (web || version == null) return null;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android/$version',
    TargetPlatform.iOS => 'ios/$version',
    _ => null,
  };
}
