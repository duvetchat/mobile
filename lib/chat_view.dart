import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:clock/clock.dart' as time show clock;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'calls.dart';
import 'data/appearance.dart' show AppearanceScope, MessageLayout, ReplyGesture, ownBubble;
import 'data/call_notices.dart';
import 'data/images.dart';
import 'data/emoji_catalog.dart';
import 'data/launchpad.dart' show LaunchpadScope, SpaceSort, sortedSpaces;
import 'data/links.dart';
import 'data/markdown.dart' show parseLine, plainInline;
import 'data/message_tokens.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart' show VoiceController;
import 'data/gifs.dart' show GifSource;
import 'e2e/conventions.dart' show waveformSamples;
import 'e2e/decrypted_files.dart';
import 'e2e/files.dart' show gifFile, sealedSize, tooLargeToSend;
import 'e2e/host.dart' show CoreError;
import 'e2e/notices.dart';
import 'e2e/uuid.dart';
import 'encryption/conversation_start.dart';
import 'encryption/conversation_state.dart';
import 'encryption/share_history.dart';
import 'members_sheet.dart';
import 'people.dart';
import 'search.dart';
import 'space_admin.dart' show askDescription, askName, confirmDestructive, RoomPermissionsPage;
import 'spaces.dart' show showInviteSheet;
import 'tabs.dart' show SpaceDirectory;
import 'theme.dart';
import 'voice_room.dart' show openVoiceRoom;
import 'widgets/avatar.dart';
import 'widgets/bot_ui.dart';
import 'widgets/chrome.dart';
import 'widgets/duvet_mascot.dart';
import 'widgets/ghost_art.dart';
import 'widgets/disintegrate.dart';
import 'widgets/composer_controller.dart';
import 'widgets/depth.dart';
import 'widgets/emoji_picker.dart';
import 'widgets/glass.dart';
import 'widgets/link_embeds.dart';
import 'widgets/media.dart';
import 'widgets/sealed_file.dart';
import 'widgets/message_content.dart';
import 'widgets/prism.dart';
import 'widgets/role_name.dart';
import 'shell.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart';
import 'widgets/skeleton.dart';

part 'chat/actions.dart';
part 'chat/bubble.dart';
part 'chat/composer.dart';
part 'chat/reactors.dart';

/// Opens the Chat View: over everything, the tab bar included, or in the wide layout's pane.
void openChat(BuildContext context, ChatTarget target, String title, {String? jumpTo}) =>
    openChatRoute(context, ChatRoute(target: target, title: title, jumpTo: jumpTo));

/// The same for a route already made. Outside the app's shell (a widget pumped alone), over everything.
void openChatRoute(BuildContext context, ChatRoute route, {bool reveal = true}) {
  final shell = Shell.maybeOf(context);
  if (shell == null) {
    Navigator.of(context, rootNavigator: true).push(route);
  } else {
    shell.open(route, reveal: reveal);
  }
}

/// A Chat View's route. Its page keeps its state when the route moves between the pane and the whole screen.
class ChatRoute extends MaterialPageRoute<void> with PaneRoute<void> {
  final ChatTarget target;
  final String title;
  final String? jumpTo;
  final String? threadOf;
  final GlobalKey _page;

  ChatRoute({required this.target, required this.title, this.jumpTo, this.threadOf, GlobalKey? page})
    : _page = page ?? GlobalKey(),
      super(builder: _none);

  static Widget _none(BuildContext context) => const SizedBox.shrink();

  @override
  Widget buildContent(BuildContext context) => SafeSides(
    child: ChatView(key: _page, target: target, title: title, jumpTo: jumpTo, threadOf: threadOf),
  );

  @override
  String get paneId => target.id;

  @override
  ChatRoute moved() => ChatRoute(target: target, title: title, jumpTo: jumpTo, threadOf: threadOf, page: _page);

  @override
  bool same(PaneRoute<Object?> other) =>
      other is ChatRoute && other.target == target && threadOf == null && other.threadOf == null;

  // The message [other] opens at, shown in this chat as it is when it's in view or near it.
  @override
  bool reopen(PaneRoute<Object?> other) => switch ((other, _page.currentState)) {
    (ChatRoute(jumpTo: null), _) => true,
    (ChatRoute(:final jumpTo?), final _ChatViewState chat) => chat._showNear(jumpTo),
    _ => false,
  };
}

enum _Delivery { sent, sending, failed }

typedef _Entry = ({ChatMessage message, _Delivery delivery});

/// What a pending message carries, kept to send it again.
typedef _Outgoing = ({
  String content,
  List<OutgoingFile> files,
  Sticker? sticker,
  String? replyTo,
  bool? mentionReplied,
  Recording? voice,
  // A voice note's 64 peaks, an encrypted conversation's voice note's convention: kept for its Retry too.
  List<int>? waveform,
});

/// How many files one message takes.
const maxFiles = 10;

/// Picks pictures to attach.
typedef MediaPicker = Future<List<OutgoingFile>> Function(ImageSource source);

class ChatView extends StatefulWidget {
  final ChatTarget target;
  final String title;

  /// Tests pass their own; the app uses the system's photo picker and camera.
  final MediaPicker? pickMedia;

  /// A message to open at, e.g. from a link to it.
  final String? jumpTo;

  /// A thread: this message's reply chain alone, the composer replying in it.
  final String? threadOf;

  const ChatView({required this.target, required this.title, this.pickMedia, this.jumpTo, this.threadOf, super.key});

  /// Stands in for the system picker in chats [openChat] opens, in tests.
  @visibleForTesting
  static MediaPicker? debugPickMedia;

  /// Stands in for the system file picker, in tests.
  @visibleForTesting
  static Future<List<OutgoingFile>> Function()? debugPickFiles;

  /// Off, a message has no [RepaintBoundary] of its own: what
  /// `test/benchmark/message_boundary.dart` measures it against.
  @visibleForTesting
  static bool debugMessageBoundary = true;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> with SingleTickerProviderStateMixin {
  static const _pageSize = 100;
  // As the desktop: a notice every 3 s while typing, shown for 5 s.
  static const _typingFor = Duration(seconds: 5);
  static const _typingEvery = Duration(seconds: 3);

  late final _composer = ComposerController(accent: () => context.duvet.accentText);
  final _scroll = ScrollController();
  final _random = Random();
  late final _focus = FocusNode(onKeyEvent: _composerKey);

  late final ChatRepository _repository;
  StreamSubscription<MessageEvent>? _events;
  StreamSubscription<TypingUser>? _typingSub;
  StreamSubscription<void>? _resumedSub;

  // The oldest first.
  List<_Entry> _entries = [];
  bool _loading = true;
  Object? _error;
  bool _loadingOlder = false;
  bool _hasOlder = false;
  // The kept page's messages while it shows in place of the latest, and
  // where it was placed.
  Set<String>? _kept;
  double? _keptAt;
  // Until the kept page is looked for (a moment on the device) nothing
  // shows: not a frame of the skeleton before it.
  bool _lookedForKept = false;
  // The list fading in when the latest replaces a kept page it has nothing in common with.
  late final AnimationController _reveal;

  final _typing = <String, ({String name, bool recording, Timer expiry})>{};
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  // Who can be mentioned, the space's emoji and stickers, the Unicode set.
  List<Member> _members = const [];
  List<CustomEmoji> _customEmojis = const [];
  late final Future<List<Sticker>> _stickers;
  List<Sticker> _stickerList = const [];
  EmojiCatalog? _catalog;

  // Picked, not sent yet; and what each pending message carries, how far
  // its upload is, and how to stop it.
  final _files = <OutgoingFile>[];
  final _outgoing = <String, _Outgoing>{};
  final _progress = <String, double>{};
  final _cancels = <String, Completer<void>>{};
  final _tooLarge = <String>{};
  ComposerQuery? _query;

  /// The Space's bots' commands, and the one being typed (`/po`: `po`).
  List<BotCommand> _commands = const [];
  String? _slash;

  // What the composer is doing besides a new message: answering one, or
  // editing one of the user's own.
  MessageReply? _replyTo;
  ChatMessage? _editing;

  // The last message read when the chat opened: the "N new messages" divider
  // goes after it. Or, as the desktop places one later in the visit, the last
  // one seen when someone else's came while the reader was up the list, or
  // away from the chat.
  String? _unreadAfter;
  // When that one wasn't loaded on opening (further back than the first page,
  // or deleted), the first message loaded after it, as the desktop does: the
  // divider goes above it, and stays there for the visit, older pages coming
  // or not.
  String? _unreadFrom;
  final _dividerKey = GlobalKey();
  // One placed while away from the chat at its bottom is brought into view
  // once back, as the desktop does.
  bool _showDividerOnReturn = false;
  final _keys = <String, GlobalKey>{};

  /// Messages being deleted, gone to dust: their place stays a moment,
  /// then [_closing] it closes up.
  final _vanishing = <String>{};
  final _closing = <String>{};

  /// Messages the user deleted, from the confirming to the list closing up.
  final _deleting = <String>{};
  String? _flash;

  // The chat is read where the reader sees its newest messages, as the desktop
  // acks it: with the app in front and this chat on top, at the bottom of the
  // list. Opening it isn't reading it: one opened at its "New messages"
  // divider is read once the reader scrolls down. The newest message read
  // from here is acked once.
  bool _atBottom = true;
  bool _onTop = true;
  String? _acked;
  // The unread mentions of the user: each one's light comes up once, as its
  // bubble first comes all into sight. How many the chat had on opening, until
  // its page comes and tells which they are; then the ones yet to shine.
  int _unreadMentions = 0;
  final _unshone = <String>{};
  // Shone already, this visit or an earlier one: a chat left unread and opened
  // again doesn't shine them twice.
  static final _shone = <String>{};
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: DuvetTokens.panelOut, value: 1);
    EmojiCatalog.load().then((c) {
      if (mounted) setState(() => _catalog = c);
    }, onError: (Object e) => debugPrint('emoji: $e'));
    _lifecycle = AppLifecycleListener(
      onResume: _back,
      onStateChange: (_) {
        if (_events != null) _reportScreen(opened: false);
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Back on top (a thread or a chat opened over this one was closed): what
    // came meanwhile is read, at the bottom, once this build is done.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (onTop != _onTop) {
      _onTop = onTop;
      if (onTop) WidgetsBinding.instance.addPostFrameCallback((_) => _back());
      if (_events != null) _reportScreenAfterBuild();
    }
    if (_events != null) return;
    _repository = context.repository;
    _reportScreenAfterBuild();
    // Listen before loading, so nothing sent meanwhile is missed.
    _events = _repository.messageEvents(widget.target).listen(_onEvent);
    _typingSub = _repository.typing(widget.target).listen(_onTyping);
    _resumedSub = _repository.resumed.listen((_) => _catchUp());
    if (widget.threadOf == null && _repository.unread.value.contains(widget.target.id)) {
      _unreadAfter = _repository.lastReadOf(widget.target);
    }
    // Before reading the chat takes the count away. A thread has none of its own.
    if (widget.threadOf == null) _unreadMentions = _repository.mentions.value[widget.target.id] ?? 0;
    _restoreDraft();
    _composer.addListener(_onComposerChanged);
    _scroll.addListener(_onScroll);
    _voice = context.voice..addListener(_onVoice);
    _load();
    _loadDirectory();
  }

  // On top with the app in front, the chat is on screen: its mentions show no
  // notice at the top. A sheet over it takes the top too: one shows then.
  void _reportScreen({bool gone = false, bool opened = true}) => !gone && _onTop && _inFront
      ? _repository.chatShown(widget.target, threadOf: widget.threadOf, opened: opened)
      : _repository.chatHidden(widget.target, threadOf: widget.threadOf);

  // Once built: being shown takes the chat's notices away, which rebuilds
  // them.
  void _reportScreenAfterBuild() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _reportScreen();
  });

  @override
  void dispose() {
    if (_events != null) _reportScreen(gone: true);
    _saveDraft();
    _voice?.removeListener(_onVoice);
    _recordTick?.cancel();
    _levelsSub?.cancel();
    _recorder?.cancel();
    for (final c in _cancels.values) {
      if (!c.isCompleted) c.complete();
    }
    _lifecycle.dispose();
    _events?.cancel();
    _typingSub?.cancel();
    _resumedSub?.cancel();
    for (final t in _typing.values) {
      t.expiry.cancel();
    }
    _composer.dispose();
    _scroll.dispose();
    _focus.dispose();
    _reveal.dispose();
    super.dispose();
  }

  String? get _me => _repository.profile.value?.id;

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  String get _draftKey => widget.threadOf == null ? widget.target.id : 'thread:${widget.threadOf}';

  void _restoreDraft() {
    final draft = _repository.drafts[_draftKey];
    if (draft == null) return;
    _composer.restore(draft.text, mentions: draft.mentions, emojis: draft.emojis, rooms: draft.rooms);
    _files.addAll(draft.files);
    _replyTo = draft.replyTo;
  }

  void _saveDraft() {
    // An edit isn't a draft: leaving drops it.
    final text = _editing == null ? _composer.text : '';
    final picked = _composer.picked;
    final draft = ChatDraft(
      text: text,
      mentions: picked.mentions,
      emojis: picked.emojis,
      rooms: picked.rooms,
      files: [..._files],
      replyTo: _replyTo,
    );
    if (draft.isEmpty) {
      _repository.drafts.remove(_draftKey);
    } else {
      _repository.drafts[_draftKey] = draft;
    }
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  // Names for mentions, the emoji for `<:id:>`: best effort, the chat works
  // without them.
  void _loadDirectory() {
    _repository.members(widget.target).then((m) {
      if (mounted) setState(() => _members = m);
    }, onError: (Object e) => debugPrint('members: $e'));
    _repository.customEmojis().then((e) {
      if (mounted) setState(() => _customEmojis = e);
    }, onError: (Object e) => debugPrint('emojis: $e'));
    if (widget.target case RoomTarget(:final spaceId)) {
      _repository.commands(spaceId).then((c) {
        if (mounted) setState(() => _commands = c);
      }, onError: (Object e) => debugPrint('commands: $e'));
    }
    _stickers = _repository.stickers();
    _stickers.then((s) {
      if (mounted) setState(() => _stickerList = s);
    }, onError: (Object e) => debugPrint('stickers: $e'));
  }

  MessageDirectory get _directory {
    final names = {for (final m in _members) m.userId: m.displayName};
    final emojis = {for (final e in _customEmojis) e.id: e};
    final rooms = {for (final r in _repository.spaces.value.expand((s) => s.rooms)) r.id: r};
    return MessageDirectory(
      me: _me,
      nameOf: (id) => names[id] ?? _repository.nameOf(id),
      emojiOf: (id) => emojis[id],
      emojiUrl: _repository.emojiUrl,
      roomOf: (id) => rooms[id],
      nameColorsOf: switch (widget.target) {
        RoomTarget(:final spaceId) => (id) => nameColorsOf(_repository.rolesOf(spaceId, id)),
        ConversationTarget() => (_) => null,
      },
    );
  }

  /// What an encrypted conversation's start says (PLAN-E2E-CLIENTES.md, «La vista de una conversación»): null when it
  /// says nothing, a room's always.
  Widget? get _start {
    final start = _repository.chatStart(widget.target);
    if (!(start.legacy && start.cutoverAt != null) && !start.beforeJoining) return null;
    return ConversationStart(legacy: start.legacy, cutoverAt: start.cutoverAt, beforeJoining: start.beforeJoining);
  }

  /// The chat's Space; none in a DM or a group.
  String? get _spaceId => switch (widget.target) {
    RoomTarget(:final spaceId) => spaceId,
    ConversationTarget() => null,
  };

  /// The user's Spaces as their Spaces tab lists them: the pickers group emojis and stickers in that order.
  List<Space> get _spacesListed => sortedSpaces(
    _repository.spaces.value,
    context.getInheritedWidgetOfExactType<LaunchpadScope>()?.notifier?.value.sort ?? SpaceSort.gateway,
  );

  Future<void> _load() async {
    // The page kept on the device shows meanwhile; a thread's or a jump's
    // place isn't on it.
    final lookForKept = widget.threadOf == null && widget.jumpTo == null && _kept == null;
    setState(() {
      _loading = true;
      _error = null;
      if (!lookForKept) _lookedForKept = true;
    });
    if (lookForKept) {
      _repository
          .cachedMessages(widget.target)
          .then(
            _showKept,
            onError: (Object e) {
              debugPrint('kept: $e');
              _showKept(null);
            },
          );
    }
    try {
      final thread = widget.threadOf;
      final page = thread == null
          ? await _repository.messages(widget.target)
          : await _repository.thread(widget.target, thread);
      if (!mounted) return;
      final loaded = {for (final m in page) m.id};
      final kept = _kept ?? const {};
      // Not one message in common: the kept page is from before all of these,
      // with a gap between that older pages would skip. It goes, faded over.
      if (kept.isNotEmpty && !loaded.any(kept.contains) && !MediaQuery.disableAnimationsOf(context)) {
        _reveal.forward(from: 0);
      }
      // Where the kept page was placed: if the reader has scrolled since,
      // the fetched one isn't placed again.
      final moved = _keptAt != null && _scroll.hasClients && _scroll.offset != _keptAt;
      // Keep what the gateway pushed while the page loaded. What was kept
      // and isn't on the page anymore (deleted, or older than it) goes.
      final pushed = [
        for (final e in _entries)
          if (!loaded.contains(e.message.id) && !kept.contains(e.message.id)) e,
      ];
      final shown = {...loaded, for (final e in pushed) e.message.id};
      // The bots' answers to the user alone, which no history has, show among
      // the room's messages, by time.
      final ephemeral = [
        for (final m in thread == null ? _repository.ephemeralIn(widget.target) : const <ChatMessage>[])
          if (!shown.contains(m.id)) m,
      ];
      setState(() {
        _entries = [
          for (final m in _byTime(page, ephemeral))
            (message: m, delivery: m.pending ? _Delivery.failed : _Delivery.sent),
          ...pushed,
        ];
        _hasOlder = thread == null && (page.length >= _pageSize || _olderBeyond(page));
        _loading = false;
        _kept = null;
        // shortcut: this page's only, an unread mention further back doesn't
        // shine; count on through the older pages if it should.
        _unshone.addAll(unreadMentions(_entries.map((e) => e.message), _me, _unreadMentions).difference(_shone));
        _unreadMentions = 0;
        // Nothing after the last read: no divider.
        if (_unreadAfter != null && page.lastOrNull?.id == _unreadAfter) _unreadAfter = null;
        // The last read not loaded: the first message after it is, as message
        // IDs (UUIDv7s) order by time.
        final after = _unreadAfter;
        if (after != null && !_entries.any((e) => e.message.id == after)) {
          _unreadFrom = _entries.map((e) => e.message.id).where((id) => id.compareTo(after) > 0).firstOrNull;
          if (_unreadFrom == null) _unreadAfter = null;
        }
      });
      if (thread == null) _repository.opened(widget.target, widget.title, latest: page.lastOrNull);
      // Opening reads the chat only if the list is still at its bottom once
      // it's placed (at a jump's message, or at the divider); otherwise
      // scrolling down reads it.
      if (widget.jumpTo case final id?) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(id).whenComplete(_readIfSeen));
      } else if (_unreadAfter != null && !moved) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showDivider().whenComplete(_readIfSeen));
      } else {
        _readIfSeen();
      }
    } catch (e) {
      // Listed even when its history fails to load.
      _repository.opened(widget.target, widget.title);
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  /// The chat's page as it was last seen here, while its latest loads (or
  /// failed to): under what the gateway pushed meanwhile, with no older pages
  /// from it, as it may be far behind, and nothing read from it.
  void _showKept(List<ChatMessage>? page) {
    if (!mounted) return;
    if (page == null || page.isEmpty || !(_loading || _error != null)) {
      if (!_lookedForKept) setState(() => _lookedForKept = true);
      return;
    }
    final ids = {for (final m in page) m.id};
    final ephemeral = [
      for (final m in _repository.ephemeralIn(widget.target))
        if (!ids.contains(m.id)) m,
    ];
    setState(() {
      _entries = [
        for (final m in _byTime(page, ephemeral)) (message: m, delivery: _Delivery.sent),
        for (final e in _entries)
          if (!ids.contains(e.message.id)) e,
      ];
      _kept = {...ids, for (final m in ephemeral) m.id};
      _lookedForKept = true;
    });
    // At the divider, if it shows here, as a load places it; else at the bottom.
    final last = page.indexWhere((m) => m.id == _unreadAfter);
    if (last < 0 || last == page.length - 1) {
      _keptAt = 0;
    } else {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showDivider().whenComplete(() {
          if (mounted && _scroll.hasClients) _keptAt = _scroll.offset;
        }),
      );
    }
  }

  /// [list] (the oldest first) with [more] put in by time, after those as old.
  static List<ChatMessage> _byTime(List<ChatMessage> list, List<ChatMessage> more) {
    final all = [...list];
    for (final m in more) {
      var i = all.length;
      while (i > 0 && all[i - 1].createdAt.isAfter(m.createdAt)) {
        i--;
      }
      all.insert(i, m);
    }
    return all;
  }

  /// The room's own messages that were sent, the oldest first: what paging,
  /// catching up and reading go by. An ephemeral one isn't the room's.
  Iterable<ChatMessage> get _history => [
    for (final e in _entries)
      if (e.delivery == _Delivery.sent && !e.message.isEphemeral) e.message,
  ];

  /// Brings the "N new messages" divider into view, near the top.
  Future<void> _showDivider() async {
    if (!mounted || !_entries.any((e) => e.message.id == (_unreadFrom ?? _unreadAfter))) return;
    if (await _scrollUntilBuilt(() => _dividerKey.currentContext)) {
      final ctx = _dividerKey.currentContext;
      if (ctx != null && ctx.mounted) await Scrollable.ensureVisible(ctx, alignment: 0.15);
    }
  }

  /// The older page on its way. Asked again meanwhile (a jump paging back
  /// while scrolling near the top already asked), it waits for that one.
  Future<void>? _olderPage;

  Future<void> _loadOlder() => _olderPage ??= _fetchOlder().whenComplete(() => _olderPage = null);

  /// A short page with more behind it: a conversation's, whose rows from before the user joined gave way, read a few of
  /// the API's pages at a time (M7 of task 17's review).
  bool _olderBeyond(List<ChatMessage> page) => page.isNotEmpty && _repository.olderBeyond(widget.target, page.first.id);

  Future<void> _fetchOlder() async {
    final oldest = _history.firstOrNull;
    if (_loadingOlder || !_hasOlder || oldest == null) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await _repository.messages(widget.target, before: oldest.id);
      if (!mounted) return;
      final known = {for (final e in _entries) e.message.id};
      setState(() {
        _entries = [
          for (final m in page)
            if (!known.contains(m.id)) (message: m, delivery: _Delivery.sent),
          ..._entries,
        ];
        _hasOlder = page.length >= _pageSize || _olderBeyond(page);
      });
    } catch (_) {
      // Scrolling up again retries.
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// A member of the chat, by the name the app shows them.
  String _memberName(String userId) =>
      _members.where((m) => m.userId == userId).firstOrNull?.displayName ?? _repository.nameOf(userId) ?? 'Someone';

  /// A history share's notice in parts, its names apart: who shared how far back with whom, «You» and «you» for the
  /// reader.
  List<({String text, String? name})> _sharedParts(ChatMessage m, SharedHistoryNotice shared) {
    final a = m.authorId != null && m.authorId == _me ? 'You' : m.authorName;
    final range = rangeText(shared.range);
    if (shared.toUserId == _me) return Notice.sharedWithYou.parts({'a': a, 'range': range});
    return Notice.shared.parts({'a': a, 'range': range, 'b': _memberName(shared.toUserId)});
  }

  /// Whom a restart leaves out, by name: those the API no longer lists, so not among the chat's members. A name the
  /// app doesn't know comes from their profile, else it's their ID, never «Someone» (I2 of the review).
  Future<String> _leftOutName(String userId) async {
    if (_members.where((m) => m.userId == userId).firstOrNull?.displayName ?? _repository.nameOf(userId)
        case final known?) {
      return known;
    }
    try {
      return (await _repository.user(userId)).displayName;
    } catch (_) {
      return userId;
    }
  }

  /// The person's Restart encryption: whom it leaves out, they say yes to first (the core's #46), asked again when
  /// those changed meanwhile. A restart the core or the API refuses says so (M1).
  Future<void> _restart(String conversationId) async {
    var leaving = const <String>[];
    while (true) {
      final List<String> out;
      try {
        out = await _repository.restartGroup(conversationId, leaving: leaving);
      } on CoreError catch (error) {
        if (error.code != 'rule_violation') rethrow;
        if (mounted) _toast(Notice.restartRefused.text);
        return;
      }
      if (out.isEmpty || !mounted) return;
      final names = [for (final user in out) await _leftOutName(user)];
      if (!mounted || !await confirmRestart(context, peopleNamed(names))) return;
      leaving = out;
    }
  }

  /// What came while the socket was down: everything after the newest
  /// message here.
  Future<void> _catchUp() async {
    // Still on the kept page: its latest is on the way, or is asked again.
    // shortcut: only the gateway coming back asks again; a failed fetch with the socket up stays on the kept page
    // (no reads, no older pages) until the chat is reopened. Upgrade to a retry on a timer or a pull if that's seen.
    if (_kept != null) {
      if (!_loading) _load();
      return;
    }
    final newest = _history.lastOrNull;
    if (newest == null) return;
    try {
      final missed = await _repository.messagesAfter(widget.target, newest.id);
      if (!mounted || missed.isEmpty) return;
      setState(() {
        for (final m in missed) {
          _markUnreadFrom(m);
          _upsert(m);
        }
      });
      _readIfSeen();
    } catch (e) {
      debugPrint('catch up: $e');
    }
  }

  // The list is reversed: its end is the top, the oldest messages, and its
  // start the bottom, within 50 points of which (as on the desktop) the
  // newest are in view.
  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < 400) _loadOlder();
    final atBottom = position.pixels <= 50;
    if (atBottom == _atBottom) return;
    setState(() => _atBottom = atBottom);
    if (atBottom) _readIfSeen();
  }

  /// Back to the newest messages, from however far up.
  void _toLatest() {
    if (!_scroll.hasClients) return;
    MediaQuery.disableAnimationsOf(context)
        ? _scroll.jumpTo(0)
        : _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: DuvetTokens.decelerate);
  }

  /// Reads the chat up to its newest message.
  void _markRead() {
    final newest = _history.lastOrNull;
    // A kept page's newest may not be the chat's: the latest page reads it.
    if (newest == null || newest.id == _acked || _kept != null) return;
    _acked = newest.id;
    _repository.markRead(widget.target, newest.id);
  }

  /// Reads the chat if the reader sees its newest messages: the app in front,
  /// nothing opened over the chat (not a thread), and the bottom of the list.
  void _readIfSeen() {
    if (!mounted || widget.threadOf != null || !_onTop || !_inFront || !_atBottom) return;
    _markRead();
  }

  /// Back at the chat: read, as it was left at its bottom, and the divider
  /// placed meanwhile, if any, brought into view.
  void _back() {
    _readIfSeen();
    if (!_showDividerOnReturn) return;
    _showDividerOnReturn = false;
    // Not before a frame: none ran while the app was behind, so the divider isn't built yet.
    WidgetsBinding.instance.endOfFrame.then((_) => _showDivider());
  }

  static bool get _inFront => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  void _onEvent(MessageEvent event) {
    if (event is ContentChanged) {
      if (widget.target is ConversationTarget) {
        // A share came in where rows from before the user joined gave way: its pages are read again, which draws what
        // it brought (Ruling 15; I3 of task 31's review). Otherwise the rows shown are read again.
        if (event.imported && widget.threadOf == null && _repository.chatStart(widget.target).beforeJoining) {
          unawaited(_load());
        } else {
          unawaited(_readAgain());
        }
      }
      return;
    }
    if (event case ReactionChanged(:final messageId) when !_entries.any((e) => e.message.id == messageId)) return;
    // A profile change that shows nothing new on the messages here.
    if (event is AuthorChanged && _entries.every((e) => identical(e.message.changedBy(event), e.message))) return;
    if (event case AttachmentRenewed(
      :final attachmentId,
      :final url,
    ) when _entries.every((e) => identical(e.message.withAttachmentLink(attachmentId, url), e.message))) {
      return;
    }
    // A thread takes the replies to its messages, and its own sends.
    if (widget.threadOf != null) {
      if (event case MessageCreated(
        :final message,
      ) when !_entries.any((e) => e.message.id == message.reply?.messageId || e.message.nonce == message.nonce)) {
        return;
      }
    }
    setState(() {
      switch (event) {
        case MessageCreated(:final message):
          _stopTyping(message.authorId);
          _markUnreadFrom(message);
          // One that comes with the chat open shines too, in sight already or not.
          if (_mentionsUser(message, _me) && !_shone.contains(message.id)) _unshone.add(message.id);
          _upsert(message);
        case MessageUpdated(:final message):
          _applyUpdate(message);
        case MessageDeleted(:final messageId):
          // One the user deleted is going to dust: that takes it away after.
          if (!_deleting.contains(messageId)) _closeUp(messageId);
          if (_editing?.id == messageId) _stopEditing();
          // The replies quoting it say it's gone, as on the desktop.
          for (var i = 0; i < _entries.length; i++) {
            final m = _entries[i].message;
            if (m.reply case final reply? when reply.messageId == messageId && !reply.deleted) {
              _entries[i] = (message: m.copyWith(reply: reply.asDeleted), delivery: _entries[i].delivery);
            }
          }
          if (_replyTo?.messageId == messageId) _replyTo = null;
        case MessagePinned(:final messageId, :final pinned):
          final i = _entries.indexWhere((e) => e.message.id == messageId);
          if (i >= 0) {
            _entries[i] = (message: _entries[i].message.copyWith(pinned: pinned), delivery: _entries[i].delivery);
          }
        case ReactionChanged(:final messageId, :final userId, :final emoji, :final emojiId, :final added):
          final i = _entries.indexWhere((e) => e.message.id == messageId);
          // The user's own come back as an echo of what's shown already.
          final m = _entries[i].message;
          if (m.reactedWith(userId, emojiId ?? emoji) != added) {
            _entries[i] = (
              message: m.reacted(emoji, userId, add: added, emojiId: emojiId),
              delivery: _entries[i].delivery,
            );
          }
        // Someone's new name and avatar: on their messages, as the desktop
        // renames those it has, and on the replies' quotes of them.
        case AuthorChanged():
          for (var i = 0; i < _entries.length; i++) {
            final m = _entries[i].message;
            final changed = m.changedBy(event);
            if (!identical(changed, m)) _entries[i] = (message: changed, delivery: _entries[i].delivery);
          }
        case ContentChanged():
          break;
        // A file's new link, once its old one expired.
        case AttachmentRenewed(:final attachmentId, :final url):
          for (var i = 0; i < _entries.length; i++) {
            final m = _entries[i].message;
            final changed = m.withAttachmentLink(attachmentId, url);
            if (!identical(changed, m)) _entries[i] = (message: changed, delivery: _entries[i].delivery);
          }
      }
    });
    if (event is MessageCreated) _readIfSeen();
  }

  /// Someone else's [message] coming while the reader doesn't see the newest
  /// (up the list, the app behind, a chat over this one) places the divider
  /// after the last message they saw, unless the visit has one already.
  void _markUnreadFrom(ChatMessage message) {
    // A thread acks nothing, so has no last seen: it gets no divider, as on opening.
    final seen = _acked;
    if (seen == null || _unreadAfter != null || _unreadFrom != null) return;
    if (message.authorId == _me || message.id.compareTo(seen) <= 0) return;
    if (_onTop && _inFront && _atBottom) return;
    if (!_entries.any((e) => e.message.id == seen)) return;
    _unreadAfter = seen;
    if (_atBottom) _showDividerOnReturn = true;
  }

  /// What this device's own database holds of the messages shown changed (an encrypted conversation's): each takes
  /// what it holds of it now, as it is when the answer comes ([ChatMessage.heldAs]).
  Future<void> _readAgain() async {
    final shown = [..._entries];
    final List<ChatMessage> held;
    try {
      held = await _repository.withContent(widget.target, [for (final e in shown) e.message]);
    } catch (e) {
      debugPrint('read again: $e');
      return;
    }
    if (!mounted) return;
    final byId = {for (final m in held) m.id: m};
    final read = {for (final e in shown) e.message.id};
    var dropped = false;
    setState(() {
      // A row the reading dropped goes: one from before the user joined that the device doesn't hold (Ruling 15).
      final count = _entries.length;
      _entries.removeWhere((e) => read.contains(e.message.id) && !byId.containsKey(e.message.id));
      dropped = _entries.length < count;
      for (var i = 0; i < _entries.length; i++) {
        final (:message, :delivery) = _entries[i];
        if (byId[message.id] case final now? when !identical(now, message)) {
          _entries[i] = (message: message.heldAs(now), delivery: delivery);
        }
      }
    });
    // Every row of a page read before the device could be read gave way: the page is read again, which reads on past
    // them to what the device holds (N5 of task 17's re-review).
    if (dropped && _history.isEmpty) unawaited(_load());
  }

  /// An edit, or a link preview that came late, merged into the message (see
  /// [ChatMessage.updatedBy]); the replies quoting it follow its text, as on
  /// the desktop.
  void _applyUpdate(ChatMessage update) {
    for (var i = 0; i < _entries.length; i++) {
      final m = _entries[i].message;
      if (m.id == update.id) {
        _entries[i] = (message: m.updatedBy(update), delivery: _Delivery.sent);
      } else if (m.reply case final reply? when reply.messageId == update.id && !update.encrypted) {
        _entries[i] = (message: m.copyWith(reply: reply.withContent(update.content)), delivery: _entries[i].delivery);
      }
    }
  }

  /// Adds a message, or replaces the one it is: the same ID, or the pending
  /// send with its nonce (the gateway's echo often beats the REST answer).
  void _upsert(ChatMessage message) {
    final i = _entries.indexWhere(
      (e) => e.message.id == message.id || (message.nonce != null && e.message.nonce == message.nonce),
    );
    // An encrypted message's copy that brings no text (the API's) keeps what the chat shows of it: the device's text,
    // or the person's own as typed, until a read gives the device's (I4 of task 17's review).
    final keeps = i >= 0 && message.encrypted && message.content.isEmpty && _entries[i].message.content.isNotEmpty;
    final entry = (message: keeps ? message.heldAs(_entries[i].message) : message, delivery: _Delivery.sent);
    if (i >= 0) {
      _entries[i] = entry;
      if (message.nonce != null) _outgoing.remove(message.nonce);
    } else {
      _entries.add(entry);
    }
  }

  // Recording a voice message lasts as long as typing does, and either
  // replaces the other.
  void _onTyping(TypingUser user) {
    setState(() {
      _typing[user.userId]?.expiry.cancel();
      _typing[user.userId] = (
        name: user.name,
        recording: user.recording,
        expiry: Timer(_typingFor, () {
          if (mounted) setState(() => _typing.remove(user.userId));
        }),
      );
    });
  }

  void _stopTyping(String? userId) => _typing.remove(userId)?.expiry.cancel();

  bool _couldSend = false;

  void _onComposerChanged() {
    final query = _composer.query;
    final text = _composer.text;
    // The menu stays while some command, `perms user get` among them, starts
    // with what's typed; past that, `@`, `#` and emoji suggest as usual.
    final typed = text.startsWith('/') && !text.contains('\n') ? text.substring(1).toLowerCase() : null;
    final slash =
        typed != null &&
            _editing == null &&
            _canUseCommands &&
            _commands.any((c) => c.path.toLowerCase().startsWith(typed))
        ? text.substring(1)
        : null;
    if (query != _query || _canSend != _couldSend || slash != _slash) {
      setState(() {
        _query = query;
        _couldSend = _canSend;
        _slash = slash;
      });
    }
    if (_composer.text.trim().isEmpty || _editing != null) return;
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) < _typingEvery) return;
    _lastTypingSent = now;
    _repository.sendTyping(widget.target);
  }

  // A conversation's is a UUIDv4, as the conventions between clients have it (PLAN-E2E-CLIENTES.md).
  String _nonce() => widget.target is ConversationTarget
      ? uuidv4()
      : '${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1 << 20)}';

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  Future<void> _send() async {
    if (_editing != null) {
      _saveEdit();
      return;
    }
    final content = _composer.encoded.trim();
    if (content.isEmpty && _files.isEmpty) return;
    // `/name` of a command, or `/name group sub` of a subcommand, runs it.
    if (_files.isEmpty && content.startsWith('/') && _canUseCommands) {
      final command = _commands.where((c) => '/${c.path}' == content).firstOrNull;
      if (command != null) return _runCommand(command);
    }
    // Files over the upload limit stay in the tray, with the reason: an encrypted conversation's by their sealed size,
    // and the request's 32 MiB with them all (task 18's review, Missing 1).
    if (_files.isNotEmpty) {
      final limit = await _repository.uploadLimit();
      if (!mounted) return;
      final sealed = widget.target is ConversationTarget;
      // The request's 32 MiB, which no room's words name: a message too large to send, as the rooms' failure says.
      if (sealed && tooLargeToSend([for (final f in _files) f.sizeBytes ?? 0])) {
        _toast('Too large to send');
        return;
      }
      final over = [
        for (final f in _files)
          if (limit != null && (sealed ? sealedSize(f.sizeBytes ?? 0) : (f.sizeBytes ?? 0)) > limit) f,
      ];
      if (over.isNotEmpty) {
        _toast(
          over.length == 1
              ? '${over.single.displayName} is over your ${_megabytes(limit!)} upload limit'
              : '${over.length} files are over your ${_megabytes(limit!)} upload limit',
        );
        return;
      }
    }
    final files = [..._files];
    final replyTo = _replyTo;
    _composer.clear();
    setState(() {
      _files.clear();
      _replyTo = null;
    });
    _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
    // In a thread, a message with no other target replies to the thread's root.
    final to = replyTo?.messageId ?? widget.threadOf;
    _queue((
      content: content,
      files: files,
      sticker: null,
      replyTo: to,
      mentionReplied: replyTo?.mentionAuthor,
      voice: null,
      waveform: null,
    ), reply: replyTo);
  }

  /// A hardware keyboard's Enter sends, as on the desktop, or picks the first
  /// suggestion while they're open; Shift+Enter starts a new line. The
  /// on-screen keyboard's Return types its newline through the text input,
  /// never here, so it still starts a new line (#36). An IME's Enter, while it
  /// composes, confirms the text.
  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed || !_composer.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (_suggestions().firstOrNull case GlassRow(:final onPressed)) {
      onPressed();
    } else {
      unawaited(_send());
    }
    return KeyEventResult.handled;
  }

  static String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  void _sendSticker(Sticker sticker) => _sendPicked(sticker: sticker);

  void _sendGif(String url) =>
      widget.target is ConversationTarget ? unawaited(_sendSealedGif(url)) : _sendPicked(content: url);

  /// A GIF picked in an encrypted conversation goes as a sealed file of its bytes, never its link (Ruling 12).
  Future<void> _sendSealedGif(String url) async {
    final picked = await gifFile(url, GifSource.instance.bytes);
    if (!mounted) return;
    if (picked == null) return _toast(Notice.gifFailed.text);
    // Beside the decrypted files, which the engine's start empties: the engine keeps its sealed bytes for a Retry
    // (task 19's review, M5).
    final copy = await DecryptedFiles.instance.aside('gif', picked.name, bytes: picked.bytes);
    if (!mounted) return;
    final reply = _replyTo;
    if (reply != null) setState(() => _replyTo = null);
    _queue((
      content: '',
      files: [
        OutgoingFile(path: copy.path, name: picked.name, contentType: 'image/gif', sizeBytes: picked.bytes.length),
      ],
      sticker: null,
      replyTo: reply?.messageId ?? widget.threadOf,
      mentionReplied: reply?.mentionAuthor,
      voice: null,
      waveform: null,
    ), reply: reply);
  }

  // A sticker or a GIF answers the message being replied to, as a text does
  // (on the desktop they all go out the same way), and the strip closes.
  void _sendPicked({String content = '', Sticker? sticker}) {
    final reply = _replyTo;
    if (reply != null) setState(() => _replyTo = null);
    final to = reply?.messageId ?? widget.threadOf;
    _queue((
      content: content,
      files: const [],
      sticker: sticker,
      replyTo: to,
      mentionReplied: reply?.mentionAuthor,
      voice: null,
      waveform: null,
    ), reply: reply);
  }

  void _sendVoice(Recording recording) => _queue((
    content: '',
    files: const [],
    sticker: null,
    replyTo: null,
    mentionReplied: null,
    voice: recording,
    // The loudest of each stretch of the take, worked out before the send reads it (task 19's review, Missing 1).
    waveform: _take.isEmpty ? null : peaksOf(_take),
  ));

  /// A take's every level, a tenth of a second each, for its waveform.
  final _take = <double>[];

  void _queue(_Outgoing outgoing, {MessageReply? reply}) {
    final nonce = _nonce();
    final profile = _repository.profile.value;
    final pending = ChatMessage(
      id: 'pending:$nonce',
      authorId: profile?.id,
      authorName: profile?.displayName ?? '',
      authorAvatarUrl: profile?.avatarUrl,
      content: outgoing.content,
      createdAt: DateTime.now(),
      nonce: nonce,
      stickerUrl: outgoing.sticker?.url,
      reply: reply,
      isVoice: outgoing.voice != null,
      attachments: [
        for (final (i, f) in outgoing.files.indexed)
          MessageAttachment(
            id: 'pending:$nonce:$i',
            filename: f.name,
            contentType: f.contentType,
            url: f.path,
            width: f.width,
            height: f.height,
            sizeBytes: f.sizeBytes ?? 0,
            local: true,
          ),
        if (outgoing.voice case final voice?)
          MessageAttachment(
            id: 'pending:$nonce:voice',
            filename: 'voice-note.${voice.format}',
            contentType: 'audio/${voice.format}',
            url: '',
            local: true,
          ),
      ],
    );
    _outgoing[nonce] = outgoing;
    setState(() => _entries.add((message: pending, delivery: _Delivery.sending)));
    _deliver(nonce);
  }

  Future<void> _deliver(String nonce) async {
    final outgoing = _outgoing[nonce];
    if (outgoing == null) return;
    final cancel = _cancels[nonce] = Completer<void>();
    _tooLarge.remove(nonce);
    try {
      final ChatMessage sent;
      if (outgoing.voice case final voice?) {
        sent = await _repository.sendVoiceNote(
          widget.target,
          voice.bytes,
          nonce: nonce,
          format: voice.format,
          waveform: outgoing.waveform,
          length: voice.length,
        );
      } else {
        sent = await _repository.send(
          widget.target,
          outgoing.content,
          nonce: nonce,
          files: outgoing.files,
          sticker: outgoing.sticker,
          replyTo: outgoing.replyTo,
          mentionRepliedUser: outgoing.mentionReplied,
          onProgress: outgoing.files.isEmpty
              ? null
              : (p) {
                  // A redraw per percent, not per chunk.
                  if (!mounted || cancel.isCompleted) return;
                  if (((_progress[nonce] ?? -1) * 100).floor() != (p * 100).floor()) {
                    setState(() => _progress[nonce] = p);
                  }
                },
          cancel: cancel.future,
        );
      }
      _outgoing.remove(nonce);
      _progress.remove(nonce);
      if (!mounted) return;
      // The server may not echo the nonce back: match the pending entry by ours.
      setState(() {
        _entries.removeWhere((e) => e.message.id == sent.id && e.message.nonce != nonce);
        final i = _entries.indexWhere((e) => e.message.nonce == nonce);
        final entry = (message: sent, delivery: _Delivery.sent);
        if (i >= 0) {
          _entries[i] = entry;
        } else {
          _entries.add(entry);
        }
      });
    } catch (e) {
      // Cancelled: the entry is gone already.
      if (!mounted || cancel.isCompleted) return;
      setState(() {
        _progress.remove(nonce);
        if (e is UploadTooLarge) _tooLarge.add(nonce);
        final i = _entries.indexWhere((e) => e.message.nonce == nonce);
        if (i >= 0) _entries[i] = (message: _entries[i].message, delivery: _Delivery.failed);
      });
      _announce(e is UploadTooLarge ? 'Too large to send' : 'Message not sent');
      // Why the API refused it, as the desktop shows it.
      if (e is ActionFailed) _toast(e.message);
    } finally {
      _cancels.remove(nonce);
    }
  }

  /// Stops an upload: the message goes, its files back to the tray. Its text
  /// and reply come back too while the composer has neither, as the desktop
  /// does; what the user wrote or picked since stays.
  void _cancelUpload(_Entry entry) {
    final nonce = entry.message.nonce;
    if (nonce == null) return;
    _cancels[nonce]?.complete();
    final outgoing = _outgoing.remove(nonce);
    final restore = outgoing != null && _editing == null;
    final empty = _composer.text.trim().isEmpty && _replyTo == null;
    // A reply whose message was deleted meanwhile can't be sent again.
    final reply = entry.message.reply;
    setState(() {
      _entries.remove(entry);
      _progress.remove(nonce);
      if (restore) {
        _files.addAll(outgoing.files.take(maxFiles - _files.length));
        if (empty && reply != null && !reply.deleted) _replyTo = reply;
      }
    });
    if (restore && empty && outgoing.content.isNotEmpty) {
      final directory = _directory;
      _composer.setEncoded(
        outgoing.content,
        nameOf: directory.nameOf,
        emojiNameOf: (id) => directory.emojiOf(id)?.name,
        roomNameOf: (id) => directory.roomOf(id)?.name,
      );
    }
    _announce('Upload cancelled');
  }

  void _retry(_Entry entry) {
    final nonce = entry.message.nonce;
    if (nonce != null && !_outgoing.containsKey(nonce) && entry.message.pending) {
      unawaited(_resend(entry, nonce));
      return;
    }
    if (nonce == null || !_outgoing.containsKey(nonce)) return;
    setState(() {
      final i = _entries.indexOf(entry);
      if (i >= 0) _entries[i] = (message: entry.message, delivery: _Delivery.sending);
    });
    _deliver(nonce);
  }

  /// The user's message this device kept from before the app started again, sent again as the device keeps it.
  Future<void> _resend(_Entry entry, String nonce) async {
    setState(() {
      final i = _entries.indexOf(entry);
      if (i >= 0) _entries[i] = (message: entry.message, delivery: _Delivery.sending);
    });
    // The row retried, by its own ID: a copy of the message a page or the gateway brought has its nonce too.
    final retried = entry.message.id;
    try {
      final sent = await _repository.resend(widget.target, nonce);
      if (!mounted) return;
      setState(() {
        // It takes the message, and any other row of it goes (N1 of task 17's re-review). One a copy replaced
        // meanwhile is that copy already.
        final i = _entries.indexWhere((e) => e.message.id == retried);
        if (i < 0) return;
        final kept = (message: sent, delivery: _Delivery.sent);
        _entries[i] = kept;
        _entries.removeWhere((e) => e.message.id == sent.id && !identical(e, kept));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final i = _entries.indexWhere((e) => e.message.id == retried);
        if (i >= 0) _entries[i] = (message: _entries[i].message, delivery: _Delivery.failed);
      });
      _announce('Message not sent');
      if (e is ActionFailed) _toast(e.message);
    }
  }

  /// Drops a message that failed to send, and what it carried: a conversation's waits on this device no more.
  void _discard(_Entry entry) {
    setState(() {
      _entries.remove(entry);
      _outgoing.remove(entry.message.nonce);
    });
    if (entry.message.nonce case final nonce? when widget.target is ConversationTarget) {
      unawaited(_repository.discard(widget.target, nonce).catchError((Object e) => debugPrint('discard: $e')));
    }
    _announce('Message deleted');
  }

  // ---------------------------------------------------------------------------
  // Voice notes
  // ---------------------------------------------------------------------------

  VoiceRecorder? _recorder;
  StreamSubscription<double>? _levelsSub;
  Timer? _recordTick;
  // Counted by the tick, a tenth of a second at a time.
  Duration _recordedFor = Duration.zero;
  final _levels = <double>[];

  /// Hands-free: slid up while holding Send, or started from the + menu.
  bool _recordLocked = false;
  Offset _recordSlide = Offset.zero;

  bool get _recording => _recorder != null;

  Duration get _recorded => _recordedFor;

  VoiceController? _voice;

  // Voice took the microphone (a call answered from over this chat, say): the
  // voice note being recorded stops.
  void _onVoice() {
    if (_recording && _voice!.inVoice) unawaited(_stopRecording(send: false));
  }

  Future<void> _startRecording({required bool locked}) async {
    if (_recording || _editing != null) return;
    // The recorder would take the microphone and the audio routing (a
    // Bluetooth headset's included) from under the call.
    if (context.voice.inVoice) {
      _toast('You can’t record while in a call or a voice room');
      return;
    }
    final recorder = VoiceRecorder.create();
    setState(() {
      _recorder = recorder;
      _recordLocked = locked;
      _recordSlide = Offset.zero;
      _levels.clear();
    });
    final allowed = await recorder.start();
    if (!mounted) return;
    if (!allowed) {
      setState(() => _recorder = null);
      _toast('Duvet can’t use the microphone');
      return;
    }
    HapticFeedback.mediumImpact();
    _recordedFor = Duration.zero;
    _take.clear();
    _levelsSub = recorder.levels.listen((l) {
      if (!mounted) return;
      _take.add(l);
      setState(() {
        _levels.add(l);
        if (_levels.length > 48) _levels.removeAt(0);
      });
    });
    var sinceIndicator = 0;
    _repository.sendRecording(widget.target);
    _recordTick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _recordedFor += const Duration(milliseconds: 100));
      // The others see "recording…" while it lasts.
      if (++sinceIndicator % 50 == 0) _repository.sendRecording(widget.target);
    });
    _announce('Recording');
  }

  Future<void> _stopRecording({required bool send}) async {
    final recorder = _recorder;
    if (recorder == null) return;
    // Cleared at once: a release right after a slide finds nothing to stop.
    final long = _recorded >= const Duration(milliseconds: 600);
    _recordTick?.cancel();
    final levels = _levelsSub;
    _levelsSub = null;
    setState(() {
      _recorder = null;
      _recordLocked = false;
    });
    unawaited(levels?.cancel());
    if (!send || !long) {
      await recorder.cancel();
      _announce(send ? 'Too short to send' : 'Recording cancelled');
      return;
    }
    final recording = await recorder.stop();
    if (!mounted || recording == null) return;
    _sendVoice(recording);
  }

  // Holding Send: slide left to cancel, up to lock.
  void _onHoldMove(Offset offset) {
    if (!_recording || _recordLocked) return;
    setState(() => _recordSlide = offset);
    if (offset.dx < -100) {
      _stopRecording(send: false);
    } else if (offset.dy < -60) {
      HapticFeedback.selectionClick();
      setState(() => _recordLocked = true);
    }
  }

  void _onHoldEnd() {
    if (_recording && !_recordLocked) _stopRecording(send: true);
  }

  // ---------------------------------------------------------------------------
  // Reply, edit, delete, react
  // ---------------------------------------------------------------------------

  void _startReply(ChatMessage m) {
    if (m.id.startsWith('pending:') || m.isNotice || m.isEphemeral) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (_editing != null) _stopEditing();
      _replyTo = MessageReply(
        messageId: m.id,
        authorId: m.authorId,
        authorName: m.authorName,
        content: _repository.previewOf(m),
        // The desktop's @ ON: a reply pings its author unless turned off.
        mentionAuthor: m.authorId != _me && m.webhookId == null,
      );
    });
    _focus.requestFocus();
    _announce('Replying to ${m.authorName}');
  }

  void _cancelReply() => setState(() => _replyTo = null);

  void _toggleReplyMention() {
    final reply = _replyTo;
    if (reply == null) return;
    setState(() => _replyTo = reply.withMentionAuthor(!reply.mentionAuthor));
    _focus.requestFocus();
  }

  // As on the desktop: no @ ON/OFF for a reply to oneself or to a webhook.
  bool _canMentionReplied(MessageReply reply) =>
      reply.authorId != _me &&
      _entries.where((e) => e.message.id == reply.messageId).firstOrNull?.message.webhookId == null;

  /// Dismisses a bot's answer to the user alone: it goes for the session.
  void _dismiss(ChatMessage m) {
    _repository.dismissEphemeral(widget.target, m.id);
    setState(() => _entries.removeWhere((e) => e.message.id == m.id));
  }

  void _startEditing(ChatMessage m) {
    final directory = _directory;
    setState(() {
      _replyTo = null;
      _editing = m;
    });
    _composer.setEncoded(
      m.content,
      nameOf: directory.nameOf,
      emojiNameOf: (id) => directory.emojiOf(id)?.name,
      roomNameOf: (id) => directory.roomOf(id)?.name,
    );
    _focus.requestFocus();
  }

  void _stopEditing() {
    _editing = null;
    _composer.clear();
  }

  Future<void> _saveEdit() async {
    final editing = _editing;
    if (editing == null) return;
    final content = _composer.encoded.trim();
    if (content.isEmpty) return;
    setState(_stopEditing);
    if (content == editing.content) return;
    // Shown at once; put back if the server says no.
    _replace(editing.copyWith(content: content, edited: true));
    try {
      // The API answers the message without its files, reactions or reply.
      final saved = await _repository.edit(widget.target, editing.id, content);
      if (mounted) setState(() => _applyUpdate(saved));
    } catch (_) {
      _replace(editing);
      _toast('Couldn’t save your edit');
    }
  }

  void _replace(ChatMessage m) {
    if (!mounted) return;
    setState(() {
      final i = _entries.indexWhere((e) => e.message.id == m.id);
      if (i >= 0) _entries[i] = (message: m, delivery: _entries[i].delivery);
    });
  }

  /// Takes a message away by easing its place shut, so the messages around
  /// don't jump; at once with reduced motion.
  void _closeUp(String messageId) {
    if (MediaQuery.disableAnimationsOf(context) || !_entries.any((e) => e.message.id == messageId)) {
      _entries.removeWhere((e) => e.message.id == messageId);
      return;
    }
    _vanishing.add(messageId);
    _closing.add(messageId);
    Future<void>.delayed(_Vanish.closing, () {
      _vanishing.remove(messageId);
      _closing.remove(messageId);
      if (mounted) setState(() => _entries.removeWhere((e) => e.message.id == messageId));
    });
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final confirmed = await _showDeleteSheet(
      context,
      message: m,
      mine: m.authorId != null && m.authorId == _me,
      directory: _directory,
      where: _where,
    );
    if (confirmed != true || !mounted) return;
    // Asked for at once, so leaving the chat as the sheet closes can't lose
    // it; its MESSAGE_DELETE waits for the dust.
    _deleting.add(m.id);
    final deleted = _repository.delete(widget.target, m.id).then((_) => true, onError: (_) => false);
    try {
      // Once the sheet is gone and the keyboard down, so the list stands
      // still under the dust.
      await Future<void>.delayed(DuvetTokens.panelOut);
      for (var t = 0; t < 12 && mounted && MediaQuery.viewInsetsOf(context).bottom > 0; t++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!mounted) return;
      final i = _entries.indexWhere((e) => e.message.id == m.id);
      if (i < 0) return;
      final removed = _entries[i];
      // Its place stays, empty, while the dust goes; then the list closes up.
      if (_keys[m.id] case final key?) {
        final covered = EdgeInsets.only(
          top: _topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight,
          bottom: _composerHeight,
        );
        if (disintegrate(context, key, _linkFor(m.id), covered: covered) case final dust?) {
          setState(() => _vanishing.add(m.id));
          await dust;
          // The dust gone, the messages around ease together.
          if (mounted) setState(() => _closing.add(m.id));
          await Future<void>.delayed(_Vanish.closing);
          _vanishing.remove(m.id);
          _closing.remove(m.id);
          if (!mounted) return;
        }
      }
      setState(() => _entries.removeWhere((e) => e.message.id == m.id));
      if (await deleted) {
        _announce('Message deleted');
      } else if (mounted) {
        setState(() => _entries.insert(min(i, _entries.length), removed));
        _toast('Couldn’t delete the message');
      }
    } finally {
      _deleting.remove(m.id);
    }
  }

  String get _where => widget.target is RoomTarget ? widget.title.replaceFirst('# ', '#') : 'this conversation';

  Future<void> _toggleReaction(ChatMessage m, String emoji, {String? emojiId}) async {
    final me = _me;
    if (me == null || m.id.startsWith('pending:')) return;
    final current = _entries.where((e) => e.message.id == m.id).firstOrNull?.message ?? m;
    // By the emoji itself: another Space's emoji can have this one's name.
    final add = !current.reactedWith(me, emojiId ?? emoji);
    HapticFeedback.selectionClick();
    _replace(current.reacted(emoji, me, add: add, emojiId: emojiId));
    try {
      await _repository.react(widget.target, m.id, emoji, add: add, emojiId: emojiId);
    } catch (_) {
      final now = _entries.where((e) => e.message.id == m.id).firstOrNull?.message;
      if (now != null) _replace(now.reacted(emoji, me, add: !add, emojiId: emojiId));
      _toast('Couldn’t react');
    }
  }

  /// A reaction from the full picker.
  Future<void> _pickReaction(ChatMessage m) async {
    final choice = await showEmojiPicker(
      context,
      customEmojis: Future.value(_customEmojis),
      stickers: Future.value(const []),
      spaces: _spacesListed,
      currentSpaceId: _spaceId,
    );
    if (!mounted) return;
    switch (choice) {
      case PickedEmoji(:final emoji):
        await _toggleReaction(m, emoji);
      case PickedCustomEmoji(:final emoji):
        await _toggleReaction(m, emoji.name, emojiId: emoji.id);
      case PickedSticker() || PickedGif() || null:
    }
  }

  // ---------------------------------------------------------------------------
  // Jumping
  // ---------------------------------------------------------------------------

  /// A link to a message: here, it scrolls there; elsewhere, that chat opens
  /// at it.
  void _openLink(MessageLink link) {
    final target = targetOf(link);
    if (target == widget.target) {
      _jumpTo(link.messageId);
      return;
    }
    if (linksHiddenRoom(_repository, link)) return _toast(roomUnavailable);
    final String title;
    if (target case ConversationTarget(:final conversationId)) {
      title =
          _repository.conversations.value.where((c) => c.id == conversationId).firstOrNull?.title ?? 'Direct message';
    } else {
      final room = _repository.spaces.value.expand((s) => s.rooms).where((r) => r.id == link.roomId).firstOrNull;
      title = '# ${room?.name ?? 'room'}';
    }
    Navigator.of(context).push(ChatRoute(target: target, title: title, jumpTo: link.messageId));
  }

  /// The chat opened again at [messageId] from outside it (its notification, a link in a message's text), the
  /// message in view or near it: scrolled to and flashed, as for a link to one of the chat's own messages. Answers
  /// whether it was. One further off is for a fresh chat opened at it: [_jumpTo] only looks back from where the list
  /// is, and a notification's message may not have come yet.
  bool _showNear(String messageId) {
    if (_keys[messageId]?.currentContext == null) return false;
    _jumpTo(messageId);
    return true;
  }

  void _openSpace(String spaceId) {
    final space = _repository.spaces.value.where((s) => s.id == spaceId).firstOrNull;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => SpaceDirectory(spaceId: spaceId, name: space?.name ?? 'Space').readable,
      ),
    );
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  // Each message's place, for its dust to follow as the list scrolls.
  final _links = <String, LayerLink>{};
  LayerLink _linkFor(String id) => _links.putIfAbsent(id, LayerLink.new);

  /// Scrolls toward older messages, or toward newer ones when [newer], until [find] has a context (its item got
  /// built), or the list runs out that way. Answers whether it was found.
  Future<bool> _scrollUntilBuilt(BuildContext? Function() find, {bool newer = false}) async {
    for (var tries = 0; tries < 40 && mounted; tries++) {
      if (find() != null) return true;
      if (!_scroll.hasClients) return false;
      final position = _scroll.position;
      if (newer) {
        // Down toward the newest, which the list has all of: no page to load that way.
        if (position.pixels <= position.minScrollExtent) return find() != null;
        _scroll.jumpTo(max(position.pixels - position.viewportDimension * 0.8, position.minScrollExtent));
      } else if (position.pixels >= position.maxScrollExtent) {
        if (!_hasOlder) return find() != null;
        await _loadOlder();
      } else {
        _scroll.jumpTo(min(position.pixels + position.viewportDimension * 0.8, position.maxScrollExtent));
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    return find() != null;
  }

  /// Shows the message a reply quotes: scrolled to and flashed if it's in the
  /// chat (paging back for it), else on its own in a sheet.
  Future<void> _jumpTo(String messageId) async {
    final at = _entries.indexWhere((e) => e.message.id == messageId);
    // Newer than every message built, it's below the view (#301): the list builds those in view and a little past.
    final newestBuilt = _entries.lastIndexWhere((e) => _keys[e.message.id]?.currentContext != null);
    final found = at >= 0 || _hasOlder
        ? await _scrollUntilBuilt(() => _keys[messageId]?.currentContext, newer: newestBuilt >= 0 && at > newestBuilt)
        : false;
    if (!mounted) return;
    final ctx = _keys[messageId]?.currentContext;
    if (found && ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() => _flash = messageId);
      Timer(const Duration(milliseconds: 900), () {
        if (mounted && _flash == messageId) setState(() => _flash = null);
      });
      return;
    }
    try {
      final original = await _repository.fetchMessage(widget.target, messageId);
      if (mounted) await _showOriginalSheet(context, message: original, directory: _directory);
    } catch (_) {
      _toast('That message is gone');
    }
  }

  // ---------------------------------------------------------------------------
  // Composer actions
  // ---------------------------------------------------------------------------

  Future<void> _openAttachMenu(BuildContext anchor) async {
    final picked = await showGlassMenu(
      anchor,
      label: 'Add to message',
      items: [
        const GlassMenuItem(icon: FLucideIcons.images, label: 'Photos & GIFs', value: 'gallery'),
        const GlassMenuItem(icon: FLucideIcons.camera, label: 'Camera', value: 'camera'),
        if (_stickerList.isNotEmpty)
          const GlassMenuItem(icon: FLucideIcons.sticker, label: 'Sticker', value: 'sticker'),
        const GlassMenuItem(icon: FLucideIcons.paperclip, label: 'File', value: 'file'),
        const GlassMenuItem(icon: FLucideIcons.mic, label: 'Voice note', value: 'voice'),
        const GlassMenuItem(icon: FLucideIcons.atSign, label: 'Mention someone', value: 'mention'),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'gallery':
        await _pick(ImageSource.gallery);
      case 'camera':
        await _pick(ImageSource.camera);
      case 'sticker':
        await _openPicker(PickerTab.stickers);
      case 'file':
        await _pickFiles();
      case 'voice':
        await _startRecording(locked: true);
      case 'mention':
        _composer.startMention();
        _focus.requestFocus();
    }
  }

  Future<void> _pickFiles() async {
    final room = maxFiles - _files.length;
    if (room <= 0) {
      _toast('A message takes up to $maxFiles files');
      return;
    }
    try {
      final picked = await (ChatView.debugPickFiles ?? _pickWithFilePicker)();
      if (!mounted || picked.isEmpty) return;
      final added = picked.take(room).toList();
      setState(() => _files.addAll(added));
      if (picked.length > room) _toast('Added $room: a message takes up to $maxFiles files');
      _announce(added.length == 1 ? '${added.single.name} attached' : '${added.length} files attached');
    } on PlatformException {
      _toast('Couldn’t open your files');
    }
  }

  static Future<List<OutgoingFile>> _pickWithFilePicker() async {
    final picked = await FilePicker.pickFiles();
    return [
      for (final f in picked)
        if (f.path != null)
          OutgoingFile(
            path: f.path!,
            name: f.name,
            contentType: _typeOf(f.name),
            sizeBytes: await File(f.path!).length(),
          ),
    ];
  }

  Future<void> _pick(ImageSource source) async {
    final room = maxFiles - _files.length;
    if (room <= 0) {
      _toast('A message takes up to $maxFiles files');
      return;
    }
    try {
      final picked = await (widget.pickMedia ?? ChatView.debugPickMedia ?? _pickWithImagePicker)(source);
      if (!mounted || picked.isEmpty) return;
      final added = picked.take(room).toList();
      setState(() => _files.addAll(added));
      if (picked.length > room) _toast('Added $room: a message takes up to $maxFiles files');
      _announce(added.length == 1 ? '${added.single.name} attached' : '${added.length} files attached');
    } on PlatformException catch (e) {
      _toast(e.code == 'camera_access_denied' ? 'Duvet can’t use the camera' : 'Couldn’t open your photos');
    }
  }

  static Future<List<OutgoingFile>> _pickWithImagePicker(ImageSource source) async {
    final picker = ImagePicker();
    final files = source == ImageSource.camera
        ? [?await picker.pickImage(source: ImageSource.camera, imageQuality: 90)]
        // Originals, uncompressed: a GIF stays animated.
        : await picker.pickMultipleMedia(limit: maxFiles);
    return [
      for (final f in files)
        OutgoingFile(
          path: f.path,
          name: f.name,
          contentType: f.mimeType ?? _typeOf(f.name),
          sizeBytes: await f.length(),
        ),
    ];
  }

  static String _typeOf(String name) => switch (name.split('.').last.toLowerCase()) {
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'zip' => 'application/zip',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'gif' => 'image/gif',
    'png' => 'image/png',
    'apng' => 'image/apng',
    'webp' => 'image/webp',
    'jpg' || 'jpeg' => 'image/jpeg',
    'heic' => 'image/heic',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    _ => 'application/octet-stream',
  };

  Future<void> _openPicker([PickerTab tab = PickerTab.emoji]) async {
    final choice = await showEmojiPicker(
      context,
      customEmojis: Future.value(_customEmojis),
      stickers: _stickers,
      spaces: _spacesListed,
      currentSpaceId: _spaceId,
      tab: tab,
      gifs: true,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case PickedEmoji(:final emoji):
        _composer.insertEmoji(emoji);
        _focus.requestFocus();
      case PickedCustomEmoji(:final emoji):
        _composer.insertCustomEmoji(emoji);
        _focus.requestFocus();
      case PickedSticker(:final sticker):
        _sendSticker(sticker);
      case PickedGif(:final gif):
        _sendGif(gif.url);
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  bool get _isGroup =>
      widget.target is ConversationTarget &&
      (_repository.conversations.value.where((c) => c.id == widget.target.id).firstOrNull?.isGroup ?? false);

  // A DM or a group can be called; a room or a thread can't.
  bool get _callable => widget.target is ConversationTarget && widget.threadOf == null;

  /// Whether Call may place or join a call now: none going on here, and not
  /// the user's own while it rings from another device.
  bool get _canCall => context.voice.call == null && !callingElsewhere(context.voice, widget.target.id);

  /// Call's menu, as the desktop's (desktop#370): a voice call, or a video
  /// call, which turns the camera on as the user's voice joins. Asked again
  /// once picked: a call may have come in while the menu was open.
  Future<void> _openCallMenu(BuildContext anchor) async {
    // Out of the composer: or the menu hands the keyboard back as it closes.
    _focus.unfocus();
    final video = await showGlassMenu<bool>(
      anchor,
      label: 'Start a call',
      items: const [
        GlassMenuItem(icon: FLucideIcons.phone, label: 'Voice call', value: false),
        GlassMenuItem(icon: FLucideIcons.video, label: 'Video call', value: true),
      ],
    );
    if (video == null || !mounted || !_canCall) return;
    await callConversation(context, widget.target.id, video: video);
  }

  /// A DM's other person's presence, under its name: none in a group, a room
  /// or a thread, nor before the gateway or the friends list has told it.
  Presence? get _dmPresence {
    if (widget.target is! ConversationTarget || widget.threadOf != null) return null;
    final other = _repository.conversations.value.where((c) => c.id == widget.target.id).firstOrNull?.otherUserId;
    return other == null ? null : _repository.presence.value[other];
  }

  /// Under the top bar: the connection's state, and the call going on here.
  Widget? _topBanner() {
    final status = switch (_repository.status.value) {
      LiveStatus.reconnecting => const ConnectionBanner(
        text: 'Reconnecting…',
        detail: 'messages will send when you’re back',
      ),
      LiveStatus.offline => const ConnectionBanner(text: 'Offline', detail: '· showing saved messages'),
      // Connected, yet the latest failed to load: what shows is the page kept.
      _ when _error != null && _entries.isNotEmpty => Semantics(
        button: true,
        child: GestureDetector(
          onTap: _load,
          child: const ConnectionBanner(
            text: 'Couldn’t load the latest messages',
            detail: '· tap to try again',
            icon: FLucideIcons.refreshCw,
          ),
        ),
      ),
      _ => null,
    };
    final call = _callable && CallBanner.shows(context.voice, widget.target.id)
        ? CallBanner(conversationId: widget.target.id)
        : null;
    if (status == null || call == null) return status ?? call;
    return Column(mainAxisSize: MainAxisSize.min, children: [status, const SizedBox(height: 8), call]);
  }

  Future<void> _openMore(BuildContext anchor) async {
    // Out of the composer: or the menu and the sheet after it hand the
    // keyboard back as they close.
    _focus.unfocus();
    final picked = await showGlassMenu(
      anchor,
      label: 'Chat options',
      items: [
        if (_isGroup) const GlassMenuItem(icon: FLucideIcons.info, label: 'Group info', value: 'group'),
        if (_inRoomMay(Perm.createInvites))
          const GlassMenuItem(
            icon: FLucideIcons.userPlus,
            label: 'Invite people',
            value: 'invite',
            hint: 'A link to this room',
          ),
        // Beside the chat where there's room: the item shows and hides them.
        GlassMenuItem(
          icon: FLucideIcons.users,
          label: !_membersBeside
              ? 'Members'
              : PaneScope.maybeOf(context)!.showMembers
              ? 'Hide members'
              : 'Show members',
          value: 'members',
        ),
        const GlassMenuItem(icon: FLucideIcons.pin, label: 'Pinned messages', value: 'pins'),
        // Running the room, for those who may: ManageChannels in it.
        if (_inRoomMay(Perm.manageChannels) && _room != null) ...[
          const GlassMenuItem(icon: FLucideIcons.pencil, label: 'Rename room', value: 'rename'),
          const GlassMenuItem(icon: FLucideIcons.text, label: 'Edit description', value: 'describe'),
          const GlassMenuItem(icon: FLucideIcons.shield, label: 'Permissions', value: 'perms'),
          const GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete room', value: 'delete', destructive: true),
        ],
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'invite' || 'rename' || 'describe' || 'perms' || 'delete':
        await _roomAction(picked!);
      case 'group':
        await Navigator.of(
          context,
          rootNavigator: true,
        ).push(MaterialPageRoute<void>(builder: (_) => GroupInfoPage(conversationId: widget.target.id)));
      case 'members':
        if (_membersBeside) {
          PaneScope.maybeOf(context)!.toggleMembers();
        } else {
          await _openMembers();
        }
      case 'pins':
        await _openPins();
    }
  }

  /// Inviting to, or running, the room the user is in.
  Future<void> _roomAction(String action) async {
    final target = widget.target;
    final room = _room;
    if (target is! RoomTarget || room == null) return;
    final repository = _repository;
    final label = '#${room.name}';
    Future<void> attempt(String failure, Future<void> Function() change) async {
      try {
        await change();
      } catch (e) {
        _toast(e is ActionFailed ? e.message : failure);
      }
    }

    switch (action) {
      case 'invite':
        final space = repository.spaces.value.where((s) => s.id == target.spaceId).firstOrNull;
        if (space != null) await showInviteSheet(context, space: space, room: room);
      case 'rename':
        final got = await askName<void>(context, title: 'Rename $label', initial: room.name);
        if (got == null || !mounted) return;
        await attempt('Couldn’t rename $label', () => repository.renameRoom(target.spaceId, room.id, got.$1));
      case 'describe':
        final got = await askDescription(context, title: 'What $label is for', initial: room.description ?? '');
        if (got == null || !mounted) return;
        await attempt(
          'Couldn’t change what $label is for',
          () => repository.setRoomDescription(target.spaceId, room.id, got),
        );
      case 'perms':
        final admin = repository.adminRooms(target.spaceId).where((r) => r.id == room.id).firstOrNull;
        if (admin == null) return;
        await Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => RoomPermissionsPage(spaceId: target.spaceId, room: admin),
          ),
        );
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete $label?',
          body: 'Its messages go with it, for everyone. This can’t be undone.',
          action: 'Delete',
        );
        if (!sure || !mounted) return;
        try {
          await repository.deleteRoom(target.spaceId, room.id);
          // Out of the room that's gone.
          if (mounted) await Navigator.of(context).maybePop();
        } catch (e) {
          _toast(e is ActionFailed ? e.message : 'Couldn’t delete $label');
        }
    }
  }

  /// The Space's rooms in a glass sheet, this one selected; picking another
  /// swaps the chat.
  Future<void> _openSwitcher() async {
    final target = widget.target;
    if (target is! RoomTarget) return;
    final space = _repository.spaces.value.where((s) => s.id == target.spaceId).firstOrNull;
    if (space == null) return;
    final room = await showChannelSwitcher(context, space: space, current: target.roomId);
    if (room == null || !mounted || room.id == target.roomId) return;
    Navigator.of(context).pushReplacement(ChatRoute(target: room.target, title: '# ${room.name}')..instant = true);
  }

  Future<void> _openPins() async {
    final picked = await showPinsSheet(
      context,
      pins: () => _repository.pins(widget.target),
      changes: _repository.messageEvents(widget.target).where((e) => e is MessagePinned),
      where: _where,
      directory: _directory,
      message: (m) => _bubbleFor((message: m, delivery: _Delivery.sent), pinned: true),
      onUnpin: _canPin ? (m) => _setPinned(m, false) : null,
    );
    if (picked != null && mounted) await _jumpTo(picked.id);
  }

  /// Pins or unpins a message; answers whether the server did. A refusal says
  /// the API's reason, as the desktop does.
  Future<bool> _setPinned(ChatMessage m, bool pinned) async {
    _replace(m.copyWith(pinned: pinned));
    try {
      await _repository.pin(widget.target, m.id, pinned: pinned);
      _announce(pinned ? 'Pinned' : 'Unpinned');
      return true;
    } catch (e) {
      _replace(m);
      _toast(e is ActionFailed ? e.message : (pinned ? 'Couldn’t pin the message' : 'Couldn’t unpin the message'));
      return false;
    }
  }

  // In the chat's own navigator: beside the list in the pane, over everything on a phone.
  void _openThread(ChatMessage m) =>
      Navigator.of(context).push(ChatRoute(target: widget.target, title: widget.title, threadOf: m.id));

  Future<void> _openSearch() async {
    final hit = await Navigator.of(context).push<SearchHit>(
      MaterialPageRoute(
        builder: (_) => InChatSearch(target: widget.target, title: widget.title),
      ),
    );
    if (hit == null || !mounted) return;
    if (hit.target == widget.target) {
      await _jumpTo(hit.message.id);
    } else if (hit.target case RoomTarget(:final roomId)) {
      final room = _repository.spaces.value.expand((s) => s.rooms).where((r) => r.id == roomId).firstOrNull;
      _openLinkTo(hit.target, '# ${room?.name ?? 'room'}', hit.message.id);
    }
  }

  void _openLinkTo(ChatTarget target, String title, String messageId) =>
      Navigator.of(context).push(ChatRoute(target: target, title: title, jumpTo: messageId));

  Future<void> _openMembers() async {
    final picked = await showMembersSheet(context, repository: _repository, target: widget.target);
    if (!mounted || picked == null) return;
    final (member, action) = picked;
    await _onMember(member, action);
  }

  Future<void> _onMember(Member member, MemberAction action) async {
    switch (action) {
      case MemberAction.mention:
        _mention(member);
      case MemberAction.message:
        try {
          final dm = await _repository.directMessage(member.userId);
          if (mounted) openChat(context, dm.target, dm.title);
        } catch (e) {
          _toast(e is ActionFailed ? e.message : 'Couldn’t open a conversation with ${member.displayName}');
        }
      case MemberAction.shareHistory:
        if (widget.target case ConversationTarget(:final conversationId)) {
          final said = await showShareHistorySheet(
            context,
            repository: _repository,
            conversationId: conversationId,
            member: member,
          );
          if (said != null) _toast(said);
        }
    }
  }

  /// Someone's profile; Mention and Message act here.
  Future<void> _openProfile(Member member) async {
    final target = widget.target;
    final action = await showProfileSheet(
      context,
      member: member,
      spaceId: target is RoomTarget ? target.spaceId : null,
      canMention: true,
    );
    if (action != null && mounted) await _onMember(member, action);
  }

  void _openAuthor(ChatMessage m) {
    final id = m.authorId;
    if (id == null) return;
    _openProfile(
      _members.where((x) => x.userId == id).firstOrNull ??
          Member(userId: id, username: m.authorName, avatarUrl: m.authorAvatarUrl, isBot: m.fromBot && !m.fromWebhook),
    );
  }

  /// A mention tapped: who it names, as the room knows them, else as the
  /// app does. Else only their name is known, not their username: the
  /// profile shows no handle rather than a made-up one.
  void _openMention(String userId) => _openProfile(
    _members.where((x) => x.userId == userId).firstOrNull ??
        _repository.people.where((p) => p.userId == userId).firstOrNull ??
        Member(userId: userId, username: '', alias: _repository.nameOf(userId) ?? 'Someone'),
  );

  /// A room mention tapped: that room, unless it's this one.
  void _openRoom(Room room) {
    if (room.id == widget.target.id) return;
    switch (room.kind) {
      case RoomKind.text:
        openChat(context, room.target, '# ${room.name}');
      case RoomKind.voice:
        openVoiceRoom(context, room);
    }
  }

  /// Who reacted to [m], with [picked] first; who's tapped, their profile.
  Future<void> _openReactors(ChatMessage m, [Reaction? picked]) async {
    final target = widget.target;
    final member = await _showReactors(
      context,
      reactions: m.reactions,
      initial: picked,
      directory: _directory,
      known: (id) =>
          _members.where((x) => x.userId == id).firstOrNull ??
          _repository.people.where((p) => p.userId == id).firstOrNull,
      presenceOf: (id) =>
          presenceIn(_repository.presence.value, id, spaceId: target is RoomTarget ? target.spaceId : null),
    );
    if (member != null && mounted) await _openProfile(member);
  }

  void _mention(Member member) {
    _composer.startMention();
    _composer.insertMention(member);
    _focus.requestFocus();
  }

  /// Long press: quick reactions over the lifted bubble, and its actions.
  Future<void> _messageActions(BuildContext anchor, _Entry entry) async {
    final m = entry.message;
    final directory = _directory;
    final readable = readableContent(
      m.content,
      nameOf: directory.nameOf,
      emojiNameOf: (id) => directory.emojiOf(id)?.name,
      roomNameOf: (id) => directory.roomOf(id)?.name,
    );
    final mine = m.authorId != null && m.authorId == _me;
    // Nothing of the room's applies to a bot's answer to the user alone: no
    // reactions, replies, pins or deleting, as on the desktop.
    final sent = entry.delivery == _Delivery.sent && !m.isEphemeral;
    final canPin = _canPin;
    final canDelete = mine || _canDeleteOthers;
    final items = [
      if (sent) const GlassMenuItem(icon: FLucideIcons.reply, label: 'Reply', value: _Action.reply),
      if (sent && widget.threadOf == null)
        const GlassMenuItem(icon: FLucideIcons.messagesSquare, label: 'View thread', value: _Action.thread),
      if (sent && m.reactions.isNotEmpty)
        const GlassMenuItem(icon: FLucideIcons.smile, label: 'Reactions', value: _Action.reactions),
      if (readable.isNotEmpty) const GlassMenuItem(icon: FLucideIcons.copy, label: 'Copy text', value: _Action.copy),
      if (sent) const GlassMenuItem(icon: FLucideIcons.link, label: 'Copy link', value: _Action.copyLink),
      if (mine && sent && m.content.isNotEmpty && m.stickerUrl == null)
        const GlassMenuItem(icon: FLucideIcons.pencil, label: 'Edit', value: _Action.edit),
      if (sent && !m.isNotice && canPin)
        m.pinned
            ? const GlassMenuItem(icon: FLucideIcons.pinOff, label: 'Unpin', value: _Action.unpin)
            : const GlassMenuItem(icon: FLucideIcons.pin, label: 'Pin', value: _Action.pin),
      if (!mine && m.authorId != null && !m.isEphemeral)
        GlassMenuItem(icon: FLucideIcons.atSign, label: 'Mention ${m.authorName}', value: _Action.mention),
      if (entry.delivery == _Delivery.failed)
        const GlassMenuItem(icon: FLucideIcons.rotateCw, label: 'Send again', value: _Action.retry),
      if (canDelete && sent)
        const GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete', value: _Action.delete, destructive: true),
      if (entry.delivery == _Delivery.failed)
        const GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete', value: _Action.discard, destructive: true),
    ];
    if (items.isEmpty && !sent) return;
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    // Out of the composer: or the menu and any sheet after it hand the
    // keyboard back as they close. Replying, editing and mentioning focus
    // it again.
    _focus.unfocus();
    final picked = await _showMessageActions(
      context,
      bubble: box.localToGlobal(Offset.zero) & box.size,
      // Lit as in the list, which it's held up from.
      lifted: PrismViewport(
        top: _topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight,
        bottom: _composerHeight,
        child: _bubbleFor(entry, lifted: true),
      ),
      me: _me,
      reactions: sent ? m.reactions : null,
      catalog: _catalog,
      items: items,
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case (_Action.react, final emoji?):
        // A quick reaction counts as a use, as a pick in the picker does; taking one back doesn't.
        if (_me case final me? when !m.reactedWith(me, emoji)) EmojiCatalog.used(emoji);
        await _toggleReaction(m, emoji);
      case (_Action.moreReactions, _):
        await _pickReaction(m);
      case (_Action.reactions, _):
        await _openReactors(m);
      case (_Action.thread, _):
        _openThread(m);
      case (_Action.pin, _):
        await _setPinned(m, true);
      case (_Action.unpin, _):
        await _setPinned(m, false);
      case (_Action.reply, _):
        _startReply(m);
      case (_Action.copy, _):
        await Clipboard.setData(ClipboardData(text: readable));
        _toast('Copied');
      case (_Action.copyLink, _):
        await Clipboard.setData(ClipboardData(text: messageLink(widget.target, m.id)));
        _toast('Link copied');
      case (_Action.edit, _):
        _startEditing(m);
      case (_Action.mention, _):
        _mention(
          _members.where((x) => x.userId == m.authorId).firstOrNull ??
              Member(userId: m.authorId!, username: m.authorName, avatarUrl: m.authorAvatarUrl),
        );
      case (_Action.retry, _):
        _retry(entry);
      case (_Action.delete, _):
        await _confirmDelete(m);
      case (_Action.discard, _):
        _discard(entry);
      case (_Action.react, null):
    }
  }

  /// Pins take PinMessages in a room, as the API has it; every member of a
  /// conversation pins.
  /// This room as the Space has it now (a rename shows at once), or null:
  /// not a room, or not known yet.
  Room? get _room => switch (widget.target) {
    RoomTarget(:final spaceId, :final roomId) =>
      _repository.spaces.value
          .where((s) => s.id == spaceId)
          .firstOrNull
          ?.rooms
          .where((r) => r.id == roomId)
          .firstOrNull,
    ConversationTarget() => null,
  };

  /// The room's name, live; the one it was opened with until it's known.
  String get _roomName => _room?.name ?? widget.title.replaceFirst('# ', '');

  /// In a room (not a thread of it), with [bit] there, overwrites included.
  bool _inRoomMay(int bit) => switch (widget.target) {
    RoomTarget(:final spaceId, :final roomId) => widget.threadOf == null && _repository.canInRoom(spaceId, roomId, bit),
    ConversationTarget() => false,
  };

  bool get _canPin => switch (widget.target) {
    RoomTarget(:final spaceId, :final roomId) => _repository.canInRoom(spaceId, roomId, Perm.pinMessages),
    ConversationTarget() => true,
  };

  /// Commands are for the rooms the user can write in, as on the desktop;
  /// conversations have none.
  bool get _canUseCommands => switch (widget.target) {
    RoomTarget(:final spaceId, :final roomId) => _repository.canInRoom(spaceId, roomId, Perm.sendMessages),
    ConversationTarget() => false,
  };

  /// Someone else's message is deleted with ManageMessages in a room; in a
  /// conversation, each member deletes only their own.
  bool get _canDeleteOthers => switch (widget.target) {
    RoomTarget(:final spaceId, :final roomId) => _repository.canInRoom(spaceId, roomId, Perm.manageMessages),
    ConversationTarget() => false,
  };

  /// Who may delete a notice, as the desktop has it: ManageMessages in a
  /// room; in a conversation, either of a DM's two, or a group's owner.
  bool get _canDeleteNotices => switch (widget.target) {
    RoomTarget() => _canDeleteOthers,
    ConversationTarget(:final conversationId) => switch (_repository.conversations.value
        .where((c) => c.id == conversationId)
        .firstOrNull) {
      null => false,
      final c => !c.isGroup || c.ownerId == _me,
    },
  };

  /// A notice held: Delete, the one thing to do with it.
  Future<void> _noticeActions(BuildContext anchor, ChatMessage m) async {
    final picked = await showGlassMenu(
      anchor,
      label: 'Notice options',
      items: const [GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete', value: true, destructive: true)],
    );
    if (picked != true || !mounted) return;
    final sure = await confirmDestructive(
      context,
      title: 'Delete this notice?',
      body: m.call != null || m.sharedHistory != null
          ? 'It goes for everyone in the conversation.'
          : 'The message stays pinned.',
      action: 'Delete',
    );
    if (!sure || !mounted) return;
    try {
      await _repository.delete(widget.target, m.id);
      if (mounted) setState(() => _entries = [..._entries]..removeWhere((e) => e.message.id == m.id));
    } catch (e) {
      _toast(e is ActionFailed ? e.message : 'Couldn’t delete the notice');
    }
  }

  // ---------------------------------------------------------------------------
  // Bots
  // ---------------------------------------------------------------------------

  String get _spaceName {
    final target = widget.target;
    if (target is! RoomTarget) return 'this conversation';
    return _repository.spaces.value.where((s) => s.id == target.spaceId).firstOrNull?.name ?? 'this Space';
  }

  /// What a select offers: its options, or this chat's people, rooms or
  /// roles; its defaults chosen. The rooms are those the user can see, of the
  /// types it takes, by position: the API takes no others, and the desktop
  /// offers no others.
  List<ComponentOption> _selectChoices(UiComponent select) {
    final defaults = select.defaultValues.toSet();
    ComponentOption option(String label, String value, [String? description]) =>
        ComponentOption(label: label, value: value, description: description, isDefault: defaults.contains(value));
    final people = [for (final m in _members) option(m.displayName, m.userId, '@${m.username}')];
    final target = widget.target;
    final roles = target is RoomTarget
        ? [for (final r in _repository.spaceRoles(target.spaceId)) option('@${r.name}', r.id, 'Role')]
        : <ComponentOption>[];
    return switch (select.type) {
      ComponentKind.userSelect => people,
      ComponentKind.roleSelect => roles,
      ComponentKind.mentionableSelect => [...people, ...roles],
      ComponentKind.roomSelect when target is RoomTarget => [
        for (final r in _repository.adminRooms(target.spaceId))
          if ((select.roomTypes.isEmpty || select.roomTypes.contains(_roomType(r.kind))) &&
              _repository.canInRoom(target.spaceId, r.id, Perm.viewChannels))
            option(r.kind == AdminRoomKind.category ? r.name : '#${r.name}', r.id),
      ],
      ComponentKind.roomSelect => const [],
      _ => select.options,
    };
  }

  /// A room's type as the API numbers it, in `room_types`.
  static int _roomType(AdminRoomKind kind) => switch (kind) {
    AdminRoomKind.text => 1,
    AdminRoomKind.voice => 2,
    AdminRoomKind.category => 3,
  };

  List<ComponentOption> _optionChoices(BotCommandOption o) => _selectChoices(
    UiComponent(
      type: switch (o.type) {
        OptionKind.user => ComponentKind.userSelect,
        OptionKind.role => ComponentKind.roleSelect,
        OptionKind.room => ComponentKind.roomSelect,
        _ => ComponentKind.mentionableSelect,
      },
      roomTypes: o.roomTypes,
    ),
  );

  Future<void> _openModal(BotModal? modal, String botName) async {
    if (modal == null || !mounted) return;
    await showBotModal(
      context,
      modal: modal,
      from: 'From $botName · a bot in $_spaceName',
      choices: _selectChoices,
      directory: _directory,
    );
  }

  Future<void> _useComponent(ChatMessage m, UiComponent component, List<String>? values) async {
    final target = widget.target;
    if (target is! RoomTarget) return;
    try {
      final modal = await _repository.useComponent(target, m.id, component, values: values);
      // The button is done once the bot answers; its modal is on its own.
      unawaited(_openModal(modal, m.authorName));
    } catch (e) {
      _toast(e is ActionFailed ? e.message : 'This interaction failed');
    }
  }

  Future<void> _runCommand(BotCommand command) async {
    final target = widget.target;
    if (target is! RoomTarget) return;
    _composer.clear();
    Map<String, Object> options = const {};
    if (command.options.isNotEmpty) {
      final filled = await showCommandForm(context, command: command, choicesFor: _optionChoices);
      if (filled == null) return;
      options = filled;
    }
    try {
      final modal = await _repository.useCommand(target, command, options);
      await _openModal(modal, command.appName);
    } catch (e) {
      _toast(e is ActionFailed ? e.message : 'This interaction failed');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showFToast(context: context, title: Text(message), duration: const Duration(seconds: 3));
  }

  void _announce(String message) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), message, Directionality.of(context));
  }

  // ---------------------------------------------------------------------------
  // Suggestions
  // ---------------------------------------------------------------------------

  List<Widget> _suggestions() {
    if (_slash case final typed?) {
      final needle = typed.toLowerCase();
      return [
        for (final c in _commands.where((c) => c.path.toLowerCase().startsWith(needle)).take(5))
          GlassRow(
            label: '/${c.path}',
            detail: [c.appName, if (c.description.isNotEmpty) c.description].join(' · '),
            hint: 'Double tap to use',
            leading: const BotAvatar(),
            onPressed: () => _runCommand(c),
          ),
      ];
    }
    final q = _query;
    if (q == null) return const [];
    final needle = q.query.toLowerCase();
    if (q.trigger == '@') {
      final others = _members.where((m) => m.userId != _me);
      final starts = others
          .where((m) => m.displayName.toLowerCase().startsWith(needle) || m.username.toLowerCase().startsWith(needle))
          .take(10)
          .toList();
      final contains = needle.isEmpty
          ? const <Member>[]
          : others
                .where((m) => !starts.contains(m) && m.displayName.toLowerCase().contains(needle))
                .take(10 - starts.length);
      return [
        for (final m in [...starts, ...contains])
          GlassRow(
            label: m.displayName,
            detail: '@${m.username}',
            hint: 'Double tap to mention',
            leading: ExcludeSemantics(
              child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 32),
            ),
            banner: m.bannerUrl,
            bannerOffline: isOffline(
              presenceIn(
                _repository.presence.value,
                m.userId,
                spaceId: switch (widget.target) {
                  RoomTarget(:final spaceId) => spaceId,
                  _ => null,
                },
              ),
            ),
            onPressed: () => _composer.insertMention(m),
          ),
      ];
    }
    if (q.trigger == '#') {
      // The Space's rooms the user may see; a conversation has none.
      final target = widget.target;
      final rooms = target is RoomTarget
          ? _repository.spaces.value.where((s) => s.id == target.spaceId).expand((s) => s.rooms)
          : const <Room>[];
      return [
        for (final r in rooms.where((r) => r.name.toLowerCase().contains(needle)).take(10))
          GlassRow(
            label: '#${r.name}',
            detail: r.kind == RoomKind.voice ? 'Voice room' : null,
            hint: 'Double tap to mention',
            leading: Icon(
              r.kind == RoomKind.voice ? FLucideIcons.volume2 : FLucideIcons.hash,
              size: 24,
              color: context.theme.colors.mutedForeground,
            ),
            onPressed: () => _composer.insertRoom(r),
          ),
      ];
    }
    // Every Space's, the chat's own first.
    final matching = _customEmojis.where((e) => e.name.toLowerCase().contains(needle));
    final custom = [
      ...matching.where((e) => e.spaceId == _spaceId),
      ...matching.where((e) => e.spaceId != _spaceId),
    ].take(3).toList();
    final unicode = _catalog?.search(q.query, limit: 5 - custom.length) ?? const <EmojiEntry>[];
    return [
      for (final e in custom)
        GlassRow(
          label: ':${e.name}:',
          hint: 'Double tap to insert',
          leading: Image(
            image: cachedImage(e.url, cacheWidth: (28 * MediaQuery.devicePixelRatioOf(context)).round()),
            width: 28,
            height: 28,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const SizedBox.square(dimension: 28),
          ),
          onPressed: () {
            EmojiCatalog.used(e.code);
            _composer.insertCustomEmoji(e);
          },
        ),
      for (final e in unicode)
        GlassRow(
          label: ':${e.name.replaceAll(' ', '_')}:',
          hint: 'Double tap to insert ${e.name}',
          leading: ExcludeSemantics(child: Text(e.emoji, style: DuvetType.emojiStyle(26, height: 1.1))),
          onPressed: () {
            EmojiCatalog.used(e.emoji);
            _composer.insertEmoji(e.emoji);
          },
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  // Content under the bars: the top one has older messages above the screen,
  // the composer newer ones below it (the list is reversed).
  bool _underTop = false;
  bool _underComposer = false;
  double _composerHeight = 0;
  double _topHeight = 0;

  bool _onScrollMetrics(ScrollMetrics m) {
    final underTop = m.extentAfter > 0;
    final underComposer = m.pixels > 0;
    if (underTop != _underTop || underComposer != _underComposer) {
      setState(() {
        _underTop = underTop;
        _underComposer = underComposer;
      });
    }
    return false;
  }

  final _chatKey = GlobalKey();

  /// Whether the chat lists members: a room or a group, not a thread or a DM's two.
  bool get _hasMembers => widget.threadOf == null && (widget.target is RoomTarget || _isGroup);

  /// Whether they go beside the chat (the wide layout's members column, as the desktop has it), not in a sheet.
  bool get _membersBeside => _hasMembers && (PaneScope.maybeOf(context)?.roomForMembers ?? false);

  @override
  Widget build(BuildContext context) {
    // Keyed: the messages keep their place as the members come and go beside them.
    final chat = KeyedSubtree(key: _chatKey, child: _chat(context));
    if (!_membersBeside || !PaneScope.maybeOf(context)!.showMembers) return chat;
    final media = MediaQuery.of(context);
    return ColoredBox(
      color: context.theme.colors.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // The chat measures itself without them.
            child: MediaQuery(
              data: media.copyWith(size: Size(media.size.width - ShellSizes.members - 1, media.size.height)),
              child: chat,
            ),
          ),
          SizedBox(width: 1, child: ColoredBox(color: context.duvet.hairline)),
          SizedBox(
            width: ShellSizes.members,
            child: MembersPanel(repository: _repository, target: widget.target, onPicked: _onMember),
          ),
        ],
      ),
    );
  }

  Widget _chat(BuildContext context) {
    final suggestions = _suggestions();
    final colors = context.theme.colors;
    final isRoom = widget.target is RoomTarget;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) => _onScrollMetrics(n.metrics),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) => _onScrollMetrics(n.metrics),
                child: _body(context),
              ),
            ),
          ),
          // Over the newest messages, just above the composer.
          Positioned(
            left: 12,
            right: 12,
            bottom: _composerHeight + 8,
            child: _SuggestionsPanel(
              label: _slash != null
                  ? 'Commands'
                  : switch (_query?.trigger) {
                      '@' => 'Mention suggestions',
                      '#' => 'Room suggestions',
                      _ => 'Emoji suggestions',
                    },
              children: suggestions,
            ),
          ),
          // Scrolled up: a way back down to the newest.
          if (!_atBottom && suggestions.isEmpty)
            Positioned(
              right: 16,
              bottom: _composerHeight + 12,
              child: Semantics(
                container: true,
                button: true,
                label: 'Jump to the newest messages',
                excludeSemantics: true,
                onTap: _toLatest,
                child: Pressable(
                  onTap: _toLatest,
                  builder: (context, pressed) => Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.card,
                      shape: BoxShape.circle,
                      boxShadow: pressed ? null : context.duvet.shadowRaised,
                    ),
                    child: Icon(FLucideIcons.arrowDown, size: 20, color: colors.foreground),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _MeasureHeight(
              onChange: (h) {
                if (h != _topHeight) setState(() => _topHeight = h);
              },
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  _repository.status,
                  context.voice,
                  _repository.conversations,
                  _repository.presence,
                  // The room's name and description, as they change.
                  _repository.spaces,
                ]),
                builder: (context, _) => GlassTopBar(
                  hairline: _underTop,
                  // The pane's own chat has nothing under it to go back to.
                  onBack: PaneScope.rootOf(context) ? null : () => Navigator.of(context).maybePop(),
                  title: widget.threadOf != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Thread'),
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                            ),
                          ],
                        )
                      : switch (_dmPresence) {
                          final presence? => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(
                                presenceText(presence),
                                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                              ),
                            ],
                          ),
                          null => () {
                            final name = Text.rich(
                              TextSpan(
                                children: [
                                  if (isRoom)
                                    TextSpan(
                                      text: '# ',
                                      style: TextStyle(color: colors.mutedForeground),
                                    ),
                                  TextSpan(text: isRoom ? _roomName : widget.title),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                            // What the room is for, under its name: one line.
                            final description = isRoom ? _room?.description : null;
                            if (description == null) return name;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                name,
                                Text(
                                  description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                ),
                              ],
                            );
                          }(),
                        },
                  onTitle: isRoom && widget.threadOf == null ? _openSwitcher : null,
                  titleLabel: isRoom && widget.threadOf == null
                      ? ['Channel $_roomName', ?_room?.description, 'switch channel'].join(', ')
                      : null,
                  actions: [
                    // One call at a time. Into this conversation's call
                    // going on they join, as its banner's Join does, but not
                    // the user's own while it rings from another device.
                    // One button, as the desktop's: its menu has Voice call
                    // and Video call, which is a voice call with the camera on.
                    if (_callable)
                      Builder(
                        builder: (anchor) => IconAction(
                          icon: FLucideIcons.phone,
                          label: 'Call',
                          onPressed: _canCall ? () => _openCallMenu(anchor) : null,
                        ),
                      ),
                    if (widget.threadOf == null)
                      IconAction(icon: FLucideIcons.search, label: 'Search', onPressed: _openSearch),
                    Builder(
                      builder: (anchor) =>
                          IconAction(icon: FLucideIcons.ellipsis, label: 'More', onPressed: () => _openMore(anchor)),
                    ),
                  ],
                  // The connection's state lives in the chrome, never over
                  // messages; so does a call going on here.
                  bottom: _topBanner(),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _MeasureHeight(
              onChange: (h) {
                if (h != _composerHeight) setState(() => _composerHeight = h);
              },
              child: GlassChrome(
                top: false,
                hairline: _underComposer,
                // The tray runs edge to edge, its files scrolling to the
                // screen's edges; the rest sits 16 in.
                child: Padding(
                  padding: EdgeInsets.fromLTRB(0, 8, 0, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // What a conversation says of its encrypted group, over its message box.
                      if (widget.target case ConversationTarget(:final conversationId))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ValueListenableBuilder(
                            valueListenable: _repository.conversationStates,
                            builder: (context, states, _) {
                              final state = states[conversationId];
                              return ConversationStateBar(
                                state: state,
                                nameOf: _memberName,
                                members: [for (final m in _members) m.displayName],
                                onRestart: () => _restart(conversationId),
                                onAccept: () => _repository.acceptMembers(conversationId),
                              );
                            },
                          ),
                        ),
                      // What other members shared of the conversation's history, the newest three, until the person
                      // adds or dismisses each.
                      if (widget.target case ConversationTarget(:final conversationId))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ValueListenableBuilder(
                            valueListenable: _repository.historyOffers,
                            builder: (context, offers, _) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final offer in offers[conversationId] ?? const [])
                                  SharedHistoryOfferBar(
                                    key: ValueKey(offer.shareId),
                                    offer: offer,
                                    nameOf: _memberName,
                                    onAdd: (offer) => _repository.takeHistoryOffer(conversationId, offer.shareId),
                                    onDismiss: (offer) =>
                                        _repository.dismissHistoryOffer(conversationId, offer.shareId),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _TypingLine(
                          users: [
                            for (final MapEntry(key: id, value: t) in _typing.entries)
                              TypingUser(userId: id, name: t.name, recording: t.recording),
                          ],
                        ),
                      ),
                      if (_files.isNotEmpty && _editing == null)
                        _AttachmentTray(
                          files: _files,
                          onRemove: (f) => setState(() => _files.remove(f)),
                          onToggleSpoiler: (f) => setState(() {
                            final i = _files.indexOf(f);
                            if (i >= 0) _files[i] = f.withSpoiler(!f.isSpoiler);
                          }),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ComposerStrip(
                              reply: _replyTo,
                              onToggleMention: switch (_replyTo) {
                                final r? when _canMentionReplied(r) => _toggleReplyMention,
                                _ => null,
                              },
                              editing: _editing != null,
                              onClose: () {
                                if (_editing != null) {
                                  setState(_stopEditing);
                                } else {
                                  _cancelReply();
                                }
                              },
                            ),
                            if (_recording && !_recordLocked) const _RecordingHint(),
                            // The field stays while recording, unseen: a held Send
                            // keeps its gesture until it's released.
                            Stack(
                              children: [
                                Visibility(
                                  visible: !_recording,
                                  maintainState: true,
                                  maintainAnimation: true,
                                  maintainSize: true,
                                  maintainInteractivity: true,
                                  maintainSemantics: false,
                                  child: _ComposerField(
                                    controller: _composer,
                                    focusNode: _focus,
                                    hint: widget.threadOf != null
                                        ? 'Reply in thread'
                                        : 'Message ${widget.title.replaceFirst('# ', '#')}',
                                    canSend: _canSend,
                                    editing: _editing != null,
                                    onAttach: _openAttachMenu,
                                    onEmoji: _openPicker,
                                    onSend: _send,
                                    onHoldStart: () => _startRecording(locked: false),
                                    onHoldMove: _onHoldMove,
                                    onHoldEnd: _onHoldEnd,
                                  ),
                                ),
                                if (_recording)
                                  Positioned.fill(
                                    child: _RecordingField(
                                      elapsed: _recorded,
                                      levels: _levels,
                                      locked: _recordLocked,
                                      slide: _recordSlide,
                                      onCancel: () => _stopRecording(send: false),
                                      onSend: () => _stopRecording(send: true),
                                    ),
                                  ),
                              ],
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
        ],
      ),
    );
  }

  bool get _canSend => _composer.text.trim().isNotEmpty || (_files.isNotEmpty && _editing == null);

  /// [pinned]: in the pins, where a reply or a quote tapped closes them
  /// first, and holding it does nothing.
  Widget _bubbleFor(_Entry entry, {bool lifted = false, bool first = true, bool last = true, bool pinned = false}) {
    final m = entry.message;
    void closingPins(VoidCallback then) {
      if (pinned) Navigator.of(context).pop();
      then();
    }

    return _Bubble(
      key: lifted ? null : ValueKey(m.nonce ?? m.id),
      entry: entry,
      mine: m.authorId != null && m.authorId == _me,
      me: _me,
      firstOfRun: first,
      lastOfRun: last,
      lifted: lifted,
      directory: _directory,
      stickerName: m.stickerUrl == null ? null : _stickerList.where((s) => s.url == m.stickerUrl).firstOrNull?.name,
      editing: _editing?.id == m.id,
      flash: _flash == m.id,
      waiting: entry.delivery == _Delivery.sending && _repository.status.value == LiveStatus.reconnecting,
      onRetry: entry.delivery == _Delivery.failed ? () => _retry(entry) : null,
      onDiscard: entry.delivery == _Delivery.failed ? () => _discard(entry) : null,
      onReply: () => closingPins(() => _startReply(m)),
      onJump: (id) => closingPins(() => _jumpTo(id)),
      onReact: (emoji, emojiId) => _toggleReaction(m, emoji, emojiId: emojiId),
      onMoreReactions: () => _pickReaction(m),
      onOpenReactors: (r) => _openReactors(m, r),
      onLongPress: pinned ? null : (anchor) => _messageActions(anchor, entry),
      progress: m.nonce == null ? null : _progress[m.nonce],
      // Once every byte is up the API may post the message whatever comes
      // next, so there's nothing left to cancel: it shows as being sent.
      onCancelUpload: entry.delivery == _Delivery.sending && (_progress[m.nonce] ?? 0) < 1
          ? () => _cancelUpload(entry)
          : null,
      tooLarge: m.nonce != null && _tooLarge.contains(m.nonce),
      onOpenLink: _openLink,
      onOpenSpace: _openSpace,
      onOpenAuthor: () => _openAuthor(m),
      onOpenMention: _openMention,
      onOpenRoom: _openRoom,
      onUseComponent: (component, values) => _useComponent(m, component, values),
      selectChoices: _selectChoices,
      onDismiss: m.isEphemeral ? () => _dismiss(m) : null,
      // Not in the pins: a copy there is lit already.
      // Nor one that shone in another view of the chat, a thread over it.
      onShine: !pinned && _unshone.contains(m.id) && !_shone.contains(m.id)
          ? () {
              _unshone.remove(m.id);
              _shone.add(m.id);
            }
          : null,
    );
  }

  /// A quick first line goes into the composer to edit or send, not straight out.
  void _startWith(String line) {
    _composer.value = TextEditingValue(
      text: line,
      selection: TextSelection.collapsed(offset: line.length),
    );
    _focus.requestFocus();
  }

  // Nothing to show yet: messages drawn as blocks, crossed into the list once
  // it comes. Only that change fades; the list itself is updated in place.
  Widget _body(BuildContext context) => AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.panelOut,
    switchInCurve: DuvetTokens.decelerate,
    layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
    child: _loading && _entries.isEmpty && _lookedForKept
        ? KeyedSubtree(
            key: const ValueKey('skeleton'),
            child: _MessagesSkeleton(
              flat: AppearanceScope.maybeOf(context)?.messageLayout == MessageLayout.flat,
              padding: EdgeInsets.fromLTRB(
                16,
                (_topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight) + 8,
                16,
                _composerHeight + 8,
              ),
            ),
          )
        : KeyedSubtree(key: const ValueKey('messages'), child: _messages(context)),
  );

  Widget _messages(BuildContext context) {
    if (_error != null && _entries.isEmpty) {
      return EmptyState(
        mascot: MascotState.oops,
        text: 'Couldn’t load messages',
        action: DuvetButton(label: 'Try again', onPressed: _load),
      );
    }
    if (_loading && _entries.isEmpty) return const SizedBox.shrink();
    if (_entries.isEmpty) {
      // A new DM: the ghost tucked in, and a first line to start with.
      if (widget.target is ConversationTarget && widget.threadOf == null) {
        final start = _start;
        final empty = EmptyState(
          mascot: MascotState.underDuvet,
          text: 'Just you and ${widget.title}',
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final line in const ['Hi!', 'How’s it going?'])
                DuvetChip(label: line, selected: false, action: true, onTap: () => _startWith(line)),
            ],
          ),
        );
        return start == null
            ? empty
            : Column(
                children: [
                  SizedBox(height: _topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight),
                  start,
                  Expanded(child: empty),
                ],
              );
      }
      return const EmptyState(mascot: MascotState.empty, text: 'No messages yet. Say hi!');
    }
    final items = _items(flat: AppearanceScope.maybeOf(context)?.messageLayout == MessageLayout.flat);
    final count = items.length + (_loadingOlder ? 1 : 0);
    final top = _topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight;
    // Where each message is now: one kept alive off screen (a YouTube video playing) follows it as newer ones come.
    final indexOf = <Key, int>{
      for (final (i, item) in items.indexed)
        if (item case _Message(:final entry)) ?_keys[entry.message.id]: items.length - 1 - i,
    };
    return FadeTransition(
      opacity: _reveal,
      // The mentions' light goes by what shows of the list, between the bars.
      child: PrismViewport(
        top: top,
        bottom: _composerHeight,
        child: ListView.builder(
          controller: _scroll,
          reverse: true,
          findChildIndexCallback: (key) => indexOf[key],
          // A list with its own controller only scrolls once full: a short chat bounces too.
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(16, top + 8, 16, _composerHeight + 8),
          itemCount: count,
          itemBuilder: (context, index) {
            if (index == items.length) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: FCircularProgress(size: .sm)),
              );
            }
            return switch (items[items.length - 1 - index]) {
              _Start() => _start ?? const SizedBox.shrink(),
              _Day(:final day) => _DaySeparator(day: day),
              _NewMessages(:final count) => _NewMessagesDivider(
                key: _dividerKey,
                text: count == 1 ? '1 new message' : '$count new messages',
              ),
              _Replies(:final count) => _NewMessagesDivider(
                text: count == 1 ? '1 reply' : '$count replies',
                quiet: true,
              ),
              _Message(:final entry, :final first, :final last) =>
                entry.message.isNotice
                    ? switch ((callNoticeLine(entry.message, _me), entry.message.sharedHistory)) {
                        (final line?, _) => _CallNoticeRow(
                          line: line,
                          onHold: _canDeleteNotices ? (anchor) => _noticeActions(anchor, entry.message) : null,
                        ),
                        (_, final shared?) => _SharedNoticeRow(
                          parts: _sharedParts(entry.message, shared),
                          onHold: _canDeleteNotices ? (anchor) => _noticeActions(anchor, entry.message) : null,
                        ),
                        _ => _Notice(
                          who: entry.message.authorName,
                          where: widget.target is RoomTarget ? 'room' : 'conversation',
                          onJump: switch (entry.message.reply?.messageId) {
                            final id? => () => _jumpTo(id),
                            null => null,
                          },
                          onPins: _openPins,
                          onHold: _canDeleteNotices ? (anchor) => _noticeActions(anchor, entry.message) : null,
                        ),
                      }
                    : KeyedSubtree(
                        key: _keyFor(entry.message.id),
                        child: _boundary(
                          CompositedTransformTarget(
                            link: _linkFor(entry.message.id),
                            child: _Vanish(
                              hidden: _vanishing.contains(entry.message.id),
                              closed: _closing.contains(entry.message.id),
                              child: _bubbleFor(entry, first: first, last: last),
                            ),
                          ),
                        ),
                      ),
            };
          },
        ),
      ),
    );
  }

  /// Its own layer, for the picture a delete breaks up. Measured for #64
  /// (`test/benchmark/message_boundary.dart`, the test binding): one more
  /// OffsetLayer for each message built, 9 to 11 of some 100 layers on a
  /// phone, in a chat of 300 messages as in one of 3000, as the list only
  /// builds those near the screen; and a scrolled frame's time on the UI
  /// thread with it and without differs by less than two runs of either.
  /// Raster time and memory on a device aren't measured.
  Widget _boundary(Widget child) => ChatView.debugMessageBoundary ? RepaintBoundary(child: child) : child;

  /// The entries, oldest first, with a separator where the day changes, the
  /// "N new messages" divider after the last one read (or above [_unreadFrom]),
  /// and each message marked first and last of its run: one author, minutes
  /// apart. A webhook has no author ID: its own ID and the name it posts under
  /// stand in, as on the desktop. A person's name isn't compared: the history
  /// names them by their Space nickname, which live messages may not know.
  /// In [flat] rows a reply starts a run too (see [_sameRun]).
  List<_Item> _items({required bool flat}) {
    // Over the oldest message, once no older page is left: what an encrypted conversation's start says.
    final items = <_Item>[if (!_hasOlder && widget.threadOf == null && _start != null) const _Start()];
    for (var i = 0; i < _entries.length; i++) {
      final m = _entries[i].message;
      final previous = i > 0 ? _entries[i - 1].message : null;
      final next = i + 1 < _entries.length ? _entries[i + 1].message : null;
      final day = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      final newDay = previous == null || !_sameDay(previous.createdAt, m.createdAt);
      if (newDay) items.add(_Day(day));
      final unreadStart = _unreadFrom != null ? m.id == _unreadFrom : previous != null && previous.id == _unreadAfter;
      if (unreadStart) items.add(_NewMessages(_entries.length - i));
      if (widget.threadOf != null && i == 1) items.add(_Replies(_entries.length - 1));
      final nextBreaks = next == null || (_unreadFrom != null ? next.id == _unreadFrom : m.id == _unreadAfter);
      items.add(
        _Message(
          _entries[i],
          first: newDay || unreadStart || !_sameRun(previous, m, flat: flat),
          last: nextBreaks || !_sameRun(m, next, flat: flat),
        ),
      );
    }
    return items;
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Whether [b] goes on [a]'s run. In [flat] rows, as the desktop groups
  /// them (`message-groups.ts`), a reply or a bot's answer to an interaction
  /// starts a group of its own: its quote goes over its own head line.
  static bool _sameRun(ChatMessage? a, ChatMessage? b, {bool flat = false}) =>
      a != null &&
      b != null &&
      !a.isNotice &&
      !b.isNotice &&
      a.authorId == b.authorId &&
      a.webhookId == b.webhookId &&
      (a.authorId != null || a.authorName == b.authorName) &&
      a.isEphemeral == b.isEphemeral &&
      _sameDay(a.createdAt, b.createdAt) &&
      b.createdAt.difference(a.createdAt).abs() <= const Duration(minutes: 5) &&
      (!flat || (b.reply == null && b.interaction == null));
}

/// A message on its way out: hidden while it goes to dust, its place held,
/// then that place eased shut.
class _Vanish extends StatelessWidget {
  final bool hidden;
  final bool closed;
  final Widget child;
  const _Vanish({required this.hidden, required this.closed, required this.child});

  static const closing = Duration(milliseconds: 450);

  @override
  Widget build(BuildContext context) => ClipRect(
    // Only while it closes: a bubble's shadow reaches past its row.
    clipBehavior: hidden ? Clip.hardEdge : Clip.none,
    child: AnimatedAlign(
      alignment: Alignment.topCenter,
      heightFactor: closed ? 0 : 1,
      duration: closing,
      curve: Curves.easeInOutCubic,
      // Hidden at once for dust, which takes its place; faded as it closes
      // when it goes without.
      child: AnimatedOpacity(opacity: hidden ? 0 : 1, duration: closed ? closing * 0.6 : Duration.zero, child: child),
    ),
  );
}

sealed class _Item {
  const _Item();
}

/// The chat's start, over its oldest message: what an encrypted conversation says there ([ConversationStart]).
class _Start extends _Item {
  const _Start();
}

class _Day extends _Item {
  final DateTime day;
  const _Day(this.day);
}

class _NewMessages extends _Item {
  /// The messages below it, as the desktop counts them.
  final int count;
  const _NewMessages(this.count);
}

/// In a thread, between its root and the replies.
class _Replies extends _Item {
  final int count;
  const _Replies(this.count);
}

class _Message extends _Item {
  final _Entry entry;
  final bool first;
  final bool last;
  const _Message(this.entry, {required this.first, required this.last});
}

/// Reports its child's height after each layout: the list pads for the bars
/// laid over it.
class _MeasureHeight extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onChange;
  const _MeasureHeight({required this.onChange, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureHeight(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureHeight renderObject) => renderObject.onChange = onChange;
}

class _RenderMeasureHeight extends RenderProxyBox {
  ValueChanged<double> onChange;
  double? _last;
  _RenderMeasureHeight(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _last) return;
    _last = height;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(height));
  }
}

/// A take's waveform from its levels (0 to 1, a tenth of a second each): [waveformSamples] peaks, each the loudest of
/// its stretch of the take, a byte each.
List<int> peaksOf(List<double> levels) {
  final n = levels.length;
  return [
    for (var i = 0; i < waveformSamples; i++)
      (levels
                  .sublist(i * n ~/ waveformSamples, max(i * n ~/ waveformSamples + 1, (i + 1) * n ~/ waveformSamples))
                  .fold(0.0, max) *
              255)
          .round()
          .clamp(0, 255),
  ];
}
