import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// How the Spaces tab lays its Spaces out: today's two-column cards, rows, or
/// wide cards with their banners.
enum SpaceView { grid, list, cards }

/// The Spaces' order: as the gateway sends them (the desktop's), or by name.
enum SpaceSort { gateway, alphabetical }

/// [spaces], which come in the gateway's order, as [sort] has them.
List<Space> sortedSpaces(List<Space> spaces, SpaceSort sort) => switch (sort) {
  SpaceSort.gateway => spaces,
  SpaceSort.alphabetical =>
    [...spaces]..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    }),
};

typedef LaunchpadChoice = ({SpaceView view, SpaceSort sort});

/// The Spaces tab's view and order, kept on the device.
class LaunchpadPrefs extends ValueNotifier<LaunchpadChoice> {
  final LaunchpadStore _store;
  LaunchpadPrefs([LaunchpadStore? store])
    : _store = store ?? const SecureLaunchpadStore(),
      super((view: SpaceView.grid, sort: SpaceSort.gateway));

  Future<void> load() async {
    try {
      // As written: "view sort"; anything else falls back to the defaults.
      final words = (await _store.read())?.split(' ') ?? const [];
      value = (
        view: SpaceView.values.where((v) => v.name == words.elementAtOrNull(0)).firstOrNull ?? SpaceView.grid,
        sort: SpaceSort.values.where((s) => s.name == words.elementAtOrNull(1)).firstOrNull ?? SpaceSort.gateway,
      );
    } catch (e) {
      debugPrint('launchpad: $e');
    }
  }

  Future<void> setView(SpaceView view) => _set((view: view, sort: value.sort));
  Future<void> setSort(SpaceSort sort) => _set((view: value.view, sort: sort));

  Future<void> _set(LaunchpadChoice choice) async {
    value = choice;
    try {
      await _store.write('${choice.view.name} ${choice.sort.name}');
    } catch (e) {
      debugPrint('launchpad: $e');
    }
  }
}

abstract interface class LaunchpadStore {
  Future<String?> read();
  Future<void> write(String choice);
}

class SecureLaunchpadStore implements LaunchpadStore {
  const SecureLaunchpadStore();
  static const _key = 'duvet_launchpad';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String choice) => _storage.write(key: _key, value: choice);
}

class MemoryLaunchpadStore implements LaunchpadStore {
  String? choice;
  MemoryLaunchpadStore([this.choice]);

  @override
  Future<String?> read() async => choice;

  @override
  Future<void> write(String choice) async => this.choice = choice;
}

/// Hands the [LaunchpadPrefs] down the tree.
class LaunchpadScope extends InheritedNotifier<LaunchpadPrefs> {
  const LaunchpadScope({required LaunchpadPrefs prefs, required super.child, super.key}) : super(notifier: prefs);

  static LaunchpadPrefs of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LaunchpadScope>()!.notifier!;
}
