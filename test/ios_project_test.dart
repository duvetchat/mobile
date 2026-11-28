import 'dart:io';

import 'package:duvet/push/renewal.dart' show renewalEvery, renewalTask;
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

  // The session's renewal while the app sits closed (lib/push/renewal.dart; PLAN-E2E-PLATAFORMAS.md, Task 13): iOS
  // runs a BGTaskScheduler task only under an identifier Info.plist permits, an app refresh only with the fetch
  // background mode, and only once a launch handler was registered before the app's launch ended.
  test('the session renews in the background on iOS, under the task Dart schedules', () {
    final plist = read('ios/Runner/Info.plist');
    List<String> array(String key) {
      final values = RegExp('<key>$key</key>\\s*<array>(.*?)</array>', dotAll: true).firstMatch(plist)?[1] ?? '';
      return [for (final match in RegExp('<string>([^<]*)</string>').allMatches(values)) match[1]!];
    }

    expect(array('BGTaskSchedulerPermittedIdentifiers'), [renewalTask]);
    expect(array('UIBackgroundModes'), unorderedEquals(['audio', 'fetch']));

    final delegate = read('ios/Runner/AppDelegate.swift');
    final launch = RegExp(r'didFinishLaunchingWithOptions(.*?)return super\.application', dotAll: true);
    final handler = RegExp(
      r'registerPeriodicTask\(\s*withIdentifier: "([^"]*)",\s*earliestBeginInSeconds: NSNumber\(value: (\d+)\)\)',
    );
    final registered = handler.firstMatch(launch.firstMatch(delegate)?[1] ?? '');
    expect(registered?[1], renewalTask);
    // Each run asks for the next one no sooner than the renewal is due.
    expect(int.parse(registered?[2] ?? '0'), renewalEvery.inSeconds);
    // The task's engine reads and writes the session, and gets the Keychain's plugin alone: none of the app's audio,
    // calls or notifications start there, as a call's audio did under Android's background engines.
    final plugins = RegExp(
      r'setPluginRegistrantCallback \{ registry in(.*?)\n    \}',
      dotAll: true,
    ).firstMatch(delegate);
    expect(RegExp(r'(\w+)\.register\(with:').allMatches(plugins?[1] ?? '').map((m) => m[1]), [
      'FlutterSecureStorageDarwinPlugin',
    ]);
  });
}
