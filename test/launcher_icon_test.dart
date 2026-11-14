// The launcher icon picked in Appearance: what the app asks of Android.
import 'package:duvet/data/launcher_icon.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chat.duvet/icon');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('nothing to pick where the icon can\'t be changed', () async {
    expect(await LauncherIcon.picked(), isNull);
  });

  test('the one picked is Android\'s, and picking another tells it by name', () async {
    final calls = <MethodCall>[];
    var picked = 'violet';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'pick') picked = call.arguments as String;
      return call.method == 'get' ? picked : null;
    });
    expect(await LauncherIcon.picked(), LauncherIcon.violet);
    await LauncherIcon.black.pick();
    expect(calls.last.arguments, 'black');
    expect(await LauncherIcon.picked(), LauncherIcon.black);
  });

  test('a name it doesn\'t know is no icon, not a crash', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => 'gold');
    expect(await LauncherIcon.picked(), isNull);
  });
}
