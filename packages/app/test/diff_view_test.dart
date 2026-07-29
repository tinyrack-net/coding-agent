import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/widgets/diff/diff_view.dart';
import 'package:fluent_ui/fluent_ui.dart';
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
  return FluentApp(
    home: ScaffoldPage(
      content: MediaQuery(
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
    expect(find.text('new_file.dart'), findsOneWidget);
    expect(find.text('changed.dart'), findsOneWidget);
    expect(find.text('gone.dart'), findsOneWidget);
    expect(find.text('logo.png'), findsOneWidget);
    expect(find.text('assets'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
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
    await tester.tap(find.text('changed.dart'));
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
    await tester.tap(find.text('gone.dart'));
    await tester.pumpAndSettle();
    expect(find.text('deleted line'), findsOneWidget);

    // Binary file placeholder.
    await tester.tap(find.text('logo.png'));
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);

    // Folder rows aggregate stats and retain their stable path when collapsed.
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('-2'), findsOneWidget);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('new_file.dart'), findsNothing);
    expect(find.text('changed.dart'), findsNothing);
    expect(find.text('gone.dart'), findsNothing);
  });

  testWidgets('narrow layout: collapsible file sections', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(const DiffView(diff: _diff)));

    // Collapsed by default: file rows visible. Fluent's `Expander` keeps its
    // content mounted (animating height via `SizeTransition`) rather than
    // unmounting it like Material's `ExpansionTile`, so we only assert the
    // row is present here and check content visibility after expanding.
    expect(find.text('lib/changed.dart'), findsOneWidget);

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

  testWidgets('a renamed file shows "old -> new" and the renamed style', (
    tester,
  ) async {
    const renamed = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/new_name.dart',
          oldPath: 'lib/old_name.dart',
          status: DiffFileStatus.renamed,
          additions: 0,
          deletions: 0,
        ),
      ],
    );
    await tester.pumpWidget(_wrap(const DiffView(diff: renamed)));

    expect(find.text('old_name.dart → new_name.dart'), findsOneWidget);
    expect(find.byIcon(FluentIcons.move_to_folder), findsOneWidget);
  });

  testWidgets('a non-binary file with no hunks shows "No textual changes"', (
    tester,
  ) async {
    const noHunks = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/mode_only.dart',
          status: DiffFileStatus.modified,
          additions: 0,
          deletions: 0,
        ),
      ],
    );
    await tester.pumpWidget(_wrap(const DiffView(diff: noHunks)));

    expect(find.text('No textual changes'), findsOneWidget);
  });

  testWidgets('long diff lines remain single-line and scroll horizontally', (
    tester,
  ) async {
    final longLine = 'final value = "${List.filled(160, 'x').join()}";';
    final diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/long.dart',
          status: DiffFileStatus.modified,
          additions: 1,
          deletions: 0,
          hunks: [
            DiffHunk(
              header: '@@ -1 +1 @@',
              lines: [
                DiffLine(type: DiffLineType.add, text: longLine, newLineNo: 1),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(900, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(DiffView(diff: diff)));

    final text = tester.widget<Text>(find.text(longLine));
    expect(text.softWrap, isFalse);
    final scrollFinder = find.byKey(const ValueKey('diff-horizontal-scroll'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollFinder, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    await tester.drag(scrollFinder, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets(
    'didUpdateWidget resets the selected file index when the file list '
    'shrinks below it',
    (tester) async {
      const twoFiles = DiffResponse(
        files: [
          DiffFile(
            path: 'lib/a.dart',
            status: DiffFileStatus.modified,
            additions: 1,
            deletions: 0,
          ),
          DiffFile(
            path: 'lib/b.dart',
            status: DiffFileStatus.modified,
            additions: 1,
            deletions: 0,
            hunks: [
              DiffHunk(
                header: '@@ -1 +1 @@',
                lines: [
                  DiffLine(
                    type: DiffLineType.add,
                    text: 'b changed',
                    newLineNo: 1,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      const oneFile = DiffResponse(
        files: [
          DiffFile(
            path: 'lib/a.dart',
            status: DiffFileStatus.modified,
            additions: 1,
            deletions: 0,
            hunks: [
              DiffHunk(
                header: '@@ -1 +1 @@',
                lines: [
                  DiffLine(
                    type: DiffLineType.add,
                    text: 'a changed',
                    newLineNo: 1,
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_wrap(const DiffView(diff: twoFiles)));

      // Select the second file (index 1).
      await tester.tap(find.text('b.dart'));
      await tester.pumpAndSettle();
      expect(find.text('b changed'), findsOneWidget);

      // Shrink the file list to one entry: didUpdateWidget must clamp the
      // selected index back to 0 instead of throwing a range error.
      await tester.pumpWidget(_wrap(const DiffView(diff: oneFile)));
      await tester.pumpAndSettle();

      expect(find.text('a changed'), findsOneWidget);
    },
  );
}
