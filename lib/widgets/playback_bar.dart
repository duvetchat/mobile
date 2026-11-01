import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'chrome.dart';
import 'media.dart';

/// Over the tab bar while something plays, or is paused and not dismissed:
/// what it is, play or pause, a thin progress line along its top, and
/// dismiss, which stops it. It follows [playback]'s state, so any source
/// behind [AudioPlayback] (a voice note today) shows here.
class MediaPlaybackBar extends StatelessWidget {
  final AudioPlayback playback;
  const MediaPlaybackBar({required this.playback, super.key});

  static const height = DuvetTokens.sizeTabBar;

  /// Whether there's something for it to show.
  static bool shows(PlaybackState state) => state.id != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ValueListenableBuilder(
      valueListenable: playback.state,
      builder: (context, state, _) {
        final duration = state.duration;
        final progress = duration == null || duration == Duration.zero
            ? 0.0
            : (state.position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final time = duration == null ? null : '${clock(state.position)} / ${clock(duration)}';
        final subtitle = [?state.artist, ?time].join(' · ');
        return GlassChrome(
          top: false,
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  child: ExcludeSemantics(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress,
                      child: SizedBox(height: 2, child: ColoredBox(color: colors.primary)),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Semantics(
                        container: true,
                        label: [state.title, ?state.artist, ?time].join(', '),
                        excludeSemantics: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                            ),
                            if (subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.caption.copyWith(
                                  color: colors.mutedForeground,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconAction(
                      icon: state.playing ? FLucideIcons.pause : FLucideIcons.play,
                      label: state.playing ? 'Pause' : 'Play',
                      onPressed: state.playing ? playback.pause : playback.resume,
                    ),
                    IconAction(icon: FLucideIcons.x, label: 'Stop and close', onPressed: playback.stop),
                    const SizedBox(width: 8),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
