import 'package:flutter/services.dart';

/// The app's icons on the home screen, to pick between in Appearance. Android's
/// only so far: an activity-alias each, by these names (LauncherIcon.kt).
enum LauncherIcon {
  violet('Violet', 'assets/logo/app-icon-colored.svg'),
  black('Black', 'assets/logo/app-icon-rounded.svg');

  final String label;

  /// The icon as a picture, to pick it by.
  final String asset;
  const LauncherIcon(this.label, this.asset);

  static const _channel = MethodChannel('chat.duvet/icon');

  /// The one picked; null where the icon can't be changed.
  static Future<LauncherIcon?> picked() async {
    try {
      return values.asNameMap()[await _channel.invokeMethod<String>('get')];
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Picks it. The launcher shows it once the app is closed: changing its entry
  /// under a running app makes many launchers close the app.
  Future<void> pick() => _channel.invokeMethod<void>('pick', name);
}
