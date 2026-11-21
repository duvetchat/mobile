import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import 'code_theme.dart';

/// The one gesture that replies to a message. Only [doubleTap] makes a tap
/// on a picture wait to rule out a second one.
enum ReplyGesture { swipeLeft, swipeRight, doubleTap }

/// How a chat draws its messages (#292): bubbles, or flat rows as the
/// desktop's, which fit more on screen.
enum MessageLayout { bubbles, flat }

/// System, light or dark, the reply gesture, the message layout and the code
/// theme, kept on the device.
class Appearance extends ValueNotifier<ThemeMode> {
  final AppearanceStore _store;
  final http.Client Function() _client;
  Appearance([AppearanceStore? store, http.Client Function()? client])
    : _store = store ?? const SecureAppearanceStore(),
      _client = client ?? http.Client.new,
      super(ThemeMode.system);

  ReplyGesture replyGesture = ReplyGesture.swipeLeft;

  /// Bubbles until the user picks flat rows, on every platform.
  MessageLayout messageLayout = MessageLayout.bubbles;

  /// A custom code theme; null for GitHub's.
  CodeTheme? codeTheme;

  /// Completes once [load] has read the mode, the first thing it reads, or failed to: the app's start waits for it
  /// alone (main), so a forced light or dark theme draws the first frame.
  Future<void> get modeLoaded => _modeLoaded.future;
  final _modeLoaded = Completer<void>();

  Future<void> load() async {
    // The mode first: the whole app draws by it, and the rest only shows in a chat.
    try {
      value = switch (await _store.read()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (e) {
      debugPrint('appearance: $e');
    }
    if (!_modeLoaded.isCompleted) _modeLoaded.complete();
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
      final layout = MessageLayout.values.asNameMap()[await _store.readMessageLayout()];
      if (layout != null && layout != messageLayout) {
        messageLayout = layout;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('appearance: $e');
    }
    try {
      // Fetched once, on Apply: launching never asks the theme's server again.
      if (await _store.readCodeTheme() case (:final url, :final json)) {
        codeTheme = CodeTheme.parse(url, json);
      }
    } catch (e) {
      debugPrint('appearance: $e');
      // A theme kept that no longer reads: forget it rather than fail each launch.
      if (e is FormatException || e is TypeError) await _store.writeCodeTheme(null).catchError((_) {});
    }
    // Bubbles are azure (#293): a colour an older version kept for them goes.
    try {
      await _store.forgetBubbleColor();
    } catch (e) {
      debugPrint('appearance: $e');
    }
    // Only for a change: an app closed before this lands has disposed it.
    if (codeTheme != null) notifyListeners();
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

  Future<void> setMessageLayout(MessageLayout layout) async {
    messageLayout = layout;
    notifyListeners();
    try {
      await _store.writeMessageLayout(layout.name);
    } catch (e) {
      debugPrint('appearance: $e');
    }
  }

  /// Fetches the VS Code theme at [url] and uses it for code. Throws, with
  /// nothing changed, when it can't be fetched or read.
  Future<void> applyCodeTheme(String url) async {
    final client = _client();
    try {
      final got = await fetchCodeTheme(url, client);
      await _store.writeCodeTheme((url: got.theme.url, json: got.json));
      codeTheme = got.theme;
      notifyListeners();
    } finally {
      client.close();
    }
  }

  /// Back to GitHub's colors.
  Future<void> resetCodeTheme() async {
    codeTheme = null;
    notifyListeners();
    try {
      await _store.writeCodeTheme(null);
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
  Future<String?> readMessageLayout();
  Future<void> writeMessageLayout(String layout);

  /// The custom code theme: its URL and the JSON fetched from it.
  Future<({String url, String json})?> readCodeTheme();

  /// Null forgets it.
  Future<void> writeCodeTheme(({String url, String json})? theme);

  /// Deletes the colour of the user's bubbles that versions before #293
  /// kept, if there is one.
  Future<void> forgetBubbleColor();
}

class SecureAppearanceStore implements AppearanceStore {
  const SecureAppearanceStore();
  static const _key = 'duvet_appearance';
  static const _replyKey = 'duvet_reply_gesture';
  static const _layoutKey = 'duvet_message_layout';
  static const _codeThemeKey = 'duvet_code_theme_url';
  static const _bubbleKey = 'duvet_bubble_color';
  static const _storage = FlutterSecureStorage();

  // The theme's JSON is too big for secure storage. It sits outside the
  // per-account cache, which signing out wipes: it belongs to the device.
  static Future<File> _themeFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = await Directory('${base.path}/device').create(recursive: true);
    return File('${dir.path}/code_theme.json');
  }

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String mode) => _storage.write(key: _key, value: mode);

  @override
  Future<String?> readReplyGesture() => _storage.read(key: _replyKey);

  @override
  Future<void> writeReplyGesture(String gesture) => _storage.write(key: _replyKey, value: gesture);

  @override
  Future<String?> readMessageLayout() => _storage.read(key: _layoutKey);

  @override
  Future<void> writeMessageLayout(String layout) => _storage.write(key: _layoutKey, value: layout);

  @override
  Future<({String url, String json})?> readCodeTheme() async {
    final url = await _storage.read(key: _codeThemeKey);
    if (url == null) return null;
    final file = await _themeFile();
    return await file.exists() ? (url: url, json: await file.readAsString()) : null;
  }

  @override
  Future<void> writeCodeTheme(({String url, String json})? theme) async {
    final file = await _themeFile();
    if (theme == null) {
      await _storage.delete(key: _codeThemeKey);
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(theme.json, flush: true);
    await _storage.write(key: _codeThemeKey, value: theme.url);
  }

  // Deleting a key that isn't there succeeds, on Android as on iOS.
  @override
  Future<void> forgetBubbleColor() => _storage.delete(key: _bubbleKey);
}

class MemoryAppearanceStore implements AppearanceStore {
  String? mode;
  String? replyGesture;
  String? messageLayout;
  ({String url, String json})? codeTheme;

  /// The colour of the user's bubbles, as versions before #293 kept it.
  String? bubbleColor;
  @override
  Future<String?> read() async => mode;

  @override
  Future<void> write(String mode) async => this.mode = mode;

  @override
  Future<String?> readReplyGesture() async => replyGesture;

  @override
  Future<void> writeReplyGesture(String gesture) async => replyGesture = gesture;

  @override
  Future<String?> readMessageLayout() async => messageLayout;

  @override
  Future<void> writeMessageLayout(String layout) async => messageLayout = layout;

  @override
  Future<({String url, String json})?> readCodeTheme() async => codeTheme;

  @override
  Future<void> writeCodeTheme(({String url, String json})? theme) async => codeTheme = theme;

  @override
  Future<void> forgetBubbleColor() async => bubbleColor = null;
}

/// Your bubbles, always azure as on the desktop (#293): their fill, their
/// white ink, and that the ink is light, so code on them takes a dark theme.
const ownBubble = (fill: Duvet.azure, ink: Color(0xFFFFFFFF), onDark: true);

/// Hands the [Appearance] down the tree.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({required Appearance appearance, required super.child, super.key})
    : super(notifier: appearance);

  static Appearance of(BuildContext context) => maybeOf(context)!;

  /// Null outside the app: a widget pumped alone in a test.
  static Appearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
