// What the Rooms page costs to open and to lay out in a big Space (#65).
// Not under test/, so `flutter test` doesn't run it:
//
//     flutter test benchmark/rooms_layout.dart
//
// The times are a debug build's on the test binding: read them against each
// other, not as a phone's. Each is the best of 15 runs, the one a busy
// machine slowed least. The second table lays the same rows out both ways in
// one run, so its two columns compare whatever else the machine is doing.
// ROOMS_SIZES=50,200 picks the sizes; ROOMS_SHOTS=dir also writes the Rooms
// and Roles pages there as PNGs, to compare by eye or byte across a change.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duvet/data/admin.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/space_admin.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/rows.dart' show ListRow;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../test/support/fake_repository.dart';
import '../test/support/fonts.dart';

const _runs = 15;

/// [count] rooms: all outside any category, or 20 to a category.
List<AdminRoom> _rooms(int count, {required bool loose}) => [
  if (loose)
    for (var i = 0; i < count; i++)
      AdminRoom(id: 'r$i', name: 'room-$i', kind: i % 7 == 0 ? AdminRoomKind.voice : AdminRoomKind.text, position: i)
  else
    for (var c = 0; c * 20 < count; c++) ...[
      AdminRoom(id: 'c$c', name: 'Category $c', kind: AdminRoomKind.category, position: c),
      for (var i = c * 20; i < count && i < (c + 1) * 20; i++)
        AdminRoom(
          id: 'r$i',
          name: 'room-$i',
          kind: i % 7 == 0 ? AdminRoomKind.voice : AdminRoomKind.text,
          parentId: 'c$c',
          position: i - c * 20,
        ),
    ],
];

Widget _host(FakeRepository repository, Widget page) => RepositoryScope(
  repository: repository,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Duvet.material(Brightness.light),
    home: FTheme(
      data: Duvet.theme(Brightness.light),
      child: RepaintBoundary(child: page),
    ),
  ),
);

/// Signed in, so it has the Space the pages are of.
Future<FakeRepository> _signedIn() async {
  final repository = FakeRepository();
  await repository.restore();
  return repository;
}

String _best(List<int> micros) => (micros.reduce((a, b) => a < b ? a : b) / 1000).toStringAsFixed(1);

/// Every box under the view laid out again, with nothing to build or paint.
int _layOutAgain(WidgetTester tester) {
  _dirty(tester.binding.renderViews.first);
  final watch = Stopwatch()..start();
  tester.binding.rootPipelineOwner.flushLayout();
  return (watch..stop()).elapsedMicroseconds;
}

/// A room's row as the page laid it out before #65: a second pass over the
/// row, for its height, then the edge stretched to it.
Widget _intrinsicRow(Widget body, Widget edge) => IntrinsicHeight(
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: body),
      edge,
    ],
  ),
);

void _dirty(RenderObject object) {
  object.markNeedsLayout();
  object.visitChildren(_dirty);
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['ROOMS_SHOTS'];
  if (dir == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  final sizes = [for (final s in (Platform.environment['ROOMS_SIZES'] ?? '50,200,1000').split(',')) int.parse(s)];
  final lines = <String>[];
  final rowLines = <String>[];

  setUpAll(loadAppFonts);
  tearDownAll(() {
    // ignore: avoid_print
    print(
      [
        '| Rooms | Rows built | Open, first frame (ms) | Layout alone (ms) |',
        '|---|---|---|---|',
        ...lines,
        '',
        '| Rows alone | IntrinsicHeight, layout (ms) | EdgedRow, layout (ms) |',
        '|---|---|---|',
        ...rowLines,
      ].join('\n'),
    );
  });

  for (final loose in [true, false]) {
    for (final count in sizes) {
      testWidgets('$count rooms, ${loose ? 'in no category' : '20 to a category'}', (tester) async {
        tester.view.physicalSize = const Size(390 * 3, 844 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final repository = (await _signedIn())..adminRoomList['s-guild'] = _rooms(count, loose: loose);
        final page = _host(repository, const RoomsAdminPage(spaceId: 's-guild'));

        final open = <int>[];
        final layout = <int>[];
        var rows = 0;
        // The first two warm the JIT up.
        for (var run = 0; run < _runs + 2; run++) {
          await tester.pumpWidget(const SizedBox());
          final watch = Stopwatch()..start();
          await tester.pumpWidget(page);
          watch.stop();
          rows = find.byType(ListRow, skipOffstage: false).evaluate().length;

          // A frame first, for what the first one left to build (the route's focus).
          await tester.pump();
          final again = _layOutAgain(tester);
          await tester.pump();
          if (run < 2) continue;
          open.add(watch.elapsedMicroseconds);
          layout.add(again);
        }
        lines.add(
          '| $count, ${loose ? 'no category' : '20 to a category'} | $rows '
          '| ${_best(open)} | ${_best(layout)} |',
        );
      });
    }
  }

  for (final count in sizes) {
    testWidgets('$count rows alone, laid out both ways', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      Widget rows(Widget Function(Widget body, Widget edge) row) => _host(
        FakeRepository(),
        SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < count; i++)
                row(ListRow(title: 'room-$i', hash: true, onTap: () {}), DragEdge(index: i)),
            ],
          ),
        ),
      );
      final ways = [rows(_intrinsicRow), rows((body, edge) => EdgedRow(edge: edge, child: body))];
      final times = [<int>[], <int>[]];
      // Turn about, so neither way has the quieter half of the run.
      for (var run = 0; run < _runs + 2; run++) {
        for (final (way, widget) in ways.indexed) {
          await tester.pumpWidget(widget);
          await tester.pump();
          final again = _layOutAgain(tester);
          await tester.pump();
          if (run >= 2) times[way].add(again);
        }
      }
      rowLines.add('| $count | ${_best(times[0])} | ${_best(times[1])} |');
    });
  }

  testWidgets('the pages, as PNGs', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = (await _signedIn())
      ..adminRoomList['s-guild'] = const [
        AdminRoom(id: 'r-a', name: 'general', kind: AdminRoomKind.text),
        AdminRoom(id: 'r-b', name: 'lounge', kind: AdminRoomKind.voice, position: 1),
        AdminRoom(id: 'r-c', name: 'locked', kind: AdminRoomKind.text, position: 2),
        AdminRoom(id: 'c-a', name: 'Work', kind: AdminRoomKind.category, position: 3),
        AdminRoom(
          id: 'r-d',
          name: 'a-room-with-a-name-long-enough-to-run-off-its-row',
          kind: AdminRoomKind.text,
          parentId: 'c-a',
        ),
        AdminRoom(id: 'r-e', name: 'standup', kind: AdminRoomKind.voice, parentId: 'c-a', position: 1),
        AdminRoom(id: 'c-b', name: 'Empty', kind: AdminRoomKind.category, position: 4),
        AdminRoom(id: 'c-c', name: 'Not mine', kind: AdminRoomKind.category, position: 5),
      ]
      ..deniedInRoom['r-c'] = Perm.manageChannels
      ..deniedInRoom['c-c'] = Perm.manageChannels
      ..roleList['s-guild'] = const [
        SpaceRole(id: 'role-helpers', name: 'Helpers', position: 3),
        SpaceRole(id: 'role-mod', name: 'Moderator', perms: Perm.manageChannels, position: 2),
        SpaceRole(id: 'role-admins', name: 'Admins', perms: Perm.administrator, position: 1, hoisted: true),
        SpaceRole(id: 's-guild', name: '@everyone', everyone: true),
      ];
    for (final direction in TextDirection.values) {
      Widget directed(Widget page) => _host(repository, Directionality(textDirection: direction, child: page));
      await tester.pumpWidget(directed(const RoomsAdminPage(spaceId: 's-guild')));
      await tester.pumpAndSettle();
      await _shot(tester, 'rooms-${direction.name}');
      // The owner's, every role theirs to move, then a member's, every one locked.
      for (final owner in [true, false]) {
        repository.spaceOwner = owner;
        await tester.pumpWidget(directed(RolesPage(key: ValueKey(owner), spaceId: 's-guild')));
        await tester.pumpAndSettle();
        await _shot(tester, 'roles-${owner ? 'owner' : 'member'}-${direction.name}');
      }
      repository.spaceOwner = true;
    }
  });
}
