import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../data/scope.dart';
import '../theme.dart';
import 'depth.dart';
import 'glass.dart';
import 'message_content.dart';
import 'rows.dart';

/// The choices a select offers: its own options, or the chat's members,
/// rooms or roles.
typedef SelectChoices = List<ComponentOption> Function(UiComponent select);

/// A bot's message components: rows of buttons and selects, texts, sections
/// and containers. Using one tells the bot; a modal it answers with opens.
class BotComponents extends StatefulWidget {
  final List<UiComponent> components;
  final MessageDirectory directory;
  final SelectChoices choices;

  /// Uses a button (no values) or a select (its values).
  final Future<void> Function(UiComponent component, List<String>? values) onUse;
  const BotComponents({
    required this.components,
    required this.directory,
    required this.choices,
    required this.onUse,
    super.key,
  });

  @override
  State<BotComponents> createState() => _BotComponentsState();
}

class _BotComponentsState extends State<BotComponents> {
  String? _busy;

  Future<void> _use(UiComponent c, List<String>? values) async {
    if (_busy != null) return;
    setState(() => _busy = c.customId);
    try {
      await widget.onUse(c, values);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pick(UiComponent select) async {
    final options = widget.choices(select);
    final picked = await showSelectSheet(context, select: select, options: options);
    if (picked != null) await _use(select, picked);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (i, c) in widget.components.indexed)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
          child: _component(context, c),
        ),
    ],
  );

  Widget _component(BuildContext context, UiComponent c) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    switch (c.type) {
      case ComponentKind.actionRow:
        return Wrap(spacing: 8, runSpacing: 8, children: [for (final child in c.children) _component(context, child)]);
      case ComponentKind.button:
        return _BotButton(component: c, busy: _busy != null && _busy == c.customId, onPressed: () => _use(c, null));
      case final t when ComponentKind.selects.contains(t):
        final chosen = [
          for (final o in widget.choices(c))
            if (o.isDefault) o.label,
        ];
        return Semantics(
          container: true,
          button: true,
          enabled: !c.disabled,
          label: c.placeholder ?? 'Choose',
          value: chosen.join(', '),
          excludeSemantics: true,
          onTap: c.disabled ? null : () => _pick(c),
          child: GestureDetector(
            onTap: c.disabled ? null : () => _pick(c),
            child: Container(
              width: 268,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                border: Border.all(color: tokens.hairline),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chosen.isEmpty ? (c.placeholder ?? 'Choose') : chosen.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DuvetType.body.copyWith(
                        color: chosen.isEmpty ? colors.mutedForeground : colors.foreground,
                      ),
                    ),
                  ),
                  if (_busy != null && _busy == c.customId)
                    const FCircularProgress(size: .sm)
                  else
                    Icon(FLucideIcons.chevronDown, size: 16, color: colors.mutedForeground),
                ],
              ),
            ),
          ),
        );
      case ComponentKind.textDisplay:
        return MessageText(
          content: c.content ?? '',
          directory: widget.directory,
          style: DuvetType.body.copyWith(color: colors.foreground),
        );
      case ComponentKind.section:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final child in c.children) _component(context, child)],
              ),
            ),
            if (c.accessory case final a?) ...[const SizedBox(width: 12), _component(context, a)],
          ],
        );
      case ComponentKind.container:
        return Container(
          width: 300,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            boxShadow: tokens.shadowRaised,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, child) in c.children.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                  child: _component(context, child),
                ),
            ],
          ),
        );
      case ComponentKind.separator:
        return Container(height: 1, width: 268, color: tokens.hairline);
      case ComponentKind.thumbnail:
        return c.mediaUrl == null
            ? const SizedBox.shrink()
            : ClipRRect(
                borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                child: Image.network(
                  c.mediaUrl!,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  semanticLabel: c.description,
                  errorBuilder: (_, _, _) => const SizedBox.square(dimension: 64),
                ),
              );
      case ComponentKind.mediaGallery:
        // One picture shows whole, at its own ratio (the desktop's
        // object-contain); several are square thumbnails.
        if (c.galleryUrls.length == 1) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            child: Image.network(
              c.galleryUrls.single,
              width: 268,
              // Decoded at its shown width: a big GIF's every frame at full size runs the phone out of memory.
              cacheWidth: (268 * MediaQuery.devicePixelRatioOf(context)).round(),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.square(dimension: 128),
            ),
          );
        }
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final url in c.galleryUrls)
              ClipRRect(
                borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                child: Image.network(
                  url,
                  width: 128,
                  height: 128,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.square(dimension: 128),
                ),
              ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

/// A bot's button, in Duvet's three variants: Primary for the bot's primary
/// and success, Destructive for danger, Secondary otherwise; a link opens.
class _BotButton extends StatelessWidget {
  final UiComponent component;
  final bool busy;
  final VoidCallback onPressed;
  const _BotButton({required this.component, required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = component;
    final label = [?c.emoji, ?c.label].join(' ');
    final link = c.style == ButtonStyleKind.link;
    return DuvetButton(
      label: label.isEmpty ? 'Button' : label,
      icon: link ? FLucideIcons.externalLink : null,
      busy: busy,
      variant: switch (c.style) {
        ButtonStyleKind.primary || ButtonStyleKind.success => ButtonVariant.primary,
        ButtonStyleKind.danger => ButtonVariant.destructive,
        _ => ButtonVariant.secondary,
      },
      onPressed: c.disabled
          ? null
          : link
          ? switch (Uri.tryParse(c.url ?? '')) {
              final u? when u.scheme == 'http' || u.scheme == 'https' => () => MessageText.launch(u),
              _ => null,
            }
          : onPressed,
    );
  }
}

/// A select's choices in a glass sheet: one, or as many as it takes, with
/// Done. Answers the values chosen.
Future<List<String>?> showSelectSheet(
  BuildContext context, {
  required UiComponent select,
  required List<ComponentOption> options,
}) => showGlassSheet<List<String>>(
  context,
  label: select.placeholder ?? 'Choose',
  builder: (context, scroll) => _Select(select: select, options: options, scroll: scroll),
);

class _Select extends StatefulWidget {
  final UiComponent select;
  final List<ComponentOption> options;
  final ScrollController scroll;
  const _Select({required this.select, required this.options, required this.scroll});

  @override
  State<_Select> createState() => _SelectState();
}

class _SelectState extends State<_Select> {
  late final _chosen = {
    for (final o in widget.options)
      if (o.isDefault) o.value,
  };

  int get _max => widget.select.maxValues ?? 1;
  int get _min => widget.select.minValues ?? 1;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final many = _max > 1;
    return Column(
      children: [
        SheetTitle(title: widget.select.placeholder ?? 'Choose', caption: many ? 'Up to $_max' : null),
        Expanded(
          child: ListView(
            controller: widget.scroll,
            children: [
              for (final o in widget.options)
                Semantics(
                  container: true,
                  checked: _chosen.contains(o.value),
                  inMutuallyExclusiveGroup: !many,
                  label: [o.label, ?o.description].join(', '),
                  excludeSemantics: true,
                  onTap: () => _toggle(o, many),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggle(o, many),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(o.label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                                if (o.description != null)
                                  Text(
                                    o.description!,
                                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                  ),
                              ],
                            ),
                          ),
                          _Check(on: _chosen.contains(o.value)),
                        ],
                      ),
                    ),
                  ),
                ),
              if (widget.options.isEmpty) const ListNote('Nothing to choose'),
            ],
          ),
        ),
        if (many)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: DuvetButton(
              label: 'Done',
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: _chosen.length < _min ? null : () => Navigator.of(context).pop(_chosen.toList()),
            ),
          ),
      ],
    );
  }

  void _toggle(ComponentOption o, bool many) {
    if (!many) {
      Navigator.of(context).pop([o.value]);
      return;
    }
    setState(() {
      if (!_chosen.remove(o.value) && _chosen.length < _max) _chosen.add(o.value);
    });
  }
}

class _Check extends StatelessWidget {
  final bool on;
  const _Check({required this.on});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: on ? Duvet.accent : context.duvet.secondaryFill,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
      ),
      child: on ? Icon(FLucideIcons.check, size: 16, color: colors.primaryForeground) : null,
    );
  }
}

// -----------------------------------------------------------------------------
// Modals
// -----------------------------------------------------------------------------

/// A bot's modal, as a glass sheet like any other: the bot named, its texts
/// and fields, Cancel and Submit. Submitting checks the fields as the API
/// does; Cancel tells the bot nothing.
Future<void> showBotModal(
  BuildContext context, {
  required BotModal modal,
  required String from,
  required SelectChoices choices,
  required MessageDirectory directory,
}) => showGlassSheet<void>(
  context,
  label: modal.title,
  initialSize: 0.85,
  builder: (context, scroll) =>
      _Modal(modal: modal, from: from, choices: choices, directory: directory, scroll: scroll),
);

class _Modal extends StatefulWidget {
  final BotModal modal;
  final String from;
  final SelectChoices choices;
  final MessageDirectory directory;
  final ScrollController scroll;
  const _Modal({
    required this.modal,
    required this.from,
    required this.choices,
    required this.directory,
    required this.scroll,
  });

  @override
  State<_Modal> createState() => _ModalState();
}

class _ModalState extends State<_Modal> {
  late final Map<String, ModalValue> _values = initialValues(widget.modal);
  late final _texts = {
    for (final (label: _, :input) in widget.modal.inputs)
      if (input.type == ComponentKind.textInput)
        input.customId!: TextEditingController(text: _values[input.customId!] as String? ?? ''),
  };
  Map<String, String> _problems = {};
  bool _sending = false;
  String? _failure;

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    for (final e in _texts.entries) {
      _values[e.key] = e.value.text;
    }
    final answers = modalAnswers(widget.modal, _values);
    if (answers.components == null) {
      setState(() => _problems = answers.problems);
      return;
    }
    final navigator = Navigator.of(context);
    setState(() {
      _problems = {};
      _sending = true;
      _failure = null;
    });
    try {
      await context.repository.submitModal(widget.modal, answers.components!);
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _failure = e is ActionFailed ? e.message : 'This interaction failed');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const _BotSquare(size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(widget.modal.title, style: DuvetType.title.copyWith(color: colors.foreground)),
                    ),
                    const SizedBox(height: 2),
                    Text(widget.from, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: widget.scroll,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            children: [
              for (final c in widget.modal.components)
                Padding(padding: const EdgeInsets.only(bottom: 16), child: _field(context, c)),
              if (_failure != null)
                Semantics(
                  liveRegion: true,
                  child: Text(_failure!, style: DuvetType.caption.copyWith(color: colors.destructive)),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.paddingOf(context).bottom),
          child: Row(
            children: [
              Expanded(
                child: DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop()),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DuvetButton(
                  label: 'Submit',
                  variant: ButtonVariant.primary,
                  expand: true,
                  busy: _sending,
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(BuildContext context, UiComponent c) {
    final colors = context.theme.colors;
    if (c.type == ComponentKind.textDisplay) {
      return MessageText(
        content: c.content ?? '',
        directory: widget.directory,
        style: DuvetType.body.copyWith(color: colors.foreground),
      );
    }
    final input = c.input;
    if (c.type != ComponentKind.label || input?.customId == null) return const SizedBox.shrink();
    final id = input!.customId!;
    final label = [
      c.label ?? '',
      if (!isRequired(input) && input.type != ComponentKind.checkbox) '· optional',
    ].join(' ');
    final problem = _problems[id];
    Widget titled(Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
        ),
        if (c.description != null)
          Text(c.description!, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
        const SizedBox(height: 8),
        child,
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(problem, style: DuvetType.caption.copyWith(color: colors.destructive)),
          ),
      ],
    );
    switch (input.type) {
      case ComponentKind.textInput:
        return DuvetTextField(
          label: label,
          controller: _texts[id],
          hint: input.placeholder,
          maxLines: input.paragraph ? 4 : 1,
          error: problem,
          helper: c.description,
        );
      case ComponentKind.checkbox:
        final on = _values[id] == true;
        return Semantics(
          container: true,
          checked: on,
          label: c.label,
          excludeSemantics: true,
          onTap: () => setState(() => _values[id] = !on),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _values[id] = !on),
            child: Row(
              children: [
                _Check(on: on),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(c.label ?? '', style: DuvetType.body.copyWith(color: colors.foreground)),
                ),
              ],
            ),
          ),
        );
      case ComponentKind.radioGroup || ComponentKind.checkboxGroup:
        final many = input.type == ComponentKind.checkboxGroup;
        final chosen = many ? {...(_values[id] as List? ?? const [])} : {?_values[id]};
        return titled(
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in input.options)
                DuvetChip(
                  label: o.label,
                  selected: chosen.contains(o.value),
                  radio: !many,
                  onTap: () => setState(() {
                    if (!many) {
                      _values[id] = o.value;
                    } else {
                      final list = [...(_values[id] as List? ?? const [])];
                      list.contains(o.value) ? list.remove(o.value) : list.add(o.value);
                      _values[id] = list;
                    }
                  }),
                ),
            ],
          ),
        );
      default:
        // A select: its choices in a sheet of their own.
        final options = widget.choices(input);
        final chosen = {...(_values[id] as List? ?? const [])};
        final names = [
          for (final o in options)
            if (chosen.contains(o.value)) o.label,
        ];
        return titled(
          Semantics(
            container: true,
            button: true,
            label: c.label,
            value: names.join(', '),
            excludeSemantics: true,
            onTap: () => _choose(input, options),
            child: GestureDetector(
              onTap: () => _choose(input, options),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: colors.card,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                  border: Border.all(color: problem == null ? context.duvet.hairline : colors.destructive),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        names.isEmpty ? (input.placeholder ?? 'Choose') : names.join(', '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.body.copyWith(
                          color: names.isEmpty ? colors.mutedForeground : colors.foreground,
                        ),
                      ),
                    ),
                    Icon(FLucideIcons.chevronDown, size: 16, color: colors.mutedForeground),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }

  // The choices sheet replaces nothing: it's a route over this one, the one
  // place two sheets stack, as a select needs its list.
  Future<void> _choose(UiComponent input, List<ComponentOption> options) async {
    final picked = await showSelectSheet(context, select: input, options: options);
    if (picked != null && mounted) setState(() => _values[input.customId!] = picked);
  }
}

/// A bot's mark: bots aren't people, so a rounded square, not a circle.
class _BotSquare extends StatelessWidget {
  final double size;
  const _BotSquare({required this.size});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(size * 0.3)),
        child: InsetShadow(
          shadows: context.duvet.shadowWell,
          borderRadius: BorderRadius.circular(size * 0.3),
          child: Icon(FLucideIcons.bot, size: size * 0.55, color: colors.foreground),
        ),
      ),
    );
  }
}

/// A bot's avatar beside its messages.
class BotAvatar extends StatelessWidget {
  final double size;
  const BotAvatar({this.size = 32, super.key});

  @override
  Widget build(BuildContext context) => _BotSquare(size: size);
}

/// The quiet tag after a bot's name.
class BotTag extends StatelessWidget {
  /// A webhook's message: WEBHOOK, as on the desktop.
  final bool webhook;
  const BotTag({this.webhook = false, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(4)),
      child: Text(
        webhook ? 'WEBHOOK' : 'BOT',
        style: DuvetType.tabLabel.copyWith(fontSize: 10, fontWeight: FontWeight.w700, color: colors.foreground),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Commands
// -----------------------------------------------------------------------------

/// A command's options, to fill before it runs: texts, numbers, a switch,
/// choices, members, rooms, roles. Answers the values by name, once they
/// pass the API's checks.
Future<Map<String, Object>?> showCommandForm(
  BuildContext context, {
  required BotCommand command,
  required List<ComponentOption> Function(BotCommandOption option) choicesFor,
}) => showGlassSheet<Map<String, Object>>(
  context,
  label: '/${command.name}',
  initialSize: 0.75,
  builder: (context, scroll) => _CommandForm(command: command, choicesFor: choicesFor, scroll: scroll),
);

class _CommandForm extends StatefulWidget {
  final BotCommand command;
  final List<ComponentOption> Function(BotCommandOption option) choicesFor;
  final ScrollController scroll;
  const _CommandForm({required this.command, required this.choicesFor, required this.scroll});

  @override
  State<_CommandForm> createState() => _CommandFormState();
}

class _CommandFormState extends State<_CommandForm> {
  final _values = <String, Object>{};
  late final _texts = {
    for (final o in widget.command.options)
      if (o.choices.isEmpty &&
          (o.type == OptionKind.string || o.type == OptionKind.integer || o.type == OptionKind.number))
        o.name: TextEditingController(),
  };
  Map<String, String> _problems = {};

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _send() {
    final problems = <String, String>{};
    final values = <String, Object>{..._values};
    for (final o in widget.command.options) {
      if (_texts[o.name] case final c?) {
        final text = c.text.trim();
        if (text.isEmpty) {
          values.remove(o.name);
        } else if (o.type == OptionKind.string) {
          // Counted in characters, as the API counts them: 6000 at most when
          // the option says no other, as on the desktop.
          final length = text.runes.length;
          final max = o.maxLength ?? 6000;
          if (o.minLength case final min? when length < min) {
            problems[o.name] = 'Takes $min characters at least';
            continue;
          }
          if (length > max) {
            problems[o.name] = 'Takes $max characters at most';
            continue;
          }
          values[o.name] = text;
        } else {
          final n = _numberIn(o, text);
          if (n == null) {
            problems[o.name] = o.type == OptionKind.integer ? 'A whole number' : 'A number';
            continue;
          }
          if (o.minValue != null && n < o.minValue! || o.maxValue != null && n > o.maxValue!) {
            problems[o.name] = 'From ${o.minValue ?? '…'} to ${o.maxValue ?? '…'}';
            continue;
          }
          values[o.name] = n;
        }
      }
      if (o.required && !values.containsKey(o.name)) problems[o.name] = 'This one is required';
    }
    if (problems.isNotEmpty) {
      setState(() => _problems = problems);
      return;
    }
    Navigator.of(context).pop(values);
  }

  // The number in an integer or number option's text, as the desktop reads it
  // and the API takes it (commands.CheckUse): an integer in plain digits,
  // within ±(2^53 - 1); any other number finite, within ±2^53. Null for
  // anything else, NaN and infinities among them, which JSON can't carry.
  static num? _numberIn(BotCommandOption o, String text) {
    if (o.type == OptionKind.integer) {
      final n = RegExp(r'^-?\d+$').hasMatch(text) ? int.tryParse(text) : null;
      return n != null && n.abs() <= _maxSafeInteger ? n : null;
    }
    final n = num.tryParse(text);
    return n != null && n.isFinite && n.abs() <= _maxNumber ? n : null;
  }

  static const _maxSafeInteger = 9007199254740991;
  static const _maxNumber = 9007199254740992;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final command = widget.command;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const _BotSquare(size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('/${command.name}', style: DuvetType.code.copyWith(fontSize: 18, color: colors.foreground)),
                    Text(
                      [command.appName, if (command.description.isNotEmpty) command.description].join(' · '),
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: widget.scroll,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
            children: [
              for (final o in command.options)
                Padding(padding: const EdgeInsets.only(bottom: 16), child: _option(context, o)),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.paddingOf(context).bottom),
          child: DuvetButton(
            label: 'Send /${command.name}',
            variant: ButtonVariant.primary,
            expand: true,
            onPressed: _send,
          ),
        ),
      ],
    );
  }

  Widget _option(BuildContext context, BotCommandOption o) {
    final colors = context.theme.colors;
    final label = '${o.name}${o.required ? '' : ' · optional'}';
    final problem = _problems[o.name];
    if (_texts[o.name] case final c?) {
      return DuvetTextField(
        label: label,
        controller: c,
        helper: o.description.isEmpty ? null : o.description,
        error: problem,
        keyboardType: o.type == OptionKind.string
            ? null
            : const TextInputType.numberWithOptions(decimal: true, signed: true),
      );
    }
    final List<ComponentOption> choices = o.choices.isNotEmpty
        ? [for (final ch in o.choices) ComponentOption(label: ch.name, value: '${ch.value}')]
        : o.type == OptionKind.boolean
        ? const [ComponentOption(label: 'Yes', value: 'true'), ComponentOption(label: 'No', value: 'false')]
        : widget.choicesFor(o);
    final raw = {for (final ch in o.choices) '${ch.value}': ch.value};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
        ),
        if (o.description.isNotEmpty)
          Text(o.description, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final ch in choices)
              DuvetChip(
                label: ch.label,
                selected: '${_values[o.name]}' == ch.value,
                onTap: () => setState(
                  () =>
                      _values[o.name] = o.type == OptionKind.boolean ? ch.value == 'true' : (raw[ch.value] ?? ch.value),
                ),
              ),
          ],
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(problem, style: DuvetType.caption.copyWith(color: colors.destructive)),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Bot invites
// -----------------------------------------------------------------------------

/// A bot's invite link, as a card: the bot, and Add to a Space.
class BotInviteCard extends StatefulWidget {
  final String botId;
  const BotInviteCard({required this.botId, super.key});

  @override
  State<BotInviteCard> createState() => _BotInviteCardState();
}

class _BotInviteCardState extends State<BotInviteCard> {
  late Future<BotInfo> _bot;
  String? _added;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bot = context.repository.bot(widget.botId);
  }

  Future<void> _add(BotInfo bot) async {
    final repository = context.repository;
    final space = await showGlassSheet<Space>(
      context,
      label: 'Add ${bot.name} to a Space',
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: 'Add ${bot.name} to…'),
          for (final s in repository.spaces.value)
            ListRow(
              leading: SpaceIcon(space: s),
              title: s.name,
              onTap: () => Navigator.of(context).pop(s),
            ),
          if (repository.spaces.value.isEmpty) const ListNote('You’re not in any spaces'),
        ],
      ),
    );
    if (space == null || !mounted) return;
    try {
      await repository.addBot(space.id, bot.id);
      if (mounted) setState(() => _added = space.name);
    } catch (e) {
      // The API's reason, as the desktop shows it.
      if (mounted) {
        showFToast(
          context: context,
          title: Text(e is ActionFailed ? e.message : 'Couldn’t add ${bot.name} to ${space.name}'),
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return FutureBuilder(
      future: _bot,
      builder: (context, snapshot) {
        final bot = snapshot.data;
        if (bot == null) {
          return snapshot.hasError ? const SizedBox.shrink() : const SizedBox(width: 280, height: 56);
        }
        return Semantics(
          container: true,
          label: 'Invite for the bot ${bot.name}',
          explicitChildNodes: true,
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
              boxShadow: tokens.shadowRaised,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text('ADD A BOT', style: DuvetType.overline.copyWith(color: colors.mutedForeground)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const _BotSquare(size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              bot.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DuvetType.rowTitle.copyWith(color: colors.foreground),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const BotTag(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DuvetButton(
                  label: _added == null ? 'Add to a Space' : 'Added to $_added',
                  expand: true,
                  onPressed: _added == null ? () => _add(bot) : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
