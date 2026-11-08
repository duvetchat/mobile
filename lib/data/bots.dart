/// Bots in a chat: the components of their messages, the commands of a
/// Space's applications, and the modals they open. Shaped as the API sends
/// them (`types/index.ts`'s `Component` on desktop).
library;

abstract final class ComponentKind {
  static const actionRow = 1;
  static const button = 2;
  static const stringSelect = 3;
  static const textInput = 4;
  static const userSelect = 5;
  static const roleSelect = 6;
  static const mentionableSelect = 7;
  static const roomSelect = 8;
  static const section = 9;
  static const textDisplay = 10;
  static const thumbnail = 11;
  static const mediaGallery = 12;
  static const file = 13;
  static const separator = 14;
  static const container = 17;
  static const label = 18;
  static const radioGroup = 21;
  static const checkboxGroup = 22;
  static const checkbox = 23;

  static const selects = {stringSelect, userSelect, roleSelect, mentionableSelect, roomSelect};
}

abstract final class ButtonStyleKind {
  static const primary = 1;
  static const secondary = 2;
  static const success = 3;
  static const danger = 4;
  static const link = 5;
}

class ComponentOption {
  final String label;
  final String value;
  final String? description;
  final bool isDefault;
  const ComponentOption({required this.label, required this.value, this.description, this.isDefault = false});

  static ComponentOption fromJson(Map<String, dynamic> j) => ComponentOption(
    label: j['label'] as String? ?? '${j['value']}',
    value: '${j['value']}',
    description: j['description'] as String?,
    isDefault: j['default'] as bool? ?? false,
  );
}

/// A media gallery's item.
typedef GalleryItem = ({String url, String? contentType, String? description, String? attachmentId, bool spoiler});

/// One component, any kind: the fields it has are its kind's.
class UiComponent {
  final int type;
  final int? id;
  final String? customId;
  final int? style;
  final String? label;
  final String? emoji;
  final String? url;
  final bool disabled;
  final String? placeholder;
  final int? minValues;
  final int? maxValues;
  final List<ComponentOption> options;
  final List<String> defaultValues;

  /// A room select's room types (1 text, 2 voice, 3 category); empty takes
  /// any.
  final List<int> roomTypes;
  final List<UiComponent> children;
  final UiComponent? accessory;

  /// A label's input.
  final UiComponent? input;
  final String? content;
  final String? mediaUrl;

  /// The file behind [mediaUrl] when the message carries it: its link
  /// renews.
  final String? mediaAttachmentId;

  /// A gallery's items: each one's link, its `content_type` (a `video/*`
  /// one is a video), its description, its file and whether it's a spoiler.
  final List<GalleryItem> gallery;
  final String? description;

  /// A container, thumbnail or file covered until tapped.
  final bool spoiler;

  /// A container's stripe down its left side, as `0xRRGGBB`.
  final int? accentColor;

  /// A file's name and size in bytes, as the API gives them.
  final String? fileName;
  final int? fileSize;
  final bool? required;
  final int? minLength;
  final int? maxLength;
  final String? value;
  final bool defaultChecked;

  /// A text input's style: 2 is a paragraph.
  final bool paragraph;

  const UiComponent({
    required this.type,
    this.id,
    this.customId,
    this.style,
    this.label,
    this.emoji,
    this.url,
    this.disabled = false,
    this.placeholder,
    this.minValues,
    this.maxValues,
    this.options = const [],
    this.defaultValues = const [],
    this.roomTypes = const [],
    this.children = const [],
    this.accessory,
    this.input,
    this.content,
    this.mediaUrl,
    this.mediaAttachmentId,
    this.gallery = const [],
    this.description,
    this.spoiler = false,
    this.accentColor,
    this.fileName,
    this.fileSize,
    this.required,
    this.minLength,
    this.maxLength,
    this.value,
    this.defaultChecked = false,
    this.paragraph = false,
  });

  bool get isSelect => ComponentKind.selects.contains(type);

  static UiComponent fromJson(Map<String, dynamic> j) {
    String? webUrl(Object? u) => u is String && RegExp(r'^https?://', caseSensitive: false).hasMatch(u) ? u : null;
    return UiComponent(
      type: j['type'] as int? ?? 0,
      id: j['id'] as int?,
      customId: j['custom_id'] as String?,
      style: j['style'] as int?,
      label: j['label'] as String?,
      emoji: (j['emoji'] as Map?)?['name'] as String?,
      url: webUrl(j['url']),
      disabled: j['disabled'] as bool? ?? false,
      placeholder: j['placeholder'] as String?,
      minValues: j['min_values'] as int?,
      maxValues: j['max_values'] as int?,
      options: [
        for (final o in j['options'] as List? ?? const [])
          if (o is Map<String, dynamic>) ComponentOption.fromJson(o),
      ],
      defaultValues: [
        for (final d in j['default_values'] as List? ?? const [])
          if (d is Map) '${d['id']}',
      ],
      roomTypes: [
        for (final t in j['room_types'] as List? ?? const [])
          if (t is int) t,
      ],
      children: [
        for (final c in j['components'] as List? ?? const [])
          if (c is Map<String, dynamic>) fromJson(c),
      ],
      accessory: switch (j['accessory']) {
        final Map<String, dynamic> a => fromJson(a),
        _ => null,
      },
      input: switch (j['component']) {
        final Map<String, dynamic> c => fromJson(c),
        _ => null,
      },
      content: j['content'] as String?,
      mediaUrl: webUrl((j['media'] as Map?)?['url']) ?? webUrl((j['file'] as Map?)?['url']),
      mediaAttachmentId: ((j['media'] ?? j['file']) as Map?)?['attachment_id'] as String?,
      gallery: [
        for (final i in j['items'] as List? ?? const [])
          if (i case {'media': final Map m} when webUrl(m['url']) != null)
            (
              url: m['url'] as String,
              contentType: m['content_type'] as String?,
              description: i['description'] as String?,
              attachmentId: m['attachment_id'] as String?,
              spoiler: i['spoiler'] == true,
            ),
      ],
      description: j['description'] as String?,
      spoiler: j['spoiler'] == true,
      accentColor: j['accent_color'] as int?,
      fileName: j['name'] as String?,
      fileSize: j['size'] as int?,
      required: j['required'] as bool?,
      minLength: j['min_length'] as int?,
      maxLength: j['max_length'] as int?,
      value: j['value'] as String?,
      defaultChecked: j['default'] as bool? ?? false,
      paragraph: j['type'] == ComponentKind.textInput && j['style'] == 2,
    );
  }
}

List<UiComponent> componentsFromJson(List<Map<String, dynamic>>? list) => [
  for (final c in list ?? const <Map<String, dynamic>>[]) UiComponent.fromJson(c),
];

/// A command of an application in a Space.
class BotCommand {
  final String id;
  final String applicationId;
  final String appName;
  final String name;
  final String description;
  final List<BotCommandOption> options;
  const BotCommand({
    required this.id,
    required this.applicationId,
    required this.appName,
    required this.name,
    required this.description,
    this.options = const [],
  });
}

abstract final class OptionKind {
  /// Something the command does, with options of its own: a command's
  /// options are all subcommands and groups of them, or none of them.
  static const subcommand = 1;

  /// Subcommands that go together, one level deep: a group holds only
  /// subcommands.
  static const subcommandGroup = 2;
  static const string = 3;
  static const integer = 4;
  static const boolean = 5;
  static const user = 6;
  static const room = 7;
  static const role = 8;
  static const mentionable = 9;
  static const number = 10;
}

class BotCommandOption {
  final int type;
  final String name;
  final String description;
  final bool required;
  final List<({String name, Object value})> choices;
  final num? minValue;
  final num? maxValue;
  final int? minLength;
  final int? maxLength;

  /// A room option's room types, as a select's; empty takes any.
  final List<int> roomTypes;

  /// A subcommand's options, or a group's subcommands.
  final List<BotCommandOption> options;
  const BotCommandOption({
    required this.type,
    required this.name,
    this.description = '',
    this.required = false,
    this.choices = const [],
    this.minValue,
    this.maxValue,
    this.minLength,
    this.maxLength,
    this.roomTypes = const [],
    this.options = const [],
  });

  bool get isSubcommand => type == OptionKind.subcommand || type == OptionKind.subcommandGroup;
}

/// A modal a bot opened, and where its submit goes.
class BotModal {
  final String customId;
  final String title;
  final List<UiComponent> components;
  final String applicationId;
  final String roomId;

  /// The message whose component opened it, if one did.
  final String? messageId;
  const BotModal({
    required this.customId,
    required this.title,
    required this.components,
    required this.applicationId,
    required this.roomId,
    this.messageId,
  });

  static BotModal fromJson(
    Map<String, dynamic> j, {
    required String applicationId,
    required String roomId,
    String? messageId,
  }) => BotModal(
    customId: j['custom_id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    components: [
      for (final c in j['components'] as List? ?? const [])
        if (c is Map<String, dynamic>) UiComponent.fromJson(c),
    ],
    applicationId: applicationId,
    roomId: roomId,
    messageId: messageId,
  );

  /// Each label with its input.
  List<({UiComponent label, UiComponent input})> get inputs => [
    for (final c in components)
      if (c.type == ComponentKind.label && c.input?.customId != null) (label: c, input: c.input!),
  ];
}

/// What a modal's field holds: a text, choices, a radio's choice, a checkbox.
typedef ModalValue = Object?;

/// Whether an input must be answered: unless it says otherwise; a checkbox
/// always has a value.
bool isRequired(UiComponent input) => input.type != ComponentKind.checkbox && input.required != false;

/// What each input starts with, by custom ID.
Map<String, ModalValue> initialValues(BotModal modal) => {
  for (final (label: _, :input) in modal.inputs)
    input.customId!: switch (input.type) {
      ComponentKind.textInput => input.value ?? '',
      ComponentKind.radioGroup => input.options.where((o) => o.isDefault).firstOrNull?.value,
      ComponentKind.checkbox => input.defaultChecked,
      ComponentKind.stringSelect || ComponentKind.checkboxGroup => [
        for (final o in input.options)
          if (o.isDefault) o.value,
      ],
      _ => [...input.defaultValues],
    },
};

/// Why a field can't be sent, as the API checks it, or null.
String? problemOf(UiComponent input, ModalValue value) {
  switch (input.type) {
    case ComponentKind.checkbox:
      return null;
    case ComponentKind.textInput:
      final length = (value is String ? value : '').runes.length;
      if (length == 0) return isRequired(input) ? 'This field is required' : null;
      if (length < (input.minLength ?? 0)) return 'Must be at least ${input.minLength} characters';
      if (length > (input.maxLength ?? 4000)) return 'Must be at most ${input.maxLength ?? 4000} characters';
      return null;
    case ComponentKind.radioGroup:
      return value == null && isRequired(input) ? 'This field is required' : null;
    default:
      final count = value is List ? value.length : 0;
      if (count == 0) return isRequired(input) ? 'This field is required' : null;
      final max = input.maxValues ?? (input.type == ComponentKind.checkboxGroup ? input.options.length : 1);
      final min = input.minValues ?? 1;
      return count < min || count > max ? 'Choose ${min == max ? '$min' : '$min to $max'}' : null;
  }
}

/// The components a submit sends, or each field's problem by custom ID.
({List<Map<String, dynamic>>? components, Map<String, String> problems}) modalAnswers(
  BotModal modal,
  Map<String, ModalValue> values,
) {
  final components = <Map<String, dynamic>>[];
  final problems = <String, String>{};
  for (final (:label, :input) in modal.inputs) {
    final id = input.customId!;
    final value = values[id];
    if (problemOf(input, value) case final p?) {
      problems[id] = p;
      continue;
    }
    components.add({
      'type': ComponentKind.label,
      'id': ?label.id,
      'component': {
        'type': input.type,
        'id': ?input.id,
        'custom_id': id,
        ...switch (input.type) {
          ComponentKind.textInput => {'value': value is String ? value : ''},
          ComponentKind.radioGroup => {'value': value is String ? value : null},
          ComponentKind.checkbox => {'value': value == true},
          _ => {
            'values': value is List ? [for (final v in value) '$v'] : <String>[],
          },
        },
      },
    });
  }
  return (components: problems.isEmpty ? components : null, problems: problems);
}

/// A bot to add to a Space, from its invite link.
class BotInfo {
  final String id;
  final String name;
  final String? avatarUrl;
  const BotInfo({required this.id, required this.name, this.avatarUrl});
}
