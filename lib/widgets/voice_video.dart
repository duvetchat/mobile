import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/scope.dart';
import '../data/voice.dart';
import '../theme.dart';
import '../voice_room.dart';
import 'avatar.dart';
import 'glass.dart';
import 'rows.dart';

/// Why the camera and the screen are off limits where the user is.
String noVideoReason(VoiceController voice) =>
    'You can’t use video in this ${voice.target is RoomVoice ? 'room' : 'call'}';

typedef _Tile = ({String key, VoicePerson person, bool screen});

/// The people in voice, a tile each with their camera or their face, and a
/// tile per screen shared. Its layout follows the count: one large, two
/// stacked, a 2×2 grid to four, then two columns scrolling. A tap shows a
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
    // A focused tile that's gone (its person left, or stopped sharing) leaves the grid as it was.
    final focused = tiles.where((t) => t.key == _focused).firstOrNull;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: focused == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _focused = null);
      },
      child: AnimatedSwitcher(
        duration: reduce ? Duration.zero : DuvetTokens.panelIn,
        reverseDuration: reduce ? Duration.zero : DuvetTokens.panelOut,
        // The spring's tiny overshoot on the scale only: an opacity can't pass 1.
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: DuvetTokens.decelerate),
          child: ScaleTransition(
            scale: Tween(
              begin: 0.97,
              end: 1.0,
            ).animate(CurvedAnimation(parent: animation, curve: DuvetTokens.overshoot)),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(focused?.key),
          child: focused == null ? _grid(tiles) : _focus(tiles, focused),
        ),
      ),
    );
  }

  Widget _grid(List<_Tile> tiles) => LayoutBuilder(
    builder: (context, box) {
      final n = tiles.length;
      final columns = n <= 2 ? 1 : 2;
      final rows = (n / columns).ceil();
      final fill = (box.maxHeight - widget.padding.vertical - (rows - 1) * 12) / rows;
      final extent = n <= 4 ? math.max(156.0, fill) : 180.0;
      final eyes = eyesToward(widget.people, context.voice.levels.value, columns);
      return GridView.builder(
        padding: widget.padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: extent,
        ),
        itemCount: n,
        itemBuilder: (context, i) => _tile(tiles[i], eyes: eyes[tiles[i].person.id] ?? Offset.zero, size: extent),
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

  Widget _tile(_Tile t, {Offset eyes = Offset.zero, required double size}) {
    final focused = _focused == t.key;
    void toggle() => setState(() => _focused = focused ? null : t.key);
    return t.screen
        ? _screenTile(t.person, focused: focused, onTap: toggle, key: ValueKey(t.key))
        : _personTile(t.person, eyes: eyes, size: size, focused: focused, onTap: toggle, key: ValueKey(t.key));
  }

  Widget _personTile(
    VoicePerson p, {
    required Offset eyes,
    required double size,
    required bool focused,
    required VoidCallback onTap,
    Key? key,
  }) {
    final voice = context.voice;
    final level = voice.levels.value[p.id] ?? 0;
    final speaking = level > 0 && !p.muted;
    // Only this place's: the user's own capture, else the camera coming in.
    final camera = voice.camera;
    final video = !p.camera || !widget.here
        ? null
        : p.isMe && camera != null
        ? camera.preview(mirror: camera.facing == CameraFacing.front)
        : voice.remoteVideos.value
              .where((v) => v.userId == p.id && v.kind == VideoKind.camera)
              .firstOrNull
              ?.view(false);
    final faceSize = (size * 0.4).clamp(48.0, 120.0);
    final faces = VoicePrefsScope.maybeOf(context)?.facesInVoice ?? false;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return _TileFrame(
      key: key,
      label: [
        p.isMe ? '${p.name} (you)' : p.name,
        if (p.deafened) 'deafened' else if (p.muted) 'muted',
        if (p.camera) video == null ? 'camera on, video is off' : 'camera on',
        if (speaking) 'speaking',
      ].join(', '),
      name: p.name,
      marks: [
        if (p.deafened) FLucideIcons.headphoneOff else if (p.muted) FLucideIcons.micOff,
        if (p.camera && video == null) FLucideIcons.videoOff,
      ],
      speaking: speaking,
      bannerUrl: video == null ? p.bannerUrl : null,
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
                    builder: (context, open, _) =>
                        UserAvatar(name: p.name, url: p.avatarUrl, size: faceSize, mouthOpen: open, eyeOffset: eyes),
                  ),
          ),
    );
  }

  Widget _screenTile(VoicePerson p, {required bool focused, required VoidCallback onTap, Key? key}) {
    final voice = context.voice;
    final watching = _watching.contains(p.id);
    void watch(bool on) => setState(() => on ? _watching.add(p.id) : _watching.remove(p.id));
    final Widget content;
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
      content = Center(
        child: DuvetButton(
          label: 'Watch',
          icon: FLucideIcons.monitorUp,
          variant: ButtonVariant.primary,
          onPressed: () => watch(true),
        ),
      );
    } else {
      final screen = voice.remoteVideos.value.where((v) => v.userId == p.id && v.kind == VideoKind.screen).firstOrNull;
      content = Stack(
        fit: StackFit.expand,
        children: [
          screen?.view(false) ?? const Center(child: FCircularProgress(semanticsLabel: 'Loading the screen')),
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: DuvetButton(label: 'Stop watching', onPressed: () => watch(false)),
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
      focused: focused,
      onTap: onTap,
      buttonsInside: true,
      child: content,
    );
  }
}

/// A tile: `base-raised`, `radius-card`, `shadow-raised`, its content
/// clipped to it, a name on a pill of unblurred glass (a grid that scrolls
/// takes no blur), and the `accent-text` ring while its person speaks.
class _TileFrame extends StatelessWidget {
  final String label;
  final String name;

  /// Glyphs before the name: muted, deafened, video off.
  final List<IconData> marks;
  final bool speaking;
  final String? bannerUrl;
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
    this.buttonsInside = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: focused ? 'Show everyone' : 'Show large',
      onTap: onTap,
      excludeSemantics: !buttonsInside,
      explicitChildNodes: buttonsInside,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.pressOut,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.card,
            image: memberBanner(context, bannerUrl),
            borderRadius: radius,
            boxShadow: tokens.shadowRaised,
          ),
          // Over the video, not under it.
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: speaking ? tokens.accentText : Colors.transparent, width: 2),
          ),
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
                        color: tokens.glass,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                        border: Border.all(color: tokens.glassEdge),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final m in marks) ...[
                            Icon(m, size: 16, color: colors.foreground),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DuvetType.caption.copyWith(color: colors.foreground),
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
    );
  }
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
    action();
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // iOS can't share the screen yet: it needs ReplayKit.
              if (defaultTargetPlatform != TargetPlatform.iOS)
                _Disabled(
                  reason: voice.canVideo ? null : noVideoReason(voice),
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
              if (voice.cameraOn)
                GlassRow(
                  icon: FLucideIcons.switchCamera,
                  label: 'Flip camera',
                  onPressed: () => _then(voice.switchCamera),
                ),
              if (voice.canVideo)
                FutureBuilder(
                  future: _cameras,
                  builder: (context, cameras) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // One camera is nothing to pick from.
                      if ((cameras.data?.length ?? 0) > 1)
                        for (final c in cameras.data!)
                          GlassRow(
                            icon: FLucideIcons.camera,
                            label: c.label.isEmpty ? _facing(c.facing) : c.label,
                            detail: _facing(c.facing),
                            onPressed: () => _then(() => voice.selectCamera(c.id)),
                          ),
                    ],
                  ),
                ),
              Semantics(
                container: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => voice.setIncomingVideo(!voice.incomingVideo),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
      label: child.label,
      hint: reason,
      child: ExcludeSemantics(
        child: IgnorePointer(child: Opacity(opacity: 0.5, child: child)),
      ),
    );
  }
}
