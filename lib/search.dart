import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'people.dart' show PersonRow;
import 'tabs.dart' show SpaceDirectory, voiceSnippet;
import 'voice_room.dart' show openVoiceRoom;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/mascot.dart';
import 'widgets/rows.dart';

/// [text] with each place [query]'s words match in Bold [accent], as Global
/// Search marks them: never a yellow highlight. With [tint], on it too (the
/// `accent-tint` behind a hit in one chat's search, where the match is the
/// point of each row).
List<InlineSpan> highlighted(String text, String query, Color accent, {Color? tint}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return [TextSpan(text: text)];
  final lower = text.toLowerCase();
  final marks = List.filled(text.length, false);
  for (final w in words) {
    for (var i = lower.indexOf(w); i >= 0; i = lower.indexOf(w, i + 1)) {
      for (var j = i; j < i + w.length && j < marks.length; j++) {
        marks[j] = true;
      }
    }
  }
  final spans = <InlineSpan>[];
  var start = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i == text.length || marks[i] != marks[start]) {
      final part = text.substring(start, i);
      spans.add(
        marks[start]
            ? TextSpan(
                text: part,
                style: TextStyle(color: accent, fontWeight: FontWeight.w700, backgroundColor: tint),
              )
            : TextSpan(text: part),
      );
      start = i;
    }
  }
  return spans;
}

/// A search result: who, when, and the message with its matches marked;
/// [tinted], on the `accent-tint` too.
class SearchResultRow extends StatelessWidget {
  final ChatMessage message;
  final String query;
  final String? where;
  final bool tinted;
  final VoidCallback onTap;
  const SearchResultRow({
    required this.message,
    required this.query,
    required this.onTap,
    this.where,
    this.tinted = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final text = context.repository.previewOf(message);
    return Semantics(
      container: true,
      button: true,
      label: '${message.authorName}${where == null ? '' : ' in $where'}, ${shortTime(message.createdAt)}: $text',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(name: message.authorName, url: message.authorAvatarUrl, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: message.authorName),
                                if (where != null)
                                  TextSpan(
                                    text: ' · $where',
                                    style: TextStyle(color: colors.mutedForeground, fontWeight: FontWeight.w400),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                          ),
                        ),
                        Text(
                          shortTime(message.createdAt),
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                    Text.rich(
                      TextSpan(
                        children: tinted
                            ? highlighted(text, query, colors.foreground, tint: tokens.accentTint)
                            : highlighted(text, query, tokens.accentText),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.snippet.copyWith(color: colors.foreground),
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

/// Searching one chat: a field and filters in the top bar, results by day,
/// and how many under them; a room can widen to its whole Space. Answers the
/// result picked.
class InChatSearch extends StatefulWidget {
  final ChatTarget target;
  final String title;
  const InChatSearch({required this.target, required this.title, super.key});

  @override
  State<InChatSearch> createState() => _InChatSearchState();
}

class _InChatSearchState extends State<InChatSearch> {
  final _query = TextEditingController();
  Timer? _debounce;
  bool _hasFile = false;
  bool _pinned = false;
  bool _wholeSpace = false;
  List<SearchHit>? _hits;
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_changed);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _run);
  }

  Future<void> _run() async {
    final text = _query.text.trim();
    if (text.isEmpty && !_hasFile && !_pinned) {
      setState(() => _hits = null);
      return;
    }
    final request = ++_request;
    setState(() => _loading = true);
    final target = widget.target;
    try {
      final hits = await context.repository.search(
        SearchQuery(
          text,
          spaceId: target is RoomTarget ? target.spaceId : null,
          roomId: target is RoomTarget && !_wholeSpace ? target.roomId : null,
          conversationId: target is ConversationTarget ? target.conversationId : null,
          hasFile: _hasFile,
          pinned: _pinned,
        ),
      );
      if (mounted && request == _request) setState(() => _hits = hits);
    } catch (_) {
      if (mounted && request == _request) setState(() => _hits = const []);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  String? get _spaceName => switch (widget.target) {
    RoomTarget(:final spaceId) => context.repository.spaces.value.where((s) => s.id == spaceId).firstOrNull?.name,
    _ => null,
  };

  String? _roomName(ChatTarget t) => switch (t) {
    RoomTarget(:final roomId) =>
      context.repository.spaces.value.expand((s) => s.rooms).where((r) => r.id == roomId).firstOrNull?.name,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    final hits = _hits;
    final where = _wholeSpace ? (_spaceName ?? 'this Space') : widget.title.replaceFirst('# ', '#');
    // By day, the newest first.
    final groups = <String, List<SearchHit>>{};
    for (final h in hits ?? const <SearchHit>[]) {
      (groups[dayLabel(h.message.createdAt)] ??= []).add(h);
    }
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(top: padding.top + 108, bottom: padding.bottom + 72),
              children: [
                if (_loading && hits == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: FCircularProgress()),
                  )
                else if (hits != null && hits.isEmpty)
                  ListNote('Nothing found in $where')
                else
                  for (final MapEntry(key: day, value: list) in groups.entries) ...[
                    Overline(day),
                    for (final h in list)
                      SearchResultRow(
                        message: h.message,
                        query: _query.text,
                        where: _wholeSpace ? _roomName(h.target) : null,
                        tinted: true,
                        onTap: () => Navigator.of(context).pop(h),
                      ),
                  ],
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassChrome(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, padding.top + 6, 8, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: SearchField(
                            controller: _query,
                            autofocus: true,
                            hint: 'Search ${widget.title.replaceFirst('# ', '')}',
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Cancel',
                          excludeSemantics: true,
                          onTap: () => Navigator.of(context).pop(),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).pop(),
                            child: SizedBox(
                              height: 44,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Center(
                                  widthFactor: 1,
                                  child: Text('Cancel', style: DuvetType.label.copyWith(color: tokens.accentText)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        DuvetChip(
                          label: 'Has file',
                          selected: _hasFile,
                          radio: false,
                          leading: Icon(
                            FLucideIcons.paperclip,
                            size: 16,
                            color: _hasFile ? tokens.chosenText : colors.mutedForeground,
                          ),
                          onTap: () {
                            setState(() => _hasFile = !_hasFile);
                            _run();
                          },
                        ),
                        const SizedBox(width: 8),
                        DuvetChip(
                          label: 'Pinned',
                          selected: _pinned,
                          radio: false,
                          leading: Icon(
                            FLucideIcons.pin,
                            size: 16,
                            color: _pinned ? tokens.chosenText : colors.mutedForeground,
                          ),
                          onTap: () {
                            setState(() => _pinned = !_pinned);
                            _run();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hits != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GlassChrome(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4 + padding.bottom),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            '${hits.length == 1 ? '1 result' : '${hits.length} results'} in $where',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        ),
                      ),
                      if (widget.target is RoomTarget && !_wholeSpace && _spaceName != null)
                        Semantics(
                          button: true,
                          label: 'Search all of $_spaceName',
                          excludeSemantics: true,
                          onTap: _widen,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _widen,
                            child: SizedBox(
                              height: 44,
                              child: Center(
                                child: Text(
                                  'Search all of $_spaceName',
                                  style: DuvetType.caption.copyWith(
                                    color: tokens.accentText,
                                    fontWeight: FontWeight.w500,
                                  ),
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
        ],
      ),
    );
  }

  void _widen() {
    setState(() => _wholeSpace = true);
    _run();
  }
}

enum _Filter { all, messages, people, spaces }

/// The Chats search field and its Global Search dropdown: a glass panel 8pt
/// under the field with filters, then messages, people and Spaces matching,
/// the matches in Bold `accent-text`.
class GlobalSearch extends StatefulWidget {
  const GlobalSearch({super.key});

  @override
  State<GlobalSearch> createState() => _GlobalSearchState();
}

class _GlobalSearchState extends State<GlobalSearch> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _focus = FocusNode();
  final _query = TextEditingController();
  _Filter _filter = _Filter.all;
  Timer? _debounce;
  List<SearchHit> _messages = const [];
  bool _searching = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) _portal.show();
    });
    _query.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), _searchMessages);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    _query.dispose();
    super.dispose();
  }

  void _close() {
    _focus.unfocus();
    _query.clear();
    _portal.hide();
  }

  Future<void> _searchMessages() async {
    final text = _query.text.trim();
    final request = ++_request;
    if (text.length < 2) {
      setState(() => _messages = const []);
      return;
    }
    final repository = context.repository;
    setState(() => _searching = true);
    final queries = [
      for (final s in repository.spaces.value) SearchQuery(text, spaceId: s.id),
      // The recent conversations: each is a request of its own.
      for (final c in repository.conversations.value.take(5)) SearchQuery(text, conversationId: c.id),
    ];
    final found = <SearchHit>[];
    await Future.wait([for (final q in queries) repository.search(q).then(found.addAll, onError: (_) {})]);
    found.sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    if (mounted && request == _request) {
      setState(() {
        _messages = found.take(20).toList();
        _searching = false;
      });
    }
  }

  String _where(ChatRepository repository, ChatTarget t) => switch (t) {
    RoomTarget(:final spaceId, :final roomId) => () {
      final space = repository.spaces.value.where((s) => s.id == spaceId).firstOrNull;
      final room = space?.rooms.where((r) => r.id == roomId).firstOrNull;
      return '#${room?.name ?? 'room'}';
    }(),
    ConversationTarget(:final conversationId) =>
      repository.conversations.value.where((c) => c.id == conversationId).firstOrNull?.title ?? 'Direct message',
  };

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: _dropdown,
    child: CompositedTransformTarget(
      link: _link,
      child: TapRegion(
        groupId: _link,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SearchField(controller: _query, focusNode: _focus),
        ),
      ),
    ),
  );

  Widget _dropdown(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final text = _query.text.trim();
    final q = text.toLowerCase();
    final screen = MediaQuery.sizeOf(context);

    final people = q.isEmpty
        ? const <Member>[]
        : [
            for (final m in repository.people)
              if (m.userId != repository.profile.value?.id &&
                  (m.displayName.toLowerCase().contains(q) || m.username.toLowerCase().contains(q)))
                m,
          ].take(5).toList();
    final spaces = q.isEmpty
        ? const <Space>[]
        : repository.spaces.value.where((s) => s.name.toLowerCase().contains(q)).take(5).toList();
    bool show(_Filter f) => _filter == _Filter.all || _filter == f;

    final rooms = q.isEmpty
        ? const <({Space space, Room room})>[]
        : [
            for (final space in repository.spaces.value)
              for (final room in space.rooms)
                if (room.name.toLowerCase().contains(q)) (space: space, room: room),
          ].take(5).toList();
    // Headers name the kinds while more than one could show.
    final headed = _filter == _Filter.all || (_filter == _Filter.spaces && rooms.isNotEmpty);

    // By kind: the shapes first, people's circles, then Spaces' and rooms'
    // rounded squares; the messages, longer, under them.
    final results = <Widget>[
      if (show(_Filter.people) && people.isNotEmpty) ...[
        if (_filter == _Filter.all) const Overline('People'),
        for (final m in people)
          _PersonResult(
            member: m,
            query: text,
            onTap: () async {
              _close();
              // The dropdown's context goes with it: the search field's stays.
              try {
                final dm = await repository.directMessage(m.userId);
                if (mounted) openChat(this.context, dm.target, dm.title);
              } catch (e) {
                debugPrint('open DM: $e');
                if (mounted) {
                  showFToast(
                    context: this.context,
                    title: Text(e is ActionFailed ? e.message : 'Couldn’t open a conversation with ${m.displayName}'),
                    duration: const Duration(seconds: 3),
                  );
                }
              }
            },
          ),
      ],
      if (show(_Filter.spaces) && spaces.isNotEmpty) ...[
        if (headed) const Overline('Spaces'),
        for (final s in spaces)
          ListRow(
            leading: SpaceIcon(space: s),
            title: s.name,
            snippet: s.onlineCount == null ? null : '${s.onlineCount} online',
            onTap: () {
              _close();
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => SpaceDirectory(spaceId: s.id, name: s.name),
                ),
              );
            },
          ),
      ],
      if (show(_Filter.spaces) && rooms.isNotEmpty) ...[
        if (headed) const Overline('Rooms'),
        for (final (:space, :room) in rooms)
          ListRow(
            leading: RoomMark(kind: room.kind, live: context.voice.participants(room.id).isNotEmpty),
            title: room.name,
            hash: room.kind == RoomKind.text,
            snippet: switch (room.kind) {
              RoomKind.text => space.name,
              RoomKind.voice => '${space.name} · ${voiceSnippet(repository, context.voice, room.id)}',
            },
            detail: room.kind == RoomKind.voice ? 'voice room' : null,
            onTap: () {
              _close();
              switch (room.kind) {
                case RoomKind.text:
                  openChat(this.context, room.target, '# ${room.name}');
                case RoomKind.voice:
                  openVoiceRoom(this.context, room);
              }
            },
          ),
      ],
      if (show(_Filter.messages) && _messages.isNotEmpty) ...[
        if (_filter == _Filter.all) const Overline('Messages'),
        for (final h in _messages)
          SearchResultRow(
            message: h.message,
            query: text,
            where: _where(repository, h.target),
            onTap: () {
              _close();
              final title = h.target is RoomTarget
                  ? '# ${_where(repository, h.target).substring(1)}'
                  : _where(repository, h.target);
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatView(target: h.target, title: title, jumpTo: h.message.id),
                ),
              );
            },
          ),
      ],
    ];

    // Above the keyboard, which is always up while it shows: rows under it
    // would count as on screen, and never scroll into view.
    final field = this.context.findRenderObject() as RenderBox?;
    final top = field == null || !field.attached ? 0.0 : field.localToGlobal(Offset(0, field.size.height)).dy + 8;
    final room = screen.height - MediaQuery.viewInsetsOf(context).bottom - top - 16;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(16, 8),
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _link,
          onTapOutside: (_) => _close(),
          child: _DropIn(
            child: SizedBox(
              width: screen.width - 32,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: math.max(120, math.min(screen.height * 0.7, room))),
                child: Semantics(
                  label: 'Search results',
                  explicitChildNodes: true,
                  child: GlassSurface(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                          child: Segmented(
                            label: 'Show',
                            value: _filter,
                            options: const {
                              _Filter.all: 'All',
                              _Filter.messages: 'Messages',
                              _Filter.people: 'People',
                              _Filter.spaces: 'Spaces',
                            },
                            onChanged: (f) => setState(() => _filter = f),
                          ),
                        ),
                        Flexible(
                          child: results.isEmpty
                              ? text.isNotEmpty && _searching
                                    ? Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(
                                          'Searching…',
                                          style: DuvetType.body.copyWith(color: colors.mutedForeground),
                                        ),
                                      )
                                    : _Nothing(
                                        text: text.isEmpty
                                            ? 'Search messages, people and Spaces'
                                            : 'Nothing found for “$text”',
                                        next: text.isEmpty
                                            ? null
                                            : _filter != _Filter.all
                                            ? null
                                            : text.length < 2
                                            ? 'Type another letter to search messages too.'
                                            : 'Try fewer words, or search one chat from its top bar.',
                                        action: text.isNotEmpty && _filter != _Filter.all
                                            ? TextAction(
                                                label: 'Search everything',
                                                onPressed: () => setState(() => _filter = _Filter.all),
                                              )
                                            : null,
                                      )
                              : ListView(
                                  shrinkWrap: true,
                                  // A drag through the results puts the keyboard away; they stay open.
                                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                  padding: const EdgeInsets.only(bottom: 8),
                                  children: results,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dropdown with nothing in it: the mascot over what to search, or over
/// what found nothing, and the next thing to try.
class _Nothing extends StatelessWidget {
  final String text;
  final String? next;
  final Widget? action;
  const _Nothing({required this.text, this.next, this.action});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        children: [
          const Mascot(size: 64),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: DuvetType.rowTitle.copyWith(color: colors.foreground),
          ),
          if (next case final next?) ...[
            const SizedBox(height: 4),
            Text(
              next,
              textAlign: TextAlign.center,
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
          ],
          if (action case final action?) ...[const SizedBox(height: 4), action],
        ],
      ),
    );
  }
}

class _PersonResult extends StatelessWidget {
  final Member member;
  final String query;
  final VoidCallback onTap;
  const _PersonResult({required this.member, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) => PersonRow(
    member: member,
    presence: context.repository.presence.value[member.userId],
    name: highlighted(member.displayName, query, context.duvet.accentText),
    onTap: onTap,
  );
}

/// The dropdown's entrance: it drops 8pt and fades in on the panel spring.
class _DropIn extends StatefulWidget {
  final Widget child;
  const _DropIn({required this.child});

  @override
  State<_DropIn> createState() => _DropInState();
}

class _DropInState extends State<_DropIn> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: DuvetTokens.dropdownIn)..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: DuvetTokens.decelerate.transform(_controller.value),
        child: Transform.translate(
          offset: Offset(0, (1 - DuvetTokens.overshoot.transform(_controller.value)) * -8),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
