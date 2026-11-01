import 'dart:async';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../theme.dart';
import 'chrome.dart';
import 'media.dart' show videoBackdrop;

/// A YouTube video handed on from a chat: which, its title, and where it got to.
/// [session], when a playing tile hands its own player on: the dock shows the
/// same view, so the video plays on without a pause.
typedef DockedYouTube = ({String id, String? title, double seconds, YouTubeSession? session});

/// The video in the dock over the tabs, if any. A tile still playing as it
/// goes (its chat closed, or scrolled far away) puts it there; close clears it.
final dockedYouTube = ValueNotifier<DockedYouTube?>(null);

/// A YouTube player and its one view, handed on whole (to full screen, back,
/// or to the dock) so the page never loads again.
class YouTubeSession {
  final YoutubePlayerController controller;

  // Moving the view under this key keeps Android's platform view, and so the
  // WebView attached: a new one, even for a frame, pauses the video as hidden.
  final view = GlobalKey();

  /// What the player's own full-screen button does; full screen swaps in its
  /// close while it shows this.
  VoidCallback? onFullScreen;

  double seconds;
  late final StreamSubscription<YoutubeVideoState> _position;
  late final StreamSubscription<YoutubePlayerValue> _state;

  // The one playing: another starting pauses it, so two never play at once.
  static YouTubeSession? _playing;

  YouTubeSession(String id, {this.seconds = 0, bool fullScreenButton = false})
    : controller = YoutubePlayerController.fromVideoId(
        videoId: id,
        autoPlay: true,
        startSeconds: seconds,
        params: YoutubePlayerParams(showFullscreenButton: fullScreenButton, strictRelatedVideos: true),
      ) {
    controller.initWithParams(params: controller.params);
    controller.webViewController.setBackgroundColor(videoBackdrop);
    // The package's full screen only fills the player's box: ours is a route.
    // Its option is turned off at once, so each tap of the button asks again.
    controller.setFullScreenListener((on) {
      if (!on) return;
      controller.exitFullScreen();
      onFullScreen?.call();
    });
    // Where it got to, for a dock that opens without a session; handoffs move
    // the session itself.
    _position = controller.videoStateStream.listen((s) => seconds = s.position.inMilliseconds / 1000);
    _state = controller.stream.listen((value) {
      if (value.playerState != PlayerState.playing || identical(_playing, this)) return;
      _playing?.controller.pauseVideo();
      _playing = this;
    });
  }

  bool get playing => switch (controller.value.playerState) {
    PlayerState.playing || PlayerState.buffering => true,
    _ => false,
  };

  void close() {
    if (identical(_playing, this)) _playing = null;
    _position.cancel();
    _state.cancel();
    controller.close();
  }
}

/// The session's view: shown in one place at a time, which takes it from the
/// last in the same frame.
class YouTubeView extends StatelessWidget {
  final YouTubeSession session;
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;
  const YouTubeView(this.session, {this.gestureRecognizers = const {}, super.key});

  @override
  Widget build(BuildContext context) => WebViewWidget(
    key: session.view,
    controller: session.controller.webViewController,
    gestureRecognizers: gestureRecognizers,
  );
}

/// Shows [session] over everything, black around it, turning with the phone.
/// The caller stops showing it until this returns; it plays on or stays
/// paused as it was.
Future<void> openYouTubeFullScreen(BuildContext context, {required YouTubeSession session, double ratio = 16 / 9}) =>
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        transitionDuration: DuvetTokens.panelIn,
        reverseTransitionDuration: DuvetTokens.panelOut,
        pageBuilder: (_, _, _) => _YouTubeFullScreen(session: session, ratio: ratio),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: DuvetTokens.decelerate),
          child: child,
        ),
      ),
    );

class _YouTubeFullScreen extends StatefulWidget {
  final YouTubeSession session;
  final double ratio;
  const _YouTubeFullScreen({required this.session, required this.ratio});

  @override
  State<_YouTubeFullScreen> createState() => _YouTubeFullScreenState();
}

class _YouTubeFullScreenState extends State<_YouTubeFullScreen> {
  VoidCallback? _onFullScreen;

  // Closing: the view goes back to the caller in the frame of the pop.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    // The player's full-screen button closes this rather than opening another.
    _onFullScreen = widget.session.onFullScreen;
    widget.session.onFullScreen = _close;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!_leaving) widget.session.onFullScreen = _onFullScreen;
    super.dispose();
  }

  void _close() {
    if (_leaving) return;
    widget.session.onFullScreen = _onFullScreen;
    setState(() => _leaving = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const ink = DuvetTokens.mediaInk;
    return PopScope(
      // Back hands the view back, as the close button does.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return _close();
        // Popped from elsewhere: the caller takes the view back all the same.
        if (!_leaving) {
          widget.session.onFullScreen = _onFullScreen;
          setState(() => _leaving = true);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: AspectRatio(aspectRatio: widget.ratio, child: _leaving ? null : YouTubeView(widget.session)),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 6,
              left: 8,
              child: Semantics(
                button: true,
                label: 'Exit full screen',
                excludeSemantics: true,
                onTap: _close,
                child: GestureDetector(
                  onTap: _close,
                  child: const SizedBox.square(dimension: 40, child: Icon(FLucideIcons.x, color: ink)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Over the tabs while a YouTube video handed on from a chat plays: a small
/// live player, its title, play or pause, full screen, and close, which stops it.
class YouTubeDock extends StatefulWidget {
  final DockedYouTube video;
  const YouTubeDock({required this.video, super.key});

  static const _playerHeight = 64.0;
  static const height = _playerHeight + 16;

  @override
  State<YouTubeDock> createState() => _YouTubeDockState();
}

class _YouTubeDockState extends State<YouTubeDock> {
  late final YouTubeSession _session;

  // Full screen: the view is there meanwhile.
  bool _away = false;

  @override
  void initState() {
    super.initState();
    _session = widget.video.session ?? YouTubeSession(widget.video.id, seconds: widget.video.seconds);
    _session.onFullScreen = _expand;
  }

  @override
  void dispose() {
    _session.close();
    super.dispose();
  }

  Future<void> _expand() async {
    if (_away) return;
    setState(() => _away = true);
    await openYouTubeFullScreen(context, session: _session);
    if (mounted) setState(() => _away = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final session = _session;
    final title = widget.video.title ?? 'YouTube video';
    return GlassChrome(
      top: false,
      child: SizedBox(
        height: YouTubeDock.height,
        child: Row(
          children: [
            const SizedBox(width: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
              child: SizedBox(
                width: YouTubeDock._playerHeight * 16 / 9,
                height: YouTubeDock._playerHeight,
                child: ColoredBox(
                  color: videoBackdrop,
                  // Its buttons drive it; a tap on the tiny page would only
                  // bring up YouTube's own controls.
                  child: _away ? null : IgnorePointer(child: YouTubeView(session)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                container: true,
                label: '$title, YouTube',
                excludeSemantics: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                    ),
                    Text('YouTube', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                  ],
                ),
              ),
            ),
            YoutubeValueBuilder(
              controller: session.controller,
              buildWhen: (o, n) => o.playerState != n.playerState,
              builder: (context, _) => IconAction(
                icon: session.playing ? FLucideIcons.pause : FLucideIcons.play,
                label: session.playing ? 'Pause' : 'Play',
                onPressed: session.playing ? session.controller.pauseVideo : session.controller.playVideo,
              ),
            ),
            IconAction(icon: FLucideIcons.maximize, label: 'Full screen', onPressed: _expand),
            IconAction(icon: FLucideIcons.x, label: 'Stop and close', onPressed: () => dockedYouTube.value = null),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
