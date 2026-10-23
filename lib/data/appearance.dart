import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// System, light or dark, kept on the device.
class Appearance extends ValueNotifier<ThemeMode> {
  final AppearanceStore _store;
  Appearance([AppearanceStore? store]) : _store = store ?? const SecureAppearanceStore(), super(ThemeMode.system);

  Future<void> load() async {
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
}

class SecureAppearanceStore implements AppearanceStore {
  const SecureAppearanceStore();
  static const _key = 'duvet_appearance';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String mode) => _storage.write(key: _key, value: mode);
}

class MemoryAppearanceStore implements AppearanceStore {
  String? mode;
  @override
  Future<String?> read() async => mode;

  @override
  Future<void> write(String mode) async => this.mode = mode;
}

/// Hands the [Appearance] down the tree.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({required Appearance appearance, required super.child, super.key})
    : super(notifier: appearance);

  static Appearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()!.notifier!;
}
