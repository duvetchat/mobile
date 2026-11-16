import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' as svc;
import 'package:clock/clock.dart' as time show clock;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;
import 'package:video_player/video_player.dart';

import '../data/images.dart';
import '../data/models.dart';
import '../data/ogg.dart';
import '../data/appearance.dart' show ownBubble;
import '../theme.dart';
import 'attachment_link.dart';
import 'depth.dart';
import 'skeleton.dart';

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
  /// [link], when given, answers the link to load instead, a new one when
  /// [url] is about to expire, and is asked once more when it fails to load.
  Future<void> play(String id, String url, {required String title, String? artist, String? artUrl, LinkSource? link});

  /// Plays what was paused.
  Future<void> resume();
  Future<void> pause();
  Future<void> seek(String id, Duration position);

  /// Stops and forgets it: the playback bar and the media notification go.
  Future<void> stop();

  /// Each note's speed, as the user set it: one missing plays at 1×.
  ValueListenable<Map<String, double>> get speeds;

  /// Plays [id] at [speed]: at once if it's playing, and whenever it plays
  /// next.
  Future<void> setSpeed(String id, double speed);

  /// The desktop's steps, which the speed button goes through in turn.
  static const speedSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  /// The step after [speed], back to the first after the last.
  static double nextSpeed(double speed) {
    final i = speedSteps.indexOf(speed);
    return speedSteps[(i + 1) % speedSteps.length];
  }

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
  final _speeds = ValueNotifier(const <String, double>{});

  @override
  ValueListenable<Map<String, double>> get speeds => _speeds;

  @override
  Future<void> setSpeed(String id, double speed) async {
    _speeds.value = {..._speeds.value, id: speed};
    if (_state.value.id == id) await _handler?.player.setSpeed(speed);
  }

  ({String id, String url, String title, String? artist, String? artUrl, LinkSource? link})? _last;

  @override
  ValueListenable<PlaybackState> get state => _state;

  VoiceNoteHandler _ensure() {
    if (_handler case final existing?) return existing;
    final handler = _handler = VoiceNoteHandler.instance;
    handler.onStopped = () => _state.value = PlaybackState.idle;
    handler.onReplay = () async {
      if (_last case final l?) {
        await play(l.id, l.url, title: l.title, artist: l.artist, artUrl: l.artUrl, link: l.link);
      }
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
  Future<void> play(
    String id,
    String url, {
    required String title,
    String? artist,
    String? artUrl,
    LinkSource? link,
  }) async {
    final handler = _ensure();
    _last = (id: id, url: url, title: title, artist: artist, artUrl: artUrl, link: link);
    if (_state.value.id != id) {
      await handler.player.stop();
      _state.value = PlaybackState(id: id, title: title, artist: artist);
      handler.mediaItem.add(
        svc.MediaItem(id: id, title: title, artist: artist, artUri: artUrl == null ? null : Uri.tryParse(artUrl)),
      );
      // Its link, renewed first when it's about to expire, and once more when
      // it won't load: an expired link is refused.
      String? failed;
      for (var refused = false; ; refused = true) {
        final source = link == null ? url : await link(failed: failed);
        // Another note, or Stop, took over while its link came.
        if (_state.value.id != id) return;
        try {
          await handler.player.setUrl(source);
          break;
        } on ja.PlayerInterruptedException {
          // Another note, or Stop, took over while this one loaded.
          return;
        } catch (e) {
          if (link != null && !refused) {
            failed = source;
            continue;
          }
          // A note that won't load mustn't stay in the bar and the notification.
          debugPrint('Voice note $id failed to load: $e');
          await handler.stop();
          return;
        }
      }
    }
    await handler.player.setSpeed(_speeds.value[id] ?? 1);
    // Stop, or another note, took over while the speed was set.
    if (_state.value.id != id) return;
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
    final ink = ownBubble(context).ink;
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
          decoration: BoxDecoration(color: onAccent ? ink.withAlpha(0x2E) : colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: onAccent ? const [] : (pressed ? tokens.shadowPressed : tokens.shadowWell),
            borderRadius: radius,
            child: Icon(
              playing ? FLucideIcons.pause : FLucideIcons.play,
              size: 18,
              color: onAccent ? ink : colors.foreground,
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
    final bubble = ownBubble(context);
    final ink = mine ? bubble.ink : colors.foreground;
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
              color: mine ? bubble.fill : colors.card,
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
                          link: linkSource(context, attachment),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ExcludeSemantics(
                    child: LayoutBuilder(
                      builder: (context, box) => GestureDetector(
                        // Tap along the waveform to jump there.
                        onTapDown: duration == null
                            ? null
                            : (d) {
                                final f = (d.localPosition.dx / math.max(1, box.maxWidth)).clamp(0.0, 1.0);
                                playback.seek(attachment.id, duration * f);
                              },
                        child: Waveform(bars: bars, color: ink, progress: active ? progress : 0),
                      ),
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
                const SizedBox(width: 6),
                _SpeedButton(id: attachment.id, onAccent: mine),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A voice note's speed, "1×": a tap takes the next of the desktop's steps.
class _SpeedButton extends StatelessWidget {
  final String id;
  final bool onAccent;
  const _SpeedButton({required this.id, required this.onAccent});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final ink = ownBubble(context).ink;
    final playback = AudioPlayback.instance;
    return ValueListenableBuilder(
      valueListenable: playback.speeds,
      builder: (context, speeds, _) {
        final speed = speeds[id] ?? 1;
        final shown = '${speed.toString().replaceFirst(RegExp(r'\.0$'), '')}×';
        void next() => playback.setSpeed(id, AudioPlayback.nextSpeed(speed));
        return Semantics(
          container: true,
          button: true,
          label: 'Speed, $shown',
          excludeSemantics: true,
          onTap: next,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: next,
            // At least 40 by 40 to hit, the chip to see.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: onAccent ? ink.withAlpha(0x2E) : colors.secondary,
                    borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                  ),
                  child: Text(
                    shown,
                    style: DuvetType.caption.copyWith(
                      color: onAccent ? ink : colors.foreground,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
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
                      : playback.play(
                          attachment.id,
                          attachment.url,
                          title: attachment.displayName,
                          link: linkSource(context, attachment),
                        ),
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
/// screen. The poster is [poster] (an embed's picture) or else, for an
/// upload, the video's first frame, loaded paused.
class VideoTile extends StatefulWidget {
  final MessageAttachment attachment;
  final double width;
  final String? poster;

  /// An embed's video, from another host: nothing loads from there until
  /// someone plays it (#172), so it shows [poster] or the play mark alone.
  final bool embed;
  const VideoTile({required this.attachment, this.width = 248, this.poster, this.embed = false, super.key});

  /// Lets go of the players kept for tiles that scrolled away, on signing
  /// out: they hold the account's links. The tiles still there keep none.
  static void releaseParked() => _VideoTileState._release();

  @override
  State<VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<VideoTile> {
  // Each first frame is a paused player and a decoder of its own, so at most 3 are kept, shown or not; the rest wait
  // their turn, pulsing, and take the next slot that frees.
  // shortcut: the frame is the paused player itself, as video_player hands out no picture of it; upgrade when the API
  // sends a poster for uploaded videos.
  static const _maxFrames = 3;

  // Players loading a frame or showing one.
  static int _frames = 0;

  // The players of frames whose tiles scrolled away, oldest first, by file: scrolled back, a tile shows its frame at
  // once; a tile waiting for a slot takes the oldest one's.
  static final _parked = <String, VideoPlayerController>{};

  // Tiles waiting for a slot, in the order they showed.
  static final _waiting = <_VideoTileState>[];

  // How many times the parked ones were let go: a tile from before parks nothing.
  static int _releases = 0;
  int _since = 0;

  static void _release() {
    _releases++;
    for (final parked in _parked.values) {
      unawaited(parked.dispose());
    }
    _parked.clear();
  }

  VideoPlayerController? _frame;
  bool _counted = false;
  late LinkSource _link;

  // Only an upload's frame is loaded here: an embed's video is reached only once played (#172).
  bool get _grabs => !widget.embed && widget.poster == null && !widget.attachment.local;

  @override
  void initState() {
    super.initState();
    if (_grabs) _queue();
  }

  @override
  void didUpdateWidget(VideoTile old) {
    super.didUpdateWidget(old);
    // A video sent from here, uploaded now: its message keeps this tile.
    if (old.attachment.local && _grabs) _queue();
  }

  // Shows the frame kept for it, or waits for a slot to load it.
  void _queue() {
    _since = _releases;
    _link = linkSource(context, widget.attachment);
    if (_parked.remove(widget.attachment.id) case final parked?) {
      _frames++;
      _counted = true;
      _frame = parked;
      return;
    }
    _waiting.add(this);
    _next();
  }

  // Starts the tiles waiting while there's a slot, or a parked player to give up for one.
  static void _next() {
    while (_waiting.isNotEmpty) {
      if (_frames + _parked.length >= _maxFrames) {
        if (_parked.isEmpty) return;
        unawaited(_parked.remove(_parked.keys.first)!.dispose());
      }
      _waiting.removeAt(0)._start();
    }
  }

  void _start() {
    _frames++;
    _counted = true;
    final a = widget.attachment;
    // Its link renewed first when it's about to expire.
    if (a.linkDueAt(time.clock.now())) {
      _link().then((url) => _load(url, _link), onError: (Object _) => _fail());
    } else {
      _load(a.url, _link);
    }
  }

  // Loads the first frame from [url]; once more from a new link when it
  // won't, as an expired link is refused.
  void _load(String url, LinkSource link, {bool retry = true}) {
    if (!mounted) return;
    final frame = _frame = VideoPage.controllerFor(Uri.parse(url));
    frame.initialize().then(
      (_) {
        if (mounted) setState(() {});
      },
      onError: (Object _) async {
        if (!mounted || !identical(_frame, frame)) return;
        if (!retry || widget.attachment.linkExpires == null) {
          _fail();
          return;
        }
        final String next;
        try {
          next = await link(failed: url);
        } catch (_) {
          _fail();
          return;
        }
        if (!mounted || !identical(_frame, frame)) return;
        _frame = null;
        // Not awaited: a player that failed to start never finishes disposing.
        unawaited(frame.dispose());
        _load(next, link, retry: false);
      },
    );
  }

  // Its frame won't load: the play mark alone, and its slot to the next.
  void _fail() {
    if (!mounted) return;
    unawaited(_frame?.dispose());
    _frame = null;
    _counted = false;
    _frames--;
    _next();
    setState(() {});
  }

  @override
  void dispose() {
    _waiting.remove(this);
    if (_counted) {
      _frames--;
      final frame = _frame;
      if (frame != null && frame.value.isInitialized && _since == _releases) {
        unawaited(_parked.remove(widget.attachment.id)?.dispose());
        _parked[widget.attachment.id] = frame;
      } else {
        unawaited(frame?.dispose());
      }
      // Once this frame's other tiles have gone too: one going mustn't start.
      scheduleMicrotask(_next);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    // Sized like a picture: its own ratio, so a tall or wide video isn't cropped; a 248:168 box until its size is known.
    final ratio = (attachment.width ?? 0) <= 0 || (attachment.height ?? 0) <= 0
        ? 248 / 168
        : attachment.width! / attachment.height!;
    final height = math.min(widget.width / ratio, 320.0);
    final width = math.min(widget.width, height * ratio);
    final frame = _frame?.value;
    void open() => openVideo(context, attachment);
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
                Image(
                  image: cachedImage(
                    poster,
                    cacheWidth: math.max(1, (width * MediaQuery.devicePixelRatioOf(context)).round()),
                  ),
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  frameBuilder: (_, child, shown, sync) => shown == null && !sync ? const SkeletonBox() : child,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (frame != null && frame.isInitialized && !frame.size.isEmpty)
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.fromSize(size: frame.size, child: VideoPlayer(_frame!)),
                )
              // Its first frame on its way, or waiting its turn: the desktop's video-skeleton.
              else if ((_counted || _waiting.contains(this)) && !(frame?.isInitialized ?? false))
                const SkeletonBox(),
              const Center(child: PlayMark()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plays [attachment] full screen ([VideoPage]).
void openVideo(BuildContext context, MessageAttachment attachment) => Navigator.of(context, rootNavigator: true).push(
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

/// A video, full screen on near-black: play and pause, a scrub bar, the time;
/// swipe down or Close to leave.
class VideoPage extends StatefulWidget {
  final MessageAttachment attachment;
  const VideoPage({required this.attachment, super.key});

  /// Builds the controller; tests swap in their own.
  @visibleForTesting
  static VideoPlayerController Function(Uri url) controllerFor = VideoPlayerController.networkUrl;

  static final _playing = <Object>{};

  /// Whether a video is playing: iOS's sounds then leave the audio session to it (data/sounds.dart).
  static bool get playing => _playing.isNotEmpty;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  // Null until its link is there: a new one, when its own is about to expire.
  VideoPlayerController? _player;
  Object? _error;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    final a = widget.attachment;
    final link = linkSource(context, a);
    if (a.linkDueAt(time.clock.now())) {
      link().then((url) => _load(url, link));
    } else {
      _load(a.url, link);
    }
  }

  // Plays it from [url]; once more from a new link when it won't load, as an
  // expired link is refused.
  void _load(String url, LinkSource link, {bool retry = true}) {
    if (!mounted) return;
    final player = _player = VideoPage.controllerFor(Uri.parse(url))..addListener(_changed);
    player.initialize().then(
      (_) {
        if (mounted && identical(_player, player)) player.play();
      },
      onError: (Object e) async {
        if (!mounted || !identical(_player, player)) return;
        if (!retry || widget.attachment.linkExpires == null) {
          setState(() => _error = e);
          return;
        }
        final next = await link(failed: url);
        if (!mounted || !identical(_player, player)) return;
        player.removeListener(_changed);
        _player = null;
        await player.dispose();
        _load(next, link, retry: false);
      },
    );
  }

  void _changed() {
    if (_player?.value.isPlaying ?? false) {
      VideoPage._playing.add(this);
    } else {
      VideoPage._playing.remove(this);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    VideoPage._playing.remove(this);
    _player?.removeListener(_changed);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink = DuvetTokens.mediaInk;
    final controller = _player;
    final value = controller?.value ?? const VideoPlayerValue.uninitialized();
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
                        : value.isInitialized && controller != null
                        ? GestureDetector(
                            onTap: () => value.isPlaying ? controller.pause() : controller.play(),
                            child: AspectRatio(aspectRatio: value.aspectRatio, child: VideoPlayer(controller)),
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
              if (value.isInitialized && controller != null)
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
                        onTap: () => value.isPlaying ? controller.pause() : controller.play(),
                        child: GestureDetector(
                          onTap: () => value.isPlaying ? controller.pause() : controller.play(),
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
                          onSeek: (f) => controller.seekTo(duration * f),
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

  static int _recording = 0;
  bool _counted = false;

  /// Whether a take is going: iOS's sounds then leave the audio session to it (data/sounds.dart).
  static bool get recording => _recording > 0;

  void _count(bool on) {
    if (_counted == on) return;
    _counted = on;
    _recording += on ? 1 : -1;
  }

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    // Opus needs Android 10; before it, AAC.
    final opus = await _recorder.isEncoderSupported(rec.AudioEncoder.opus);
    _format = opus ? 'ogg' : 'm4a';
    final dir = await getTemporaryDirectory();
    final path = _path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.$_format';
    // From before it starts: starting is what takes the session.
    _count(true);
    try {
      await _recorder.start(
        rec.RecordConfig(encoder: opus ? rec.AudioEncoder.opus : rec.AudioEncoder.aacLc, numChannels: 1),
        path: path,
      );
    } catch (_) {
      _count(false);
      rethrow;
    }
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
    final String? path;
    try {
      path = await _recorder.stop() ?? _path;
    } finally {
      _count(false);
    }
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
    try {
      await _recorder.cancel();
    } finally {
      _count(false);
    }
    unawaited(_recorder.dispose());
  }
}
