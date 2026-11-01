import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../theme.dart';
import 'chrome.dart';
import 'media.dart' show videoBackdrop;

/// A YouTube video handed on from a chat: which, its title, and where it got to.
/// [session], when a playing tile hands its own player on: the dock shows it
/// as it is, so the video doesn't stop to load again.
typedef DockedYouTube = ({String id, String? title, double seconds, YouTubeSession? session});

/// The video in the dock over the tabs, if any. A tile still playing as it
/// goes (its chat closed, or scrolled far away) puts it there; close clears it.
final dockedYouTube = ValueNotifier<DockedYouTube?>(null);

/// A YouTube player that keeps where it is, so its video can be handed on
/// (to full screen, back, or to the dock) and pick up there.
class YouTubeSession {
  final YoutubePlayerController controller;
  double seconds;
  late final StreamSubscription<YoutubeVideoState> _position;
  late final StreamSubscription<YoutubePlayerValue> _state;

  // The one playing: another starting pauses it, so two never play at once.
  static YouTubeSession? _playing;

  YouTubeSession(String id, {this.seconds = 0, bool autoPlay = true, bool fullScreenButton = false})
    : controller = YoutubePlayerController.fromVideoId(
        videoId: id,
        autoPlay: autoPlay,
        startSeconds: seconds,
        params: YoutubePlayerParams(showFullscreenButton: fullScreenButton, strictRelatedVideos: true),
      ) {
    // shortcut: the player reports its time only while playing, so a seek made
    // while paused is lost on a handoff; ask controller.currentTime if that matters.
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

/// Plays [id] from [seconds] over everything, black around it, turning with
/// the phone. Pops with where it got to and whether it was playing.
Future<({double seconds, bool playing})?> openYouTubeFullScreen(
  BuildContext context, {
  required String id,
  required double seconds,
  double ratio = 16 / 9,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder(
    transitionDuration: DuvetTokens.panelIn,
    reverseTransitionDuration: DuvetTokens.panelOut,
    pageBuilder: (_, _, _) => _YouTubeFullScreen(id: id, seconds: seconds, ratio: ratio),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: DuvetTokens.decelerate),
      child: child,
    ),
  ),
);

class _YouTubeFullScreen extends StatefulWidget {
  final String id;
  final double seconds;
  final double ratio;
  const _YouTubeFullScreen({required this.id, required this.seconds, required this.ratio});

  @override
  State<_YouTubeFullScreen> createState() => _YouTubeFullScreenState();
}

class _YouTubeFullScreenState extends State<_YouTubeFullScreen> {
  late final YouTubeSession _session;

  @override
  void initState() {
    super.initState();
    _session = YouTubeSession(widget.id, seconds: widget.seconds);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _session.close();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop((seconds: _session.seconds, playing: _session.playing));

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFF2F1EE);
    return PopScope(
      // Back pops with where the video got to, as the close button does.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: widget.ratio,
                // Its own overlay: the player draws in the nearest one, and the
                // close button has to stay over it.
                child: Overlay.wrap(
                  child: YoutubePlayer(
                    controller: _session.controller,
                    aspectRatio: widget.ratio,
                    backgroundColor: Colors.black,
                    autoFullScreen: false,
                    enableFullScreenOnVerticalDrag: false,
                  ),
                ),
              ),
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
  // None while it plays full screen: one player at a time.
  YouTubeSession? _session;

  // The tile's own player, still playing: shown as its webview alone, since a
  // new YoutubePlayer loads the page again.
  bool _handedOn = false;

  @override
  void initState() {
    super.initState();
    _handedOn = widget.video.session != null;
    _session = widget.video.session ?? YouTubeSession(widget.video.id, seconds: widget.video.seconds);
    // Android pauses a webview's video while it's off screen, between the tile
    // and the dock; still loaded, it plays on at once when it's back.
    // shortcut: asked again a moment later, as the first can come before the
    // view is on screen; listen for the view's attach if this still stutters.
    if (_handedOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _session?.controller.playVideo();
      });
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _session?.controller.playVideo();
      });
    }
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _expand() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _session = null;
      _handedOn = false;
    });
    session.close();
    final back = await openYouTubeFullScreen(context, id: widget.video.id, seconds: session.seconds);
    if (back != null && mounted) {
      setState(() => _session = YouTubeSession(widget.video.id, seconds: back.seconds, autoPlay: back.playing));
    }
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
                  // Its own overlay, as in a chat: kept to this box, under the
                  // routes above the tabs.
                  child: session == null
                      ? null
                      : _handedOn
                      // Its buttons drive it; a tap on the tiny page would only
                      // bring up YouTube's own controls.
                      ? IgnorePointer(child: WebViewWidget(controller: session.controller.webViewController))
                      : Overlay.wrap(
                          child: YoutubePlayer(
                            controller: session.controller,
                            backgroundColor: videoBackdrop,
                            autoFullScreen: false,
                            enableFullScreenOnVerticalDrag: false,
                          ),
                        ),
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
            if (session != null)
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
