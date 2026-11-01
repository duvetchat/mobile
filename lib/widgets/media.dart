import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;
import 'package:video_player/video_player.dart';

import '../data/models.dart';
import '../data/ogg.dart';
import '../theme.dart';
import 'depth.dart';

// -----------------------------------------------------------------------------
// Playback
// -----------------------------------------------------------------------------

/// What's playing: one voice note or audio file at a time, app-wide. The
/// playback bar over the tabs shows it while [id] is set.
@immutable
class PlaybackState {
  final String? id;

  /// What it is and who sent it, for the playback bar and Android's media
  /// controls.
  final String title;
  final String? artist;
  final bool playing;
  final Duration position;
  final Duration? duration;
  const PlaybackState({
    this.id,
    this.title = '',
    this.artist,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
  });

  static const idle = PlaybackState();
}

/// Plays voice notes and audio files, one at a time: starting one stops the
/// last. Tests swap in their own [instance].
abstract class AudioPlayback {
  ValueListenable<PlaybackState> get state;

  /// Plays [url] as [id], from where it was paused if it's the same.
  /// [title] and [artist] name it in the playback bar and the system's media
  /// controls, which show [artUrl] (the sender's avatar) as its artwork.
  Future<void> play(String id, String url, {required String title, String? artist, String? artUrl});

  /// Plays what was paused.
  Future<void> resume();
  Future<void> pause();
  Future<void> seek(String id, Duration position);

  /// Stops and forgets it: the playback bar and the media notification go.
  Future<void> stop();

  static AudioPlayback instance = JustAudioPlayback();
}

/// The one player, as Android's media session through audio_service: a voice
/// note shows in the media notification, quick settings and the phone's own
/// surfaces (Infinix's Dynamic Bar), with its sender's avatar. main() registers
/// it; unregistered (in tests, or if that failed) it still plays.
class VoiceNoteHandler extends svc.BaseAudioHandler with svc.SeekHandler {
  VoiceNoteHandler._() {
    // A note that fails while it plays goes from the bar and the notification. just_audio 0.10 reports that on
    // errorStream; stop() is safe to run twice. Not Android's abort (10000000): that's one load giving way to the
    // next note, which mustn't be stopped.
    player.playbackEventStream.listen((_) => playbackState.add(_session()), onError: (Object _) {});
    player.errorStream.where((e) => e.code != 10000000).listen((_) => stop());
    player.durationStream.listen((d) {
      if (mediaItem.value case final item? when d != null) mediaItem.add(item.copyWith(duration: d));
    });
  }

  static final instance = VoiceNoteHandler._();

  final player = ja.AudioPlayer();

  /// Called once it's stopped, from the app or the notification: the app
  /// forgets the note too.
  VoidCallback? onStopped;

  /// Plays the last note again: the system's Play once it has ended.
  Future<void> Function()? onReplay;

  svc.PlaybackState _session() => playbackState.value.copyWith(
    controls: [if (player.playing) svc.MediaControl.pause else svc.MediaControl.play, svc.MediaControl.stop],
    systemActions: const {svc.MediaAction.seek},
    androidCompactActionIndices: const [0, 1],
    processingState: switch (player.processingState) {
      ja.ProcessingState.idle => svc.AudioProcessingState.idle,
      ja.ProcessingState.loading => svc.AudioProcessingState.loading,
      ja.ProcessingState.buffering => svc.AudioProcessingState.buffering,
      ja.ProcessingState.ready => svc.AudioProcessingState.ready,
      ja.ProcessingState.completed => svc.AudioProcessingState.completed,
    },
    playing: player.playing,
    updatePosition: player.position,
    bufferedPosition: player.bufferedPosition,
    speed: player.speed,
  );

  @override
  Future<void> play() async {
    // Nothing loaded: its note ended or was stopped, and the system's media
    // card still offers Play.
    if (player.processingState == ja.ProcessingState.idle) return onReplay?.call();
    return player.play();
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    onStopped?.call();
    await super.stop();
  }
}

class JustAudioPlayback implements AudioPlayback {
  VoiceNoteHandler? _handler;
  final _state = ValueNotifier(PlaybackState.idle);
  ({String id, String url, String title, String? artist, String? artUrl})? _last;

  @override
  ValueListenable<PlaybackState> get state => _state;

  VoiceNoteHandler _ensure() {
    if (_handler case final existing?) return existing;
    final handler = _handler = VoiceNoteHandler.instance;
    handler.onStopped = () => _state.value = PlaybackState.idle;
    handler.onReplay = () async {
      if (_last case final l?) await play(l.id, l.url, title: l.title, artist: l.artist, artUrl: l.artUrl);
    };
    final player = handler.player;
    player.positionStream.listen((p) => _update(position: p));
    player.durationStream.listen((d) => _update(duration: d));
    player.playerStateStream.listen((s) {
      // A note played to its end is done: the bar and the notification go.
      if (s.processingState == ja.ProcessingState.completed) {
        unawaited(handler.stop());
      } else {
        _update(playing: s.playing);
      }
    });
    return handler;
  }

  void _update({bool? playing, Duration? position, Duration? duration}) {
    final s = _state.value;
    if (s.id == null) return;
    _state.value = PlaybackState(
      id: s.id,
      title: s.title,
      artist: s.artist,
      playing: playing ?? s.playing,
      position: position ?? s.position,
      duration: duration ?? s.duration,
    );
  }

  @override
  Future<void> play(String id, String url, {required String title, String? artist, String? artUrl}) async {
    final handler = _ensure();
    _last = (id: id, url: url, title: title, artist: artist, artUrl: artUrl);
    if (_state.value.id != id) {
      await handler.player.stop();
      _state.value = PlaybackState(id: id, title: title, artist: artist);
      handler.mediaItem.add(
        svc.MediaItem(id: id, title: title, artist: artist, artUri: artUrl == null ? null : Uri.tryParse(artUrl)),
      );
      try {
        await handler.player.setUrl(url);
      } on ja.PlayerInterruptedException {
        // Another note, or Stop, took over while this one loaded.
        return;
      } catch (e) {
        // A note that won't load mustn't stay in the bar and the notification.
        debugPrint('Voice note $id failed to load: $e');
        await handler.stop();
        return;
      }
    }
    // The player's own play: the handler's would replay a note that's idle.
    unawaited(handler.player.play());
  }

  @override
  Future<void> resume() async => _handler?.play();

  @override
  Future<void> pause() async => _handler?.pause();

  @override
  Future<void> stop() async => _handler?.stop();

  @override
  Future<void> seek(String id, Duration position) async {
    if (_state.value.id == id) await _handler?.seek(position);
  }
}

/// `m:ss`.
String clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Bars for a waveform when the audio's own aren't known: the desktop app's
/// fallback, seeded by the attachment so a note always looks the same.
List<double> fallbackBars(String seed, int count) {
  var hash = 0;
  int i32(int v) => v.toSigned(32);
  for (final c in seed.codeUnits) {
    hash = i32((hash << 5) - hash + c);
  }
  return [
    for (var i = 0; i < count; i++)
      () {
        hash = i32((hash << 5) - hash + i * 7);
        return 0.15 + ((hash & 0xFFFFFFFF) % 100) / 100 * 0.85;
      }(),
  ];
}

/// A row of bars, filled up to [progress].
class Waveform extends StatelessWidget {
  final List<double> bars;
  final double progress;
  final Color color;
  final double height;
  const Waveform({required this.bars, required this.color, this.progress = 1, this.height = 28, super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        for (final (i, b) in bars.indexed)
          Expanded(
            child: Center(
              child: Container(
                width: 3,
                height: math.max(3, b * height),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: (i + 0.5) / bars.length <= progress ? 1 : 0.38),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// The 36pt rounded-square play button of a voice note or audio file.
class _PlaySquare extends StatelessWidget {
  final bool playing;
  final bool onAccent;
  final String label;
  final VoidCallback onPressed;
  const _PlaySquare({required this.playing, required this.onAccent, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) => Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: onAccent ? const Color(0x2EFFFFFF) : colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: onAccent ? const [] : (pressed ? tokens.shadowPressed : tokens.shadowWell),
            borderRadius: radius,
            child: Icon(
              playing ? FLucideIcons.pause : FLucideIcons.play,
              size: 18,
              color: onAccent ? colors.primaryForeground : colors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// A voice note, as a bubble: play, its waveform filling as it plays, and
/// the time left or its length.
class VoiceNotePlayer extends StatelessWidget {
  final MessageAttachment attachment;
  final bool mine;
  final String authorName;

  /// The sender's avatar: the note's artwork in the system's media controls.
  final String? authorAvatarUrl;
  const VoiceNotePlayer({
    required this.attachment,
    required this.mine,
    required this.authorName,
    this.authorAvatarUrl,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final playback = AudioPlayback.instance;
    final ink = mine ? colors.primaryForeground : colors.foreground;
    final bars = fallbackBars(attachment.id, 30);
    return ValueListenableBuilder(
      valueListenable: playback.state,
      builder: (context, state, _) {
        final active = state.id == attachment.id;
        final playing = active && state.playing;
        final duration = active ? state.duration : null;
        final position = active ? state.position : Duration.zero;
        final progress = duration == null || duration == Duration.zero
            ? 0.0
            : position.inMilliseconds / duration.inMilliseconds;
        final time = active && position > Duration.zero ? clock(position) : (duration == null ? '' : clock(duration));
        final who = mine ? 'Your voice note' : 'Voice note from $authorName';
        return Semantics(
          container: true,
          label: [who, if (duration != null) clock(duration), if (playing) 'playing, ${clock(position)} in'].join(', '),
          child: Container(
            width: 260,
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            decoration: BoxDecoration(
              color: mine ? Duvet.azure : colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              boxShadow: tokens.shadowRest,
            ),
            child: Row(
              children: [
                _PlaySquare(
                  playing: playing,
                  onAccent: mine,
                  label: playing ? 'Pause' : 'Play voice note',
                  onPressed: () => playing
                      ? playback.pause()
                      : playback.play(
                          attachment.id,
                          attachment.url,
                          title: 'Voice message',
                          artist: authorName,
                          artUrl: authorAvatarUrl,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ExcludeSemantics(
                    child: GestureDetector(
                      // Tap along the waveform to jump there.
                      onTapDown: duration == null
                          ? null
                          : (d) {
                              final box = context.findRenderObject() as RenderBox?;
                              final width = (box?.size.width ?? 1) - 76;
                              final f = ((d.localPosition.dx) / math.max(1, width)).clamp(0.0, 1.0);
                              playback.seek(attachment.id, duration * f);
                            },
                      child: Waveform(bars: bars, color: ink, progress: active ? progress : 0),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ExcludeSemantics(
                  child: Text(
                    time,
                    style: DuvetType.caption.copyWith(
                      color: mine ? ink.withValues(alpha: 0.85) : colors.mutedForeground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// An audio file: play, its name, a scrub bar and "1:12 / 4:30".
class AudioFileTile extends StatelessWidget {
  final MessageAttachment attachment;
  const AudioFileTile({required this.attachment, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final playback = AudioPlayback.instance;
    return ValueListenableBuilder(
      valueListenable: playback.state,
      builder: (context, state, _) {
        final active = state.id == attachment.id;
        final playing = active && state.playing;
        final duration = active ? state.duration : null;
        final position = active ? state.position : Duration.zero;
        final progress = duration == null || duration == Duration.zero
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        return Semantics(
          container: true,
          label: ['Audio file ${attachment.displayName}', if (duration != null) clock(duration)].join(', '),
          child: Container(
            width: 268,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              boxShadow: tokens.shadowRest,
            ),
            child: Row(
              children: [
                _PlaySquare(
                  playing: playing,
                  onAccent: false,
                  label: playing ? 'Pause' : 'Play ${attachment.displayName}',
                  onPressed: () => playing
                      ? playback.pause()
                      : playback.play(attachment.id, attachment.url, title: attachment.displayName),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground),
                      ),
                      const SizedBox(height: 8),
                      _Scrub(
                        progress: progress,
                        onSeek: duration == null ? null : (f) => playback.seek(attachment.id, duration * f),
                      ),
                      const SizedBox(height: 8),
                      ExcludeSemantics(
                        child: Text(
                          duration == null ? 'Audio' : '${clock(position)} / ${clock(duration)}',
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A 4pt track with a rounded-square thumb (circles are for people).
class _Scrub extends StatelessWidget {
  final double progress;
  final ValueChanged<double>? onSeek;
  final Color? track;
  final Color? fill;
  const _Scrub({required this.progress, this.onSeek, this.track, this.fill});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void seek(Offset at) => onSeek?.call((at.dx / width).clamp(0.0, 1.0));
        return Semantics(
          slider: true,
          value: '${(progress * 100).round()}%',
          increasedValue: '${(math.min(1.0, progress + 0.1) * 100).round()}%',
          decreasedValue: '${(math.max(0.0, progress - 0.1) * 100).round()}%',
          onIncrease: onSeek == null ? null : () => onSeek!(math.min(1, progress + 0.1)),
          onDecrease: onSeek == null ? null : () => onSeek!(math.max(0, progress - 0.1)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seek(d.localPosition),
            onHorizontalDragUpdate: (d) => seek(d.localPosition),
            child: SizedBox(
              height: 16,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(color: track ?? colors.secondary, borderRadius: BorderRadius.circular(2)),
                  ),
                  Container(
                    width: width * progress,
                    height: 4,
                    decoration: BoxDecoration(color: fill ?? colors.foreground, borderRadius: BorderRadius.circular(2)),
                  ),
                  Positioned(
                    left: (width * progress - 8).clamp(0, math.max(0, width - 16)),
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: tokens.shadowControl,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Video
// -----------------------------------------------------------------------------

/// Behind a video until its poster or first frame shows.
const videoBackdrop = Color(0xFF2B2D33);

/// The play mark over a video's poster.
class PlayMark extends StatelessWidget {
  const PlayMark({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      color: DuvetTokens.mediaScrim,
      borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
      border: Border.all(color: DuvetTokens.mediaScrimEdge),
    ),
    child: const Icon(FLucideIcons.play, color: DuvetTokens.mediaInk, size: 24),
  );
}

/// A video in a message: a poster with a play button; tapping plays it full
/// screen. The poster is [poster] (an embed's picture) or else the video's
/// first frame, loaded paused.
class VideoTile extends StatefulWidget {
  final MessageAttachment attachment;
  final double width;
  final String? poster;
  const VideoTile({required this.attachment, this.width = 248, this.poster, super.key});

  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  // Each first frame is a player and a decoder of its own.
  // shortcut: at most 3 load at once, the rest show the play mark only; upgrade when the API sends a poster for
  // uploaded videos.
  static const _maxFrames = 3;
  static int _frames = 0;

  // Only while on screen: the list drops (and so disposes) a tile scrolled away.
  VideoPlayerController? _frame;

  @override
  void initState() {
    super.initState();
    if (widget.poster != null || widget.attachment.local || _frames >= _maxFrames) return;
    _frames++;
    _frame = VideoPage.controllerFor(Uri.parse(widget.attachment.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      }, onError: (Object _) {});
  }

  @override
  void dispose() {
    if (_frame case final frame?) {
      _frames--;
      frame.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    // Sized like a picture: its own ratio, so a tall or wide video isn't cropped; 248×168 until its size is known.
    final ratio = (attachment.width ?? 0) <= 0 || (attachment.height ?? 0) <= 0
        ? 248 / 168
        : attachment.width! / attachment.height!;
    final height = math.min(widget.width / ratio, 320.0);
    final width = math.min(widget.width, height * ratio);
    final frame = _frame?.value;
    void open() => Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: DuvetTokens.panelIn,
        reverseTransitionDuration: DuvetTokens.panelOut,
        pageBuilder: (_, _, _) => VideoPage(attachment: attachment),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: DuvetTokens.decelerate),
          child: child,
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      label: 'Video, ${attachment.displayName}. Play',
      excludeSemantics: true,
      onTap: attachment.local ? null : open,
      child: GestureDetector(
        onTap: attachment.local ? null : open,
        child: Container(
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: videoBackdrop,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.poster case final poster?)
                Image.network(
                  poster,
                  fit: BoxFit.cover,
                  cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (frame != null && frame.isInitialized && !frame.size.isEmpty)
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.fromSize(size: frame.size, child: VideoPlayer(_frame!)),
                ),
              const Center(child: PlayMark()),
            ],
          ),
        ),
      ),
    );
  }
}

/// A video, full screen on near-black: play and pause, a scrub bar, the time;
/// swipe down or Close to leave.
class VideoPage extends StatefulWidget {
  final MessageAttachment attachment;
  const VideoPage({required this.attachment, super.key});

  /// Builds the controller; tests swap in their own.
  @visibleForTesting
  static VideoPlayerController Function(Uri url) controllerFor = VideoPlayerController.networkUrl;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final VideoPlayerController _controller = VideoPage.controllerFor(Uri.parse(widget.attachment.url));
  Object? _error;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _controller.initialize().then(
      (_) {
        if (mounted) _controller.play();
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink = DuvetTokens.mediaInk;
    final value = _controller.value;
    final duration = value.duration;
    final progress = duration == Duration.zero ? 0.0 : value.position.inMilliseconds / duration.inMilliseconds;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Video, ${widget.attachment.displayName}',
      child: Scaffold(
        backgroundColor: Color.fromRGBO(10, 10, 11, (1 - _drag.abs() / 400).clamp(0.3, 1)),
        body: GestureDetector(
          onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
          onVerticalDragEnd: (_) {
            if (_drag.abs() > 120) {
              Navigator.of(context).pop();
            } else {
              setState(() => _drag = 0);
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  child: Center(
                    child: _error != null
                        ? Text('Couldn’t play this video', style: DuvetType.body.copyWith(color: ink))
                        : value.isInitialized
                        ? GestureDetector(
                            onTap: () => value.isPlaying ? _controller.pause() : _controller.play(),
                            child: AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(_controller)),
                          )
                        : const CircularProgressIndicator(color: ink),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.paddingOf(context).top + 6,
                left: 8,
                child: Semantics(
                  button: true,
                  label: 'Close',
                  excludeSemantics: true,
                  onTap: () => Navigator.of(context).pop(),
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const SizedBox.square(dimension: 40, child: Icon(FLucideIcons.x, color: ink)),
                  ),
                ),
              ),
              if (value.isInitialized)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.paddingOf(context).bottom + 16,
                  child: Row(
                    children: [
                      Semantics(
                        button: true,
                        label: value.isPlaying ? 'Pause' : 'Play',
                        excludeSemantics: true,
                        onTap: () => value.isPlaying ? _controller.pause() : _controller.play(),
                        child: GestureDetector(
                          onTap: () => value.isPlaying ? _controller.pause() : _controller.play(),
                          child: SizedBox.square(
                            dimension: 40,
                            child: Icon(value.isPlaying ? FLucideIcons.pause : FLucideIcons.play, color: ink),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _Scrub(
                          progress: progress.clamp(0, 1),
                          track: const Color(0x3DFFFFFF),
                          fill: ink,
                          onSeek: (f) => _controller.seekTo(duration * f),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${clock(value.position)} / ${clock(duration)}',
                        style: DuvetType.caption.copyWith(color: ink),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Recording
// -----------------------------------------------------------------------------

/// A finished recording.
typedef Recording = ({List<int> bytes, String format, Duration length});

/// Records voice notes. Tests swap in their own [instance].
abstract class VoiceRecorder {
  /// Asks for the microphone if needed; answers whether it may record.
  Future<bool> start();

  /// Loudness while recording, 0 to 1.
  Stream<double> get levels;

  /// Stops and answers the recording, or null when there's none.
  Future<Recording?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  static VoiceRecorder Function() create = RecordVoiceRecorder.new;
}

/// Ogg/Opus through the `record` package (Android 10 and later; AAC before).
class RecordVoiceRecorder implements VoiceRecorder {
  final _recorder = rec.AudioRecorder();
  String? _path;
  DateTime? _started;

  String _format = 'ogg';

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    // Opus needs Android 10; before it, AAC.
    final opus = await _recorder.isEncoderSupported(rec.AudioEncoder.opus);
    _format = opus ? 'ogg' : 'm4a';
    final dir = await getTemporaryDirectory();
    final path = _path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.$_format';
    await _recorder.start(
      rec.RecordConfig(encoder: opus ? rec.AudioEncoder.opus : rec.AudioEncoder.aacLc, numChannels: 1),
      path: path,
    );
    _started = DateTime.now();
    return true;
  }

  @override
  Stream<double> get levels => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      // dBFS, -60 (quiet) to 0 (loud).
      .map((a) => ((a.current + 60) / 60).clamp(0.0, 1.0));

  @override
  Future<Recording?> stop() async {
    final path = await _recorder.stop() ?? _path;
    final started = _started;
    unawaited(_recorder.dispose());
    if (path == null || started == null) return null;
    final file = File(path);
    final bytes = await file.readAsBytes();
    unawaited(file.delete().then((_) {}, onError: (_) {}));
    // Android's Ogg muxer puts each packet's start where its end goes, which Firefox rejects (data/ogg.dart).
    return (bytes: recordingToUpload(bytes, _format), format: _format, length: DateTime.now().difference(started));
  }

  @override
  Future<void> cancel() async {
    await _recorder.cancel();
    unawaited(_recorder.dispose());
  }
}
