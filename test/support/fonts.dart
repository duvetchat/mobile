import 'package:flutter/services.dart';

/// Loads the app's faces (pubspec's `fonts:`), so text lays out and wraps as
/// it does on a phone instead of in the test font's boxes.
Future<void> loadAppFonts() async {
  const files = {
    'Fraunces': ['Fraunces'],
    'Inter': ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'Inter-Bold'],
    'Roboto': ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold'],
    'Fira Mono': ['FiraMono-Regular'],
  };
  for (final MapEntry(key: family, value: names) in files.entries) {
    final loader = FontLoader(family);
    for (final name in names) {
      loader.addFont(rootBundle.load('assets/fonts/$name.ttf'));
    }
    await loader.load();
  }
}
