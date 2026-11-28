import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Nothing of the app goes to Android's backups or to a new phone (PLAN-E2E-CLIENTES.md, Ruling 20 and Review Focus
// 10): its encryption database restored on another phone would be a cloned device. android:allowBackup="false" keeps
// it out of backups, but an app that targets Android 12 or later still moves whole to a new phone unless its data
// extraction rules' device-transfer part leaves it out. A Windows checkout has CRLF: read as LF.
String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final manifest = read('android/app/src/main/AndroidManifest.xml');
  final application = RegExp(r'<application\b[^>]*>').firstMatch(manifest)?[0] ?? '';

  test('the manifest says android:allowBackup="false"', () {
    expect(application, contains('android:allowBackup="false"'));
  });

  test('and leaves every file out of cloud backups and device transfers on Android 12 and later', () {
    expect(application, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    final rules = read('android/app/src/main/res/xml/data_extraction_rules.xml');
    for (final part in ['cloud-backup', 'device-transfer']) {
      final section = RegExp('<$part>(.*?)</$part>', dotAll: true).firstMatch(rules)?[1];
      expect(section, isNotNull, reason: part);
      for (final domain in ['root', 'file', 'database', 'sharedpref', 'external', 'device_root']) {
        expect(section, contains('<exclude domain="$domain" path="."/>'), reason: '$part, $domain');
      }
      expect(section, isNot(contains('<include')), reason: part);
    }
  });
}
