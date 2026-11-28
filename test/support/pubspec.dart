import 'dart:io';

/// pubspec.yaml's version without its build number, the one `flutter build` and `flutter test` hand the app (Flutter's
/// appBuildName), its CRLF made LF first, as a Windows checkout has it.
String pubspecVersion() {
  final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
  return RegExp(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\+', multiLine: true).firstMatch(pubspec)![1]!;
}
