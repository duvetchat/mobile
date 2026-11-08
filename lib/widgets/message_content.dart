import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart'
    show PlayerState, YoutubePlayerController, YoutubeValueBuilder;

import '../data/appearance.dart';
import '../data/code_theme.dart';
import '../data/emoji_catalog.dart';
import '../data/links.dart';
import '../data/markdown.dart';
import '../deep_links.dart';
import '../data/message_tokens.dart';
import '../data/models.dart';
import '../theme.dart';
import 'apng.dart';
import 'attachment_link.dart';
import 'code_highlight.dart';
import 'depth.dart';
import 'glass.dart';
import 'media.dart';
import 'media_actions.dart';
import 'role_name.dart';
import 'youtube_dock.dart';

/// What a bubble needs to show names and custom emoji.
class MessageDirectory {
  final String? me;
  final String? Function(String userId) nameOf;
  final CustomEmoji? Function(String emojiId) emojiOf;

  /// A room the user may see; null for one hidden or gone.
  final Room? Function(String roomId) roomOf;

  /// A member's name colors in this Space (see [nameColorsOf]); null outside one or without a colored role.
  final RoleColors? Function(String userId) nameColorsOf;
  const MessageDirectory({
    required this.me,
    required this.nameOf,
    required this.emojiOf,
    this.roomOf = _noRoom,
    this.nameColorsOf = _noColors,
  });

  static String? _noName(String _) => null;
  static RoleColors? _noColors(String _) => null;
  static CustomEmoji? _noEmoji(String _) => null;
  static Room? _noRoom(String _) => null;
  static const empty = MessageDirectory(me: null, nameOf: _noName, emojiOf: _noEmoji);
}

/// A message's text: its markdown, mentions as `@Name` in the accent, custom
/// emoji as images, and emoji-only messages large. Links open in the browser;
/// spoilers stay hidden until tapped; a mention, with [onMention], opens that
/// person, and a room's, with [onRoom], that room. Screen readers get the whole text as one label, with actions for
/// its links, its spoilers, the mentions it shows, and [messageActions].
class MessageText extends StatefulWidget {
  final String content;
  final MessageDirectory directory;

  /// On the accent fill of the user's own bubble.
  final bool onAccent;
  final TextStyle style;

  /// One line, its block markup dropped: a reply's quote.
  final bool singleLine;

  /// A mention tapped: the user it names. Without it, mentions are text.
  final ValueChanged<String>? onMention;

  /// A room mention tapped: the room, when the user may see it.
  final ValueChanged<Room>? onRoom;

  /// The message's own actions (Reply, its options), offered with the
  /// text's: a screen reader's stop has one set, and two don't merge.
  final Map<CustomSemanticsAction, VoidCallback> messageActions;

  const MessageText({
    required this.content,
    required this.directory,
    required this.style,
    this.onAccent = false,
    this.singleLine = false,
    this.onMention,
    this.onRoom,
    this.messageActions = const {},
    super.key,
  });

  /// Opens a link; tests replace it.
  @visibleForTesting
  static Future<bool> Function(Uri uri) openLink = (uri) async {
    // Duvet's own (an invite, a message): the app opens it, not the browser.
    if (parseDeepLink(uri.toString()) != null) {
      DeepLinkSource.tapped.add(uri);
      return true;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  };

  /// Opens a link outside the app, as a tapped link in a message does.
  static Future<bool> launch(Uri uri) => openLink(uri);

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <GestureRecognizer>[];
  bool _revealed = false;
  late List<MdBlock> _blocks = _parse();

  // Its code blocks' colors, worked out once a block and a theme, not each build.
  final _colored = <(String, String, bool, CodeTheme?), TextSpan?>{};

  List<MdBlock> _parse() {
    if (!widget.singleLine) return parseMarkdown(widget.content);
    // Code blocks as inline code; headings, quotes and lists as plain text.
    final line = widget.content
        .replaceAllMapped(
          RegExp(r'```[\w+#-]*\n?([\s\S]*?)```'),
          (m) => '`${m.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ')}`',
        )
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^(?:#{1,3} |-# |>>> |> |\s*[-*]\s+|\s*\d+[.)]\s+)'), ''))
        .join(' ');
    return [MdParagraph(parseInline(line))];
  }

  @override
  void didUpdateWidget(MessageText old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content || old.singleLine != widget.singleLine) {
      _blocks = _parse();
      _colored.clear();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  void _reveal() {
    if (!_revealed) setState(() => _revealed = true);
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await MessageText.openLink(uri);
    } catch (_) {
      // No app for it: nothing to do.
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = context.duvet;
    final colors = context.theme.colors;
    final jumbo = !widget.singleLine && isJumboEmoji(widget.content);
    final base = jumbo ? widget.style.copyWith(fontSize: 40, height: 1.2) : widget.style;
    final emojiSize = jumbo ? 48.0 : 22.0;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final appearance = AppearanceScope.maybeOf(context);
    // Overlays on your bubble are its ink, faint: white on azure.
    final ink = ownBubble(context).ink;
    final codeFill = widget.onAccent
        ? ink.withAlpha(0x29)
        : dark
        ? const Color(0x14FFFFFF)
        : const Color(0x0F141416);
    final links = <String>[];
    // The people mentioned where a mention shows (not in code, a link's text
    // or a hidden spoiler), in order, each once: their IDs and names.
    final mentions = <String, String>{};
    // The rooms mentioned where they show, each once.
    final rooms = <String, Room>{};
    var spoilers = false;

    // A mention in its member's role colors, as their name shows in the
    // member list; violet without a colored role. On your azure bubble, bold
    // ink-on-accent instead, which keeps its contrast.
    InlineSpan mention(String name, String userId, TextStyle? style) {
      final bold = (style ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700);
      final role = widget.onAccent ? null : widget.directory.nameColorsOf(userId);
      final onMention = widget.onMention;
      if (role case (from: _?, via: _, to: _?)) {
        // A gradient spans the name, so the name is a box of its own in the line.
        return WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: onMention == null ? null : () => onMention(userId),
            child: RoleName(name, colors: role, style: base.merge(bold)),
          ),
        );
      }
      return TextSpan(
        text: name,
        recognizer: onMention == null ? null : _tap(() => onMention(userId)),
        style: bold.copyWith(color: widget.onAccent ? null : roleColorOn(context, role?.from) ?? tokens.violetText),
      );
    }

    // Mentions and custom emoji within a text leaf.
    List<InlineSpan> leaf(String text, TextStyle? style) => [
      for (final token in tokenize(text))
        switch (token) {
          TextToken(:final text) => TextSpan(text: text, style: style),
          MentionToken(:final userId) => mention(
            '@${mentions[userId] = widget.directory.nameOf(userId) ?? 'someone'}',
            userId,
            style,
          ),
          RoomToken(:final roomId) => switch (widget.directory.roomOf(roomId)) {
            // Hidden or gone: no name, nothing to open.
            null => TextSpan(text: '#unknown', style: style),
            final room => TextSpan(
              text: '#${(rooms[roomId] = room).name}',
              recognizer: switch (widget.onRoom) {
                final onRoom? => _tap(() => onRoom(room)),
                null => null,
              },
              style: (style ?? const TextStyle()).copyWith(
                color: widget.onAccent ? null : tokens.accentText,
                fontWeight: FontWeight.w700,
              ),
            ),
          },
          EmojiToken(:final emojiId) => switch (widget.directory.emojiOf(emojiId)) {
            null => TextSpan(text: ':emoji:', style: style),
            final emoji => WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Image.network(
                  emoji.url,
                  width: emojiSize,
                  height: emojiSize,
                  cacheWidth: (emojiSize * MediaQuery.devicePixelRatioOf(context)).round(),
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => Text(':${emoji.name}:'),
                ),
              ),
            ),
          },
        },
    ];

    List<InlineSpan> spans(List<MdInline> inlines, [TextStyle? style, GestureRecognizer? link]) => [
      for (final i in inlines)
        ...switch (i) {
          MdText(:final text) =>
            link == null ? leaf(text, style) : [TextSpan(text: text, style: style, recognizer: link)],
          MdCode(:final code) => [
            TextSpan(
              text: ' $code ',
              style: DuvetType.code.copyWith(
                fontSize: (base.fontSize ?? 16) - 2,
                backgroundColor: codeFill,
                fontWeight: style?.fontWeight,
              ),
              recognizer: link,
            ),
          ],
          MdStyled(:final styles, :final children) => spans(
            children,
            (style ?? const TextStyle()).copyWith(
              fontWeight: styles.contains(MdStyle.bold) ? FontWeight.w700 : null,
              fontStyle: styles.contains(MdStyle.italic) ? FontStyle.italic : null,
              decoration: TextDecoration.combine([
                ?style?.decoration,
                if (styles.contains(MdStyle.underline)) TextDecoration.underline,
                if (styles.contains(MdStyle.strike)) TextDecoration.lineThrough,
              ]),
            ),
            link,
          ),
          MdLink(:final url, :final children) => () {
            links.add(url);
            return spans(
              children,
              (style ?? const TextStyle()).copyWith(
                color: widget.onAccent ? ink : tokens.accentText,
                decoration: TextDecoration.underline,
                decorationColor: widget.onAccent ? ink : tokens.accentText,
              ),
              _tap(() => _open(url)),
            );
          }(),
          MdSpoiler(:final children) => () {
            spoilers = true;
            if (_revealed) return spans(children, style, link);
            // Hidden: the text's shape on base-sunken, its letters invisible.
            return spans(
              children,
              (style ?? const TextStyle()).copyWith(
                color: const Color(0x00000000),
                backgroundColor: widget.onAccent ? ink.withAlpha(0x52) : colors.secondary,
                decoration: TextDecoration.none,
              ),
              _tap(_reveal),
            );
          }(),
        },
    ];

    final secondary = widget.onAccent ? base.color?.withValues(alpha: 0.78) : colors.mutedForeground;
    Widget rich(List<MdInline> inlines, TextStyle style, {int? maxLines, TextAlign? textAlign}) => Text.rich(
      TextSpan(style: style, children: spans(inlines)),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      textAlign: textAlign,
    );

    final children = <Widget>[
      for (final block in _blocks)
        switch (block) {
          MdParagraph(:final inlines) => rich(inlines, base, maxLines: widget.singleLine ? 1 : null),
          MdHeading(:final level, :final inlines) => rich(
            inlines,
            base.merge(level == 1 ? DuvetType.titleSans : DuvetType.navTitle).copyWith(color: base.color),
          ),
          MdSubtext(:final inlines) => rich(inlines, base.merge(DuvetType.caption).copyWith(color: secondary)),
          MdQuote(:final inlines) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: widget.onAccent ? ink.withAlpha(0x1F) : colors.secondary,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            child: rich(inlines, base.copyWith(color: secondary)),
          ),
          MdList(:final ordered, :final items) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (n, item) in items.indexed)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Text(ordered ? '${n + 1}.' : '•', style: base.copyWith(color: secondary)),
                    ),
                    Expanded(child: rich(item, base)),
                  ],
                ),
            ],
          ),
          // Its columns as wide as they need, the table scrolled sideways
          // past the bubble's width.
          MdTable(:final header, :final aligns, :final rows) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: colors.border),
              children: [
                for (final (r, row) in [header, ...rows].indexed)
                  TableRow(
                    decoration: r == 0 ? BoxDecoration(color: codeFill) : null,
                    children: [
                      for (var c = 0; c < header.length; c++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: rich(
                            c < row.length ? row[c] : const [],
                            r == 0 ? base.copyWith(fontWeight: FontWeight.w600) : base,
                            textAlign: switch (c < aligns.length ? aligns[c] : null) {
                              MdAlign.center => TextAlign.center,
                              MdAlign.end => TextAlign.end,
                              MdAlign.start || null => TextAlign.start,
                            },
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          MdCodeBlock(:final code, :final language) => Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: codeFill, borderRadius: BorderRadius.circular(DuvetTokens.radiusField)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: () {
                final style = DuvetType.code.copyWith(fontSize: 13, height: 1.5, color: base.color);
                // Its language's colors, as the desktop's; on your bubble,
                // those for its ink.
                final onDark = widget.onAccent ? ownBubble(context).onDark : dark;
                final custom = appearance?.codeTheme;
                final colored = language == null
                    ? null
                    : _colored.putIfAbsent((
                        code,
                        language,
                        onDark,
                        custom,
                      ), () => highlightCode(code, language, base: style, dark: onDark, custom: custom));
                return colored == null ? Text(code, style: style) : Text.rich(colored);
              }(),
            ),
          ),
        },
    ];

    final spoken = _blocks
        .map(
          (b) => switch (b) {
            MdParagraph(:final inlines) ||
            MdHeading(:final inlines) ||
            MdSubtext(:final inlines) ||
            MdQuote(:final inlines) => plainInline(inlines, revealSpoilers: _revealed),
            MdList(:final items) => items.map((i) => plainInline(i, revealSpoilers: _revealed)).join('\n'),
            // A row a line, each cell after its column's name.
            MdTable(:final header, :final rows) => [
              for (final row in rows)
                [
                  for (final (c, cell) in row.indexed)
                    c < header.length && header[c].isNotEmpty
                        ? '${plainInline(header[c], revealSpoilers: _revealed)}: ${plainInline(cell, revealSpoilers: _revealed)}'
                        : plainInline(cell, revealSpoilers: _revealed),
                ].join(', '),
            ].join('\n'),
            MdCodeBlock(:final code) => code,
          },
        )
        .join('\n');
    final label = readableContent(
      spoken,
      nameOf: widget.directory.nameOf,
      emojiNameOf: (id) => widget.directory.emojiOf(id)?.name,
      roomNameOf: (id) => widget.directory.roomOf(id)?.name,
    );

    // Two people shown by the same name get an action each, told apart.
    final named = <String, int>{};
    for (final name in mentions.values) {
      named[name] = (named[name] ?? 0) + 1;
    }
    // Counted by name: the second Sam is Sam's mention 2.
    final seen = <String, int>{};
    final actions = {
      ...widget.messageActions,
      if (spoilers && !_revealed) const CustomSemanticsAction(label: 'Reveal spoiler'): _reveal,
      for (final url in links) CustomSemanticsAction(label: 'Open $url'): () => _open(url),
      if (widget.onMention case final onMention?)
        for (final MapEntry(key: id, value: name) in mentions.entries)
          CustomSemanticsAction(
            label: named[name]! > 1
                ? 'Open $name’s profile, mention ${seen[name] = (seen[name] ?? 0) + 1}'
                : 'Open $name’s profile',
          ): () =>
              onMention(id),
      if (widget.onRoom case final onRoom?)
        for (final room in rooms.values) CustomSemanticsAction(label: 'Open #${room.name}'): () => onRoom(room),
    };

    return Semantics(
      label: label,
      excludeSemantics: true,
      // None at all for plain text, so it reads as part of its message.
      customSemanticsActions: actions.isEmpty ? null : actions,
      child: children.length == 1
          ? children.single
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, c) in children.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                    child: c,
                  ),
              ],
            ),
    );
  }
}

/// A message's images, GIFs and files, as a grid under its text.
class MessageAttachments extends StatelessWidget {
  final List<MessageAttachment> attachments;
  final double maxWidth;

  /// While they upload: how far, 0 to 1, over all of them.
  final double? uploadProgress;

  /// A double tap on a picture: its message's (a reply). A single tap then
  /// waits for the second before it opens the picture.
  final VoidCallback? onDoubleTap;
  const MessageAttachments({
    required this.attachments,
    this.maxWidth = 260,
    this.uploadProgress,
    this.onDoubleTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final images = attachments.where((a) => a.isImage).toList();
    final files = attachments.where((a) => !a.isImage).toList();
    Widget tile(MessageAttachment f) => f.isVideo
        ? VideoTile(attachment: f, width: maxWidth)
        : f.isAudio
        ? AudioFileTile(attachment: f)
        : _FileTile(attachment: f, width: maxWidth);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.length == 1)
          _uploading(
            images.single,
            _Picture(attachment: images.single, width: maxWidth, gallery: images, index: 0, onDoubleTap: onDoubleTap),
          )
        else if (images.length > 1)
          SizedBox(
            width: maxWidth,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final (i, a) in images.indexed)
                  _uploading(
                    a,
                    _Picture(
                      attachment: a,
                      width: (maxWidth - 4) / 2,
                      square: true,
                      gallery: images,
                      index: i,
                      onDoubleTap: onDoubleTap,
                    ),
                  ),
              ],
            ),
          ),
        for (final f in files)
          Padding(
            padding: EdgeInsets.only(top: images.isEmpty && f == files.first ? 0 : 4),
            child: _uploading(f, f.isSpoiler ? _SpoilerCover(attachment: f, child: tile(f)) : tile(f)),
          ),
      ],
    );
  }

  // A file's own upload, as a bar along its bottom edge.
  Widget _uploading(MessageAttachment a, Widget child) {
    final total = uploadProgress;
    if (total == null) return child;
    final f = fileProgress(attachments, attachments.indexOf(a), total);
    return Stack(
      children: [
        child,
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: f,
                minHeight: 4,
                color: const Color(0xFFFFFFFF),
                backgroundColor: const Color(0x3DFFFFFF),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A spoiler video, audio or file: blurred under a cover until a tap reveals
/// it, as the desktop has it; what it hides takes no taps meanwhile.
/// Pictures have their own cover ([_Picture]).
class _SpoilerCover extends StatefulWidget {
  final MessageAttachment attachment;
  final Widget child;
  const _SpoilerCover({required this.attachment, required this.child});

  @override
  State<_SpoilerCover> createState() => _SpoilerCoverState();
}

class _SpoilerCoverState extends State<_SpoilerCover> {
  bool _revealed = false;

  void _reveal() => setState(() => _revealed = true);

  @override
  Widget build(BuildContext context) {
    if (_revealed) return widget.child;
    final a = widget.attachment;
    final kind = a.isVideo
        ? 'Video'
        : a.isAudio
        ? 'Audio file'
        : 'File';
    return Semantics(
      container: true,
      button: true,
      label: 'Spoiler, $kind, ${a.displayName}',
      hint: 'Double tap to reveal',
      excludeSemantics: true,
      onTap: _reveal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _reveal,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12, tileMode: TileMode.decal),
                  child: widget.child,
                ),
              ),
              const _Badge(text: 'Spoiler'),
            ],
          ),
        ),
      ),
    );
  }
}

/// How far the file at [index] is, when [total] of all their bytes have gone:
/// the files go one after another, by size (equal shares when unknown).
double fileProgress(List<MessageAttachment> files, int index, double total) {
  final sizes = [for (final f in files) f.sizeBytes > 0 ? f.sizeBytes.toDouble() : 1.0];
  final all = sizes.fold(0.0, (a, b) => a + b);
  final before = sizes.take(index).fold(0.0, (a, b) => a + b);
  return ((total * all - before) / sizes[index]).clamp(0.0, 1.0);
}

/// Which file is uploading when [total] of their bytes have gone.
int uploadingIndex(List<MessageAttachment> files, double total) {
  for (var i = 0; i < files.length; i++) {
    if (fileProgress(files, i, total) < 1) return i;
  }
  return files.length - 1;
}

/// An image or GIF in a message, at its aspect ratio within bounds. A GIF
/// plays unless animations are off, then waits for a tap. A long press is its
/// message's (the actions), as on a text bubble.
class _Picture extends StatefulWidget {
  final MessageAttachment attachment;
  final double width;
  final bool square;
  final List<MessageAttachment> gallery;
  final int index;
  final VoidCallback? onDoubleTap;
  const _Picture({
    required this.attachment,
    required this.width,
    required this.gallery,
    required this.index,
    this.square = false,
    this.onDoubleTap,
  });

  @override
  State<_Picture> createState() => _PictureState();
}

class _PictureState extends State<_Picture> {
  bool _playing = false;
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final colors = context.theme.colors;
    // Its own ratio, so the box fits the whole picture (the desktop's
    // object-contain): a clamp here would crop tall and wide ones.
    final ratio = widget.square || (a.width ?? 0) <= 0 || (a.height ?? 0) <= 0 ? 1.0 : a.width! / a.height!;
    final height = math.min(widget.width / ratio, 320.0);
    final width = widget.square ? widget.width : math.min(widget.width, height * ratio);
    final still = MediaQuery.disableAnimationsOf(context) && !_playing;
    final kind = a.isGif ? 'GIF' : 'Photo';
    // A spoiler: blurred under a cover until tapped.
    if (a.isSpoiler && !_revealed) {
      return Semantics(
        container: true,
        image: true,
        button: true,
        label: 'Spoiler, $kind, ${a.displayName}',
        hint: 'Double tap to reveal',
        excludeSemantics: true,
        onTap: () => setState(() => _revealed = true),
        child: GestureDetector(
          onTap: () => setState(() => _revealed = true),
          onDoubleTap: widget.onDoubleTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
            child: Container(
              width: width,
              height: height,
              color: colors.secondary,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.decal),
                    child: TickerMode(enabled: false, child: _image(a, width / 4)),
                  ),
                  const Center(child: _Badge(text: 'Spoiler')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      image: true,
      button: true,
      label: '$kind, ${a.displayName}',
      hint: a.isGif && still ? 'Double tap to play' : 'Double tap to open',
      excludeSemantics: true,
      onTap: a.isGif && still ? () => setState(() => _playing = true) : () => _open(context),
      child: GestureDetector(
        onTap: a.isGif && still ? () => setState(() => _playing = true) : () => _open(context),
        onDoubleTap: widget.onDoubleTap,
        child: Hero(
          tag: _heroTag(a),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
            child: Container(
              width: width,
              height: height,
              color: colors.secondary,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // A still GIF shows its first frame: images pause with tickers.
                  TickerMode(enabled: !still, child: _image(a, width)),
                  if (a.isGif) Positioned(left: 8, bottom: 8, child: _Badge(text: still ? 'GIF ▶' : 'GIF')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    // Out of the composer: or closing the viewer hands it the keyboard back.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: DuvetTokens.panelIn,
        reverseTransitionDuration: DuvetTokens.panelOut,
        pageBuilder: (_, _, _) => ImageViewer(gallery: widget.gallery, initial: widget.index),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: DuvetTokens.decelerate),
          child: child,
        ),
      ),
    );
  }
}

String _heroTag(MessageAttachment a) => 'attachment:${a.id}:${a.url}';

Widget _image(MessageAttachment a, double width, {BoxFit fit = BoxFit.cover}) {
  final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  final cache = math.max(1, (width * dpr).round());
  Widget broken(BuildContext context, Object _, StackTrace? _) =>
      Center(child: Icon(FLucideIcons.imageOff, color: context.theme.colors.mutedForeground));
  // Flutter plays GIFs and WebPs itself, APNGs not: apng.dart does.
  Widget played(String url, Widget still) => a.contentType == 'image/apng'
      ? ApngImage(key: ValueKey(url), url: url, local: a.local, width: width, fit: fit, placeholder: still)
      : still;
  if (a.local) {
    return played(
      a.url,
      Image.file(File(a.url), fit: fit, cacheWidth: fit == BoxFit.cover ? cache : null, errorBuilder: broken),
    );
  }
  return AttachmentLinkBuilder(
    attachment: a,
    builder: (context, url, refused) => played(
      url,
      Image.network(
        url,
        fit: fit,
        cacheWidth: fit == BoxFit.cover ? cache : null,
        errorBuilder: (context, error, stack) {
          // Its link expired: the API refuses it.
          if (error is NetworkImageLoadException && error.statusCode == 403) refused();
          return broken(context, error, stack);
        },
        frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
          opacity: frame == null && !sync ? 0 : 1,
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: const Color(0xB3141416), borderRadius: BorderRadius.circular(8)),
    child: Text(
      text,
      style: DuvetType.tabLabel.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
}

class _FileTile extends StatelessWidget {
  final MessageAttachment attachment;
  final double width;
  const _FileTile({required this.attachment, required this.width});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final a = attachment;
    final kind = a.displayName.contains('.') ? a.displayName.split('.').last.toUpperCase() : 'File';
    return Builder(
      // Under the tile, so the options menu opens on it.
      builder: (context) {
        final onTap = a.local ? null : () => _fileMenu(context, a);
        return Semantics(
          container: true,
          button: true,
          label: '$kind, ${a.displayName}, ${_size(a.sizeBytes)}',
          hint: onTap == null ? null : 'Double tap for options',
          excludeSemantics: true,
          onTap: onTap,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: width,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                boxShadow: context.duvet.shadowRest,
              ),
              child: Row(
                children: [
                  // A file's kind in a recess, a rounded square.
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.secondary,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                    ),
                    child: InsetShadow(
                      shadows: context.duvet.shadowWell,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                      child: Icon(FLucideIcons.fileText, size: 20, color: colors.foreground),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                        ),
                        Text(
                          '$kind · ${_size(a.sizeBytes)}',
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _size(int bytes) {
    if (bytes <= 0) return 'unknown size';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

Future<void> _fileMenu(BuildContext anchor, MessageAttachment a) async {
  final link = linkSource(anchor, a);
  final picked = await showGlassMenu(
    anchor,
    label: 'File options',
    items: const [
      GlassMenuItem(icon: FLucideIcons.externalLink, label: 'Open', value: 'open'),
      GlassMenuItem(icon: FLucideIcons.share2, label: 'Share', value: 'share'),
      GlassMenuItem(icon: FLucideIcons.link, label: 'Copy link', value: 'copy'),
    ],
  );
  try {
    switch (picked) {
      case 'open':
        await MediaActions.instance.open(await link());
      case 'share':
        await MediaActions.instance.share(await link(), a.displayName, a.contentType);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: await link()));
    }
  } catch (_) {
    if (anchor.mounted) {
      showFToast(context: anchor, title: const Text('Couldn’t open the file'), duration: const Duration(seconds: 3));
    }
  }
}

/// A sticker: large, with no bubble; a `base-sunken` square until it loads.
class StickerView extends StatelessWidget {
  final String url;
  final String? name;
  const StickerView({required this.url, this.name, super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    image: true,
    label: name == null ? 'Sticker' : 'Sticker, $name',
    excludeSemantics: true,
    child: Image.network(
      url,
      width: 160,
      height: 160,
      cacheWidth: (160 * MediaQuery.devicePixelRatioOf(context)).round(),
      fit: BoxFit.contain,
      // Not behind the sticker once it's there: stickers are see-through.
      frameBuilder: (context, child, frame, sync) => frame == null && !sync
          ? Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                color: context.theme.colors.secondary,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              ),
            )
          : child,
      errorBuilder: (context, _, _) => SizedBox(
        width: 160,
        height: 160,
        child: Center(
          child: Text('Sticker unavailable', style: TextStyle(color: context.theme.colors.mutedForeground)),
        ),
      ),
    ),
  );
}

/// A link preview or a bot's card.
class EmbedCard extends StatelessWidget {
  final MessageEmbed embed;
  final double width;
  const EmbedCard({required this.embed, this.width = 260, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final e = embed;
    // Only a web link opens (the desktop's webEmbed): any other scheme, or a
    // malformed one, is nothing to tap.
    final uri = e.url == null ? null : Uri.tryParse(e.url!);
    final link = uri != null && (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // The picture at its own ratio when known (so nothing is cropped), else
    // a banner; a GIF link's embed is only this, bare, up to the card's width.
    Widget picture(double w) {
      final ratio = (e.imageWidth ?? 0) > 0 && (e.imageHeight ?? 0) > 0 ? e.imageWidth! / e.imageHeight! : null;
      final height = ratio == null ? 140.0 : math.min(w / ratio, 320.0);
      return ClipRRect(
        borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
        child: Image.network(
          e.imageUrl!,
          width: ratio == null ? w : math.min(w, height * ratio),
          height: height,
          cacheWidth: (w * dpr).round(),
          fit: ratio == null ? BoxFit.cover : BoxFit.contain,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    }

    // A GIF link's animated picture is its preview, though Tenor's names an mp4
    // too.
    final gif = e.imageUrl != null && (Uri.tryParse(e.imageUrl!)?.path.toLowerCase().endsWith('.gif') ?? false);
    final youtube = e.isDirectVideo || e.videoUrl == null ? null : YoutubePlayerController.convertUrlToId(e.videoUrl!);

    // Its video as the chat's own play (a file) on its poster, a YouTube video
    // played in place, or any other player page's poster with a play mark that
    // opens it in the browser.
    Widget? media(double w) {
      if (gif) return picture(w);
      if (e.isDirectVideo) {
        return VideoTile(
          attachment: MessageAttachment(
            id: e.videoUrl!,
            filename: e.title ?? 'Video',
            contentType: e.videoContentType ?? 'video/mp4',
            url: e.videoUrl!,
            width: e.imageWidth,
            height: e.imageHeight,
          ),
          width: w,
          poster: e.imageUrl,
        );
      }
      if (youtube != null) {
        final ratio = (e.imageWidth ?? 0) > 0 && (e.imageHeight ?? 0) > 0 ? e.imageWidth! / e.imageHeight! : 16 / 9;
        return _YouTubeTile(videoId: youtube, poster: e.imageUrl, ratio: ratio, width: w, title: e.title);
      }
      if (e.imageUrl == null) return null;
      if (e.videoUrl == null) return picture(w);
      return Stack(alignment: Alignment.center, children: [picture(w), const PlayMark()]);
    }

    if (e.isWordless && (e.imageUrl != null || e.isDirectVideo)) {
      final bare = media(width)!;
      if ((e.isDirectVideo && !gif) || youtube != null) return bare;
      final play = !gif && e.videoUrl != null && link != null;
      return Semantics(
        image: !play,
        button: play,
        label: play ? 'Video preview. Play' : 'Image preview',
        child: GestureDetector(onTap: play ? () => MessageText.openLink(link) : null, child: bare),
      );
    }

    final muted = DuvetType.caption.copyWith(color: colors.mutedForeground);
    final authorLink = switch (e.authorUrl) {
      final u? => switch (Uri.tryParse(u)) {
        final uri? when uri.scheme == 'http' || uri.scheme == 'https' => uri,
        _ => null,
      },
      null => null,
    };
    // Its footer and its date, as the desktop's "FxTwitter • 10/21/26, 3:02 AM".
    final footer = [
      ?e.footer,
      if (e.timestamp case final t?)
        '${MaterialLocalizations.of(context).formatShortDate(t)}, '
            '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t))}',
    ].join(' • ');
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (e.provider != null) Text(e.provider!, style: muted),
        if (e.authorName != null)
          GestureDetector(
            onTap: authorLink == null ? null : () => MessageText.openLink(authorLink),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (e.authorIconUrl != null) ...[
                    ClipOval(
                      child: Image.network(
                        e.authorIconUrl!,
                        width: 16,
                        height: 16,
                        cacheWidth: (16 * dpr).round(),
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(e.authorName!, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                  ),
                ],
              ),
            ),
          ),
        // Four lines here hold what the desktop's two do in its wider
        // card: a GitHub run's title with its result at the end.
        if (e.title != null)
          Text(
            e.title!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: DuvetType.rowTitle.copyWith(color: colors.foreground),
          ),
        if (e.description != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              e.description!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
            ),
          ),
        if (e.fields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                for (final f in e.fields)
                  // A field not inline takes its own line.
                  SizedBox(
                    width: f.inline ? null : double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          f.name.toUpperCase(),
                          style: DuvetType.tabLabel.copyWith(
                            color: colors.mutedForeground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(f.value, style: DuvetType.snippet.copyWith(color: colors.foreground)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (footer.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(footer, style: DuvetType.tabLabel.copyWith(color: colors.mutedForeground)),
          ),
      ],
    );
    // Its color as a stripe down the left side: a gradient top to bottom when
    // it has more than one, as the desktop's border.
    final stripe = switch (e.colors) {
      [] => null,
      [final c] => BoxDecoration(color: Color(0xFF000000 | c)),
      final cs => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [for (final c in cs) Color(0xFF000000 | c)],
        ),
      ),
    };
    return Semantics(
      container: true,
      button: link != null,
      hint: link != null ? 'Double tap to open' : null,
      child: Builder(
        builder: (context) => GestureDetector(
          onTap: link == null ? null : () => MessageText.openLink(link),
          child: Container(
            width: width,
            clipBehavior: stripe == null ? Clip.none : Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              boxShadow: context.duvet.shadowRest,
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (e.thumbnailUrl == null)
                        text
                      else
                        // A small picture beside the text, as the desktop's card.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: text),
                            const SizedBox(width: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                              child: Image.network(
                                e.thumbnailUrl!,
                                width: 64,
                                height: 64,
                                cacheWidth: (64 * dpr).round(),
                                fit: BoxFit.cover,
                                excludeFromSemantics: true,
                                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                              ),
                            ),
                          ],
                        ),
                      if (media(width - 24) case final m?) Padding(padding: const EdgeInsets.only(top: 8), child: m),
                    ],
                  ),
                ),
                if (stripe != null)
                  Positioned(left: 0, top: 0, bottom: 0, width: 4, child: DecoratedBox(decoration: stripe)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A YouTube video in a message: its poster with a play mark until tapped,
/// then the player in its place, so a scroll past starts no web view.
class _YouTubeTile extends StatefulWidget {
  final String videoId;
  final String? poster;
  final double ratio;
  final double width;
  final String? title;
  const _YouTubeTile({required this.videoId, required this.ratio, required this.width, this.poster, this.title});

  @override
  State<_YouTubeTile> createState() => _YouTubeTileState();
}

class _YouTubeTileState extends State<_YouTubeTile> with AutomaticKeepAliveClientMixin {
  YouTubeSession? _session;
  Animation<double>? _route;

  // Full screen: the view is there meanwhile, and this never takes it back,
  // even rebuilt under it (the phone turned).
  bool _away = false;

  // A video started here goes on as the list scrolls it far away, and is where
  // it got to when it scrolls back.
  @override
  bool get wantKeepAlive => _session != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route?.removeStatusListener(_onRoute);
    _route = ModalRoute.of(context)?.animation?..addStatusListener(_onRoute);
  }

  // Its chat starting to close: its view on to the dock in this frame, so it
  // is never off screen for Android to pause.
  void _onRoute(AnimationStatus status) {
    final session = _session;
    if (status != AnimationStatus.reverse || session == null || !session.playing) return;
    setState(() => _session = null);
    updateKeepAlive();
    dockedYouTube.value = (id: widget.videoId, title: widget.title, seconds: session.seconds, session: session);
  }

  void _play() {
    // A video starting here takes the dock's place.
    dockedYouTube.value = null;
    final session = YouTubeSession(widget.videoId, fullScreenButton: true);
    session.onFullScreen = () => _fullScreen(session);
    setState(() => _session = session);
    updateKeepAlive();
  }

  // The view goes to a route of its own, and comes back as it is.
  Future<void> _fullScreen(YouTubeSession session) async {
    if (_away) return;
    setState(() => _away = true);
    await openYouTubeFullScreen(context, session: session, ratio: widget.ratio);
    if (mounted) setState(() => _away = false);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onRoute);
    // Kept alive while it plays, it only goes here with its message, or with a
    // chat replaced or closed without the pop _onRoute docks on: the dock
    // would sit under the next screen, so the video stops.
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final height = math.min(widget.width / widget.ratio, 320.0);
    final width = math.min(widget.width, height * widget.ratio);
    final session = _session;
    final playing = session != null;
    final poster = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.poster case final poster?)
          Image.network(
            poster,
            fit: BoxFit.cover,
            cacheWidth: math.max(1, (width * MediaQuery.devicePixelRatioOf(context)).round()),
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        if (!playing) const Center(child: PlayMark()),
      ],
    );
    return Semantics(
      container: true,
      button: !playing,
      label: 'YouTube video${widget.title == null ? '' : ', ${widget.title}'}${playing ? '' : '. Play'}',
      explicitChildNodes: playing,
      excludeSemantics: !playing,
      onTap: playing ? null : _play,
      child: GestureDetector(
        onTap: playing ? null : _play,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          child: ColoredBox(
            color: videoBackdrop,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (session != null && !_away)
                    YouTubeView(
                      session,
                      // Taps and scrubbing are the player's; a vertical drag still scrolls.
                      gestureRecognizers: {
                        Factory<TapGestureRecognizer>(TapGestureRecognizer.new),
                        Factory<HorizontalDragGestureRecognizer>(HorizontalDragGestureRecognizer.new),
                      },
                    ),
                  // Over the view, which paints its backdrop until the video
                  // shows: the poster stays till then, as the package's does.
                  IgnorePointer(
                    ignoring: playing,
                    child: session == null || _away
                        ? poster
                        : YoutubeValueBuilder(
                            controller: session.controller,
                            buildWhen: (o, n) => o.playerState != n.playerState,
                            builder: (context, value) => AnimatedOpacity(
                              duration: DuvetTokens.panelOut,
                              opacity: switch (value.playerState) {
                                PlayerState.unknown || PlayerState.unStarted => 1,
                                _ => 0,
                              },
                              child: poster,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full screen: swipe between a message's pictures, pinch to zoom, GIFs play.
class ImageViewer extends StatefulWidget {
  final List<MessageAttachment> gallery;
  final int initial;
  const ImageViewer({required this.gallery, this.initial = 0, super.key});

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

/// Where the photo, at [photo] in [view] before any zoom, goes once scaled by
/// [scale] and moved by [pan]: moved back so it stops at its edges. It covers
/// the view on an axis it's larger than, and is centred on one it's smaller
/// than.
Offset clampToPhoto(double scale, Offset pan, Size view, Rect photo) {
  double axis(double t, double start, double extent, double view) => extent * scale <= view
      ? (view - extent * scale) / 2 - start * scale
      : t.clamp(view - (start + extent) * scale, -start * scale);
  return Offset(axis(pan.dx, photo.left, photo.width, view.width), axis(pan.dy, photo.top, photo.height, view.height));
}

class _ImageViewerState extends State<ImageViewer> with TickerProviderStateMixin {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  // The zoom of the photo shown: paging stops while it's zoomed, so the others
  // are always at their size.
  double _scale = 1;
  Offset _pan = Offset.zero;
  // Zoomed in, a finger pans the photo: swiping to page or to close waits
  // until it's back at its size.
  bool get _zoomed => _scale > 1.01;
  Size _view = Size.zero;
  Offset _tapAt = Offset.zero;
  // The pinch, or the pan while zoomed, as it began: since the fingers down
  // last changed. Taken from the fingers themselves, not from a recognizer:
  // the swipe or the page may have won the first finger before the second
  // landed.
  double _startScale = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  double _startSpan = 0;
  Offset _focal = Offset.zero;
  bool _moved = false;
  VelocityTracker? _speed;
  late final _zoomMotion = AnimationController(vsync: this, duration: DuvetTokens.panelIn);
  Animation<double>? _scaleTo;
  Animation<Offset>? _panTo;
  static const _maxScale = 5.0;

  // The swipe to close: the photo follows the finger, and springs back when
  // let go short of closing.
  Offset _drag = Offset.zero;
  bool _swiping = false;
  // The fingers down, where they are, and the one the swipe follows: a drag
  // reports whichever finger landed last, so a second one would throw the
  // photo to it.
  final _fingers = <int, Offset>{};
  int? _finger;
  static const _closeAt = 120.0;
  late final _back = AnimationController(vsync: this, duration: DuvetTokens.panelOut);
  Animation<Offset>? _dragBack;

  // Two fingers down is a pinch: swiping to page or to close steps aside, as
  // either would take a pinch with one finger still.
  bool get _pinching => _fingers.length > 1;

  static const _ink = DuvetTokens.mediaInk;
  static const _ground = Color(0xFF0A0A0B);

  @override
  void initState() {
    super.initState();
    _zoomMotion.addListener(
      () => setState(() {
        _scale = _scaleTo!.value;
        _pan = _panTo!.value;
      }),
    );
    _back.addListener(() => setState(() => _drag = _dragBack!.value));
  }

  @override
  void dispose() {
    _pages.dispose();
    _zoomMotion.dispose();
    _back.dispose();
    super.dispose();
  }

  /// Where the photo shown sits in the view at its size.
  Rect get _photo {
    final a = widget.gallery[_index];
    final whole = Offset.zero & _view;
    // shortcut: a photo of unknown size takes the whole view, so panning can reach past its edges.
    if (a.width == null || a.height == null || a.width == 0 || a.height == 0) return whole;
    final size = Size(a.width!.toDouble(), a.height!.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, size, _view).destination;
    // A photo smaller than the screen shows at its own size: it isn't scaled up.
    return Alignment.center.inscribe(fitted.width > size.width ? size : fitted, whole);
  }

  // Eases the zoom to [scale] and [pan], as Duvet's panels settle.
  void _settle(double scale, Offset pan) {
    _zoomMotion.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _scale = scale;
        _pan = pan;
      });
      return;
    }
    final curve = CurvedAnimation(parent: _zoomMotion, curve: DuvetTokens.decelerate);
    _scaleTo = Tween(begin: _scale, end: scale).animate(curve);
    _panTo = Tween(begin: _pan, end: pan).animate(curve);
    _zoomMotion.forward(from: 0);
  }

  // Double-tap: zoom in where tapped, or back out.
  void _toggleZoom() {
    const scale = 2.5;
    _settle(_zoomed ? 1 : scale, _zoomed ? Offset.zero : clampToPhoto(scale, _tapAt * (1 - scale), _view, _photo));
  }

  Offset get _fingersFocal => _fingers.values.reduce((a, b) => a + b) / _fingers.length.toDouble();

  // The fingers' mean distance from their focal point: 0 for one finger.
  double get _fingersSpan {
    final focal = _fingersFocal;
    return _fingers.values.map((p) => (p - focal).distance).reduce((a, b) => a + b) / _fingers.length;
  }

  // From here on, the photo moves from where it is under the fingers down now.
  void _rebase() {
    _startScale = _scale;
    _startPan = _pan;
    _startFocal = _focal = _fingersFocal;
    _startSpan = _fingersSpan;
    _speed = VelocityTracker.withKind(PointerDeviceKind.touch);
  }

  // The photo's point under the fingers stays under them. Past 1× or 5×, or
  // past an edge, it gives a little, and settles back when let go.
  void _pinchMove(Duration at) {
    // Moved during a double-tap's zoom: it stops where it is. A tap doesn't stop it.
    if (_zoomMotion.isAnimating) {
      _zoomMotion.stop();
      _rebase();
    }
    _moved = true;
    final focal = _fingersFocal;
    final span = _fingersSpan;
    final raw = _startSpan > 0 && span > 0 ? _startScale * span / _startSpan : _startScale;
    final scale = raw < 1
        ? 1 - (1 - raw) / 3
        : raw > _maxScale
        ? _maxScale + (raw - _maxScale) / 3
        : raw;
    final pan = focal - (_startFocal - _startPan) * (scale / _startScale);
    final kept = clampToPhoto(scale, pan, _view, _photo);
    _speed?.addPosition(at, focal);
    setState(() {
      _focal = focal;
      _scale = scale;
      _pan = kept + (pan - kept) / 3;
    });
  }

  // The last finger up: back within 1× to 5× about the fingers, and a flick
  // carries on a little.
  void _pinchEnd() {
    if (!_moved) return;
    _moved = false;
    final scale = _scale.clamp(1.0, _maxScale);
    // Barely zoomed is a brush, not a zoom: it'd leave swiping to close off.
    if (scale < 1.1) return _settle(1, Offset.zero);
    final flung = _speed?.getVelocity().pixelsPerSecond ?? Offset.zero;
    final pan = _focal - (_focal - _pan) * (scale / _scale) + flung * 0.15;
    _settle(scale, clampToPhoto(scale, pan, _view, _photo));
  }

  void _dragStart(DragStartDetails _) {
    // Two fingers down is a pinch, not a swipe.
    if (_fingers.length != 1) return;
    _back.stop();
    _swiping = true;
    _finger = _fingers.keys.single;
    // Picked up, as a long-pressed message is.
    HapticFeedback.mediumImpact();
  }

  void _follow(Offset by) {
    final closing = _drag.dy.abs() > _closeAt;
    setState(() => _drag += by);
    // Letting go now closes it, or no longer does: as swipe-to-reply arms.
    if ((_drag.dy.abs() > _closeAt) != closing) HapticFeedback.selectionClick();
  }

  void _press(PointerDownEvent e) {
    setState(() => _fingers[e.pointer] = e.position);
    // A second finger mid-swipe: the photo goes back, and the two pinch.
    if (_pinching && _swiping) {
      _swiping = false;
      _finger = null;
      _springBack();
    }
    _rebase();
  }

  void _move(PointerMoveEvent e) {
    if (!_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.position;
    if (e.pointer == _finger) return _follow(e.delta);
    // At its size, one finger swipes to page or to close: it doesn't move the photo.
    if (_pinching || (_zoomed && !_swiping)) _pinchMove(e.timeStamp);
  }

  void _lift(PointerEvent e) {
    setState(() => _fingers.remove(e.pointer));
    if (e.pointer == _finger) {
      _finger = null;
      // The system took the touch (the notification shade, a call): the drag
      // reports it as a release, so it's caught here, and it goes back.
      if (e is PointerCancelEvent && _swiping) {
        _swiping = false;
        _springBack();
      }
    }
    if (_fingers.isEmpty) return _pinchEnd();
    // The fingers left carry on from where the photo is.
    _rebase();
  }

  // [d] is null when the drag was cancelled (a system cancel is caught in
  // _lift, as the drag reports it as a release): then it always goes back.
  void _dragEnd(DragEndDetails? d) {
    if (!_swiping) return;
    _swiping = false;
    _finger = null;
    final speed = d?.primaryVelocity ?? 0;
    // A flick back toward where it started doesn't close it.
    final flung = speed.abs() > 800 && speed.sign == _drag.dy.sign;
    if (d != null && (_drag.dy.abs() > _closeAt || flung)) {
      Navigator.of(context).pop();
      return;
    }
    _springBack();
  }

  void _springBack() {
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _drag = Offset.zero);
      return;
    }
    _dragBack = Tween(
      begin: _drag,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _back, curve: DuvetTokens.overshoot));
    _back.forward(from: 0);
  }

  void _toast(String text) {
    if (mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));
  }

  Future<void> _save(MessageAttachment a) async {
    final link = linkSource(context, a);
    try {
      final saved = await MediaActions.instance.saveToGallery(await link(), a.displayName);
      _toast(saved ? 'Saved to your photos' : 'Duvet can’t save to your photos');
    } catch (_) {
      _toast('Couldn’t save the photo');
    }
  }

  Future<void> _share(MessageAttachment a) async {
    final link = linkSource(context, a);
    try {
      await MediaActions.instance.share(await link(), a.displayName, a.contentType);
    } catch (_) {
      _toast('Couldn’t share the photo');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.gallery[_index];
    final padding = MediaQuery.paddingOf(context);
    final view = MediaQuery.sizeOf(context);
    if (view != _view) {
      // Turned while zoomed: the photo comes back within its edges.
      if (!_view.isEmpty && _zoomed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _pan = clampToPhoto(_scale, _pan, _view, _photo));
        });
      }
      _view = view;
    }
    final fade = (1 - _drag.dy.abs() / 400).clamp(0.3, 1.0);
    // Shrinks as it goes, to three quarters at a screen's height away.
    final shrink = _view.height == 0 ? 1.0 : 1 - (_drag.dy.abs() / _view.height).clamp(0.0, 1.0) * 0.25;
    // The bars give the photo the screen while it's dragged.
    final chrome = (fade - 0.3) / 0.7;
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                Icon(icon, size: 24, color: _ink),
                const SizedBox(height: 4),
                Text(label, style: DuvetType.tabLabel.copyWith(color: _ink)),
              ],
            ),
          ),
        ),
      ),
    );
    // The viewer is always dark: photos read best on near-black.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: widget.gallery.length > 1 ? 'Photo ${_index + 1} of ${widget.gallery.length}' : 'Photo',
        child: Scaffold(
          backgroundColor: _ground.withValues(alpha: fade),
          body: Stack(
            children: [
              // Swipe down (or up) to close: started up or down, the photo then
              // follows its finger either way, on the screen as it moves.
              Listener(
                onPointerDown: _press,
                onPointerMove: _move,
                onPointerUp: _lift,
                onPointerCancel: _lift,
                child: GestureDetector(
                  onDoubleTapDown: (d) => _tapAt = d.localPosition,
                  onDoubleTap: _toggleZoom,
                  child: Transform.translate(
                    offset: _drag,
                    child: Transform.scale(
                      scale: shrink,
                      child: PageView.builder(
                        controller: _pages,
                        physics: _zoomed || _pinching ? const NeverScrollableScrollPhysics() : null,
                        itemCount: widget.gallery.length,
                        onPageChanged: (i) => setState(() => _index = i),
                        itemBuilder: (context, i) {
                          final a = widget.gallery[i];
                          return Semantics(
                            image: true,
                            label:
                                '${a.isGif ? 'GIF' : 'Photo'}, ${a.displayName}, ${i + 1} of ${widget.gallery.length}',
                            excludeSemantics: true,
                            child: RawGestureDetector(
                              gestures: {
                                if (!_zoomed && !_pinching)
                                  _OneFingerDrag: GestureRecognizerFactoryWithHandlers<_OneFingerDrag>(
                                    _OneFingerDrag.new,
                                    (r) => r
                                      ..gestureSettings = MediaQuery.gestureSettingsOf(context)
                                      ..onStart = _dragStart
                                      ..onEnd = _dragEnd
                                      ..onCancel = (() => _dragEnd(null)),
                                  ),
                              },
                              // The whole screen takes a pinch, not only the photo: a
                              // wide one leaves most of it empty.
                              child: ColoredBox(
                                color: Colors.transparent,
                                child: Transform(
                                  transform: i == _index
                                      ? (Matrix4.diagonal3Values(_scale, _scale, 1)
                                          ..setTranslationRaw(_pan.dx, _pan.dy, 0))
                                      : Matrix4.identity(),
                                  child: Center(
                                    child: Hero(
                                      tag: _heroTag(a),
                                      child: _image(a, MediaQuery.sizeOf(context).width, fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: chrome,
                  child: _DarkGlass(
                    edge: const Border(bottom: BorderSide(color: DuvetTokens.mediaScrimEdge)),
                    child: Padding(
                      padding: EdgeInsets.only(top: padding.top),
                      child: SizedBox(
                        height: DuvetTokens.sizeTopBar,
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            Semantics(
                              button: true,
                              label: 'Close',
                              excludeSemantics: true,
                              onTap: () => Navigator.of(context).pop(),
                              child: GestureDetector(
                                onTap: () => Navigator.of(context).pop(),
                                child: const SizedBox.square(dimension: 40, child: Icon(FLucideIcons.x, color: _ink)),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    current.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: DuvetType.rowTitle.copyWith(color: _ink),
                                  ),
                                  if (widget.gallery.length > 1)
                                    Text(
                                      '${_index + 1} of ${widget.gallery.length}',
                                      style: DuvetType.caption.copyWith(color: const Color(0xFF949392)),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 48),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!current.local)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: chrome,
                    child: _DarkGlass(
                      edge: const Border(top: BorderSide(color: DuvetTokens.mediaScrimEdge)),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + padding.bottom),
                        child: Row(
                          children: [
                            action(FLucideIcons.download, 'Save', () => _save(current)),
                            action(FLucideIcons.share2, 'Share', () => _share(current)),
                            action(FLucideIcons.link, 'Copy link', () async {
                              final link = linkSource(context, current);
                              await Clipboard.setData(ClipboardData(text: await link()));
                              _toast('Link copied');
                            }),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A swipe that steps aside as soon as a second finger lands, before it has
/// started: that's a pinch, though one finger held still makes it look like a
/// drag. Once under way, it keeps the first finger, and the viewer springs the
/// photo back and pinches with both.
class _OneFingerDrag extends VerticalDragGestureRecognizer {
  final _pointers = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointers.add(event.pointer);
    // Only the open arenas reject: a started swipe's first finger is already won.
    if (_pointers.length > 1) resolve(GestureDisposition.rejected);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointers.clear();
    super.didStopTrackingLastPointer(pointer);
  }
}

/// The viewer's chrome: dark glass, whatever the theme.
class _DarkGlass extends StatelessWidget {
  final Widget child;
  final Border edge;
  const _DarkGlass({required this.child, required this.edge});

  @override
  Widget build(BuildContext context) => ClipRect(
    child: BackdropFilter(
      filter: glassBackdrop(16),
      child: DecoratedBox(
        decoration: BoxDecoration(color: DuvetTokens.mediaScrim, border: edge),
        child: child,
      ),
    ),
  );
}
