import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/notices.dart';
import 'package:flutter_test/flutter_test.dart';

// The notices are the same in both apps: PLAN-E2E-CLIENTES.md's table of notices, as the conventions' file both
// repositories carry has it, which the desktop's notices.test.ts reads too.
final conventions = jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test("are the table's, every one and nothing else", () {
    expect({for (final notice in Notice.values) notice.key: notice.text}, conventions['notices']);
  });

  test("fill their names, and leave a value's own braces alone", () {
    for (final filled in (conventions['filled_notices'] as List).cast<Map<String, dynamic>>()) {
      final notice = Notice.values.singleWhere((notice) => notice.key == filled['key']);
      expect(notice.fill((filled['values'] as Map).cast<String, String>()), filled['text']);
    }
  });

  test('a name with no value stays as it is', () {
    expect(Notice.noDevice.fill(), Notice.noDevice.text);
  });
}
