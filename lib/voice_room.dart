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

/// A person in voice: their face, its mouth moving with their voice, their
/// name, and whether they're muted or deafened. Speaking rings the tile in
/// `accent-text`, the screen's one accent while in voice.
class VoiceTile extends StatelessWidget {
  final VoicePerson person;

  /// How open the mouth is (0–1).
  final double level;
  final Offset eyes;
  const VoiceTile({required this.person, this.level = 0, this.eyes = Offset.zero, super.key});

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
          boxShadow: tokens.shadowRest,
          border: Border.all(color: speaking ? tokens.accentText : Colors.transparent, width: 2),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: speaking ? level : 0),
              duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
              builder: (context, open, _) =>
                  UserAvatar(name: person.name, url: person.avatarUrl, size: 72, mouthOpen: open, eyeOffset: eyes),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (state != null) ...[Icon(state, size: 16, color: colors.mutedForeground), const SizedBox(width: 4)],
                Flexible(
                  child: Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The people in voice, two to a row, scrolling under the bars.
class VoiceGrid extends StatelessWidget {
  final List<VoicePerson> people;
  final Map<String, double> levels;
  final EdgeInsets padding;
  const VoiceGrid({required this.people, required this.levels, required this.padding, super.key});

  static const columns = 2;

  @override
  Widget build(BuildContext context) {
    final eyes = eyesToward(people, levels, columns);
    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 156,
      ),
      itemCount: people.length,
      itemBuilder: (context, i) {
        final p = people[i];
        return VoiceTile(key: ValueKey(p.id), person: p, level: levels[p.id] ?? 0, eyes: eyes[p.id] ?? Offset.zero);
      },
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

/// A voice control: a 56pt rounded square (circles are for people) over its
/// caption. On, it's sunk into `ink` with the icon in `base`; the destructive
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
        ? colors.foreground
        : colors.card;
    final ink = destructive
        ? colors.destructiveForeground
        : active
        ? colors.background
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
                  shadows: pressed ? tokens.shadowPressed : const [],
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

/// The controls while in voice, on a glass bar at the bottom: mute, deafen,
/// where the sound plays, and leave.
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
  Widget build(BuildContext context) => GlassChrome(
    top: false,
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
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
    ),
  );
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
                    ? EmptyState(icon: FLucideIcons.volume2, text: 'No one’s here yet')
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

/// Join voice: the screen's one Primary action, and its one accent.
class _JoinPanel extends StatelessWidget {
  final Room room;
  final VoiceController voice;
  const _JoinPanel({required this.room, required this.voice});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final allowed = voice.canJoin(room);
    final inCall = voice.call != null;
    return GlassChrome(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DuvetButton(
              label: 'Join voice',
              icon: FLucideIcons.audioLines,
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: allowed ? () => voice.joinRoom(room) : null,
            ),
            if (!allowed || inCall)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  !allowed ? 'You can’t join this voice room' : 'Joining ends your call',
                  textAlign: TextAlign.center,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
