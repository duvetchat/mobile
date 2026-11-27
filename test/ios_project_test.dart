import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The iOS project builds on any Xcode (#388). A Windows checkout has CRLF: read as LF.
String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  final project = read('ios/Runner.xcodeproj/project.pbxproj');

  test("the system's frameworks are named by the SDK being built with, not by one Xcode's copy of it", () {
    final frameworks = RegExp(
      r'^\t\t\w{24} /\* \w+\.framework \*/ = \{isa = PBXFileReference;.*$',
      multiLine: true,
    ).allMatches(project).map((match) => match[0]!).toList();
    expect(frameworks, isNotEmpty);
    for (final framework in frameworks) {
      expect(framework, contains('path = System/Library/Frameworks/'), reason: framework);
      expect(framework, contains('sourceTree = SDKROOT;'), reason: framework);
    }
    // Another Xcode has another SDK version, and the simulator another platform.
    expect(project, isNot(contains('.sdk/')));
  });
}
