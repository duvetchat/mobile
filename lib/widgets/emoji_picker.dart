import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../data/emoji_catalog.dart';
import '../data/gifs.dart';
import '../data/models.dart';
import '../theme.dart';
import 'glass.dart';
import 'rows.dart';

sealed class PickerChoice {
  const PickerChoice();
}

final class PickedEmoji extends PickerChoice {
  final String emoji;
  const PickedEmoji(this.emoji);
}

final class PickedCustomEmoji extends PickerChoice {
  final CustomEmoji emoji;
  const PickedCustomEmoji(this.emoji);
}

final class PickedSticker extends PickerChoice {
  final Sticker sticker;
  const PickedSticker(this.sticker);
}

final class PickedGif extends PickerChoice {
  final Gif gif;
  const PickedGif(this.gif);
}

enum PickerTab { emoji, stickers, gifs }

/// The emoji and sticker picker, as a glass sheet: search, the recently used,
/// the space's own emoji, then every category; stickers on their own tab.
Future<PickerChoice?> showEmojiPicker(
  BuildContext context, {
  required Future<List<CustomEmoji>> customEmojis,
  required Future<List<Sticker>> stickers,
  bool inSpace = true,
  PickerTab tab = PickerTab.emoji,
  bool gifs = false,
}) => showGlassSheet<PickerChoice>(
  context,
  label: gifs ? 'Emoji, stickers and GIFs' : 'Emoji and stickers',
  initialSize: 0.62,
  builder: (context, scroll) => _Picker(
    scroll: scroll,
    customEmojis: customEmojis,
    stickers: stickers,
    inSpace: inSpace,
    initialTab: tab,
    gifs: gifs,
  ),
);

class _Picker extends StatefulWidget {
  final ScrollController scroll;
  final Future<List<CustomEmoji>> customEmojis;
  final Future<List<Sticker>> stickers;
  final bool inSpace;
  final PickerTab initialTab;

  /// With the GIFs tab: the composer's picker, not a reaction's.
  final bool gifs;
  const _Picker({
    required this.scroll,
    required this.customEmojis,
    required this.stickers,
    required this.inSpace,
    required this.initialTab,
    this.gifs = false,
  });

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  late PickerTab _tab = widget.initialTab;
  final _search = TextEditingController();
  EmojiCatalog? _catalog;
  List<CustomEmoji> _custom = const [];
  List<Sticker>? _stickers;
  Object? _stickersError;
  final _sectionKeys = <String, GlobalKey>{};
  ({String query, List<EmojiEntry> found})? _searched;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    EmojiCatalog.load().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
    widget.customEmojis.then((list) {
      if (mounted) setState(() => _custom = list);
    }, onError: (_) {});
    widget.stickers.then(
      (list) {
        if (mounted) setState(() => _stickers = list);
      },
      onError: (Object e) {
        if (mounted) setState(() => _stickersError = e);
      },
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(PickerChoice choice) {
    HapticFeedback.selectionClick();
    switch (choice) {
      case PickedEmoji(:final emoji):
        EmojiCatalog.used(emoji);
      case PickedCustomEmoji(:final emoji):
        EmojiCatalog.used(emoji.code);
      case PickedSticker() || PickedGif():
    }
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _Segmented(
            value: _tab,
            onChanged: (t) => setState(() => _tab = t),
            options: {
              PickerTab.emoji: 'Emoji',
              PickerTab.stickers: 'Stickers',
              if (widget.gifs) PickerTab.gifs: 'GIFs',
            },
          ),
        ),
        Expanded(
          child: switch (_tab) {
            PickerTab.emoji => _emojiTab(context),
            PickerTab.stickers => _stickerTab(context),
            PickerTab.gifs => _GifTab(scroll: widget.scroll, onPick: (gif) => _pick(PickedGif(gif))),
          },
        ),
      ],
    );
  }

  Widget _emojiTab(BuildContext context) {
    final catalog = _catalog;
    if (catalog == null) return const Center(child: FCircularProgress());
    final query = _search.text.trim();
    final colors = context.theme.colors;

    final List<Widget> slivers;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      final custom = _custom.where((e) => e.name.toLowerCase().contains(q)).toList();
      // Once per query: a rebuild that isn't a keystroke doesn't search again.
      if (_searched?.query != query) _searched = (query: query, found: catalog.search(query));
      final found = _searched!.found;
      slivers = [
        if (custom.isEmpty && found.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No emoji match “$query”',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.mutedForeground),
              ),
            ),
          ),
        if (custom.isNotEmpty) ..._section('This space', custom),
        if (found.isNotEmpty) ..._section('Results', found),
      ];
    } else {
      final recent = EmojiCatalog.recent.value;
      final customById = {for (final e in _custom) e.code: e};
      slivers = [
        if (recent.isNotEmpty)
          ..._section('Recently used', [
            for (final r in recent)
              if (customById[r] case final custom?)
                custom
              else if (!r.startsWith('<:'))
                EmojiEntry(r, catalog.nameOf(r) ?? r),
          ]),
        if (_custom.isNotEmpty) ..._section('This space', _custom),
        for (final c in catalog.categories) ..._section(c.label, c.emojis),
      ];
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _SearchField(controller: _search, hint: 'Search emoji'),
        ),
        if (query.isEmpty) _categoryBar(catalog),
        Expanded(
          child: CustomScrollView(
            controller: widget.scroll,
            // Scrolling to look puts the search's keyboard away.
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              ...slivers,
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ],
    );
  }

  // Jumps between sections; each tab is named for screen readers.
  Widget _categoryBar(EmojiCatalog catalog) {
    final entries = [
      if (_custom.isNotEmpty) ('This space', '✨'),
      for (final c in catalog.categories) (c.label, c.icon),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final (label, icon) in entries)
            Semantics(
              button: true,
              label: 'Jump to $label',
              excludeSemantics: true,
              onTap: () => _jumpTo(label),
              child: InkResponse(
                radius: 22,
                onTap: () => _jumpTo(label),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(child: Text(icon, style: const TextStyle(fontSize: 22))),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _jumpTo(String label) {
    final target = _sectionKeys[label]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.dropdownIn,
      curve: DuvetTokens.decelerate,
    );
  }

  // Each section's cells are built as they scroll into view, from the entries
  // (an EmojiEntry or a CustomEmoji), not made up front: there are ~1,900.
  List<Widget> _section(String label, List<Object> entries) => [
    SliverToBoxAdapter(
      child: Padding(
        key: _sectionKeys.putIfAbsent(label, GlobalKey.new),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Semantics(
          header: true,
          child: Text(
            label.toUpperCase(),
            style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground),
          ),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 48),
        delegate: SliverChildBuilderDelegate(
          (context, i) => switch (entries[i]) {
            final CustomEmoji e => _customCell(e),
            final EmojiEntry e => _unicodeCell(e),
            _ => const SizedBox.shrink(),
          },
          childCount: entries.length,
          addAutomaticKeepAlives: false,
        ),
      ),
    ),
  ];

  Widget _unicodeCell(EmojiEntry e) => _Cell(
    label: e.name,
    onTap: () => _pick(PickedEmoji(e.emoji)),
    child: Text(e.emoji, style: const TextStyle(fontSize: 28, height: 1.15)),
  );

  Widget _customCell(CustomEmoji e) => _Cell(
    label: e.name,
    onTap: () => _pick(PickedCustomEmoji(e)),
    child: Image.network(
      e.url,
      width: 30,
      height: 30,
      cacheWidth: (30 * MediaQuery.devicePixelRatioOf(context)).round(),
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => Text(':${e.name}:', maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
    ),
  );

  Widget _stickerTab(BuildContext context) {
    final colors = context.theme.colors;
    Widget message(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.mutedForeground),
        ),
      ),
    );
    if (!widget.inSpace) return message('Stickers belong to spaces. Send one from a space’s room.');
    if (_stickersError != null) return message('Couldn’t load stickers');
    final stickers = _stickers;
    if (stickers == null) return const Center(child: FCircularProgress());
    final query = _search.text.trim().toLowerCase();
    final shown = query.isEmpty ? stickers : stickers.where((s) => s.name.toLowerCase().contains(query)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _SearchField(controller: _search, hint: 'Search stickers'),
        ),
        Expanded(
          child: stickers.isEmpty
              ? message('This space has no stickers yet')
              : shown.isEmpty
              ? message('No stickers match “${_search.text.trim()}”')
              : GridView.builder(
                  controller: widget.scroll,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 112,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final s = shown[i];
                    return _Cell(
                      label: 'Sticker, ${s.name}',
                      hint: 'Double tap to send',
                      onTap: () => _pick(PickedSticker(s)),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Image.network(
                          s.url,
                          cacheWidth: (100 * MediaQuery.devicePixelRatioOf(context)).round(),
                          fit: BoxFit.contain,
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => Center(child: Text(s.name, textAlign: TextAlign.center)),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A picker cell: sinks while pressed. No implicit animations: a grid holds
/// hundreds, and an animation each would cost a controller and a ticker.
class _Cell extends StatefulWidget {
  final String label;
  final String? hint;
  final VoidCallback onTap;
  final Widget child;
  const _Cell({required this.label, required this.onTap, required this.child, this.hint});

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    hint: widget.hint,
    excludeSemantics: true,
    onTap: widget.onTap,
    child: GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Transform.scale(
        scale: _pressed && !MediaQuery.disableAnimationsOf(context) ? 0.9 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _pressed ? context.theme.colors.foreground.withValues(alpha: 0.08) : null,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
          ),
          child: Center(child: widget.child),
        ),
      ),
    ),
  );
}

/// The sunken search well; plain, since it sits on glass already.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  const _SearchField({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: colors.mutedForeground),
        prefixIcon: Icon(FLucideIcons.search, size: 20, color: colors.mutedForeground),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: controller.clear,
                icon: Icon(FLucideIcons.x, size: 20, color: colors.mutedForeground),
              ),
        filled: true,
        fillColor: colors.foreground.withValues(alpha: 0.06),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Two or three options in a pill track; the active one in the accent tint.
class _Segmented<T> extends StatelessWidget {
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  const _Segmented({required this.value, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final colors = context.theme.colors;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.foreground.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
      ),
      child: Row(
        children: [
          for (final MapEntry(:key, value: label) in options.entries)
            Expanded(
              child: Semantics(
                button: true,
                selected: key == value,
                label: label,
                excludeSemantics: true,
                onTap: () => onChanged(key),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(key),
                  child: AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    curve: DuvetTokens.decelerate,
                    decoration: BoxDecoration(
                      color: key == value ? tokens.accentTint : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      label,
                      style: DuvetType.label.copyWith(color: key == value ? tokens.accentText : colors.mutedForeground),
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

/// GIFs, as desktop finds them: search, a few quick topics, then a
/// two-column grid of previews. Picking one sends its link.
class _GifTab extends StatefulWidget {
  final ScrollController scroll;
  final ValueChanged<Gif> onPick;
  const _GifTab({required this.scroll, required this.onPick});

  @override
  State<_GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<_GifTab> {
  static const _topics = ['Trending', 'Celebrate', 'Thanks', 'Yes', 'Tired'];
  final _search = TextEditingController();
  String _topic = 'Trending';
  Future<List<Gif>>? _results;
  int _request = 0;
  Timer? _typing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _typing?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Typing searches once it pauses for half a second, as the desktop app does: each search counts against the GIF
  /// provider's hourly limit, which every user of the app shares.
  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 500), _load);
  }

  void _load() {
    final query = _search.text.trim().isNotEmpty ? _search.text.trim() : (_topic == 'Trending' ? '' : _topic);
    final request = ++_request;
    final results = query.isEmpty ? GifSource.instance.trending() : GifSource.instance.search(query);
    final shown = results.then((r) => request == _request ? r : const <Gif>[]);
    if (!mounted) return;
    setState(() {
      _results = shown;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SearchField(hint: 'Search GIFs', controller: _search, onChanged: _typed),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              for (final topic in _topics)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Semantics(
                    button: true,
                    selected: topic == _topic && _search.text.trim().isEmpty,
                    label: topic,
                    excludeSemantics: true,
                    onTap: () => _choose(topic),
                    child: GestureDetector(
                      onTap: () => _choose(topic),
                      child: _Chip(text: topic, on: topic == _topic && _search.text.trim().isEmpty),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder(
            future: _results,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Couldn’t load GIFs. Check your connection and try again.',
                    textAlign: TextAlign.center,
                    style: DuvetType.body.copyWith(color: colors.mutedForeground),
                  ),
                );
              }
              final gifs = snapshot.data;
              if (gifs == null) return const Center(child: FCircularProgress());
              if (gifs.isEmpty) {
                return Center(
                  child: Text('No GIFs found', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                );
              }
              // Two columns, each GIF placed in the shorter one.
              final columns = [<Gif>[], <Gif>[]];
              final heights = [0.0, 0.0];
              for (final g in gifs) {
                final i = heights[0] <= heights[1] ? 0 : 1;
                columns[i].add(g);
                heights[i] += g.height / g.width;
              }
              return SingleChildScrollView(
                controller: widget.scroll,
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final (i, column) in columns.indexed) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              children: [
                                for (final g in column)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _GifTile(gif: g, onTap: () => widget.onPick(g), shadow: tokens.shadowRest),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        GifSource.instance.attribution,
                        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _choose(String topic) {
    _typing?.cancel();
    _search.clear();
    _topic = topic;
    _load();
  }
}

class _GifTile extends StatelessWidget {
  final Gif gif;
  final VoidCallback onTap;
  final List<BoxShadow> shadow;
  const _GifTile({required this.gif, required this.onTap, required this.shadow});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    image: true,
    label: gif.description.isEmpty ? 'GIF' : 'GIF, ${gif.description}',
    excludeSemantics: true,
    onTap: onTap,
    child: GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        // Its own ratio, as the desktop's grid: a clamp would crop it.
        // A provider's 0 for a side would make it 0 or infinite: AspectRatio throws.
        aspectRatio: gif.width > 0 && gif.height > 0 ? gif.width / gif.height : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(DuvetTokens.radiusField), boxShadow: shadow),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: context.theme.colors.secondary),
                Image.network(
                  gif.preview,
                  fit: BoxFit.cover,
                  cacheWidth: (180 * MediaQuery.devicePixelRatioOf(context)).round(),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0x8C111113),
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                    ),
                    child: Text('GIF', style: DuvetType.tabLabel.copyWith(color: const Color(0xFFF2F1EE))),
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

/// A chip: 32pt, `radius-chip`, raised; the chosen one in the selected state.
class _Chip extends StatelessWidget {
  final String text;
  final bool on;
  const _Chip({required this.text, required this.on});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? tokens.selectedFill : colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
        boxShadow: on ? null : tokens.shadowRest,
      ),
      child: Text(
        text,
        style: DuvetType.snippet.copyWith(
          color: on ? tokens.violetText : colors.foreground,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
