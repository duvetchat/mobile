import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'tabs.dart' show SpaceDirectory;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// [text] with each place [query]'s words match in Bold `accent-text`: never a
/// block or a yellow highlight.
List<InlineSpan> highlighted(String text, String query, Color accent) {
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
                style: TextStyle(color: accent, fontWeight: FontWeight.w700),
              )
            : TextSpan(text: part),
      );
      start = i;
    }
  }
  return spans;
}

/// A search result: who, when, and the message with its matches marked.
class SearchResultRow extends StatelessWidget {
  final ChatMessage message;
  final String query;
  final String? where;
  final VoidCallback onTap;
  const SearchResultRow({required this.message, required this.query, required this.onTap, this.where, super.key});

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
                      TextSpan(children: highlighted(text, query, tokens.accentText)),
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
      (groups[dayLabel(h.message.createdAt, DateTime.now())] ??= []).add(h);
    }
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
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
                            onTap: () => Navigator.of(context).pop(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                              child: Text('Cancel', style: DuvetType.label.copyWith(color: tokens.accentText)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _Toggle(
                          label: 'Has file',
                          on: _hasFile,
                          onTap: () {
                            setState(() => _hasFile = !_hasFile);
                            _run();
                          },
                        ),
                        const SizedBox(width: 8),
                        _Toggle(
                          label: 'Pinned',
                          on: _pinned,
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
                            onTap: _widen,
                            child: SizedBox(
                              height: 40,
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

/// A filter chip that turns on and off.
class _Toggle extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _Toggle({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? tokens.accentTint : colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            border: on ? Border.all(color: tokens.accentText) : null,
            boxShadow: on ? null : tokens.shadowRest,
          ),
          child: Text(
            label,
            style: DuvetType.snippet.copyWith(
              color: on ? tokens.accentText : colors.foreground,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
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
    final tokens = context.duvet;
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

    final results = <Widget>[
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
        if (_filter == _Filter.all) const Overline('Spaces'),
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
    ];

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
                constraints: BoxConstraints(maxHeight: screen.height * 0.7),
                child: Semantics(
                  label: 'Search results',
                  explicitChildNodes: true,
                  child: GlassSurface(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final (f, label) in const [
                                  (_Filter.all, 'All'),
                                  (_Filter.messages, 'Messages'),
                                  (_Filter.people, 'People'),
                                  (_Filter.spaces, 'Spaces'),
                                ]) ...[
                                  Semantics(
                                    button: true,
                                    selected: _filter == f,
                                    label: label,
                                    excludeSemantics: true,
                                    onTap: () => setState(() => _filter = f),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => setState(() => _filter = f),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        child: Text(
                                          label,
                                          style: DuvetType.label.copyWith(
                                            color: _filter == f ? tokens.accentText : colors.mutedForeground,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (f != _Filter.spaces) const SizedBox(width: 24),
                                ],
                              ],
                            ),
                          ),
                        ),
                        Flexible(
                          child: results.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    text.isEmpty
                                        ? 'Search messages, people and Spaces'
                                        : _searching
                                        ? 'Searching…'
                                        : 'Nothing found for “$text”',
                                    style: DuvetType.body.copyWith(color: colors.mutedForeground),
                                  ),
                                )
                              : ListView(
                                  shrinkWrap: true,
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

class _PersonResult extends StatelessWidget {
  final Member member;
  final String query;
  final VoidCallback onTap;
  const _PersonResult({required this.member, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Semantics(
      container: true,
      button: true,
      label: '${member.displayName}, @${member.username}',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              UserAvatar(name: member.displayName, url: member.avatarUrl, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(children: highlighted(member.displayName, query, tokens.accentText)),
                      style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                    ),
                    Text('@${member.username}', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
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
