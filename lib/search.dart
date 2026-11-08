import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'chat_view.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'people.dart' show PersonRow;
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

// ---------------------------------------------------------------------------
// The desktop's search syntax (MessageSearch.svelte): words, and filters such
// as `from:maya in:general has:image during:2026-11-08`.
// ---------------------------------------------------------------------------

const searchHas = ['link', 'embed', 'file', 'image', 'video', 'sound', 'sticker'];
final _filterWord = RegExp(r'^(from|mentions|in|has|pinned|before|after|during):(.*)$', caseSensitive: false);

/// A room's name as `in:`'s value: lower case, without spaces.
String roomSlug(String name) => name.toLowerCase().replaceAll(RegExp(r'\s+'), '-');

String _isoDay(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// A local day, `YYYY-MM-DD`, or null.
DateTime? _parseDay(String value) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(value);
  if (m == null) return null;
  final month = int.parse(m[2]!);
  final d = DateTime(int.parse(m[1]!), month, int.parse(m[3]!));
  return d.month == month ? d : null;
}

/// [input] as a search in [spaceId] or [conversationId]. `from:` and
/// `mentions:` name one of [members], `in:` one of [rooms]; as on the desktop,
/// `after:` leaves its day out and `during:` is that day. A leading `@` or `#`
/// is fine. Throws a [FormatException] saying what's wrong.
SearchQuery parseSearch(
  String input, {
  required List<Member> members,
  List<Room> rooms = const [],
  String? spaceId,
  String? conversationId,
  DateTime? now,
}) {
  final words = <String>[];
  final roomIds = <String>[], authorIds = <String>[], mentionIds = <String>[], has = <String>[];
  bool? pinned;
  DateTime? before, after;
  for (final part in input.split(RegExp(r'\s+')).where((p) => p.isNotEmpty)) {
    final m = _filterWord.firstMatch(part);
    if (m == null) {
      words.add(part);
      continue;
    }
    final key = m[1]!.toLowerCase();
    final named = m[2]!.replaceFirst(RegExp(r'^[@#]'), '');
    final value = named.toLowerCase();
    if (value.isEmpty) continue;
    switch (key) {
      case 'from' || 'mentions':
        final member =
            members.where((u) => u.username.toLowerCase() == value).firstOrNull ??
            members.where((u) => u.displayName.toLowerCase() == value).firstOrNull;
        if (member == null) throw FormatException('No member is called $named');
        (key == 'from' ? authorIds : mentionIds).add(member.userId);
      case 'in':
        final room = rooms.where((r) => roomSlug(r.name) == value).firstOrNull;
        if (room == null) throw FormatException('No room is called $named');
        roomIds.add(room.id);
      case 'has':
        if (!searchHas.contains(value)) throw FormatException('has: takes ${searchHas.join(', ')}');
        has.add(value);
      case 'pinned':
        if (value != 'true' && value != 'false') throw const FormatException('pinned: takes true or false');
        pinned = value == 'true';
      default:
        final day = _parseDay(value);
        if (day == null) throw FormatException('$key: takes a date like ${_isoDay(now ?? DateTime.now())}');
        final next = DateTime(day.year, day.month, day.day + 1);
        switch (key) {
          case 'before':
            before = day;
          case 'after':
            after = next;
          default:
            after = day;
            before = next;
        }
    }
  }
  return SearchQuery(
    words.join(' '),
    spaceId: spaceId,
    conversationId: conversationId,
    roomIds: roomIds,
    authorIds: authorIds,
    mentionIds: mentionIds,
    has: has,
    pinned: pinned,
    before: before,
    after: after,
  );
}

/// What to put in place of the word being typed, [token].
typedef SearchSuggestion = ({String label, String? detail, String insert, Member? member, Room? room});

/// The desktop's suggestions for [token]: the filters, then the members, the
/// rooms or the values a filter takes. `pinned:` is left to a toggle, though
/// [parseSearch] still reads it.
List<SearchSuggestion> searchSuggestions(
  String token, {
  required List<Member> members,
  List<Room> rooms = const [],
  bool inSpace = false,
  DateTime? now,
}) {
  final today = _isoDay(now ?? DateTime.now());
  final m = RegExp(r'^(\w+):(\S*)$').firstMatch(token);
  if (m == null) {
    final typed = token.toLowerCase();
    return [
      for (final (key, detail) in [
        ('from', 'Messages by a member'),
        ('mentions', 'Messages that mention a member'),
        if (inSpace) ('in', 'Messages in a room'),
        ('has', 'link, embed, file, image, video, sound or sticker'),
        ('before', 'Messages before a date, like $today'),
        ('after', 'Messages after a date'),
        ('during', 'Messages on a date'),
      ])
        if (key.startsWith(typed)) (label: '$key:', detail: detail, insert: '$key:', member: null, room: null),
    ];
  }
  final key = m[1]!.toLowerCase();
  final value = m[2]!.replaceFirst(RegExp(r'^[@#]'), '').toLowerCase();
  return switch (key) {
    'from' || 'mentions' => [
      for (final u
          in members
              .where((u) => u.username.toLowerCase().startsWith(value) || u.displayName.toLowerCase().startsWith(value))
              .take(8))
        (
          label: u.displayName,
          detail: u.displayName == u.username ? null : u.username,
          insert: '$key:${u.username} ',
          member: u,
          room: null,
        ),
    ],
    'in' => [
      for (final r in rooms.where((r) => roomSlug(r.name).startsWith(value)).take(8))
        (label: '#${r.name}', detail: null, insert: 'in:${roomSlug(r.name)} ', member: null, room: r),
    ],
    'has' => [
      for (final v in searchHas)
        if (v.startsWith(value)) (label: v, detail: null, insert: 'has:$v ', member: null, room: null),
    ],
    'before' || 'after' || 'during' when today.startsWith(value) => [
      (label: today, detail: 'Today', insert: '$key:$today ', member: null, room: null),
    ],
    _ => const [],
  };
}

/// Searching a Space, or a conversation: a field with the desktop's filters
/// and their suggestions in the top bar, results by day, how many in all, and
/// more pages. Answers the result picked.
class InChatSearch extends StatefulWidget {
  final ChatTarget target;
  final String title;
  const InChatSearch({required this.target, required this.title, super.key});

  @override
  State<InChatSearch> createState() => _InChatSearchState();
}

class _InChatSearchState extends State<InChatSearch> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  bool _pinnedOnly = false;
  List<Member> _members = const [];
  SearchQuery? _shown;
  List<SearchHit>? _hits;
  int _total = 0;
  String? _failure;
  bool _loading = false;
  int _request = 0;

  bool _askedMembers = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_askedMembers) return;
    _askedMembers = true;
    // Whom from: and mentions: name; a search typed before they come runs again.
    context.repository.members(widget.target).then((m) {
      if (!mounted) return;
      setState(() => _members = m);
      if (_query.text.trim().isNotEmpty) _run();
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _lastText = '';

  void _changed() {
    setState(() {}); // the suggestions follow the caret
    if (_query.text == _lastText) return;
    _lastText = _query.text;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _run);
  }

  String? get _spaceId => switch (widget.target) {
    RoomTarget(:final spaceId) => spaceId,
    _ => null,
  };

  // The text rooms one can see: what in: names.
  List<Room> get _rooms {
    final spaceId = _spaceId;
    if (spaceId == null) return const [];
    final repository = context.repository;
    return [
      for (final r in repository.spaces.value.where((s) => s.id == spaceId).expand((s) => s.rooms))
        if (r.kind == RoomKind.text && repository.canInRoom(spaceId, r.id, Perm.viewChannels)) r,
    ];
  }

  Future<void> _run({bool more = false}) async {
    final SearchQuery query;
    if (more) {
      final last = _hits?.lastOrNull;
      if (_shown == null || last == null) return;
      query = _shown!.from(last.message.id);
    } else {
      final target = widget.target;
      try {
        query = parseSearch(
          // The Pinned toggle, as the desktop's `pinned:true`.
          _pinnedOnly ? '${_query.text} pinned:true' : _query.text,
          members: _members,
          rooms: _rooms,
          spaceId: _spaceId,
          conversationId: target is ConversationTarget ? target.conversationId : null,
        );
      } on FormatException catch (e) {
        ++_request;
        setState(() {
          _shown = null;
          _hits = const [];
          _total = 0;
          _failure = e.message;
          _loading = false;
        });
        return;
      }
      if (query.isEmpty) {
        ++_request;
        setState(() {
          _shown = null;
          _hits = null;
          _failure = null;
          _loading = false;
        });
        return;
      }
    }
    final request = ++_request;
    setState(() {
      _loading = true;
      _failure = null;
      if (!more) _shown = query;
    });
    try {
      final page = await context.repository.search(query);
      if (!mounted || request != _request) return;
      setState(() {
        _hits = more ? [...?_hits, ...page.hits] : page.hits;
        _total = page.total;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        if (!more) _hits = const [];
        _failure = 'The search failed';
      });
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  // The word the caret is in: where it starts, and its text up to the caret.
  ({int start, String value}) get _token {
    final text = _query.text;
    final at = _query.selection.isValid ? _query.selection.baseOffset.clamp(0, text.length) : text.length;
    final before = text.substring(0, at);
    final start = before.lastIndexOf(RegExp(r'\s')) + 1;
    return (start: start, value: before.substring(start));
  }

  // Puts [s] in place of the word the caret is in, as the desktop does. A
  // date filter asks for its day with a date picker.
  Future<void> _apply(SearchSuggestion s) async {
    if (const ['before:', 'after:', 'during:'].contains(s.insert)) {
      final now = DateTime.now();
      final day = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(2020),
        lastDate: now,
        helpText: switch (s.insert) {
          'before:' => 'Messages before',
          'after:' => 'Messages after',
          _ => 'Messages on',
        },
      );
      if (day == null || !mounted) return;
      s = (label: s.label, detail: null, insert: '${s.insert}${_isoDay(day)} ', member: null, room: null);
    }
    final text = _query.text;
    final token = _token;
    final end = token.start + token.value.length;
    var rest = text.substring(end).replaceFirst(RegExp(r'^\S*'), '');
    if (s.insert.endsWith(' ')) rest = rest.replaceFirst(RegExp(r'^ '), '');
    final at = token.start + s.insert.length;
    _query.value = TextEditingValue(
      text: text.substring(0, token.start) + s.insert + rest,
      selection: TextSelection.collapsed(offset: at),
    );
    _focus.requestFocus();
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
    final inSpace = _spaceId != null;
    final where = inSpace ? (_spaceName ?? 'this Space') : widget.title;
    final suggestions = searchSuggestions(_token.value, members: _members, rooms: _rooms, inSpace: inSpace);
    // Members and rooms come as a list under the bar, over the results: chips are for the short values.
    final listed = suggestions.where((s) => s.member != null || s.room != null).toList();
    final words = _shown?.text ?? '';
    final count = _total >= 1000 ? '1,000+ results' : (_total == 1 ? '1 result' : '$_total results');
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
                if (listed.isNotEmpty)
                  for (final s in listed)
                    if (s.member case final m?)
                      ListRow(
                        leading: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 40),
                        title: m.displayName,
                        snippet: '@${m.username}',
                        onTap: () => _apply(s),
                      )
                    else
                      ListRow(title: s.room!.name, hash: true, onTap: () => _apply(s))
                else if (_loading && (hits == null || hits.isEmpty))
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: FCircularProgress()),
                  )
                else if (hits != null && hits.isEmpty)
                  ListNote(_failure ?? 'Nothing found in $where')
                else ...[
                  for (final MapEntry(key: day, value: list) in groups.entries) ...[
                    Overline(day),
                    for (final h in list)
                      SearchResultRow(
                        message: h.message,
                        query: words,
                        where: inSpace ? _roomName(h.target) : null,
                        onTap: () => Navigator.of(context).pop(h),
                      ),
                  ],
                  if (hits != null && _failure != null) ListNote(_failure!),
                  if (hits != null && hits.length < _total)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _loading
                          ? const Center(child: FCircularProgress())
                          : FButton(onPress: () => _run(more: true), child: const Text('More results')),
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
                            focusNode: _focus,
                            autofocus: true,
                            hint: 'Search ${inSpace ? where : widget.title.replaceFirst('# ', '')}',
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
                    // The desktop's suggestions, as chips: a tap puts one in place of the word typed.
                    SizedBox(
                      height: 32,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _Chip(
                              label: 'Pinned',
                              on: _pinnedOnly,
                              onTap: () {
                                setState(() => _pinnedOnly = !_pinnedOnly);
                                _run();
                              },
                            ),
                          ),
                          for (final s in suggestions)
                            if (listed.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _Chip(label: s.label, hint: s.detail, onTap: () => _apply(s)),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (hits != null && hits.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GlassChrome(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + padding.bottom),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      '$count in $where',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A suggestion chip, or with [on] a toggle; [hint] says what it does, for a
/// screen reader.
class _Chip extends StatelessWidget {
  final String label;
  final String? hint;
  final bool? on;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.onTap, this.hint, this.on});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      label: label,
      hint: hint,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on == true ? tokens.selectedFill : colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            boxShadow: on == true ? null : tokens.shadowRest,
          ),
          child: Text(
            label,
            style: DuvetType.snippet.copyWith(
              color: on == true ? tokens.violetText : colors.foreground,
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
    await Future.wait([
      for (final q in queries) repository.search(q).then((p) => found.addAll(p.hits), onError: (_) {}),
    ]);
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
