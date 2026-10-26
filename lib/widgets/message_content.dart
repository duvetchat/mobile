import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/emoji_catalog.dart';
import '../data/markdown.dart';
import '../data/message_tokens.dart';
import '../data/models.dart';
import '../theme.dart';
import 'code_highlight.dart';
import 'depth.dart';
import 'glass.dart';
import 'media.dart';
import 'media_actions.dart';

/// What a bubble needs to show names and custom emoji.
class MessageDirectory {
  final String? me;
  final String? Function(String userId) nameOf;
  final CustomEmoji? Function(String emojiId) emojiOf;
  const MessageDirectory({required this.me, required this.nameOf, required this.emojiOf});

  static String? _noName(String _) => null;
  static CustomEmoji? _noEmoji(String _) => null;
  static const empty = MessageDirectory(me: null, nameOf: _noName, emojiOf: _noEmoji);
}

/// A message's text: its markdown, mentions as `@Name` in the accent, custom
/// emoji as images, and emoji-only messages large. Links open in the browser;
/// spoilers stay hidden until tapped; a mention, with [onMention], opens that
/// person. Screen readers get the whole text as one label, with actions for
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
    this.messageActions = const {},
    super.key,
  });

  /// Opens a link; tests replace it.
  @visibleForTesting
  static Future<bool> Function(Uri uri) openLink = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Opens a link outside the app, as a tapped link in a message does.
  static Future<bool> launch(Uri uri) => openLink(uri);

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <GestureRecognizer>[];
  bool _revealed = false;
  late List<MdBlock> _blocks = _parse();

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
    if (old.content != widget.content || old.singleLine != widget.singleLine) _blocks = _parse();
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
    final codeFill = widget.onAccent
        ? const Color(0x29FFFFFF)
        : dark
        ? const Color(0x14FFFFFF)
        : const Color(0x0F141416);
    final links = <String>[];
    // The people mentioned where a mention shows (not in code, a link's text
    // or a hidden spoiler), in order, each once: their IDs and names.
    final mentions = <String, String>{};
    var spoilers = false;

    // Mentions and custom emoji within a text leaf.
    List<InlineSpan> leaf(String text, TextStyle? style) => [
      for (final token in tokenize(text))
        switch (token) {
          TextToken(:final text) => TextSpan(text: text, style: style),
          MentionToken(:final userId) => TextSpan(
            text: '@${mentions[userId] = widget.directory.nameOf(userId) ?? 'someone'}',
            recognizer: switch (widget.onMention) {
              final onMention? => _tap(() => onMention(userId)),
              null => null,
            },
            // Accent as text; on the accent bubble, bold ink-on-accent
            // instead, which keeps its contrast.
            style: (style ?? const TextStyle()).copyWith(
              color: widget.onAccent ? null : tokens.accentText,
              fontWeight: FontWeight.w700,
            ),
          ),
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
                color: widget.onAccent ? colors.primaryForeground : tokens.accentText,
                decoration: TextDecoration.underline,
                decorationColor: widget.onAccent ? colors.primaryForeground : tokens.accentText,
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
                backgroundColor: widget.onAccent ? const Color(0x52FFFFFF) : colors.secondary,
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
            base.merge(level == 1 ? DuvetType.title : DuvetType.navTitle).copyWith(color: base.color),
          ),
          MdSubtext(:final inlines) => rich(inlines, base.merge(DuvetType.caption).copyWith(color: secondary)),
          MdQuote(:final inlines) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: widget.onAccent ? const Color(0x1FFFFFFF) : colors.secondary,
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
                // Its language's colors, as the desktop's; on the accent, the dark ones.
                final colored = language == null
                    ? null
                    : highlightCode(code, language, base: style, dark: dark || widget.onAccent);
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
    final ratio = widget.square || a.width == null || a.height == null || a.height == 0
        ? 1.0
        : (a.width! / a.height!).clamp(0.5, 2.5);
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

  void _open(BuildContext context) => Navigator.of(context).push(
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

String _heroTag(MessageAttachment a) => 'attachment:${a.id}:${a.url}';

Widget _image(MessageAttachment a, double width, {BoxFit fit = BoxFit.cover}) {
  final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  final cache = (width * dpr).round();
  Widget broken(BuildContext context, Object _, StackTrace? _) =>
      Center(child: Icon(FLucideIcons.imageOff, color: context.theme.colors.mutedForeground));
  return a.local
      ? Image.file(File(a.url), fit: fit, cacheWidth: fit == BoxFit.cover ? cache : null, errorBuilder: broken)
      : Image.network(
          a.url,
          fit: fit,
          cacheWidth: fit == BoxFit.cover ? cache : null,
          errorBuilder: broken,
          frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
            opacity: frame == null && !sync ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: child,
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
        await MediaActions.instance.open(a.url);
      case 'share':
        await MediaActions.instance.share(a.url, a.displayName, a.contentType);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: a.url));
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
    return Semantics(
      container: true,
      button: e.url != null,
      hint: e.url != null ? 'Double tap to open' : null,
      child: Builder(
        builder: (context) => GestureDetector(
          onTap: e.url == null ? null : () => MessageText.openLink(Uri.parse(e.url!)),
          child: Container(
            width: width,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
              boxShadow: context.duvet.shadowRest,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (e.provider != null)
                  Text(e.provider!, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
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
                if (e.imageUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                      child: Image.network(
                        e.imageUrl!,
                        width: width - 24,
                        height: 140,
                        cacheWidth: ((width - 24) * MediaQuery.devicePixelRatioOf(context)).round(),
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
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

class _ImageViewerState extends State<ImageViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  double _drag = 0;

  static const _ink = Color(0xFFF2F1EE);
  static const _ground = Color(0xFF0A0A0B);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));
  }

  Future<void> _save(MessageAttachment a) async {
    try {
      final saved = await MediaActions.instance.saveToGallery(a.url, a.displayName);
      _toast(saved ? 'Saved to your photos' : 'Duvet can’t save to your photos');
    } catch (_) {
      _toast('Couldn’t save the photo');
    }
  }

  Future<void> _share(MessageAttachment a) async {
    try {
      await MediaActions.instance.share(a.url, a.displayName, a.contentType);
    } catch (_) {
      _toast('Couldn’t share the photo');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.gallery[_index];
    final padding = MediaQuery.paddingOf(context);
    final fade = (1 - _drag.abs() / 400).clamp(0.3, 1.0);
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
              // Swipe down (or up) to close.
              GestureDetector(
                onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
                onVerticalDragEnd: (_) {
                  if (_drag.abs() > 120) {
                    Navigator.of(context).pop();
                  } else {
                    setState(() => _drag = 0);
                  }
                },
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: widget.gallery.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) {
                      final a = widget.gallery[i];
                      return Semantics(
                        image: true,
                        label: '${a.isGif ? 'GIF' : 'Photo'}, ${a.displayName}, ${i + 1} of ${widget.gallery.length}',
                        excludeSemantics: true,
                        child: InteractiveViewer(
                          maxScale: 5,
                          child: Center(
                            child: Hero(
                              tag: _heroTag(a),
                              child: _image(a, MediaQuery.sizeOf(context).width, fit: BoxFit.contain),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _DarkGlass(
                  edge: const Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
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
              if (!current.local)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Swipe down to close · pinch to zoom',
                          style: DuvetType.caption.copyWith(color: const Color(0xFF949392)),
                        ),
                      ),
                      _DarkGlass(
                        edge: const Border(top: BorderSide(color: Color(0x1FFFFFFF))),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + padding.bottom),
                          child: Row(
                            children: [
                              action(FLucideIcons.download, 'Save', () => _save(current)),
                              action(FLucideIcons.share2, 'Share', () => _share(current)),
                              action(FLucideIcons.link, 'Copy link', () async {
                                await Clipboard.setData(ClipboardData(text: current.url));
                                _toast('Link copied');
                              }),
                            ],
                          ),
                        ),
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
        decoration: BoxDecoration(color: const Color(0x8C111113), border: edge),
        child: child,
      ),
    ),
  );
}
