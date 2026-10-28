import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// Opens a voice room's screen: who's in, and Join voice, or the controls
/// once the user is in.
Future<void> openVoiceRoom(BuildContext context, Room room) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    builder: (_) => VoiceRoomScreen(spaceId: room.spaceId, roomId: room.id),
  ),
);

/// Someone in voice, as a tile shows them.
class VoicePerson {
  final String id;
  final String name;
  final String? avatarUrl;

  /// Their banner, faintly behind their tile: see [memberBanner].
  final String? bannerUrl;
  final bool muted;
  final bool deafened;
  final bool isMe;
  const VoicePerson({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bannerUrl,
    this.muted = false,
    this.deafened = false,
    this.isMe = false,
  });
}

/// Who's in [roomId]'s voice (a room, or a call's conversation), named from
/// what the app knows; the user too while their voice is there, with their
/// own mute as it is here, before the gateway echoes it.
List<VoicePerson> voicePeople(ChatRepository repository, VoiceController voice, String roomId) {
  final me = repository.profile.value;
  final known = {for (final m in repository.people) m.userId: m};
  final here = voice.target?.id == roomId;
  VoicePerson mine() => VoicePerson(
    id: me!.id,
    name: me.displayName,
    avatarUrl: me.avatarUrl,
    bannerUrl: me.bannerUrl,
    muted: voice.muted,
    deafened: voice.deafened,
    isMe: true,
  );
  final people = [
    for (final p in voice.participants(roomId))
      if (p.userId == me?.id && here)
        mine()
      else
        VoicePerson(
          id: p.userId,
          name: known[p.userId]?.displayName ?? repository.nameOf(p.userId) ?? 'Someone',
          avatarUrl: known[p.userId]?.avatarUrl,
          bannerUrl: known[p.userId]?.bannerUrl,
          muted: p.muted,
          deafened: p.deafened,
          isMe: p.userId == me?.id,
        ),
  ];
  if (here && me != null && !people.any((p) => p.id == me.id)) people.add(mine());
  return people;
}

/// The faces in a grid of [columns] under the spotlight look up at it while
/// its speaker speaks, as on the desktop: each one's eyes turned toward the
/// spotlight's middle, and straight ahead in silence.
Map<String, Offset> eyesToward(List<VoicePerson> grid, int columns, {required bool speaking}) {
  if (!speaking) return const {};
  // The spotlight spans the grid's width, about two rows tall, above its first row.
  final (sr, sc) = (-1.5, (columns - 1) / 2);
  return {
    for (final (i, p) in grid.indexed)
      p.id: () {
        final (dx, dy) = (sc - i % columns, sr - i ~/ columns);
        final length = math.sqrt(dx * dx + dy * dy);
        return Offset(dx / length, dy / length) * 0.8;
      }(),
  };
}

/// A person in voice, on a cushion: their face, its mouth moving with their
/// voice, their name, and whether they're muted or deafened. Speaking rings
/// the tile in the mascot's ice, what's alive, and it glows.
class VoiceTile extends StatelessWidget {
  final VoicePerson person;

  /// How open the mouth is (0–1).
  final double level;
  final Offset eyes;

  /// The face's size: large in the spotlight, smaller in the grid.
  final double faceSize;

  /// In the spotlight: "speaking" under the name while they speak.
  final bool spotlight;
  const VoiceTile({
    required this.person,
    this.level = 0,
    this.eyes = Offset.zero,
    this.faceSize = 56,
    this.spotlight = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final speaking = level > 0 && !person.muted;
    final state = person.deafened
        ? FLucideIcons.headphoneOff
        : person.muted
        ? FLucideIcons.micOff
        : null;
    final label = [
      person.isMe ? '${person.name} (you)' : person.name,
      if (person.deafened) 'deafened' else if (person.muted) 'muted',
      if (speaking) 'speaking',
    ].join(', ');
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: colors.card,
          image: memberBanner(context, person.bannerUrl),
          borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
          boxShadow: speaking
              ? [BoxShadow(color: tokens.alive.withValues(alpha: 0.35), blurRadius: 18)]
              : tokens.shadowRaised,
          border: Border.all(color: speaking ? tokens.alive : Colors.transparent, width: 2.5),
        ),
        child: InsetShadow(
          shadows: tokens.cushion,
          borderRadius: BorderRadius.circular(DuvetTokens.radiusCard - 2.5),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: spotlight ? 24 : 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: speaking ? level : 0),
                  duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
                  builder: (context, open, _) => UserAvatar(
                    name: person.name,
                    url: person.avatarUrl,
                    size: faceSize,
                    mouthOpen: open,
                    eyeOffset: eyes,
                  ),
                ),
                SizedBox(height: spotlight ? 14 : 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (state != null) ...[
                      Icon(state, size: 16, color: colors.mutedForeground),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (spotlight ? DuvetType.navTitle : DuvetType.rowTitle).copyWith(color: colors.foreground),
                      ),
                    ),
                  ],
                ),
                if (spotlight && speaking) ...[
                  const SizedBox(height: 4),
                  Text('speaking', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The people in voice, scrolling under the bars: whoever is speaking in
/// the spotlight, large, and everyone else three to a row under them.
///
/// The spotlight goes to the loudest speaker, and stays with them while
/// they speak, so two voices at once don't trade it back and forth; in a
/// silence it stays with the last to speak, and before anyone has, it's
/// the first in.
class VoiceGrid extends StatefulWidget {
  final List<VoicePerson> people;
  final Map<String, double> levels;
  final EdgeInsets padding;
  const VoiceGrid({required this.people, required this.levels, required this.padding, super.key});

  static const columns = 3;

  @override
  State<VoiceGrid> createState() => _VoiceGridState();
}

class _VoiceGridState extends State<VoiceGrid> {
  String? _spotlight;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(VoiceGrid old) {
    super.didUpdateWidget(old);
    _follow();
  }

  bool _speaking(VoicePerson p) => (widget.levels[p.id] ?? 0) > 0 && !p.muted;

  void _follow() {
    final people = widget.people;
    final current = people.where((p) => p.id == _spotlight).firstOrNull;
    if (current != null && _speaking(current)) return;
    VoicePerson? loudest;
    for (final p in people.where(_speaking)) {
      if (loudest == null || widget.levels[p.id]! > widget.levels[loudest.id]!) loudest = p;
    }
    if (loudest != null) {
      _spotlight = loudest.id;
    } else if (current == null) {
      _spotlight = people.firstOrNull?.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final levels = widget.levels;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final lead = widget.people.where((p) => p.id == _spotlight).firstOrNull;
    final grid = [
      for (final p in widget.people)
        if (p.id != lead?.id) p,
    ];
    final eyes = eyesToward(grid, VoiceGrid.columns, speaking: lead != null && _speaking(lead));
    // A face, the space under it and the name, whatever the text size, in
    // the tile's padding and its speaking ring.
    final extent =
        56 + 8 + 12 * 2 + 2.5 * 2 + MediaQuery.textScalerOf(context).scale(DuvetType.rowTitle.fontSize! * 1.4);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: widget.padding,
          sliver: SliverMainAxisGroup(
            slivers: [
              if (lead != null)
                SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
                    child: VoiceTile(
                      key: ValueKey(lead.id),
                      person: lead,
                      level: levels[lead.id] ?? 0,
                      faceSize: 110,
                      spotlight: true,
                    ),
                  ),
                ),
              if (lead != null && grid.isNotEmpty) const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: VoiceGrid.columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: extent,
                ),
                itemCount: grid.length,
                itemBuilder: (context, i) {
                  final p = grid[i];
                  return VoiceTile(
                    key: ValueKey(p.id),
                    person: p,
                    level: levels[p.id] ?? 0,
                    eyes: eyes[p.id] ?? Offset.zero,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The connection's state, for the top bar's banner; none once connected.
Widget? voiceLinkBanner(VoiceLink? link) => switch (link) {
  VoiceLink.starting ||
  VoiceLink.connecting => const ConnectionBanner(text: 'Connecting…', icon: FLucideIcons.audioLines),
  VoiceLink.waiting => const ConnectionBanner(text: 'Waiting for Duvet…', detail: 'you’ll join when it’s back'),
  VoiceLink.reconnecting => const ConnectionBanner(text: 'Reconnecting…'),
  VoiceLink.connected || null => null,
};

/// A voice control: a 56pt cushion, a rounded square (circles are for
/// people), over its caption. On, it's sunk into the slate; the destructive
/// one is filled `destructive`.
class VoiceButton extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Read by screen readers in place of [label], e.g. "Hang up the call".
  final String? semanticLabel;

  /// A switch, on or off; null for a plain button.
  final bool? on;
  final bool destructive;
  final VoidCallback? onPressed;
  const VoiceButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.on,
    this.destructive = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final active = on ?? false;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    final fill = destructive
        ? colors.destructive
        : active
        ? tokens.chosen
        : colors.card;
    final ink = destructive
        ? colors.destructiveForeground
        : active
        ? tokens.chosenText
        : colors.foreground;
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: onPressed != null,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Pressable(
          onTap: onPressed,
          builder: (context, pressed) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: radius,
                  boxShadow: pressed || active ? null : tokens.shadowControl,
                ),
                child: InsetShadow(
                  // On, it stays sunk, as a pressed cushion does.
                  shadows: pressed || active
                      ? tokens.shadowPressed
                      : destructive
                      ? tokens.cushionAccent
                      : tokens.cushion,
                  borderRadius: radius,
                  child: Center(child: Icon(icon, size: 24, color: ink)),
                ),
              ),
              const SizedBox(height: 6),
              Text(label, style: DuvetType.tabLabel.copyWith(color: colors.mutedForeground)),
            ],
          ),
        ),
      ),
    );
  }
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

/// Where the sound plays: tapping switches between the loudspeaker and the
/// earpiece, or, with a headset around, opens the list of outputs.
class AudioRouteButton extends StatelessWidget {
  final VoiceController voice;
  const AudioRouteButton({required this.voice, super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: voice.routes,
    builder: (context, routes, _) {
      final current = routes.current;
      final name = current == null ? 'Speaker' : routeName(current);
      return Builder(
        builder: (anchor) => VoiceButton(
          icon: routeIcon(current?.kind),
          label: current?.kind == AudioRouteKind.bluetooth ? 'Bluetooth' : name,
          semanticLabel: 'Sound plays on: $name. Change',
          onPressed: routes.available.length < 2 ? null : () => _pick(anchor, routes),
        ),
      );
    },
  );

  Future<void> _pick(BuildContext anchor, AudioRoutes routes) async {
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
}

/// The controls while in voice, docked on a cushion floating over the
/// screen's bottom, as the tab bar does: mute, deafen, where the sound
/// plays, and leave.
class VoiceControls extends StatelessWidget {
  final VoiceController voice;
  final String leaveLabel;
  final String leaveSemanticLabel;
  final VoidCallback onLeave;
  const VoiceControls({
    required this.voice,
    required this.onLeave,
    this.leaveLabel = 'Leave',
    this.leaveSemanticLabel = 'Leave voice',
    super.key,
  });

  @override
  Widget build(BuildContext context) => VoiceDock(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        VoiceButton(
          icon: voice.muted ? FLucideIcons.micOff : FLucideIcons.mic,
          label: voice.muted ? 'Unmute' : 'Mute',
          semanticLabel: 'Mute',
          on: voice.muted,
          onPressed: voice.toggleMute,
        ),
        VoiceButton(
          icon: voice.deafened ? FLucideIcons.headphoneOff : FLucideIcons.headphones,
          label: voice.deafened ? 'Undeafen' : 'Deafen',
          semanticLabel: 'Deafen',
          on: voice.deafened,
          onPressed: voice.toggleDeafen,
        ),
        AudioRouteButton(voice: voice),
        VoiceButton(
          icon: FLucideIcons.phoneOff,
          label: leaveLabel,
          semanticLabel: leaveSemanticLabel,
          destructive: true,
          onPressed: onLeave,
        ),
      ],
    ),
  );
}

/// A raised cushion floating over the screen's bottom, inset from its edges
/// and above the safe area as the tab bar is: [VoiceControls]' dock.
class VoiceDock extends StatelessWidget {
  final Widget child;

  /// Around [child], inside the cushion.
  final EdgeInsetsGeometry padding;
  const VoiceDock({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DuvetTokens.tabBarInset,
        0,
        DuvetTokens.tabBarInset,
        safe > 0 ? safe : DuvetTokens.tabBarInset,
      ),
      child: Cushion(
        radius: DuvetTokens.radiusBar,
        shadows: context.duvet.shadowRaised,
        padding: padding,
        child: child,
      ),
    );
  }
}

/// A voice room: who's in, and Join voice; once the user is in, the controls.
class VoiceRoomScreen extends StatefulWidget {
  final String spaceId;
  final String roomId;
  const VoiceRoomScreen({required this.spaceId, required this.roomId, super.key});

  @override
  State<VoiceRoomScreen> createState() => _VoiceRoomScreenState();
}

class _VoiceRoomScreenState extends State<VoiceRoomScreen> {
  bool _loadedPeople = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedPeople) return;
    _loadedPeople = true;
    // The space's members name the people in voice.
    context.repository.members(RoomTarget(spaceId: widget.spaceId, roomId: widget.roomId)).then((_) {
      if (mounted) setState(() {});
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final colors = context.theme.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([voice, voice.levels, repository.spaces, repository.profile]),
      builder: (context, _) {
        final space = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
        final room = space?.rooms.where((r) => r.id == widget.roomId).firstOrNull;
        final here = voice.target == RoomVoice(spaceId: widget.spaceId, roomId: widget.roomId);
        final people = voicePeople(repository, voice, widget.roomId);
        final media = MediaQuery.of(context);
        final top = GlassTopBar.heightOf(context) + (here && voice.link != VoiceLink.connected ? 44 : 0);
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: room == null
                    ? const EmptyState(icon: FLucideIcons.volumeX, text: 'This voice room is gone')
                    : people.isEmpty
                    ? EmptyState(text: 'No one’s here yet')
                    : VoiceGrid(
                        people: people,
                        levels: voice.levels.value,
                        padding: EdgeInsets.fromLTRB(16, top + 16, 16, 140 + media.padding.bottom),
                      ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  onBack: () => Navigator.of(context).maybePop(),
                  title: Semantics(
                    label: room == null ? 'Voice room' : '${room.name}, voice room in ${space!.name}',
                    excludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FLucideIcons.volume2, size: 18, color: colors.mutedForeground),
                        const SizedBox(width: 6),
                        Flexible(child: Text(room?.name ?? 'Voice room', overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                  bottom: here ? voiceLinkBanner(voice.link) : null,
                ),
              ),
              if (room != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: here
                      ? VoiceControls(voice: voice, onLeave: voice.leave)
                      : _JoinPanel(room: room, voice: voice),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Join voice: the screen's one Primary action, and its one accent, on the
/// floating dock the controls take its place on once the user is in.
class _JoinPanel extends StatelessWidget {
  final Room room;
  final VoiceController voice;
  const _JoinPanel({required this.room, required this.voice});

  @override
  Widget build(BuildContext context) => VoiceDock(
    padding: const EdgeInsets.all(12),
    child: JoinVoiceButton(room: room, voice: voice, expand: true),
  );
}

/// Join voice, Primary, and under it why it can't be ("You can’t join this
/// voice room") or what it ends ("Joining ends your call"): the voice room
/// screen's own, and its Space's stage's. Joining leaves any other voice or
/// call, and asks for the microphone, in [VoiceController.joinRoom];
/// [onJoin] follows it, e.g. to open the room.
class JoinVoiceButton extends StatelessWidget {
  final Room room;
  final VoiceController voice;

  /// Full width, the caption centered under it.
  final bool expand;
  final VoidCallback? onJoin;
  const JoinVoiceButton({required this.room, required this.voice, this.expand = false, this.onJoin, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final allowed = voice.canJoin(room);
    final inCall = voice.call != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: expand ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
      children: [
        DuvetButton(
          label: 'Join voice',
          icon: FLucideIcons.audioLines,
          variant: ButtonVariant.primary,
          expand: expand,
          onPressed: allowed
              ? () {
                  unawaited(voice.joinRoom(room));
                  onJoin?.call();
                }
              : null,
        ),
        if (!allowed || inCall)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              !allowed ? 'You can’t join this voice room' : 'Joining ends your call',
              textAlign: expand ? TextAlign.center : TextAlign.start,
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
          ),
      ],
    );
  }
}

/// Something alive, in a chat's top bar: a conversation's call, or a voice
/// room of the room's Space with people in it. A cushion with the ice dot of
/// what's alive, the first faces in it, what it is in words, and its action
/// ([action], e.g. Join) at its end, the strip's height a target. Without
/// [onAction], the words alone.
class LiveStrip extends StatelessWidget {
  final List<VoicePerson> people;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  /// What screen readers hear for the action, when the label alone doesn't
  /// say what it joins.
  final String? actionLabel;
  const LiveStrip({required this.people, required this.text, this.action, this.onAction, this.actionLabel, super.key});

  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusRow));
    return Container(
      height: height,
      decoration: BoxDecoration(color: colors.card, borderRadius: radius, boxShadow: tokens.shadowRest),
      child: InsetShadow(
        shadows: tokens.cushion,
        borderRadius: radius,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const AliveDot(),
            const SizedBox(width: 8),
            if (people.isNotEmpty) ...[
              FaceStack(faces: [for (final p in people) (name: p.name, avatarUrl: p.avatarUrl)], size: 24),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
              ),
            ),
            if (action case final action? when onAction != null)
              Semantics(
                container: true,
                button: true,
                label: actionLabel ?? action,
                excludeSemantics: true,
                onTap: onAction,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onAction,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        action,
                        style: DuvetType.label.copyWith(color: tokens.accentText, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
