import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/widgets/diff/diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _diff = DiffResponse(
  files: [
    DiffFile(
      path: 'lib/new_file.dart',
      status: DiffFileStatus.added,
      additions: 2,
      deletions: 0,
      hunks: [
        DiffHunk(
          header: '@@ -0,0 +1,2 @@',
          lines: [
            DiffLine(
              type: DiffLineType.add,
              text: 'void main() {}',
              newLineNo: 1,
            ),
            DiffLine(type: DiffLineType.add, text: '// done', newLineNo: 2),
          ],
        ),
      ],
    ),
    DiffFile(
      path: 'lib/changed.dart',
      status: DiffFileStatus.modified,
      additions: 2,
      deletions: 1,
      hunks: [
        DiffHunk(
          header: '@@ -1,3 +1,3 @@',
          lines: [
            DiffLine(
              type: DiffLineType.context,
              text: 'import "dart:io";',
              oldLineNo: 1,
              newLineNo: 1,
            ),
            DiffLine(type: DiffLineType.del, text: 'old line', oldLineNo: 2),
            DiffLine(type: DiffLineType.add, text: 'new line', newLineNo: 2),
          ],
        ),
        DiffHunk(
          header: '@@ -10,1 +10,2 @@',
          lines: [
            DiffLine(
              type: DiffLineType.add,
              text: 'second hunk add',
              newLineNo: 11,
            ),
          ],
        ),
      ],
    ),
    DiffFile(
      path: 'lib/gone.dart',
      status: DiffFileStatus.deleted,
      additions: 0,
      deletions: 1,
      hunks: [
        DiffHunk(
          header: '@@ -1,1 +0,0 @@',
          lines: [
            DiffLine(
              type: DiffLineType.del,
              text: 'deleted line',
              oldLineNo: 1,
            ),
          ],
        ),
      ],
    ),
    DiffFile(
      path: 'assets/logo.png',
      status: DiffFileStatus.modified,
      binary: true,
    ),
  ],
);

Widget _wrap(Widget child, {Size size = const Size(1200, 800)}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(size: size),
        child: child,
      ),
    ),
  );
}

Color? _rowBackground(WidgetTester tester, String lineText) {
  final container = tester.widget<Container>(
    find
        .ancestor(of: find.text(lineText), matching: find.byType(Container))
        .first,
  );
  return container.color;
}

void main() {
  testWidgets('wide layout: file rows with status colors and counts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(const DiffView(diff: _diff)));

    // All file rows are listed with their add/del counts.
    expect(find.text('lib/new_file.dart'), findsOneWidget);
    expect(find.text('lib/changed.dart'), findsOneWidget);
    expect(find.text('lib/gone.dart'), findsOneWidget);
    expect(find.text('assets/logo.png'), findsOneWidget);
    expect(find.text('+2'), findsNWidgets(2)); // added + modified files
    expect(find.text('-1'), findsNWidgets(2)); // modified + deleted files

    // First file (added) selected by default: its hunk and lines render.
    expect(find.text('@@ -0,0 +1,2 @@'), findsOneWidget);
    expect(find.text('void main() {}'), findsOneWidget);
    expect(
      _rowBackground(tester, 'void main() {}'),
      Colors.green.withValues(alpha: 0.12),
    );

    // Select the modified file: both hunks, colored add/del rows, context
    // rows without a tint, and old/new line numbers.
    await tester.tap(find.text('lib/changed.dart'));
    await tester.pumpAndSettle();
    expect(find.text('@@ -1,3 +1,3 @@'), findsOneWidget);
    expect(find.text('@@ -10,1 +10,2 @@'), findsOneWidget);
    expect(find.text('second hunk add'), findsOneWidget);
    expect(
      _rowBackground(tester, 'new line'),
      Colors.green.withValues(alpha: 0.12),
    );
    expect(
      _rowBackground(tester, 'old line'),
      Colors.red.withValues(alpha: 0.12),
    );
    expect(_rowBackground(tester, 'import "dart:io";'), isNull);
    expect(find.text('11'), findsOneWidget); // new line number of second hunk

    // Deleted file.
    await tester.tap(find.text('lib/gone.dart'));
    await tester.pumpAndSettle();
    expect(find.text('deleted line'), findsOneWidget);

    // Binary file placeholder.
    await tester.tap(find.text('assets/logo.png'));
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);
  });

  testWidgets('narrow layout: collapsible file sections', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(const DiffView(diff: _diff)));

    // Collapsed by default: file rows visible, hunk bodies hidden.
    expect(find.text('lib/changed.dart'), findsOneWidget);
    expect(find.text('new line'), findsNothing);

    await tester.tap(find.text('lib/changed.dart'));
    await tester.pumpAndSettle();
    expect(find.text('new line'), findsOneWidget);
    expect(find.text('old line'), findsOneWidget);
  });

  testWidgets('empty diff shows the no-changes state', (tester) async {
    await tester.pumpWidget(
      _wrap(const DiffView(diff: DiffResponse(files: []))),
    );
    expect(find.text('No changes'), findsOneWidget);
  });
}
