import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one gesture that replies to a message. Only [doubleTap] makes a tap
/// on a picture wait to rule out a second one.
enum ReplyGesture { swipeLeft, swipeRight, doubleTap }

/// System, light or dark, and the reply gesture, kept on the device.
class Appearance extends ValueNotifier<ThemeMode> {
  final AppearanceStore _store;
  Appearance([AppearanceStore? store]) : _store = store ?? const SecureAppearanceStore(), super(ThemeMode.system);

  ReplyGesture replyGesture = ReplyGesture.swipeLeft;

  Future<void> load() async {
    try {
      final gesture = ReplyGesture.values.asNameMap()[await _store.readReplyGesture()];
      if (gesture != null && gesture != replyGesture) {
        replyGesture = gesture;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('appearance: $e');
    }
    try {
      value = switch (await _store.read()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (e) {
      debugPrint('appearance: $e');
    }
  }

  Future<void> set(ThemeMode mode) async {
    value = mode;
    try {
      await _store.write(mode.name);
    } catch (e) {
      debugPrint('appearance: $e');
    }
  }

  Future<void> setReplyGesture(ReplyGesture gesture) async {
    replyGesture = gesture;
    notifyListeners();
    try {
      await _store.writeReplyGesture(gesture.name);
    } catch (e) {
      debugPrint('appearance: $e');
    }
  }

  /// The brightness to draw with, given the system's.
  Brightness resolve(Brightness system) => switch (value) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system => system,
  };
}

abstract interface class AppearanceStore {
  Future<String?> read();
  Future<void> write(String mode);
  Future<String?> readReplyGesture();
  Future<void> writeReplyGesture(String gesture);
}

class SecureAppearanceStore implements AppearanceStore {
  const SecureAppearanceStore();
  static const _key = 'duvet_appearance';
  static const _replyKey = 'duvet_reply_gesture';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String mode) => _storage.write(key: _key, value: mode);

  @override
  Future<String?> readReplyGesture() => _storage.read(key: _replyKey);

  @override
  Future<void> writeReplyGesture(String gesture) => _storage.write(key: _replyKey, value: gesture);
}

/// Hands the [Appearance] down the tree.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({required Appearance appearance, required super.child, super.key})
    : super(notifier: appearance);

  static Appearance of(BuildContext context) => maybeOf(context)!;

  /// Null outside the app: a widget pumped alone in a test.
  static Appearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
