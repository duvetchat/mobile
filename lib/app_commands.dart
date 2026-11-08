import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/models.dart';
import 'data/scope.dart';
import 'space_admin.dart' show AdminPage, AdminPanel, adminToast, confirmDestructive;
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';
import 'widgets/unsaved_changes.dart';

/// The API's limits (`internal/domain/commands/validate.go`): a name's
/// characters, a description's, and the options or choices a list holds.
const _nameLimit = 32;
const _descriptionLimit = 100;
const _listLimit = 25;

const _valueKinds = [
  OptionKind.string,
  OptionKind.integer,
  OptionKind.number,
  OptionKind.boolean,
  OptionKind.user,
  OptionKind.room,
  OptionKind.role,
  OptionKind.mentionable,
];

String kindLabel(int kind) => switch (kind) {
  OptionKind.subcommand => 'Subcommand',
  OptionKind.subcommandGroup => 'Group of subcommands',
  OptionKind.string => 'Text',
  OptionKind.integer => 'Whole number',
  OptionKind.number => 'Number',
  OptionKind.boolean => 'Yes or no',
  OptionKind.user => 'User',
  OptionKind.room => 'Room',
  OptionKind.role => 'Role',
  OptionKind.mentionable => 'User or role',
  _ => 'Option',
};

IconData _kindIcon(int kind) => switch (kind) {
  OptionKind.subcommand => FLucideIcons.cornerDownRight,
  OptionKind.subcommandGroup => FLucideIcons.folder,
  OptionKind.string => FLucideIcons.type,
  OptionKind.integer || OptionKind.number => FLucideIcons.hash,
  OptionKind.boolean => FLucideIcons.toggleLeft,
  OptionKind.user => FLucideIcons.user,
  OptionKind.room => FLucideIcons.messageSquare,
  OptionKind.role => FLucideIcons.shield,
  _ => FLucideIcons.atSign,
};

/// The kinds an option may be beside [siblings]: a command's options are all
/// subcommands and groups or none of them; a group holds only subcommands; a
/// subcommand only options that take a value.
List<int> _kindsFor(List<BotCommandOption> siblings, {required int? parent}) => switch (parent) {
  OptionKind.subcommandGroup => const [OptionKind.subcommand],
  OptionKind.subcommand => _valueKinds,
  _ when siblings.isEmpty => const [..._valueKinds, OptionKind.subcommand, OptionKind.subcommandGroup],
  _ when siblings.first.isSubcommand => const [OptionKind.subcommand, OptionKind.subcommandGroup],
  _ => _valueKinds,
};

/// An application's slash commands: listed by name, each opening to edit it.
class CommandsPage extends StatefulWidget {
  final DevApp app;
  const CommandsPage({required this.app, super.key});

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  late Future<List<BotCommand>> _commands;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _commands = context.repository.appCommands(widget.app);
  }

  Future<void> _open([BotCommand? command]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommandEditorPage(app: widget.app, command: command),
      ),
    );
    if (!mounted) return;
    setState(() {
      _commands = context.repository.appCommands(widget.app);
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _commands,
    builder: (context, snapshot) {
      final commands = snapshot.data;
      return AdminPage(
        title: 'Commands',
        actions: [IconAction(icon: FLucideIcons.plus, label: 'New command', onPressed: _open)],
        children: [
          if (snapshot.hasError)
            const ListNote('Couldn’t load the commands')
          else if (commands == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: FCircularProgress()),
            )
          else if (commands.isEmpty)
            const ListNote('No commands yet. Members of a Space with the bot use them by typing /.')
          else
            for (final c in commands) ListRow(title: '/${c.name}', snippet: c.description, onTap: () => _open(c)),
        ],
      );
    },
  );
}

/// A command's name, description and options; saved with Save, deleted
/// from its page.
class CommandEditorPage extends StatefulWidget {
  final DevApp app;

  /// Null for a new one.
  final BotCommand? command;
  const CommandEditorPage({required this.app, this.command, super.key});

  @override
  State<CommandEditorPage> createState() => _CommandEditorPageState();
}

class _CommandEditorPageState extends State<CommandEditorPage> {
  late final _name = TextEditingController(text: widget.command?.name ?? '');
  late final _description = TextEditingController(text: widget.command?.description ?? '');
  late List<BotCommandOption> _options = widget.command?.options ?? const [];
  bool _optionsChanged = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _description.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _optionsChanged ||
      _name.text != (widget.command?.name ?? '') ||
      _description.text != (widget.command?.description ?? '');

  Future<void> _save() async {
    final name = _name.text.trim();
    final description = _description.text.trim();
    if (name.isEmpty || description.isEmpty) {
      adminToast(context, 'A command needs a name and a description');
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await context.repository.saveAppCommand(
        widget.app,
        BotCommand(
          id: widget.command?.id ?? '',
          applicationId: widget.app.id,
          appName: widget.app.name,
          name: name,
          description: description,
          options: _options,
        ),
      );
      navigator.pop();
    } catch (e) {
      // The API's reason: a name it doesn't take, an option's rules.
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t save the command');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final command = widget.command!;
    final sure = await confirmDestructive(
      context,
      title: 'Delete /${command.name}?',
      body: 'No one can use it any more, in any Space.',
      action: 'Delete command',
    );
    if (!sure || !mounted) return;
    final navigator = Navigator.of(context);
    try {
      await context.repository.deleteAppCommand(widget.app, command.id);
      navigator.pop();
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t delete the command');
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedChanges(
    dirty: _dirty,
    child: AdminPage(
      title: widget.command == null ? 'New command' : '/${widget.command!.name}',
      actions: [TextAction(label: 'Save', onPressed: _saving || !_dirty ? null : _save)],
      children: [
        DuvetTextField(
          label: 'Name',
          controller: _name,
          helper: 'Lowercase letters, digits, - and _',
          maxLength: _nameLimit,
        ),
        const SizedBox(height: 12),
        DuvetTextField(label: 'Description', controller: _description, maxLength: _descriptionLimit),
        const Overline('Options'),
        OptionList(
          options: _options,
          parent: null,
          onChanged: (options) => setState(() {
            _options = options;
            _optionsChanged = true;
          }),
        ),
        if (widget.command != null) ...[
          const SizedBox(height: 16),
          AdminPanel(
            children: [
              GlassRow(icon: FLucideIcons.trash2, label: 'Delete command', destructive: true, onPressed: _delete),
            ],
          ),
        ],
      ],
    ),
  );
}

/// A command's, a subcommand's or a group's options: each opens to edit or
/// remove it, and an Add row adds one of the kinds the list takes.
class OptionList extends StatelessWidget {
  final List<BotCommandOption> options;

  /// The kind holding them; null for a command's own.
  final int? parent;
  final ValueChanged<List<BotCommandOption>> onChanged;
  const OptionList({required this.options, required this.parent, required this.onChanged, super.key});

  Future<void> _edit(BuildContext context, int? index) async {
    final siblings = [
      for (final (i, o) in options.indexed)
        if (i != index) o,
    ];
    final result = await Navigator.of(context).push<_OptionResult>(
      MaterialPageRoute(
        builder: (_) => OptionEditorPage(
          option: index == null ? null : options[index],
          kinds: _kindsFor(siblings, parent: parent),
        ),
      ),
    );
    if (result == null) return;
    final list = [...options];
    switch ((index, result.option)) {
      case (null, final added?):
        list.add(added);
      case (final i?, final changed?):
        list[i] = changed;
      case (final i?, null):
        list.removeAt(i);
      case (null, null):
        return;
    }
    // The required ones first, as the API wants them.
    onChanged([...list.where((o) => o.required), ...list.where((o) => !o.required)]);
  }

  @override
  Widget build(BuildContext context) => AdminPanel(
    children: [
      for (final (i, o) in options.indexed)
        GlassRow(
          icon: o.isSubcommand ? FLucideIcons.cornerDownRight : FLucideIcons.slidersHorizontal,
          label: o.name,
          detail: [
            kindLabel(o.type),
            if (o.required) 'required',
            if (o.options.isNotEmpty) '${o.options.length}',
          ].join(' · '),
          onPressed: () => _edit(context, i),
        ),
      if (options.length < _listLimit)
        GlassRow(
          icon: FLucideIcons.plus,
          label: parent == OptionKind.subcommandGroup ? 'Add subcommand' : 'Add option',
          onPressed: () => _edit(context, null),
        ),
    ],
  );
}

/// What an option's page answers: the option, or null once removed.
typedef _OptionResult = ({BotCommandOption? option});

/// One option: its kind, name and description, then what its kind takes
/// (required, bounds, choices, room types, or its own options).
class OptionEditorPage extends StatefulWidget {
  final BotCommandOption? option;

  /// The kinds it may be.
  final List<int> kinds;
  const OptionEditorPage({required this.option, required this.kinds, super.key});

  @override
  State<OptionEditorPage> createState() => _OptionEditorPageState();
}

class _OptionEditorPageState extends State<OptionEditorPage> {
  late int _kind = widget.option?.type ?? widget.kinds.first;
  late final _name = TextEditingController(text: widget.option?.name ?? '');
  late final _description = TextEditingController(text: widget.option?.description ?? '');
  late final _min = TextEditingController(text: _bound(widget.option?.minValue ?? widget.option?.minLength));
  late final _max = TextEditingController(text: _bound(widget.option?.maxValue ?? widget.option?.maxLength));
  late bool _required = widget.option?.required ?? false;
  late List<({String name, Object value})> _choices = widget.option?.choices ?? const [];
  late Set<int> _roomTypes = {...?widget.option?.roomTypes};
  late List<BotCommandOption> _options = widget.option?.options ?? const [];

  static String _bound(num? n) => n == null ? '' : '$n';

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  bool get _sub => _kind == OptionKind.subcommand || _kind == OptionKind.subcommandGroup;
  bool get _bounded => _kind == OptionKind.string || _kind == OptionKind.integer || _kind == OptionKind.number;

  /// [text] as the kind reads it: a whole number (of characters, for text)
  /// or, for a number option, any number. Null when empty; throws when it
  /// doesn't read.
  num? _read(String text, String what) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final n = _kind == OptionKind.number ? num.tryParse(t) : int.tryParse(t);
    if (n == null) throw ActionFailed('$what must be ${_kind == OptionKind.number ? 'a number' : 'a whole number'}');
    return n;
  }

  void _done() {
    final name = _name.text.trim();
    final description = _description.text.trim();
    if (name.isEmpty || description.isEmpty) {
      adminToast(context, 'An option needs a name and a description');
      return;
    }
    if (_kind == OptionKind.subcommandGroup && _options.isEmpty) {
      adminToast(context, 'A group needs a subcommand');
      return;
    }
    final num? min;
    final num? max;
    try {
      min = _bounded ? _read(_min.text, 'The least') : null;
      max = _bounded ? _read(_max.text, 'The most') : null;
    } on ActionFailed catch (e) {
      adminToast(context, e.message);
      return;
    }
    final text = _kind == OptionKind.string;
    Navigator.of(context).pop<_OptionResult>((
      option: BotCommandOption(
        type: _kind,
        name: name,
        description: description,
        required: !_sub && _required,
        choices: _bounded ? _choices : const [],
        minValue: text ? null : min,
        maxValue: text ? null : max,
        minLength: text ? min?.toInt() : null,
        maxLength: text ? max?.toInt() : null,
        roomTypes: _kind == OptionKind.room ? (_roomTypes.toList()..sort()) : const [],
        options: _sub ? _options : const [],
      ),
    ));
  }

  Future<void> _pickKind(BuildContext anchor) async {
    final picked = await showGlassMenu<int>(
      anchor,
      label: 'Type',
      items: [for (final k in widget.kinds) GlassMenuItem(icon: _kindIcon(k), label: kindLabel(k), value: k)],
    );
    if (picked == null || picked == _kind || !mounted) return;
    setState(() {
      _kind = picked;
      // What the old kind took doesn't fit the new one.
      _choices = const [];
      _options = const [];
      _min.clear();
      _max.clear();
    });
  }

  Future<void> _editChoice(int? index) async {
    final got = await showGlassDialogSheet<({String name, Object value})>(
      context,
      label: index == null ? 'Add choice' : 'Choice',
      builder: (_) => _ChoiceSheet(kind: _kind, choice: index == null ? null : _choices[index]),
    );
    if (got == null || !mounted) return;
    setState(() {
      final list = [..._choices];
      // An empty name is a removal.
      if (got.name.isEmpty) {
        if (index != null) list.removeAt(index);
      } else if (index == null) {
        list.add(got);
      } else {
        list[index] = got;
      }
      _choices = list;
    });
  }

  Future<void> _remove() async {
    final sure = await confirmDestructive(
      context,
      title: 'Remove ${widget.option!.name}?',
      body: 'It goes once the command is saved.',
      action: 'Remove',
    );
    if (sure && mounted) Navigator.of(context).pop<_OptionResult>((option: null));
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: DuvetType.rowTitle.copyWith(color: context.theme.colors.foreground)),
        ),
        DuvetSwitch(label: label, value: value, onChanged: onChanged),
      ],
    ),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Text(text, style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground)),
  );

  @override
  Widget build(BuildContext context) => AdminPage(
    title: widget.option == null ? 'New option' : widget.option!.name,
    actions: [TextAction(label: 'Done', onPressed: _done)],
    children: [
      if (widget.kinds.length > 1)
        AdminPanel(
          children: [
            Builder(
              builder: (anchor) => GlassRow(
                icon: FLucideIcons.shapes,
                label: 'Type',
                detail: kindLabel(_kind),
                onPressed: () => _pickKind(anchor),
              ),
            ),
          ],
        ),
      const SizedBox(height: 12),
      DuvetTextField(
        label: 'Name',
        controller: _name,
        helper: 'Lowercase letters, digits, - and _',
        maxLength: _nameLimit,
      ),
      const SizedBox(height: 12),
      DuvetTextField(label: 'Description', controller: _description, maxLength: _descriptionLimit),
      if (!_sub) ...[
        const SizedBox(height: 12),
        AdminPanel(children: [_switchRow('Required', _required, (on) => setState(() => _required = on))]),
      ],
      if (_bounded) ...[
        Overline(_kind == OptionKind.string ? 'Length' : 'Range'),
        Row(
          children: [
            Expanded(
              child: DuvetTextField(label: 'Least', controller: _min, keyboardType: TextInputType.number),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DuvetTextField(label: 'Most', controller: _max, keyboardType: TextInputType.number),
            ),
          ],
        ),
        const Overline('Choices'),
        AdminPanel(
          children: [
            for (final (i, c) in _choices.indexed)
              GlassRow(label: c.name, detail: '${c.value}', onPressed: () => _editChoice(i)),
            if (_choices.length < _listLimit)
              GlassRow(icon: FLucideIcons.plus, label: 'Add choice', onPressed: () => _editChoice(null)),
          ],
        ),
        _note('With choices, only those can be picked.'),
      ],
      if (_kind == OptionKind.room) ...[
        const Overline('Rooms it offers'),
        AdminPanel(
          children: [
            for (final (type, label) in const [(1, 'Text rooms'), (2, 'Voice rooms'), (3, 'Categories')])
              _switchRow(
                label,
                _roomTypes.contains(type),
                (on) => setState(() => _roomTypes = on ? {..._roomTypes, type} : ({..._roomTypes}..remove(type))),
              ),
          ],
        ),
        _note('With none on, it offers every room.'),
      ],
      if (_sub) ...[
        Overline(_kind == OptionKind.subcommandGroup ? 'Subcommands' : 'Options'),
        OptionList(options: _options, parent: _kind, onChanged: (o) => setState(() => _options = o)),
      ],
      if (widget.option != null) ...[
        const SizedBox(height: 16),
        AdminPanel(
          children: [
            GlassRow(
              icon: FLucideIcons.trash2,
              label: 'Remove ${kindLabel(_kind).toLowerCase()}',
              destructive: true,
              onPressed: _remove,
            ),
          ],
        ),
      ],
    ],
  );
}

/// A choice's name and value, the value read as [kind] takes it. Answers
/// an empty name to remove it.
class _ChoiceSheet extends StatefulWidget {
  final int kind;
  final ({String name, Object value})? choice;
  const _ChoiceSheet({required this.kind, required this.choice});

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  late final _name = TextEditingController(text: widget.choice?.name ?? '');
  late final _value = TextEditingController(text: widget.choice == null ? '' : '${widget.choice!.value}');
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final text = _value.text.trim();
    final Object? value = switch (widget.kind) {
      OptionKind.integer => int.tryParse(text),
      OptionKind.number => num.tryParse(text),
      _ => text.isEmpty ? null : text,
    };
    if (name.isEmpty || value == null) {
      setState(
        () => _problem = name.isEmpty
            ? 'It needs a name'
            : widget.kind == OptionKind.string
            ? 'It needs a value'
            : 'The value must be ${widget.kind == OptionKind.number ? 'a number' : 'a whole number'}',
      );
      return;
    }
    Navigator.of(context).pop((name: name, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.choice == null ? 'Add choice' : 'Choice',
            style: DuvetType.title.copyWith(color: colors.foreground),
          ),
          const SizedBox(height: 16),
          DuvetTextField(label: 'Name', hint: 'What people see', controller: _name, autofocus: true, maxLength: 100),
          const SizedBox(height: 12),
          DuvetTextField(
            label: 'Value',
            hint: 'What the bot gets',
            controller: _value,
            error: _problem,
            maxLength: 100,
            keyboardType: widget.kind == OptionKind.string ? null : TextInputType.number,
          ),
          const SizedBox(height: 16),
          DuvetButton(label: 'Save', variant: ButtonVariant.primary, expand: true, onPressed: _save),
          if (widget.choice != null) ...[
            const SizedBox(height: 12),
            DuvetButton(
              label: 'Remove choice',
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop((name: '', value: '')),
            ),
          ],
        ],
      ),
    );
  }
}
