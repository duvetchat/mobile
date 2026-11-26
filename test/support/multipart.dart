// A multipart/form-data body as a form binding reads it (the API's gin, the fake's): its parts, each with its field's
// name, its file name when it's a file, and its bytes. For the fake API and the tests that look at a message's form.
import 'dart:convert';
import 'dart:typed_data';

/// A part of a form: a value has no [filename], a file has one.
typedef FormPart = ({String name, String? filename, Uint8List bytes});

final _boundary = RegExp(r'boundary=("?)([^";]+)\1');
final _name = RegExp(r'(?:^|;)\s*name="([^"]*)"');
final _filename = RegExp(r'(?:^|;)\s*filename="([^"]*)"');

int _find(Uint8List bytes, List<int> needle, int from) {
  outer:
  for (var at = from; at + needle.length <= bytes.length; at++) {
    for (var i = 0; i < needle.length; i++) {
      if (bytes[at + i] != needle[i]) continue outer;
    }
    return at;
  }
  return -1;
}

/// The parts of a form body whose content type is [contentType]; null for a body that isn't a form.
List<FormPart>? formParts(String? contentType, Uint8List body) {
  final boundary = _boundary.firstMatch(contentType ?? '')?.group(2);
  if (contentType == null || !contentType.startsWith('multipart/form-data') || boundary == null) return null;
  final delimiter = ascii.encode('--$boundary');
  final parts = <FormPart>[];
  var at = _find(body, delimiter, 0);
  while (at >= 0) {
    var start = at + delimiter.length;
    // The last delimiter ends with "--".
    if (start + 1 < body.length && body[start] == 0x2d && body[start + 1] == 0x2d) break;
    start += 2;
    final next = _find(body, delimiter, start);
    if (next < 0) break;
    final part = Uint8List.sublistView(body, start, next - 2);
    final split = _find(part, const [13, 10, 13, 10], 0);
    if (split < 0) break;
    final headers = latin1.decode(part.sublist(0, split));
    final disposition = headers
        .split('\r\n')
        .firstWhere((line) => line.toLowerCase().startsWith('content-disposition:'), orElse: () => '');
    final value = disposition.substring(disposition.indexOf(':') + 1);
    parts.add((
      name: _name.firstMatch(value)?.group(1) ?? '',
      filename: _filename.firstMatch(value)?.group(1),
      bytes: Uint8List.fromList(part.sublist(split + 4)),
    ));
    at = next;
  }
  return parts;
}

/// A form's values by field, each one's in order (a value repeated is a list), and its files in order.
({Map<String, List<String>> values, List<FormPart> files}) formOf(List<FormPart> parts) {
  final values = <String, List<String>>{};
  final files = <FormPart>[];
  for (final part in parts) {
    if (part.filename == null) {
      (values[part.name] ??= []).add(utf8.decode(part.bytes));
    } else {
      files.add(part);
    }
  }
  return (values: values, files: files);
}
