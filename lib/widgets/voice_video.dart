import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/scope.dart';
import '../data/voice.dart';
import '../theme.dart';
import 'avatar.dart';
import 'depth.dart';
import 'glass.dart';
import 'rows.dart';

/// Why the camera and the screen are off limits where the user is.
String noVideoReason(VoiceController voice) =>
    'You can’t use video in this ${voice.target is RoomVoice ? 'room' : 'call'}';

/// Someone in voice, as a tile shows them.
class VoicePerson {
  final String id;
  final String name;
  final String? avatarUrl;

  /// Their banner, faintly behind their tile: see [memberBanner].
  final String? bannerUrl;
  final bool muted;
  final bool deafened;
  final bool camera;
  final bool screenSharing;
  final bool isMe;
  const VoicePerson({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bannerUrl,
    this.muted = false,
    this.deafened = false,
    this.camera = false,
    this.screenSharing = false,
    this.isMe = false,
  });
}

/// The faces in a grid of [columns] look at whoever is speaking, as on the
/// desktop: each one's eyes turned toward the speaker's tile, and straight
/// ahead in silence.
Map<String, Offset> eyesToward(List<VoicePerson> people, Map<String, double> levels, int columns) {
  final speaker = people.indexWhere((p) => (levels[p.id] ?? 0) > 0);
  if (speaker < 0) return const {};
  final (sr, sc) = (speaker ~/ columns, speaker % columns);
  return {
    for (final (i, p) in people.indexed)
      if (i != speaker)
        p.id: () {
          final (dx, dy) = ((sc - i % columns).toDouble(), (sr - i ~/ columns).toDouble());
          final length = math.sqrt(dx * dx + dy * dy);
          return Offset(dx / length, dy / length) * 0.8;
        }(),
  };
}

IconData routeIcon(AudioRouteKind? kind) => switch (kind) {
  AudioRouteKind.bluetooth => FLucideIcons.bluetooth,
  AudioRouteKind.wired => FLucideIcons.headphones,
  AudioRouteKind.earpiece => FLucideIcons.ear,
  AudioRouteKind.speaker || null => FLucideIcons.volume2,
};

String routeName(AudioRoute route) => switch (route.kind) {
  AudioRouteKind.speaker => 'Speaker',
  AudioRouteKind.earpiece => 'Phone',
  AudioRouteKind.wired => 'Headphones',
  AudioRouteKind.bluetooth => route.label.isEmpty ? 'Bluetooth' : route.label,
};

/// Where the sound plays: switches between the two outputs there are, or,
/// with a headset around, opens the list of outputs under [anchor].
Future<void> pickAudioRoute(BuildContext anchor, VoiceController voice) async {
  final routes = voice.routes.value;
  final available = routes.available;
  final others = available.where((r) => r != routes.current).toList();
  if (available.length == 2 && others.length == 1) {
    await voice.selectRoute(others.single);
    return;
  }
  final picked = await showGlassMenu<AudioRoute>(
    anchor,
    label: 'Audio output',
    items: [for (final r in available) GlassMenuItem(icon: routeIcon(r.kind), label: routeName(r), value: r)],
  );
  if (picked != null) await voice.selectRoute(picked);
}

typedef _Tile = ({String key, VoicePerson person, bool screen});

/// The people in voice, a tile each with their camera or their face, and a
/// tile per screen shared. Its layout follows the count: one large, up to
/// three stacked, a 2×2 grid to four, then two columns scrolling. A tap shows a
/// tile large over a strip of the others; another tap, or back, returns.
///
/// [here] says the user's voice is in this room or call: only then are the
/// videos coming in, and their own camera and screen, this place's.
class VoiceStage extends StatefulWidget {
  final List<VoicePerson> people;
  final bool here;
  final EdgeInsets padding;
  const VoiceStage({required this.people, required this.here, required this.padding, super.key});

  @override
  State<VoiceStage> createState() => _VoiceStageState();
}

class _VoiceStageState extends State<VoiceStage> {
  String? _focused;

  // The sharers whose screens the user chose to watch: only this screen's,
  // never kept.
  final _watching = <String>{};

  // A global key per tile's video, by tile key.
  final _videos = <String, GlobalKey>{};

  @override
  Widget build(BuildContext context) {
    final people = widget.people;
    // People first, so a person's tile index is their place in the grid, for the eyes.
    final tiles = <_Tile>[
      for (final p in people) (key: 'person:${p.id}', person: p, screen: false),
      for (final p in people)
        if (p.screenSharing) (key: 'screen:${p.id}', person: p, screen: true),
    ];
    _watching.retainWhere((id) => people.any((p) => p.id == id && p.screenSharing));
    _videos.removeWhere((key, _) => tiles.every((t) => t.key != key));
    // A focused tile that's gone (its person left, or stopped sharing) is forgotten: back, it shows in the grid.
    final focused = tiles.where((t) => t.key == _focused).firstOrNull;
    if (focused == null) _focused = null;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: focused == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _focused = null);
      },
      // The new layout comes in alone, not crossfaded with the old: a video
      // can be in one place only, and moves into it by its global key.
      child: TweenAnimationBuilder<double>(
        key: ValueKey(focused?.key),
        tween: Tween(begin: 0, end: 1),
        duration: reduce ? Duration.zero : DuvetTokens.panelIn,
        // The spring's tiny overshoot on the scale only: an opacity can't pass 1.
        builder: (context, t, child) => Opacity(
          opacity: DuvetTokens.decelerate.transform(t),
          child: Transform.scale(scale: 0.97 + 0.03 * DuvetTokens.overshoot.transform(t), child: child),
        ),
        child: focused == null ? _grid(tiles) : _focus(tiles, focused),
      ),
    );
  }

  // A tile's video keeps its widget, and so its renderer, between the grid
  // and the focus: a new one would flash black while it starts.
  Widget? _keep(String tile, Widget? video) =>
      video == null ? null : KeyedSubtree(key: _videos.putIfAbsent(tile, GlobalKey.new), child: video);

  Widget _grid(List<_Tile> tiles) => LayoutBuilder(
    builder: (context, box) {
      final n = tiles.length;
      // Three stacked, not two over one beside a hole.
      final columns = n <= 3 ? 1 : 2;
      final rows = (n / columns).ceil();
      final fill = (box.maxHeight - widget.padding.vertical - (rows - 1) * 12) / rows;
      final extent = n <= 4 ? math.max(156.0, fill) : 180.0;
      return GridView.builder(
        padding: widget.padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: extent,
        ),
        itemCount: n,
        // A tile that moves (someone before it left) keeps its video view.
        findChildIndexCallback: (key) {
          final i = tiles.indexWhere((t) => ValueKey(t.key) == key);
          return i < 0 ? null : i;
        },
        itemBuilder: (context, i) => _tile(tiles[i], columns: columns, size: extent),
      );
    },
  );

  Widget _focus(List<_Tile> tiles, _Tile focused) {
    final others = tiles.where((t) => t != focused).toList();
    return Padding(
      padding: widget.padding,
      child: Column(
        children: [
          Expanded(child: _tile(focused, size: 300)),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: others.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => SizedBox(width: 160, child: _tile(others[i], size: 120)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// [columns] is the grid's, for the eyes; null out of the grid, where they look ahead.
  Widget _tile(_Tile t, {int? columns, required double size}) {
    final focused = _focused == t.key;
    void toggle() => setState(() => _focused = focused ? null : t.key);
    return t.screen
        ? _screenTile(t.person, focused: focused, onTap: toggle, key: ValueKey(t.key))
        : _personTile(t.person, columns: columns, size: size, focused: focused, onTap: toggle, key: ValueKey(t.key));
  }

  Widget _personTile(
    VoicePerson p, {
    required int? columns,
    required double size,
    required bool focused,
    required VoidCallback onTap,
    Key? key,
  }) {
    final voice = context.voice;
    // Only this place's: the user's own capture, else the camera coming in.
    final camera = voice.camera;
    final video = _keep(
      'person:${p.id}',
      !p.camera || !widget.here
          ? null
          : p.isMe && camera != null
          ? camera.preview(mirror: camera.facing == CameraFacing.front)
          : voice.remoteVideos.value
                .where((v) => v.userId == p.id && v.kind == VideoKind.camera)
                .firstOrNull
                ?.view(false),
    );
    final faceSize = (size * 0.4).clamp(48.0, 120.0);
    final faces = VoicePrefsScope.maybeOf(context)?.facesInVoice ?? false;
    final reduce = MediaQuery.disableAnimationsOf(context);
    // The levels tick about five times a second: only the frame and the face
    // follow them, the same video widget passing through untouched.
    return ValueListenableBuilder(
      key: key,
      valueListenable: voice.levels,
      child: video,
      builder: (context, levels, video) {
        final level = levels[p.id] ?? 0;
        final speaking = level > 0 && !p.muted;
        final eyes = columns == null ? Offset.zero : eyesToward(widget.people, levels, columns)[p.id] ?? Offset.zero;
        return _TileFrame(
          label: [
            p.isMe ? '${p.name} (you)' : p.name,
            if (p.deafened) 'deafened' else if (p.muted) 'muted',
            // Out of this place's voice no video comes in: the camera is only on, not off here.
            if (p.camera) widget.here && video == null ? 'camera on, video is off' : 'camera on',
            if (speaking) 'speaking',
          ].join(', '),
          name: p.name,
          marks: [
            if (p.deafened) FLucideIcons.headphoneOff else if (p.muted) FLucideIcons.micOff,
            if (p.camera && video == null) widget.here ? FLucideIcons.videoOff : FLucideIcons.video,
          ],
          speaking: speaking,
          bannerUrl: video == null ? p.bannerUrl : null,
          media: video != null,
          focused: focused,
          onTap: onTap,
          child:
              video ??
              Center(
                child: faces
                    ? VoiceFace(name: p.name, level: speaking ? level : 0, eyeOffset: eyes, size: faceSize)
                    : TweenAnimationBuilder<double>(
                        tween: Tween(end: speaking ? level : 0),
                        duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
                        builder: (context, open, _) => UserAvatar(
                          name: p.name,
                          url: p.avatarUrl,
                          size: faceSize,
                          mouthOpen: open,
                          eyeOffset: eyes,
                        ),
                      ),
              ),
        );
      },
    );
  }

  Widget _screenTile(VoicePerson p, {required bool focused, required VoidCallback onTap, Key? key}) {
    final voice = context.voice;
    final watching = _watching.contains(p.id);
    void watch(bool on) => setState(() => on ? _watching.add(p.id) : _watching.remove(p.id));
    final Widget content;
    var media = false;
    if (!widget.here) {
      content = const _Note(icon: FLucideIcons.monitorUp, text: 'Sharing their screen');
    } else if (p.isMe) {
      // Not its preview: the screen would show itself, smaller and smaller.
      content = const _Note(icon: FLucideIcons.monitorUp, text: 'You’re sharing your screen');
    } else if (!voice.incomingVideo) {
      content = _Note(
        icon: FLucideIcons.videoOff,
        text: 'Video is off',
        action: DuvetButton(label: 'Turn on video', onPressed: () => voice.setIncomingVideo(true)),
      );
    } else if (!watching) {
      // Secondary: the speaking ring is the screen's one accent.
      content = Center(
        child: DuvetButton(label: 'Watch', icon: FLucideIcons.monitorUp, onPressed: () => watch(true)),
      );
    } else {
      final screen = voice.remoteVideos.value.where((v) => v.userId == p.id && v.kind == VideoKind.screen).firstOrNull;
      media = screen != null;
      content = Stack(
        fit: StackFit.expand,
        children: [
          _keep('screen:${p.id}', screen?.view(false)) ?? _ScreenWait(name: p.name),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _MediaChip(label: 'Stop watching', onTap: () => watch(false)),
            ),
          ),
        ],
      );
    }
    final name = p.isMe ? 'Your screen' : '${p.name}’s screen';
    return _TileFrame(
      key: key,
      label: name,
      name: name,
      marks: const [FLucideIcons.monitorUp],
      media: media,
      focused: focused,
      onTap: onTap,
      buttonsInside: true,
      child: content,
    );
  }
}

/// A tile: `base-raised`, `radius-card`, `shadow-raised`, its content
/// clipped to it, its name on a pill, and the `accent-text` ring while its
/// person speaks. It presses like a card. The pill is solid, not glass: a
/// grid that scrolls takes no blur.
class _TileFrame extends StatelessWidget {
  final String label;
  final String name;

  /// Glyphs before the name: muted, deafened, video off.
  final List<IconData> marks;
  final bool speaking;
  final String? bannerUrl;

  /// Whether a video fills it: the name then sits on the media scrim, light
  /// in both themes, since a camera is as likely dark as light.
  final bool media;
  final bool focused;
  final VoidCallback onTap;

  /// Whether screen readers reach the buttons in it (Watch).
  final bool buttonsInside;
  final Widget child;
  const _TileFrame({
    required this.label,
    required this.name,
    required this.marks,
    required this.focused,
    required this.onTap,
    required this.child,
    this.speaking = false,
    this.bannerUrl,
    this.media = false,
    this.buttonsInside = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final ink = media ? DuvetTokens.mediaInk : colors.foreground;
    final reduce = MediaQuery.disableAnimationsOf(context);
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: focused ? 'Show everyone' : 'Show large',
      onTap: onTap,
      excludeSemantics: !buttonsInside,
      explicitChildNodes: buttonsInside,
      child: Pressable(
        scale: 0.98,
        onTap: onTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: reduce ? Duration.zero : DuvetTokens.pressOut,
          curve: DuvetTokens.decelerate,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.card,
            image: memberBanner(context, bannerUrl),
            borderRadius: radius,
            boxShadow: pressed ? null : tokens.shadowRaised,
          ),
          // Over the video, not under it.
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: speaking ? tokens.accentText : Colors.transparent, width: 2),
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : const [],
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child,
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ExcludeSemantics(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: media ? DuvetTokens.mediaScrim : colors.secondary,
                          borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                          border: media ? Border.all(color: DuvetTokens.mediaScrimEdge) : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final m in marks) ...[Icon(m, size: 16, color: ink), const SizedBox(width: 4)],
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.caption.copyWith(color: ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small button over a video, as the name pill is: light ink on the media
/// scrim, so it reads on a dark or a light picture and never crowds the tile.
class _MediaChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MediaChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Pressable(
      onTap: onTap,
      builder: (context, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DuvetTokens.mediaScrim,
          borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
          border: Border.all(color: DuvetTokens.mediaScrimEdge),
        ),
        child: Text(label, style: DuvetType.caption.copyWith(color: DuvetTokens.mediaInk)),
      ),
    ),
  );
}

/// A quiet line in a tile, in `ink-secondary`, with an optional button under it.
class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Note({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: colors.mutedForeground),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
            if (action case final action?) ...[const SizedBox(height: 12), action],
          ],
        ),
      ),
    );
  }
}

/// A watched screen whose video hasn't come: a spinner, then after ten
/// seconds, or at once with animations off, a calm note, never an endless spin.
class _ScreenWait extends StatefulWidget {
  final String name;
  const _ScreenWait({required this.name});

  @override
  State<_ScreenWait> createState() => _ScreenWaitState();
}

class _ScreenWaitState extends State<_ScreenWait> {
  late final Timer _timer;
  bool _late = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 10), () => setState(() => _late = true));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _late || MediaQuery.disableAnimationsOf(context)
      ? _Note(icon: FLucideIcons.monitorUp, text: 'Waiting for ${widget.name}’s screen…')
      : const Center(child: FCircularProgress(semanticsLabel: 'Loading the screen'));
}

/// The voice options past the bar's: share the screen, where the sound
/// plays, flip or pick the camera, and whether others' video comes in.
Future<void> showVoiceMore(BuildContext context, VoiceController voice) => showGlassDialogSheet<void>(
  context,
  label: 'More voice options',
  builder: (_) => _VoiceMore(voice: voice),
);

class _VoiceMore extends StatefulWidget {
  final VoiceController voice;
  const _VoiceMore({required this.voice});

  @override
  State<_VoiceMore> createState() => _VoiceMoreState();
}

class _VoiceMoreState extends State<_VoiceMore> {
  late final _cameras = widget.voice.cameras();

  // Closes the sheet, then does [action]: a system prompt (the screen's
  // consent) never comes up over it.
  void _then(Future<void> Function() action) {
    Navigator.of(context).pop();
    unawaited(action());
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final colors = context.theme.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([voice, voice.routes]),
      builder: (context, _) {
        final routes = voice.routes.value;
        final current = routes.current;
        final reason = voice.canVideo ? null : noVideoReason(voice);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // iOS can't share the screen yet: it needs ReplayKit.
              if (defaultTargetPlatform != TargetPlatform.iOS)
                _Disabled(
                  reason: reason,
                  child: GlassRow(
                    icon: voice.screenSharing ? FLucideIcons.screenShareOff : FLucideIcons.screenShare,
                    label: voice.screenSharing ? 'Stop sharing' : 'Share screen',
                    onPressed: () => _then(voice.screenSharing ? voice.stopScreenShare : voice.startScreenShare),
                  ),
                ),
              if (routes.available.length > 1)
                Builder(
                  builder: (anchor) => GlassRow(
                    icon: routeIcon(current?.kind),
                    label: 'Sound plays on',
                    detail: current == null ? 'Speaker' : routeName(current),
                    onPressed: () => pickAudioRoute(anchor, voice),
                  ),
                ),
              // Without Video, shown out of reach with why, as Share screen is.
              if (voice.cameraOn || !voice.canVideo)
                _Disabled(
                  reason: reason,
                  child: GlassRow(
                    icon: FLucideIcons.switchCamera,
                    label: 'Flip camera',
                    onPressed: () => _then(voice.switchCamera),
                  ),
                ),
              FutureBuilder(
                future: _cameras,
                builder: (context, cameras) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // One camera is nothing to pick from.
                    if ((cameras.data?.length ?? 0) > 1)
                      for (final c in cameras.data!)
                        _Disabled(
                          reason: reason,
                          child: GlassRow(
                            icon: FLucideIcons.camera,
                            label: c.label.isEmpty ? _facing(c.facing) : c.label,
                            detail: _facing(c.facing),
                            selected: c.id == voice.selectedCameraId,
                            trailing: c.id == voice.selectedCameraId
                                ? Icon(FLucideIcons.check, size: 24, color: context.duvet.accentText)
                                : null,
                            onPressed: () => _then(() => voice.selectCamera(c.id)),
                          ),
                        ),
                  ],
                ),
              ),
              // One node: the switch's state read with its label, once.
              Semantics(
                container: true,
                label: 'Incoming video',
                hint: 'See the others’ cameras and screens',
                toggled: voice.incomingVideo,
                onTap: () => voice.setIncomingVideo(!voice.incomingVideo),
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => voice.setIncomingVideo(!voice.incomingVideo),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Icon(FLucideIcons.video, size: 24, color: colors.foreground),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Incoming video', style: DuvetType.label.copyWith(color: colors.foreground)),
                              Text(
                                'See the others’ cameras and screens',
                                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        DuvetSwitch(
                          label: 'Incoming video',
                          value: voice.incomingVideo,
                          onChanged: voice.setIncomingVideo,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _facing(CameraFacing facing) => switch (facing) {
    CameraFacing.front => 'Front',
    CameraFacing.back => 'Back',
    CameraFacing.external => 'External',
  };
}

/// [child] dimmed and out of reach while there's a [reason], which screen
/// readers hear.
class _Disabled extends StatelessWidget {
  final String? reason;
  final GlassRow child;
  const _Disabled({required this.reason, required this.child});

  @override
  Widget build(BuildContext context) {
    final reason = this.reason;
    if (reason == null) return child;
    return Semantics(
      container: true,
      button: true,
      enabled: false,
      label: child.detail == null ? child.label : '${child.label}, ${child.detail}',
      hint: reason,
      child: ExcludeSemantics(
        child: IgnorePointer(child: Opacity(opacity: 0.5, child: child)),
      ),
    );
  }
}
