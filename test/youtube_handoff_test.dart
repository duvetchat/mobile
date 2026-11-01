import 'dart:convert';

import 'package:duvet/data/models.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/message_content.dart';
import 'package:duvet/widgets/youtube_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A webview platform with no webviews: it counts the controllers made (one
/// per player) and the platform views built, and plays the page's part.
class _FakeWebViews extends WebViewPlatform {
  final controllers = <_FakeController>[];
  var views = 0;

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = _FakeController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _FakeNavigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeWidget(params, this);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  final _channels = <String, JavaScriptChannelParams>{};
  var loads = 0;

  /// A message from the page's player, as player.html sends it.
  void send(String event, Object? data) {
    for (final c in _channels.values) {
      c.onMessageReceived(JavaScriptMessage(message: jsonEncode({'playerId': c.name, event: data})));
    }
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async => _channels[params.name] = params;
  @override
  Future<void> removeJavaScriptChannel(String name) async => _channels.remove(name);
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async => loads++;
  @override
  Future<void> runJavaScript(String javaScript) async {}
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      javaScript.contains('getVideoData') ? '{"video_id":"dQw4w9WgXcQ"}' : '0';
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> enableZoom(bool enabled) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
}

class _FakeNavigation extends PlatformNavigationDelegate {
  _FakeNavigation(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  final _FakeWebViews platform;
  _FakeWidget(super.params, this.platform) : super.implementation();

  @override
  Widget build(BuildContext context) => _PlatformView(platform);
}

/// Stands for Android's platform view: made in initState, gone in dispose.
class _PlatformView extends StatefulWidget {
  final _FakeWebViews platform;
  const _PlatformView(this.platform);

  @override
  State<_PlatformView> createState() => _PlatformViewState();
}

class _PlatformViewState extends State<_PlatformView> {
  @override
  void initState() {
    super.initState();
    widget.platform.views++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _FakeWebViews webViews;
  setUp(() => WebViewPlatform.instance = webViews = _FakeWebViews());

  /// The latest player's page, ready and playing.
  void playing() {
    webViews.controllers.last
      ..send('Ready', null)
      ..send('StateChange', 1);
  }

  /// One player, one platform view, on screen.
  void one(String where) {
    expect((webViews.controllers.length, webViews.views), (1, 1), reason: where);
    expect(find.byType(WebViewWidget, skipOffstage: false), findsOneWidget, reason: where);
  }

  Finder action(String label) => find.byWidgetPredicate((w) => w is IconAction && w.label == label);

  testWidgets('a YouTube video goes full screen, back, to the dock and full screen again on one player and one view', (
    tester,
  ) async {
    const embed = MessageEmbed(
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      videoUrl: 'https://www.youtube.com/embed/dQw4w9WgXcQ',
      title: 'A video',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          // The tabs, as in main.dart: the dock over them, a chat pushed on top.
          child: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Builder(
                    builder: (context) => Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const Scaffold(
                              body: Center(child: EmbedCard(embed: embed)),
                            ),
                          ),
                        ),
                        child: const Text('Open chat'),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: dockedYouTube,
                  builder: (_, docked, _) =>
                      docked == null ? const SizedBox.shrink() : YouTubeDock(key: ValueKey(docked), video: docked),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();

    // Played in the message.
    await tester.tap(find.byType(PlayMark));
    await tester.pumpAndSettle();
    playing();
    await tester.pumpAndSettle();
    one('playing in the message');

    // The player's own full-screen button, then the route's close.
    webViews.controllers.last.send('FullscreenButtonPressed', 1);
    await tester.pumpAndSettle();
    playing();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Exit full screen'), findsOneWidget);
    one('full screen from the message');
    // The chat under it rebuilt (the phone turned): it doesn't take the view back.
    tester
        .element(find.byWidgetPredicate((w) => '${w.runtimeType}' == '_YouTubeTile', skipOffstage: false))
        .markNeedsBuild();
    await tester.pump();
    one('the message rebuilt under full screen');
    await tester.tap(find.bySemanticsLabel('Exit full screen'));
    await tester.pumpAndSettle();
    playing();
    await tester.pumpAndSettle();
    one('back in the message');

    // The chat closed while it plays: on to the dock.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(dockedYouTube.value, isNotNull);
    one('in the dock');

    // Full screen from the dock, and back.
    await tester.tap(action('Full screen'));
    await tester.pumpAndSettle();
    playing();
    await tester.pumpAndSettle();
    one('full screen from the dock');
    tester.element(find.byType(YouTubeDock, skipOffstage: false)).markNeedsBuild();
    await tester.pump();
    one('the dock rebuilt under full screen');
    // The player's own full-screen button, in full screen, closes it.
    webViews.controllers.last.send('FullscreenButtonPressed', 1);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Exit full screen'), findsNothing);
    one('back in the dock');

    await tester.tap(action('Stop and close'));
    await tester.pumpAndSettle();
    expect(dockedYouTube.value, isNull);
    expect(webViews.controllers.first.loads, 1, reason: 'the page loaded once');
    // Past any timer a handoff left.
    await tester.pump(const Duration(seconds: 1));
  });
}
