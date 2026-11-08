import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../chat_view.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/scope.dart';
import '../members_sheet.dart';
import '../people.dart';
import '../theme.dart';
import '../voice_room.dart';
import 'avatar.dart';
import 'rows.dart';

// Now, at the top of Chats: the desktop's `now.ts`, with its limits.

/// The busiest voice rooms "In voice now" lists before the user opens the rest.
const nowRooms = 3;

/// The faces a voice room's card shows; the rest are a "+N".
const nowRoomFaces = 4;

/// The places in the online friends' row: their faces, the last one a "+N" when they're more.
const nowFriends = 8;

/// What a voice room shows live.
enum NowLive { screen, camera }

/// What [people] show live: someone's screen, else someone's camera.
NowLive? liveIn(Iterable<duvet.VoiceParticipant> people) {
  if (people.any((p) => p.screenSharing)) return NowLive.screen;
  if (people.any((p) => p.camera)) return NowLive.camera;
  return null;
}

/// The rooms with people in them, the busiest first, at most [max]; rooms as busy keep their order.
List<R> busiestRooms<R>(Iterable<R> rooms, int Function(R room) peopleIn, {int max = nowRooms}) {
  final counted = [for (final (i, r) in rooms.indexed) (room: r, index: i, people: peopleIn(r))];
  return [
    for (final r
        in (counted.where((r) => r.people > 0).toList()
              ..sort((a, b) => b.people != a.people ? b.people.compareTo(a.people) : a.index.compareTo(b.index)))
            .take(max))
      r.room,
  ];
}

/// The calls of [calls] Now offers to join: not those [skip] says are shown or not joinable already.
List<String> joinableCalls(Iterable<String> calls, bool Function(String id) skip) => [
  for (final id in calls)
    if (!skip(id)) id,
];

/// The first [max] of [items], and how many more there are.
({List<T> faces, int more}) capFaces<T>(List<T> items, int max) {
  final faces = items.take(max < 0 ? 0 : max).toList();
  return (faces: faces, more: items.length - faces.length);
}

/// The faces that fit in [slots] places: all when they fit, else one place fewer, for the "+N".
({List<T> faces, int more}) fitFaces<T>(List<T> items, int slots) =>
    capFaces(items, items.length <= slots ? slots : slots - 1);

/// The key a chat is pinned under in [ChatRepository.pinnedChats].
String pinKey(ChatTarget target) => switch (target) {
  RoomTarget() => 'room:${target.id}',
  ConversationTarget() => 'conv:${target.id}',
};

/// The voice rooms with people in them, and the friends online: nothing when there are none.
class NowBlock extends StatefulWidget {
  const NowBlock({super.key});

  @override
  State<NowBlock> createState() => _NowBlockState();
}

class _NowBlockState extends State<NowBlock> {
  // Not kept: the rooms past the busiest are a look, not a setting.
  bool _all = false;

  // Chats rebuilds this const block without running it again: it listens itself, as VoiceScope asks.
  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return ListenableBuilder(
      listenable: Listenable.merge([context.voice, repository.spaces, repository.presence, repository.friends]),
      builder: (context, _) => _now(context),
    );
  }

  Widget _now(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final sorted = busiestRooms(
      [
        for (final space in repository.spaces.value)
          for (final room in space.rooms)
            // Not the room the user is in (the voice bar has it), nor one they can't join.
            if (room.kind == RoomKind.voice && voice.target?.id != room.id && voice.canJoin(room)) (room, space),
      ],
      (r) => voice.participants(r.$1.id).length,
      max: 1 << 30,
    );
    final rooms = sorted.take(_all ? sorted.length : nowRooms).toList();
    final presence = repository.presence.value;
    final online = [
      for (final f in repository.friends.value.friends)
        if (!isOffline(presenceIn(presence, f.userId))) f,
    ];
    if (rooms.isEmpty && online.isEmpty) return const SizedBox.shrink();
    final friends = fitFaces(online, nowFriends);
    final colors = context.theme.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rooms.isNotEmpty) ...[
          const Overline('In voice now'),
          for (final (room, space) in rooms)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _RoomCard(key: ValueKey('now-${room.id}'), room: room, space: space),
            ),
          if (sorted.length > nowRooms)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextAction(
                  label: _all ? 'Show fewer rooms' : '${sorted.length - nowRooms} more rooms',
                  onPressed: () => setState(() => _all = !_all),
                ),
              ),
            ),
        ],
        if (online.isNotEmpty) ...[
          const Overline('Online friends'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              children: [
                for (final f in friends.faces) _FriendFace(friend: f),
                if (friends.more > 0)
                  Semantics(
                    button: true,
                    label: '${friends.more} more friends online, open Friends',
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(
                        context,
                        rootNavigator: true,
                      ).push(MaterialPageRoute<void>(builder: (_) => const FriendsPage())),
                      child: SizedBox.square(
                        dimension: 44,
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: colors.secondary, shape: BoxShape.circle),
                            child: Text(
                              '+${friends.more}',
                              style: DuvetType.caption.copyWith(color: colors.foreground),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

class _FriendFace extends StatelessWidget {
  final Member friend;
  const _FriendFace({required this.friend});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return Semantics(
      button: true,
      label: 'Message ${friend.displayName}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          try {
            final dm = await repository.directMessage(friend.userId);
            if (context.mounted) openChat(context, dm.target, dm.title);
          } catch (_) {
            if (context.mounted) {
              showFToast(
                context: context,
                title: const Text('Couldn’t open the chat'),
                duration: const Duration(seconds: 4),
              );
            }
          }
        },
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: PresenceAvatar(
              member: friend,
              presence: presenceIn(repository.presence.value, friend.userId),
              mobileOnly: repository.mobileOnly.value.contains(friend.userId),
            ),
          ),
        ),
      ),
    );
  }
}

/// A voice room with people in it: who, what is live, and Join. Raised like
/// [CallPresenceCard], with no glass inside a scrolling list.
class _RoomCard extends StatelessWidget {
  final Room room;
  final Space space;
  const _RoomCard({required this.room, required this.space, super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final voice = context.voice;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final people = voice.participants(room.id);
    final known = {for (final m in repository.people) m.userId: m};
    final shown = capFaces(people, nowRoomFaces);
    final live = switch (liveIn(people)) {
      NowLive.screen => ' · sharing screen',
      NowLive.camera => ' · camera on',
      null => '',
    };
    final detail = 'Live · ${space.name}$live';
    final count = people.length == 1 ? '1 person' : '${people.length} people';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: tokens.shadowRaised,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              label: '${room.name}, $detail, $count',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: tokens.live, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final p in shown.faces)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: UserAvatar(
                            name: known[p.userId]?.displayName ?? repository.nameOf(p.userId) ?? 'Someone',
                            url: known[p.userId]?.avatarUrl,
                            size: 28,
                          ),
                        ),
                      if (shown.more > 0)
                        Text('+${shown.more}', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          DuvetButton(
            label: 'Join',
            onPressed: () {
              voice.joinRoom(room);
              openVoiceRoom(context, room);
            },
          ),
        ],
      ),
    );
  }
}
