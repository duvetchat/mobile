import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart' show openChat;
import 'data/models.dart';
import 'data/scope.dart';
import 'data/voice.dart';
import 'tabs.dart' show voiceSnippet;
import 'theme.dart';
import 'voice_room.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/duvet_mascot.dart';
import 'widgets/depth.dart';
import 'widgets/rows.dart';
import 'widgets/voice_video.dart';

/// Opens the call screen of [conversationId]'s call.
Future<void> openCall(BuildContext context, String conversationId) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => CallScreen(conversationId: conversationId)));

// Set while a Call button places or joins a call (the members, then the
// permissions): a second tap meanwhile would stack a second call screen. Not
// kept while the screen is up: it covers the buttons, and its push doesn't
// finish if it's removed instead of popped.
bool _placing = false;

/// Calls [conversationId], or joins its call going on, and opens the call
/// screen.
Future<void> callConversation(BuildContext context, String conversationId) async {
  if (_placing) return;
  final voice = context.voice;
  if (voice.call?.conversationId != conversationId) {
    _placing = true;
    try {
      if (voice.callsInProgress.contains(conversationId)) {
        await voice.joinCall(conversationId);
      } else {
        await voice.startCall(conversationId);
      }
    } finally {
      _placing = false;
    }
  }
  if (context.mounted && voice.call?.conversationId == conversationId) await openCall(context, conversationId);
}

/// Whether the user's own call in [conversationId] still rings the others
/// from another of their devices: nothing to join from here until someone
/// answers it, as its device joins then.
bool callingElsewhere(VoiceController voice, String conversationId) =>
    voice.call?.conversationId != conversationId && voice.ownCallRinging(conversationId);

/// "2:05", or "1:02:05".
String callClock(Duration d) {
  final s = d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
}

/// A call's state in words: calling, connecting, or how long it's been.
String callStatus(VoiceController voice, ActiveCall call, DateTime now) {
  if (call.phase == CallPhase.ringing) return 'Incoming call';
  if (call.phase == CallPhase.calling) return 'Calling…';
  return switch (voice.target == CallVoice(call.conversationId) ? voice.link : null) {
    VoiceLink.connected => callClock(now.difference(call.connectedAt ?? now)),
    VoiceLink.waiting => 'Waiting for Duvet…',
    VoiceLink.reconnecting => 'Reconnecting…',
    null => 'Not connected',
    _ => 'Connecting…',
  };
}

/// Ticks once a second while built: a call's clock.
mixin _Ticking<T extends StatefulWidget> on State<T> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

/// Builds [builder] again each second, and only it: the clock's text, not the videos around it.
class _EverySecond extends StatefulWidget {
  final WidgetBuilder builder;
  const _EverySecond({required this.builder});

  @override
  State<_EverySecond> createState() => _EverySecondState();
}

class _EverySecondState extends State<_EverySecond> with _Ticking {
  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The call: who's in it, how long it's been, and the controls. Back keeps
/// the call going; the bar over the tabs brings it back.
class CallScreen extends StatefulWidget {
  final String conversationId;
  const CallScreen({required this.conversationId, super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _closing = false;

  // The call ended or moved on: this screen goes, wherever it is.
  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).removeRoute(route);
      }
    });
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
        repository.conversations,
        repository.profile,
      ]),
      builder: (context, _) {
        final call = voice.call;
        if (call == null || call.conversationId != widget.conversationId) {
          _close();
          return Scaffold(backgroundColor: colors.background);
        }
        final summary = repository.conversations.value.where((c) => c.id == call.conversationId).firstOrNull;
        final title = summary?.title ?? call.initiatorName;
        String status() => callStatus(voice, call, voice.now());
        final people = voicePeople(repository, voice, call.conversationId);
        final inVoice = voice.target == CallVoice(call.conversationId);
        final media = MediaQuery.of(context);
        return Scaffold(
          backgroundColor: colors.background,
          body: Stack(
            children: [
              Positioned.fill(
                child: call.phase == CallPhase.calling || people.isEmpty
                    ? _EverySecond(
                        builder: (_) => _Waiting(
                          name: title,
                          avatarUrl: summary?.isGroup == true ? null : summary?.avatarUrl,
                          status: status(),
                        ),
                      )
                    : VoiceStage(
                        people: people,
                        here: inVoice,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          GlassTopBar.heightOf(context) + 16,
                          16,
                          140 + media.padding.bottom,
                        ),
                      ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  onBack: () => Navigator.of(context).maybePop(),
                  title: _EverySecond(
                    builder: (_) {
                      final now = status();
                      return Semantics(
                        label: 'Call with $title, $now',
                        excludeSemantics: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(now, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: inVoice
                    ? VoiceControls(
                        voice: voice,
                        onLeave: voice.hangUp,
                        leaveLabel: 'Hang up',
                        leaveSemanticLabel: 'Hang up the call',
                      )
                    : GlassChrome(
                        top: false,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + media.padding.bottom),
                          child: Center(
                            child: VoiceButton(
                              icon: FLucideIcons.phoneOff,
                              label: call.phase == CallPhase.calling ? 'Cancel' : 'Hang up',
                              semanticLabel: call.phase == CallPhase.calling ? 'Cancel the call' : 'Hang up the call',
                              destructive: true,
                              onPressed: voice.hangUp,
                            ),
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
}

/// While the call rings out: who's called, large.
class _Waiting extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final String status;
  const _Waiting({required this.name, required this.avatarUrl, required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: UserAvatar(name: name, url: avatarUrl, size: 120),
          ),
          const SizedBox(height: 20),
          Text(name, style: DuvetType.title.copyWith(color: colors.foreground)),
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(status, style: DuvetType.body.copyWith(color: colors.mutedForeground)),
          ),
        ],
      ),
    );
  }
}

/// Someone calls: Accept or Decline, full screen, the phone buzzing (not in do not disturb).
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  Timer? _buzz;
  ValueListenable<Profile?>? _profile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _profile = context.repository.profile;
    if (_buzz != null) return;
    _buzzOnce();
    _buzz = Timer.periodic(const Duration(milliseconds: 1500), (_) => _buzzOnce());
  }

  // In do not disturb the call shows without buzzing, as the desktop's doesn't ring (callRings), and a
  // switch to it mid-ring stops the buzz.
  void _buzzOnce() {
    if (_profile?.value?.status == Presence.doNotDisturb) return;
    unawaited(HapticFeedback.heavyImpact());
  }

  @override
  void dispose() {
    _buzz?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final colors = context.theme.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([voice, repository.conversations]),
      builder: (context, _) {
        final call = voice.call;
        if (call == null || call.phase != CallPhase.ringing) return Scaffold(backgroundColor: colors.background);
        final summary = repository.conversations.value.where((c) => c.id == call.conversationId).firstOrNull;
        final group = summary?.isGroup == true;
        // Answer or decline: back doesn't dismiss a ringing call.
        return PopScope(
          canPop: false,
          child: Scaffold(
            backgroundColor: colors.background,
            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(),
                  ExcludeSemantics(
                    // A DM's avatar is the caller's; a group's call shows its caller's.
                    child: UserAvatar(
                      name: call.initiatorName,
                      url: group ? repository.avatarUrl(call.initiatorAvatar) : summary?.avatarUrl,
                      size: 120,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    liveRegion: true,
                    label: group
                        ? '${call.initiatorName} is calling ${summary!.title}'
                        : 'Incoming call from ${call.initiatorName}',
                    excludeSemantics: true,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            call.initiatorName,
                            textAlign: TextAlign.center,
                            style: DuvetType.largeTitle.copyWith(color: colors.foreground),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          group ? 'Calling ${summary!.title}' : 'Incoming call',
                          style: DuvetType.body.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(flex: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _AnswerButton(
                        icon: FLucideIcons.phoneOff,
                        label: 'Decline',
                        semanticLabel: 'Decline the call',
                        color: colors.destructive,
                        ink: colors.destructiveForeground,
                        onPressed: voice.declineCall,
                      ),
                      _AnswerButton(
                        icon: FLucideIcons.phone,
                        label: 'Accept',
                        semanticLabel: 'Accept the call',
                        color: Duvet.accent,
                        ink: colors.primaryForeground,
                        onPressed: voice.acceptCall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Accept and Decline: 72pt filled rounded squares, Accept the screen's
/// accent.
class _AnswerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String semanticLabel;
  final Color color;
  final Color ink;
  final VoidCallback onPressed;
  const _AnswerButton({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.color,
    required this.ink,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusCard));
    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color,
                borderRadius: radius,
                boxShadow: pressed ? null : tokens.shadowControl,
              ),
              child: InsetShadow(
                shadows: pressed ? tokens.shadowPressed : const [],
                borderRadius: radius,
                child: Center(child: Icon(icon, size: 32, color: ink)),
              ),
            ),
            const SizedBox(height: 8),
            Text(label, style: DuvetType.label.copyWith(color: context.theme.colors.foreground)),
          ],
        ),
      ),
    );
  }
}

/// Voice or a call going on: a glass strip over the tab bar, to go back to
/// it, mute, or leave.
class VoiceBar extends StatefulWidget {
  const VoiceBar({super.key});

  static const height = DuvetTokens.sizeTabBar;

  /// Whether there's something for it to show.
  static bool shows(VoiceController voice) => voice.inVoice;

  @override
  State<VoiceBar> createState() => _VoiceBarState();
}

class _VoiceBarState extends State<VoiceBar> with _Ticking {
  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final colors = context.theme.colors;
    final call = voice.call;
    final target = voice.target;
    final String title;
    final String status;
    final VoidCallback open;
    switch (target) {
      case RoomVoice(:final spaceId, :final roomId):
        final space = repository.spaces.value.where((s) => s.id == spaceId).firstOrNull;
        final room = space?.rooms.where((r) => r.id == roomId).firstOrNull;
        title = '${room?.name ?? 'Voice'}${space == null ? '' : ' · ${space.name}'}';
        status = switch (voice.link) {
          VoiceLink.connected => voice.muted ? 'In voice · muted' : 'In voice',
          VoiceLink.waiting => 'Waiting for Duvet…',
          VoiceLink.reconnecting => 'Reconnecting…',
          _ => 'Connecting…',
        };
        open = () {
          if (room != null) openVoiceRoom(context, room);
        };
      case _:
        if (call == null) return const SizedBox.shrink();
        final summary = repository.conversations.value.where((c) => c.id == call.conversationId).firstOrNull;
        title = summary?.title ?? call.initiatorName;
        status = callStatus(voice, call, voice.now());
        open = () => openCall(context, call.conversationId);
    }
    final isCall = target is! RoomVoice;
    // The bar ticks each second, so it follows the ping without listening to it.
    final ping = target != null && voice.link == VoiceLink.connected ? voice.ping.value : null;
    final caption = ping == null ? status : '$status · $ping ms';
    // Desktop's red from 250 ms.
    final poor = ping != null && ping >= 250;
    return GlassChrome(
      top: false,
      child: SizedBox(
        height: VoiceBar.height,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                button: true,
                label: '${isCall ? 'Call with' : 'Voice in'} $title, $caption. Open',
                excludeSemantics: true,
                onTap: open,
                child: Pressable(
                  onTap: open,
                  scale: 1,
                  // The bar's full height, so all of it opens; no vertical padding: two
                  // lines (≈41) fit the 56 bar up to ~1.38× text.
                  builder: (context, _) => Container(
                    height: VoiceBar.height,
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                    child: Row(
                      children: [
                        Icon(
                          isCall ? FLucideIcons.phoneCall : FLucideIcons.volume2,
                          size: 24,
                          color: colors.foreground,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
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
                              Text(
                                caption,
                                maxLines: 1,
                                style: DuvetType.caption.copyWith(
                                  color: poor ? colors.destructive : colors.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (target != null)
              IconAction(
                icon: voice.muted ? FLucideIcons.micOff : FLucideIcons.mic,
                label: voice.muted ? 'Unmute' : 'Mute',
                onPressed: voice.toggleMute,
              ),
            IconAction(
              icon: FLucideIcons.phoneOff,
              label: isCall ? 'Hang up' : 'Leave voice',
              color: colors.destructive,
              onPressed: voice.leave,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// Over the signed-in app: shows the incoming call screen while a call
/// rings, the call screen once it's answered here, and voice's notices as
/// toasts.
class VoiceListener extends StatefulWidget {
  final Widget child;
  const VoiceListener({required this.child, super.key});

  @override
  State<VoiceListener> createState() => _VoiceListenerState();
}

class _VoiceListenerState extends State<VoiceListener> {
  VoiceController? _voice;
  StreamSubscription<String>? _notices;
  Route<void>? _ringing;
  NavigatorState? _navigator;
  String? _ringingFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final voice = context.voice;
    if (identical(voice, _voice)) return;
    _voice?.removeListener(_changed);
    _notices?.cancel();
    _voice = voice..addListener(_changed);
    _notices = voice.notices.listen((text) {
      if (mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 4));
    });
    // A call may ring already: its screen goes up once this frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _changed();
    });
  }

  @override
  void dispose() {
    _voice?.removeListener(_changed);
    _notices?.cancel();
    // Signed out while a call rang: its screen goes too, after this frame.
    final route = _ringing;
    final navigator = _navigator;
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    super.dispose();
  }

  void _changed() {
    final call = _voice?.call;
    final ringing = call?.phase == CallPhase.ringing ? call!.conversationId : null;
    if (ringing == _ringingFor) return;
    final was = _ringingFor;
    _ringingFor = ringing;
    final navigator = _navigator = Navigator.of(context, rootNavigator: true);
    if (_ringing case final route?) {
      _ringing = null;
      if (route.isActive) navigator.removeRoute(route);
    }
    if (ringing != null) {
      final route = _ringing = MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const IncomingCallScreen(),
      );
      unawaited(navigator.push(route));
    } else if (was != null && call?.conversationId == was && call?.phase == CallPhase.connected) {
      // Answered here: the call screen.
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => CallScreen(conversationId: was))));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The Calls tab's list: the calls this phone saw, the newest first. Duvet
/// keeps no call history, so this phone's is all there is.
class CallHistoryList extends StatelessWidget {
  const CallHistoryList({super.key});

  static String describe(CallRecord c) => switch (c.outcome) {
    CallOutcome.answered => [
      c.outgoing ? 'Outgoing' : 'Incoming',
      if (c.duration case final d?) callClock(d),
    ].join(' · '),
    CallOutcome.missed => 'Missed call',
    CallOutcome.declined => 'Declined',
    CallOutcome.cancelled => 'Cancelled',
    CallOutcome.unanswered => 'No answer',
    CallOutcome.failed => 'Couldn’t connect',
  };

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    return ListenableBuilder(
      listenable: Listenable.merge([voice.history.calls, repository.conversations, voice]),
      builder: (context, _) {
        final calls = voice.history.calls.value;
        final summaries = {for (final c in repository.conversations.value) c.id: c};
        if (calls.isEmpty) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(mascot: MascotState.empty, text: 'No calls yet'),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.only(top: 8),
          sliver: SliverList.builder(
            itemCount: calls.length,
            itemBuilder: (context, i) {
              final c = calls[i];
              final summary = summaries[c.conversationId];
              final title = summary?.title ?? c.title;
              return _CallRow(
                key: ValueKey('${c.conversationId}-${c.at.microsecondsSinceEpoch}'),
                call: c,
                title: title,
                avatarUrl: summary?.isGroup == true ? null : summary?.avatarUrl,
                onOpen: () => openChat(context, ConversationTarget(c.conversationId), title),
                // As the banner's Join, it waits for someone to answer the
                // user's own call ringing from another device.
                onCall: summary == null || callingElsewhere(voice, c.conversationId)
                    ? null
                    : () => callConversation(context, c.conversationId),
              );
            },
          ),
        );
      },
    );
  }
}

class _CallRow extends StatelessWidget {
  final CallRecord call;
  final String title;
  final String? avatarUrl;
  final VoidCallback onOpen;
  final VoidCallback? onCall;
  const _CallRow({
    required this.call,
    required this.title,
    required this.avatarUrl,
    required this.onOpen,
    required this.onCall,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final missed = call.outcome == CallOutcome.missed;
    return Row(
      children: [
        Expanded(
          child: ListRow(
            leading: UserAvatar(name: title, url: avatarUrl, size: 48),
            title: title,
            snippet: CallHistoryList.describe(call),
            trailing: shortTime(call.at),
            // A missed call reads like an unread chat: weight, never a dot.
            unread: missed,
            onTap: onOpen,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: IconAction(icon: FLucideIcons.phone, label: 'Call $title', onPressed: onCall),
        ),
      ],
    );
  }
}

/// A conversation's call, in its chat's top bar: "Call in progress", with
/// who is in it, and Join; "You’re in this call · Open" for the one here; or
/// "Calling from another device", with nothing to join yet, while the user's
/// own call still rings the others from there. A `base-sunken` strip, as the
/// connection banner is.
class CallBanner extends StatelessWidget {
  final String conversationId;
  const CallBanner({required this.conversationId, super.key});

  /// Whether [conversationId] has a call to show.
  static bool shows(VoiceController voice, String conversationId) =>
      voice.callsInProgress.contains(conversationId) || voice.call?.conversationId == conversationId;

  @override
  Widget build(BuildContext context) {
    final voice = context.voice;
    final colors = context.theme.colors;
    final mine = voice.call?.conversationId == conversationId && voice.call?.phase != CallPhase.ringing;
    final elsewhere = callingElsewhere(voice, conversationId);
    final text = mine
        ? 'You’re in this call'
        : elsewhere
        ? 'Calling from another device'
        : voice.participants(conversationId).isEmpty
        ? 'Call in progress'
        : 'Call in progress · ${voiceSnippet(context.repository, voice, conversationId)}';
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Container(
      height: 36,
      decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
      child: InsetShadow(
        shadows: context.duvet.shadowWell,
        borderRadius: radius,
        padding: EdgeInsets.only(left: 12, right: elsewhere ? 12 : 0),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(FLucideIcons.phoneCall, size: 16, color: colors.foreground)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DuvetType.caption.copyWith(color: colors.foreground),
              ),
            ),
            // The user's voice would be in it alone: the device that placed
            // it joins at the first answer.
            if (!elsewhere)
              TextAction(
                label: mine ? 'Open' : 'Join',
                onPressed: () => mine ? openCall(context, conversationId) : callConversation(context, conversationId),
              ),
          ],
        ),
      ),
    );
  }
}
