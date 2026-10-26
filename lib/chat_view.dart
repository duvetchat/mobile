import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:clock/clock.dart' as time show clock;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'calls.dart';
import 'data/emoji_catalog.dart';
import 'data/links.dart';
import 'data/message_tokens.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'data/voice.dart' show VoiceController;
import 'members_sheet.dart';
import 'people.dart';
import 'search.dart';
import 'space_admin.dart' show askDescription, askName, confirmDestructive, RoomPermissionsPage;
import 'spaces.dart' show showInviteSheet;
import 'tabs.dart' show SpaceDirectory;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/bot_ui.dart';
import 'widgets/chrome.dart';
import 'widgets/disintegrate.dart';
import 'widgets/composer_controller.dart';
import 'widgets/depth.dart';
import 'widgets/emoji_picker.dart';
import 'widgets/glass.dart';
import 'widgets/link_embeds.dart';
import 'widgets/media.dart';
import 'widgets/message_content.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart';

part 'chat/actions.dart';
part 'chat/bubble.dart';
part 'chat/composer.dart';
part 'chat/reactors.dart';

/// Pushes the Chat View over everything, the tab bar included.
void openChat(BuildContext context, ChatTarget target, String title) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    builder: (_) => ChatView(target: target, title: title),
  ),
);

enum _Delivery { sent, sending, failed }

typedef _Entry = ({ChatMessage message, _Delivery delivery});

/// What a pending message carries, kept to send it again.
typedef _Outgoing = ({String content, List<OutgoingFile> files, Sticker? sticker, String? replyTo, Recording? voice});

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

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  static const _pageSize = 100;
  static const _typingFor = Duration(seconds: 6);
  static const _typingEvery = Duration(seconds: 5);

  late final _composer = ComposerController(accent: () => context.duvet.accentText);
  final _scroll = ScrollController();
  final _random = Random();
  final _focus = FocusNode();

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

  // The last message read when the chat opened: the "New messages" divider
  // goes after it.
  String? _unreadAfter;
  final _dividerKey = GlobalKey();
  final _keys = <String, GlobalKey>{};

  /// Messages being deleted, gone to dust: their place stays a moment,
  /// then [_closing] it closes up.
  final _vanishing = <String>{};
  final _closing = <String>{};

  /// Messages the user deleted, from the confirming to the list closing up.
  final _deleting = <String>{};
  String? _flash;

  // The chat is read where the reader sees it, as the desktop acks it: with
  // the app in front and this chat on top, on opening wherever the list opens
  // (once it's seen, if it opened unseen), then at the bottom of the list. The
  // newest message read from here is acked once.
  bool _atBottom = true;
  bool _onTop = true;
  bool _opening = false;
  String? _acked;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    EmojiCatalog.load().then((c) {
      if (mounted) setState(() => _catalog = c);
    }, onError: (Object e) => debugPrint('emoji: $e'));
    _lifecycle = AppLifecycleListener(onResume: _readIfSeen);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Back on top (a thread or a chat opened over this one was closed): what
    // came meanwhile is read, at the bottom, once this build is done.
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (onTop != _onTop) {
      _onTop = onTop;
      if (onTop) WidgetsBinding.instance.addPostFrameCallback((_) => _readIfSeen());
    }
    if (_events != null) return;
    _repository = context.repository;
    // Listen before loading, so nothing sent meanwhile is missed.
    _events = _repository.messageEvents(widget.target).listen(_onEvent);
    _typingSub = _repository.typing(widget.target).listen(_onTyping);
    _resumedSub = _repository.resumed.listen((_) => _catchUp());
    if (widget.threadOf == null && _repository.unread.value.contains(widget.target.id)) {
      _unreadAfter = _repository.lastReadOf(widget.target);
    }
    _restoreDraft();
    _composer.addListener(_onComposerChanged);
    _scroll.addListener(_onScroll);
    _voice = context.voice..addListener(_onVoice);
    _load();
    _loadDirectory();
  }

  @override
  void dispose() {
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
    _composer.restore(draft.text, mentions: draft.mentions, emojis: draft.emojis);
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
    _repository.customEmojis(widget.target).then((e) {
      if (mounted) setState(() => _customEmojis = e);
    }, onError: (Object e) => debugPrint('emojis: $e'));
    if (widget.target case RoomTarget(:final spaceId)) {
      _repository.commands(spaceId).then((c) {
        if (mounted) setState(() => _commands = c);
      }, onError: (Object e) => debugPrint('commands: $e'));
    }
    _stickers = _repository.stickers(widget.target);
    _stickers.then((s) {
      if (mounted) setState(() => _stickerList = s);
    }, onError: (Object e) => debugPrint('stickers: $e'));
  }

  MessageDirectory get _directory {
    final names = {for (final m in _members) m.userId: m.displayName};
    final emojis = {for (final e in _customEmojis) e.id: e};
    return MessageDirectory(me: _me, nameOf: (id) => names[id] ?? _repository.nameOf(id), emojiOf: (id) => emojis[id]);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final thread = widget.threadOf;
      final page = thread == null
          ? await _repository.messages(widget.target)
          : await _repository.thread(widget.target, thread);
      if (!mounted) return;
      final loaded = {for (final m in page) m.id};
      // Keep what the gateway pushed while the page loaded.
      final pushed = [
        for (final e in _entries)
          if (!loaded.contains(e.message.id)) e,
      ];
      final shown = {...loaded, for (final e in pushed) e.message.id};
      // The bots' answers to the user alone, which no history has, show among
      // the room's messages, by time.
      final ephemeral = [
        for (final m in thread == null ? _repository.ephemeralIn(widget.target) : const <ChatMessage>[])
          if (!shown.contains(m.id)) m,
      ];
      setState(() {
        _entries = [for (final m in _byTime(page, ephemeral)) (message: m, delivery: _Delivery.sent), ...pushed];
        _hasOlder = thread == null && page.length >= _pageSize;
        _loading = false;
        // Nothing after the last read: no divider.
        if (_unreadAfter != null && page.lastOrNull?.id == _unreadAfter) _unreadAfter = null;
      });
      if (thread == null) {
        _repository.opened(widget.target, widget.title, latest: page.lastOrNull);
        _opening = true;
        _readIfSeen();
      }
      if (widget.jumpTo case final id?) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(id));
      } else if (_unreadAfter != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showDivider());
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

  /// Brings the "New messages" divider into view, near the top.
  Future<void> _showDivider() async {
    if (!mounted || !_entries.any((e) => e.message.id == _unreadAfter)) return;
    if (await _scrollUntilBuilt(() => _dividerKey.currentContext)) {
      final ctx = _dividerKey.currentContext;
      if (ctx != null && ctx.mounted) await Scrollable.ensureVisible(ctx, alignment: 0.15);
    }
  }

  Future<void> _loadOlder() async {
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
        _hasOlder = page.length >= _pageSize;
      });
    } catch (_) {
      // Scrolling up again retries.
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// What came while the socket was down: everything after the newest
  /// message here.
  Future<void> _catchUp() async {
    final newest = _history.lastOrNull;
    if (newest == null) return;
    try {
      final missed = await _repository.messagesAfter(widget.target, newest.id);
      if (!mounted || missed.isEmpty) return;
      setState(() {
        for (final m in missed) {
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
    _atBottom = atBottom;
    if (atBottom) _readIfSeen();
  }

  /// Reads the chat up to its newest message.
  void _markRead() {
    final newest = _history.lastOrNull;
    if (newest == null || newest.id == _acked) return;
    _acked = newest.id;
    _repository.markRead(widget.target, newest.id);
  }

  /// Reads the chat if the reader sees it: the app in front and nothing
  /// opened over the chat (not a thread), and, past its opening, the bottom
  /// of the list.
  void _readIfSeen() {
    if (!mounted || widget.threadOf != null || !_onTop || !_inFront || !(_atBottom || _opening)) return;
    _opening = false;
    _markRead();
  }

  static bool get _inFront => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  void _onEvent(MessageEvent event) {
    if (event case ReactionChanged(:final messageId) when !_entries.any((e) => e.message.id == messageId)) return;
    // A profile change that shows nothing new on the messages here.
    if (event is AuthorChanged && _entries.every((e) => identical(e.message.changedBy(event), e.message))) return;
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
          _upsert(message);
        case MessageUpdated(:final message):
          _applyUpdate(message);
        case MessageDeleted(:final messageId):
          // One the user deleted is going to dust: that takes it away after.
          if (!_deleting.contains(messageId)) _closeUp(messageId);
          if (_editing?.id == messageId) _stopEditing();
        case MessagePinned(:final messageId, :final pinned):
          final i = _entries.indexWhere((e) => e.message.id == messageId);
          if (i >= 0) {
            _entries[i] = (message: _entries[i].message.copyWith(pinned: pinned), delivery: _entries[i].delivery);
          }
        case ReactionChanged(:final messageId, :final userId, :final emoji, :final emojiId, :final added):
          final i = _entries.indexWhere((e) => e.message.id == messageId);
          // The user's own come back as an echo of what's shown already.
          final m = _entries[i].message;
          final has = m.reactions.any((r) => r.emoji == emoji && r.users.contains(userId));
          if (has != added) {
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
      }
    });
    if (event is MessageCreated) _readIfSeen();
  }

  /// An edit, or a link preview that came late, merged into the message (see
  /// [ChatMessage.updatedBy]); the replies quoting it follow its text, as on
  /// the desktop.
  void _applyUpdate(ChatMessage update) {
    for (var i = 0; i < _entries.length; i++) {
      final m = _entries[i].message;
      if (m.id == update.id) {
        _entries[i] = (message: m.updatedBy(update), delivery: _Delivery.sent);
      } else if (m.reply case final reply? when reply.messageId == update.id) {
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
    final entry = (message: message, delivery: _Delivery.sent);
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
    final slash = _commands.isNotEmpty && _editing == null && _canUseCommands && RegExp(r'^/\S*$').hasMatch(text)
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

  String _nonce() => '${DateTime.now().microsecondsSinceEpoch}${_random.nextInt(1 << 20)}';

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
    // `/name` of a command runs it.
    if (_files.isEmpty && content.startsWith('/') && _canUseCommands) {
      final command = _commands.where((c) => '/${c.name}' == content).firstOrNull;
      if (command != null) return _runCommand(command);
    }
    // Files over the upload limit stay in the tray, with the reason.
    if (_files.isNotEmpty) {
      final limit = await _repository.uploadLimit();
      if (!mounted) return;
      final over = [
        for (final f in _files)
          if (limit != null && (f.sizeBytes ?? 0) > limit) f,
      ];
      if (over.isNotEmpty) {
        _toast(
          over.length == 1
              ? '${over.single.name} is over your ${_megabytes(limit!)} upload limit'
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
    _queue((content: content, files: files, sticker: null, replyTo: to, voice: null), reply: replyTo);
  }

  static String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  void _sendSticker(Sticker sticker) => _sendPicked(sticker: sticker);

  void _sendGif(String url) => _sendPicked(content: url);

  // A sticker or a GIF answers the message being replied to, as a text does
  // (on the desktop they all go out the same way), and the strip closes.
  void _sendPicked({String content = '', Sticker? sticker}) {
    final reply = _replyTo;
    if (reply != null) setState(() => _replyTo = null);
    final to = reply?.messageId ?? widget.threadOf;
    _queue((content: content, files: const [], sticker: sticker, replyTo: to, voice: null), reply: reply);
  }

  void _sendVoice(Recording recording) =>
      _queue((content: '', files: const [], sticker: null, replyTo: null, voice: recording));

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
        sent = await _repository.sendVoiceNote(widget.target, voice.bytes, nonce: nonce, format: voice.format);
      } else {
        sent = await _repository.send(
          widget.target,
          outgoing.content,
          nonce: nonce,
          files: outgoing.files,
          sticker: outgoing.sticker,
          replyTo: outgoing.replyTo,
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

  /// Stops an upload: the message goes, its files back to the tray.
  void _cancelUpload(_Entry entry) {
    final nonce = entry.message.nonce;
    if (nonce == null) return;
    _cancels[nonce]?.complete();
    final outgoing = _outgoing.remove(nonce);
    setState(() {
      _entries.remove(entry);
      _progress.remove(nonce);
      if (outgoing != null && _editing == null) _files.addAll(outgoing.files.take(maxFiles - _files.length));
    });
    _announce('Upload cancelled');
  }

  void _retry(_Entry entry) {
    final nonce = entry.message.nonce;
    if (nonce == null || !_outgoing.containsKey(nonce)) return;
    setState(() {
      final i = _entries.indexOf(entry);
      if (i >= 0) _entries[i] = (message: entry.message, delivery: _Delivery.sending);
    });
    _deliver(nonce);
  }

  /// Drops a message that failed to send, and what it carried.
  void _discard(_Entry entry) {
    setState(() {
      _entries.remove(entry);
      _outgoing.remove(entry.message.nonce);
    });
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
    _levelsSub = recorder.levels.listen((l) {
      if (!mounted) return;
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
      );
    });
    _focus.requestFocus();
    _announce('Replying to ${m.authorName}');
  }

  void _cancelReply() => setState(() => _replyTo = null);

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
    _composer.setEncoded(m.content, nameOf: directory.nameOf, emojiNameOf: (id) => directory.emojiOf(id)?.name);
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
        if (disintegrate(context, key) case final dust?) {
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
    final add = !current.reactions.any((r) => r.emoji == emoji && r.users.contains(me));
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
      inSpace: widget.target is RoomTarget,
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
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatView(target: target, title: title, jumpTo: link.messageId),
      ),
    );
  }

  void _openSpace(String spaceId) {
    final space = _repository.spaces.value.where((s) => s.id == spaceId).firstOrNull;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => SpaceDirectory(spaceId: spaceId, name: space?.name ?? 'Space'),
      ),
    );
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// Scrolls toward older messages until [find] has a context (its item got
  /// built), or the list runs out. Answers whether it was found.
  Future<bool> _scrollUntilBuilt(BuildContext? Function() find) async {
    for (var tries = 0; tries < 40 && mounted; tries++) {
      if (find() != null) return true;
      if (!_scroll.hasClients) return false;
      final position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) {
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
    final found = _entries.any((e) => e.message.id == messageId) || _hasOlder
        ? await _scrollUntilBuilt(() => _keys[messageId]?.currentContext)
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
      inSpace: widget.target is RoomTarget,
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
      _ => null,
    };
    final call = _callable && CallBanner.shows(context.voice, widget.target.id)
        ? CallBanner(conversationId: widget.target.id)
        : null;
    if (status == null || call == null) return status ?? call;
    return Column(mainAxisSize: MainAxisSize.min, children: [status, const SizedBox(height: 8), call]);
  }

  Future<void> _openMore(BuildContext anchor) async {
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
        const GlassMenuItem(icon: FLucideIcons.users, label: 'Members', value: 'members'),
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
        await _openMembers();
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
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => ChatView(target: room.target, title: '# ${room.name}'),
      ),
    );
  }

  Future<void> _openPins() async {
    final picked = await showPinsSheet(
      context,
      pins: () => _repository.pins(widget.target),
      changes: _repository.messageEvents(widget.target).where((e) => e is MessagePinned),
      where: _where,
      directory: _directory,
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

  void _openThread(ChatMessage m) => Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatView(target: widget.target, title: widget.title, threadOf: m.id),
    ),
  );

  Future<void> _openSearch() async {
    final hit = await Navigator.of(context, rootNavigator: true).push<SearchHit>(
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
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatView(target: target, title: title, jumpTo: messageId),
        ),
      );

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
      case MemberAction.profile:
        await _openProfile(member);
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
          Member(userId: id, username: m.authorName, avatarUrl: m.authorAvatarUrl),
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
      lifted: _bubbleFor(entry, lifted: true),
      me: _me,
      reactions: sent ? m.reactions : null,
      catalog: _catalog,
      items: items,
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case (_Action.react, final emoji?):
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
    } catch (_) {
      _toast('${m.authorName} didn’t answer. Try again.');
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
    } catch (_) {
      _toast('${command.appName} didn’t answer /${command.name}. Try again.');
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
        for (final c in _commands.where((c) => c.name.toLowerCase().startsWith(needle)).take(5))
          GlassRow(
            label: '/${c.name}',
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
          .take(5)
          .toList();
      final contains = needle.isEmpty
          ? const <Member>[]
          : others
                .where((m) => !starts.contains(m) && m.displayName.toLowerCase().contains(needle))
                .take(5 - starts.length);
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
    final custom = _customEmojis.where((e) => e.name.toLowerCase().contains(needle)).take(3).toList();
    final unicode = _catalog?.search(q.query, limit: 5 - custom.length) ?? const <EmojiEntry>[];
    return [
      for (final e in custom)
        GlassRow(
          label: ':${e.name}:',
          hint: 'Double tap to insert',
          leading: Image.network(
            e.url,
            width: 28,
            height: 28,
            cacheWidth: (28 * MediaQuery.devicePixelRatioOf(context)).round(),
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
          leading: ExcludeSemantics(child: Text(e.emoji, style: const TextStyle(fontSize: 26, height: 1.1))),
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

  @override
  Widget build(BuildContext context) {
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
                  : _query?.trigger == '@'
                  ? 'Mention suggestions'
                  : 'Emoji suggestions',
              children: suggestions,
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
                  onBack: () => Navigator.of(context).maybePop(),
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
                    if (_callable)
                      IconAction(
                        icon: FLucideIcons.phone,
                        label: 'Call',
                        // One call at a time; this conversation's own is in the banner.
                        onPressed:
                            context.voice.call == null && !context.voice.callsInProgress.contains(widget.target.id)
                            ? () => callConversation(context, widget.target.id)
                            : null,
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
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TypingLine(
                        users: [
                          for (final MapEntry(key: id, value: t) in _typing.entries)
                            TypingUser(userId: id, name: t.name, recording: t.recording),
                        ],
                      ),
                      if (_files.isNotEmpty && _editing == null)
                        _AttachmentTray(files: _files, onRemove: (f) => setState(() => _files.remove(f))),
                      _ComposerStrip(
                        reply: _replyTo,
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
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _canSend => _composer.text.trim().isNotEmpty || (_files.isNotEmpty && _editing == null);

  Widget _bubbleFor(_Entry entry, {bool lifted = false, bool first = true, bool last = true}) {
    final m = entry.message;
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
      onReply: () => _startReply(m),
      onJump: _jumpTo,
      onReact: (emoji, emojiId) => _toggleReaction(m, emoji, emojiId: emojiId),
      onMoreReactions: () => _pickReaction(m),
      onOpenReactors: (r) => _openReactors(m, r),
      onLongPress: (anchor) => _messageActions(anchor, entry),
      progress: m.nonce == null ? null : _progress[m.nonce],
      onCancelUpload: entry.delivery == _Delivery.sending ? () => _cancelUpload(entry) : null,
      tooLarge: m.nonce != null && _tooLarge.contains(m.nonce),
      onOpenLink: _openLink,
      onOpenSpace: _openSpace,
      onOpenAuthor: () => _openAuthor(m),
      onOpenMention: _openMention,
      onUseComponent: (component, values) => _useComponent(m, component, values),
      selectChoices: _selectChoices,
      onDismiss: m.isEphemeral ? () => _dismiss(m) : null,
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.theme.colors;
    if (_loading && _entries.isEmpty) return const Center(child: FCircularProgress());
    if (_error != null && _entries.isEmpty) {
      return EmptyState(
        icon: FLucideIcons.cloudOff,
        text: 'Couldn’t load messages',
        action: DuvetButton(label: 'Try again', onPressed: _load),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('No messages yet. Say hi!', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
      );
    }
    final items = _items();
    final count = items.length + (_loadingOlder ? 1 : 0);
    final top = _topHeight == 0 ? GlassTopBar.heightOf(context) : _topHeight;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
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
          _Day(:final day) => _DaySeparator(day: day),
          _NewMessages() => _NewMessagesDivider(key: _dividerKey),
          _Replies(:final count) => _NewMessagesDivider(text: count == 1 ? '1 reply' : '$count replies', quiet: true),
          _Message(:final entry, :final first, :final last) =>
            entry.message.isNotice
                ? _Notice(text: '${entry.message.authorName} pinned a message')
                : KeyedSubtree(
                    key: _keyFor(entry.message.id),
                    // Its own layer, for the picture a delete breaks up.
                    child: RepaintBoundary(
                      child: _Vanish(
                        hidden: _vanishing.contains(entry.message.id),
                        closed: _closing.contains(entry.message.id),
                        child: _bubbleFor(entry, first: first, last: last),
                      ),
                    ),
                  ),
        };
      },
    );
  }

  /// The entries, oldest first, with a separator where the day changes, the
  /// "New messages" divider after the last one read, and each message marked
  /// first and last of its run: one author, minutes apart. A webhook has no
  /// author ID: its own ID and the name it posts under stand in, as on the
  /// desktop. A person's name isn't compared: the history names them by
  /// their Space nickname, which live messages may not know.
  List<_Item> _items() {
    final items = <_Item>[];
    for (var i = 0; i < _entries.length; i++) {
      final m = _entries[i].message;
      final previous = i > 0 ? _entries[i - 1].message : null;
      final next = i + 1 < _entries.length ? _entries[i + 1].message : null;
      final day = DateTime(m.createdAt.year, m.createdAt.month, m.createdAt.day);
      final newDay = previous == null || !_sameDay(previous.createdAt, m.createdAt);
      if (newDay) items.add(_Day(day));
      final unreadStart = previous != null && previous.id == _unreadAfter;
      if (unreadStart) items.add(const _NewMessages());
      if (widget.threadOf != null && i == 1) items.add(_Replies(_entries.length - 1));
      final nextBreaks = next == null || m.id == _unreadAfter;
      items.add(
        _Message(
          _entries[i],
          first: newDay || unreadStart || !_sameRun(previous, m),
          last: nextBreaks || !_sameRun(m, next),
        ),
      );
    }
    return items;
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _sameRun(ChatMessage? a, ChatMessage? b) =>
      a != null &&
      b != null &&
      !a.isNotice &&
      !b.isNotice &&
      a.authorId == b.authorId &&
      a.webhookId == b.webhookId &&
      (a.authorId != null || a.authorName == b.authorName) &&
      a.isEphemeral == b.isEphemeral &&
      _sameDay(a.createdAt, b.createdAt) &&
      b.createdAt.difference(a.createdAt).abs() <= const Duration(minutes: 5);
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

class _Day extends _Item {
  final DateTime day;
  const _Day(this.day);
}

class _NewMessages extends _Item {
  const _NewMessages();
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
