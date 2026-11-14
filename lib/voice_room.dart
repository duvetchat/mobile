import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/rows.dart';
import 'widgets/voice_video.dart';

/// Opens a voice room's screen: who's in, and Join voice, or the controls
/// once the user is in.
Future<void> openVoiceRoom(BuildContext context, Room room) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    builder: (_) => VoiceRoomScreen(spaceId: room.spaceId, roomId: room.id),
  ),
);

/// Who's in [roomId]'s voice (a room, or a call's conversation), named from
/// what the app knows; the user too while their voice is there, with their
/// own mute and watching as they are here, before the gateway echoes them.
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
    camera: voice.cameraOn,
    screenSharing: voice.screenSharing,
    watching: voice.incomingVideo ? voice.watching : const [],
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
          camera: p.camera,
          screenSharing: p.screenSharing,
          watching: p.watching,
          isMe: p.userId == me?.id,
        ),
  ];
  if (here && me != null && !people.any((p) => p.id == me.id)) people.add(mine());
  return people;
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

  /// Why it's disabled: read by screen readers, and shown on a long press.
  final String? hint;

  /// A switch, on or off; null for a plain button.
  final bool? on;
  final bool destructive;
  final VoidCallback? onPressed;
  const VoiceButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.hint,
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
    final button = Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: onPressed != null,
      label: semanticLabel ?? label,
      hint: hint,
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
    return switch (hint) {
      final hint? => Tooltip(
        message: hint,
        excludeFromSemantics: true,
        decoration: BoxDecoration(
          color: colors.foreground,
          borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
          boxShadow: tokens.shadowFloat,
        ),
        textStyle: DuvetType.caption.copyWith(color: colors.background),
        child: button,
      ),
      null => button,
    };
  }
}

/// The controls while in voice, on a glass bar at the bottom: mute, deafen,
/// the camera, more (screen, sound output, cameras, incoming video), and
/// leave.
class VoiceControls extends StatefulWidget {
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
  State<VoiceControls> createState() => _VoiceControlsState();
}

class _VoiceControlsState extends State<VoiceControls> {
  // A camera opening: a second tap meanwhile would open it twice.
  bool _cameraBusy = false;

  Future<void> _toggleCamera() async {
    if (_cameraBusy) return;
    setState(() => _cameraBusy = true);
    try {
      await widget.voice.toggleCamera();
    } finally {
      if (mounted) setState(() => _cameraBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    return GlassChrome(
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
            VoiceButton(
              icon: voice.cameraOn ? FLucideIcons.video : FLucideIcons.videoOff,
              label: 'Camera',
              on: voice.cameraOn,
              hint: voice.canVideo ? null : noVideoReason(voice),
              onPressed: voice.canVideo && !_cameraBusy ? _toggleCamera : null,
            ),
            VoiceButton(
              icon: FLucideIcons.ellipsis,
              label: 'More',
              semanticLabel: 'More voice options',
              onPressed: () => showVoiceMore(context, voice),
            ),
            VoiceButton(
              icon: FLucideIcons.phoneOff,
              label: widget.leaveLabel,
              semanticLabel: widget.leaveSemanticLabel,
              destructive: true,
              onPressed: widget.onLeave,
            ),
          ],
        ),
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
      listenable: Listenable.merge([
        voice,
        voice.remoteVideos,
        VoicePrefsScope.maybeOf(context),
        repository.spaces,
        repository.profile,
      ]),
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
                    : VoiceStage(
                        people: people,
                        here: here,
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
