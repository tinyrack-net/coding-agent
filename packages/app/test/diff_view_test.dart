import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/changes_preferences_provider.dart';
import 'package:coding_agent_app/widgets/diff/diff_view.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  return ProviderScope(
    child: FluentApp(
      home: ScaffoldPage(
        content: MediaQuery(
          data: MediaQueryData(size: size),
          child: child,
        ),
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
  testWidgets('focus requests scroll once and replay for a new request id', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = [
      for (var index = 0; index < 30; index++)
        DiffFile(
          path: 'lib/file_${index.toString().padLeft(2, '0')}.dart',
          status: DiffFileStatus.modified,
        ),
    ];
    const targetPath = 'lib/file_15.dart';
    var requestId = 1;
    late StateSetter rebuild;

    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SizedBox(
              height: 240,
              child: DiffView(
                diff: DiffResponse(files: files),
                focusPath: targetPath,
                focusRequestId: requestId,
              ),
            );
          },
        ),
        size: const Size(900, 360),
      ),
    );
    await tester.pumpAndSettle();

    final scroll = find.byKey(const ValueKey('git-diff-scroll'));
    double targetTop() =>
        tester.getTopLeft(find.byKey(const ValueKey('diff-file-15'))).dy;
    final viewportTop = tester.getTopLeft(scroll).dy;
    expect(targetTop(), closeTo(viewportTop, 1));

    await tester.drag(scroll, const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(targetTop(), greaterThan(viewportTop + 80));

    rebuild(() {});
    await tester.pumpAndSettle();
    expect(targetTop(), greaterThan(viewportTop + 80));

    rebuild(() => requestId = 2);
    await tester.pumpAndSettle();
    expect(targetTop(), closeTo(viewportTop, 1));
  });

  testWidgets('a pending focus request waits for its file to arrive', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const targetPath = 'lib/file_15.dart';
    var files = [
      for (var index = 0; index < 5; index++)
        DiffFile(
          path: 'lib/file_${index.toString().padLeft(2, '0')}.dart',
          status: DiffFileStatus.modified,
        ),
    ];
    late StateSetter rebuild;

    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SizedBox(
              height: 240,
              child: DiffView(
                diff: DiffResponse(files: files),
                focusPath: targetPath,
                focusRequestId: 7,
              ),
            );
          },
        ),
        size: const Size(900, 360),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(targetPath), findsNothing);

    rebuild(
      () => files = [
        ...files,
        for (var index = 5; index < 30; index++)
          if (index != 15)
            DiffFile(
              path: 'lib/file_${index.toString().padLeft(2, '0')}.dart',
              status: DiffFileStatus.modified,
            ),
        const DiffFile(path: targetPath, status: DiffFileStatus.modified),
      ],
    );
    await tester.pumpAndSettle();

    final viewportTop = tester
        .getTopLeft(find.byKey(const ValueKey('git-diff-scroll')))
        .dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('diff-file-15'))).dy,
      closeTo(viewportTop, 1),
    );
  });

  testWidgets(
    'collapsed navigation preserves expansion and routes header presses',
    (tester) async {
      final controller = DiffViewController()..toggleFile('assets/logo.png');
      addTearDown(controller.dispose);
      final pressed = <String>[];
      var collapseFiles = true;
      late StateSetter rebuild;

      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return DiffView(
                diff: _diff,
                controller: controller,
                collapseFiles: collapseFiles,
                onFilePress: pressed.add,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('diff-file-0-body')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('diff-file-0')));
      await tester.pumpAndSettle();
      expect(pressed, ['assets/logo.png']);
      expect(find.byKey(const ValueKey('diff-file-0-body')), findsNothing);

      rebuild(() => collapseFiles = false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diff-file-0-body')), findsOneWidget);
    },
  );

  testWidgets('too-large placeholders explain why hunks are omitted', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const DiffView(
          diff: DiffResponse(
            files: [
              DiffFile(
                path: 'generated.js',
                status: DiffFileStatus.modified,
                tooLarge: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('generated.js'));
    await tester.pumpAndSettle();

    expect(find.text('Diff too large to display'), findsOneWidget);
    expect(find.text('No textual changes'), findsNothing);
  });

  testWidgets('flat list expands file bodies independently', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(const DiffView(diff: _diff)));

    // Flat mode shows path-sorted headers without folder rows.
    expect(find.text('lib/new_file.dart'), findsOneWidget);
    expect(find.text('lib/changed.dart'), findsOneWidget);
    expect(find.text('lib/gone.dart'), findsOneWidget);
    expect(find.text('assets/logo.png'), findsOneWidget);
    expect(find.text('assets'), findsNothing);
    expect(find.text('lib'), findsNothing);
    expect(find.text('+2'), findsNWidgets(2)); // added + modified files
    expect(find.text('-1'), findsNWidgets(2)); // modified + deleted files

    // Paseo starts with every file body collapsed.
    expect(find.text('@@ -0,0 +1,2 @@'), findsNothing);
    expect(find.text('void main() {}'), findsNothing);

    // Expand the modified file: both hunks, colored add/del rows, context
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

    // A second file can be expanded without collapsing the first.
    await tester.tap(find.text('lib/gone.dart'));
    await tester.pumpAndSettle();
    expect(find.text('deleted line'), findsOneWidget);
    expect(find.text('new line'), findsOneWidget);

    // Binary file placeholder.
    await tester.tap(find.text('assets/logo.png'));
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);
  });

  testWidgets('tree list groups, aggregates, and collapses folders', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const DiffView(diff: _diff, viewMode: ChangesViewMode.tree)),
    );

    expect(find.text('assets'), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    expect(find.text('logo.png'), findsOneWidget);
    expect(find.text('changed.dart'), findsOneWidget);
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('-2'), findsOneWidget);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    expect(find.text('new_file.dart'), findsNothing);
    expect(find.text('changed.dart'), findsNothing);
    expect(find.text('gone.dart'), findsNothing);
  });

  testWidgets('split layout pairs replacement rows and aligns review threads', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        const DiffView(
          diff: _diff,
          layout: ChangesLayout.split,
          reviewDraftKey: 'split-review',
        ),
      ),
    );
    await tester.tap(find.text('lib/changed.dart'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('split-diff')), findsOneWidget);
    expect(find.text('@@ -1,3 +1,3 @@'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('split-line-left-lib/changed.dart:old:2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('split-line-right-lib/changed.dart:new:2')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('split-left-fixed-gutter')))
          .width,
      28,
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey('split-line-left-lib/changed.dart:old:2'),
            ),
          )
          .height,
      18,
    );
    expect(find.byKey(const ValueKey('split-empty-left')), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('split-line-left-lib/changed.dart:old:2')),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('review-add-lib/changed.dart:old:2')),
    );
    await tester.pumpAndSettle();

    final leftPair = find.byKey(const ValueKey('split-left-row-2'));
    final rightPair = find.byKey(const ValueKey('split-right-row-2'));
    final leftGutter = find.byKey(const ValueKey('split-left-gutter-row-2'));
    final rightGutter = find.byKey(const ValueKey('split-right-gutter-row-2'));
    expect(tester.getSize(leftPair).height, tester.getSize(rightPair).height);
    expect(tester.getSize(leftPair).height, 166);
    expect(tester.getSize(leftGutter).height, 166);
    expect(tester.getSize(rightGutter).height, 166);
    expect(
      find.byKey(const ValueKey('review-thread-lib/changed.dart:old:2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('review-thread-lib/changed.dart:new:2')),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('split preference falls back to unified below desktop width', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        const DiffView(diff: _diff, layout: ChangesLayout.split),
        size: const Size(800, 800),
      ),
    );

    await tester.tap(find.text('lib/new_file.dart'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('split-diff')), findsNothing);
    expect(find.text('@@ -0,0 +1,2 @@'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow layout uses the same expandable file list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(const DiffView(diff: _diff)));

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

  testWidgets('inline review comments can be added, edited, and deleted', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(const DiffView(diff: _diff, reviewDraftKey: 'review-scope')),
    );
    await tester.tap(find.text('lib/new_file.dart'));
    await tester.pumpAndSettle();

    const addKey = ValueKey('review-add-lib/new_file.dart:new:1');
    expect(find.byKey(addKey), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('void main() {}')));
    await tester.pump();
    expect(find.byKey(addKey), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Add review comment' &&
            widget.properties.button == true,
      ),
      findsWidgets,
    );

    await tester.tap(find.byKey(addKey));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey('review-editor-lib/new_file.dart:new:1-new'),
            ),
          )
          .height,
      132,
    );
    await tester.tap(find.byKey(const ValueKey('inline-review-editor-input')));
    await tester.pump();
    expect(find.text('Ctrl+Enter'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('inline-review-editor-input')),
      'Check this line',
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('inline-review-editor-input')),
      findsNothing,
    );
    expect(find.text('Check this line'), findsOneWidget);
    final commentBlock = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.key.toString().contains('review-comment-'),
    );
    expect(tester.getSize(commentBlock).height, 72);
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey('diff-gutter-block-lib/new_file.dart:new:1'),
            ),
          )
          .height,
      tester
          .getSize(
            find.byKey(
              const ValueKey('diff-code-block-lib/new_file.dart:new:1'),
            ),
          )
          .height,
    );

    final editButton = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.key.toString().contains('review-edit-'),
    );
    await tester.tap(editButton);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('inline-review-editor-input')),
      'Discard this edit',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('inline-review-editor-input')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Check this line'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('inline-review-editor-input')),
      findsNothing,
    );

    await tester.tap(editButton);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('inline-review-editor-input')),
      'Updated review',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('inline-review-editor-save')));
    await tester.pump();
    expect(find.text('Updated review'), findsOneWidget);
    expect(find.text('Check this line'), findsNothing);

    final deleteButton = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.key.toString().contains('review-delete-'),
    );
    await tester.tap(deleteButton);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Updated review'), findsNothing);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('touch platforms start an inline review by tapping the line', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(const DiffView(diff: _diff, reviewDraftKey: 'touch-review')),
    );

    await tester.tap(find.text('lib/new_file.dart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('void main() {}'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('inline-review-editor-input')),
      findsOneWidget,
    );
    expect(find.text('Ctrl+Enter'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('closing the review editor restores the prior workspace focus', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final workspaceFocus = FocusNode(debugLabel: 'workspace-focus');
    addTearDown(workspaceFocus.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: FluentApp(
          home: ScaffoldPage(
            content: Column(
              children: [
                Button(
                  focusNode: workspaceFocus,
                  onPressed: () {},
                  child: const Text('Workspace action'),
                ),
                const Expanded(
                  child: DiffView(diff: _diff, reviewDraftKey: 'focus-review'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('lib/new_file.dart'));
    await tester.pumpAndSettle();
    workspaceFocus.requestFocus();
    await tester.pump();
    expect(workspaceFocus.hasFocus, isTrue);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('void main() {}')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('review-add-lib/new_file.dart:new:1')),
    );
    await tester.pumpAndSettle();
    final input = tester.widget<TextBox>(
      find.byKey(const ValueKey('inline-review-editor-input')),
    );
    expect(input.focusNode?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(workspaceFocus.hasFocus, isTrue);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
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

    expect(find.text('lib/old_name.dart → lib/new_name.dart'), findsOneWidget);
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

    await tester.tap(find.text('lib/mode_only.dart'));
    await tester.pumpAndSettle();
    expect(find.text('No textual changes'), findsOneWidget);
  });

  testWidgets('long diff lines remain single-line and scroll horizontally', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
    await tester.pumpWidget(
      _wrap(DiffView(diff: diff, reviewDraftKey: 'long-review')),
    );

    await tester.tap(find.text('lib/long.dart'));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text(longLine));
    expect(text.softWrap, isFalse);
    final scrollFinder = find.byKey(const ValueKey('diff-horizontal-scroll'));
    final gutterFinder = find.byKey(const ValueKey('diff-fixed-gutter'));
    final gutterOrigin = tester.getTopLeft(gutterFinder);
    expect(
      tester.getTopLeft(scrollFinder).dx,
      tester.getTopRight(gutterFinder).dx,
    );
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollFinder, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    final viewport = find.byKey(const ValueKey('diff-code-viewport'));
    final codeLine = find.byKey(
      const ValueKey('diff-code-lib/long.dart:new:1'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      Offset(
        tester.getTopLeft(viewport).dx + 40,
        tester.getCenter(codeLine).dy,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('review-add-lib/long.dart:new:1')),
    );
    await tester.pumpAndSettle();
    final thread = find.byKey(
      const ValueKey('review-thread-lib/long.dart:new:1'),
    );
    final threadOrigin = tester.getTopLeft(thread);
    expect(threadOrigin.dx, tester.getTopLeft(viewport).dx);
    expect(tester.getSize(thread).width, tester.getSize(viewport).width);

    await tester.dragFrom(
      tester.getTopLeft(viewport) + const Offset(80, 12),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(gutterFinder), gutterOrigin);
    expect(tester.getTopLeft(thread), threadOrigin);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'code typography drives row height and line-number gutter width',
    (tester) async {
      const metricsDiff = DiffResponse(
        files: [
          DiffFile(
            path: 'lib/metrics.dart',
            status: DiffFileStatus.modified,
            additions: 1,
            hunks: [
              DiffHunk(
                header: '@@ -1234 +1234 @@',
                lines: [
                  DiffLine(
                    type: DiffLineType.add,
                    text: 'metrics',
                    newLineNo: 1234,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          const DiffView(
            diff: metricsDiff,
            codeFontSize: 20,
            monoFontFamily: 'Consolas',
          ),
        ),
      );
      await tester.tap(find.text('lib/metrics.dart'));
      await tester.pumpAndSettle();

      final gutter = find.byKey(const ValueKey('diff-fixed-gutter'));
      final codeLine = find.byKey(
        const ValueKey('diff-code-lib/metrics.dart:new:1234'),
      );
      expect(tester.getSize(gutter).width, 64);
      expect(tester.getSize(codeLine).height, 30);
      final text = tester.widget<Text>(find.text('metrics'));
      expect(text.style?.fontSize, 20);
      expect(text.style?.fontFamily, 'Consolas');
      expect(text.style?.height, 1.5);
    },
  );

  testWidgets('split scroll mode keeps each line-number gutter fixed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final longLine = List.filled(120, 'scrollable').join('-');
    final diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/split_scroll.dart',
          status: DiffFileStatus.modified,
          additions: 1,
          deletions: 1,
          hunks: [
            DiffHunk(
              header: '@@ -1 +1 @@',
              lines: [
                DiffLine(type: DiffLineType.del, text: longLine, oldLineNo: 1),
                DiffLine(type: DiffLineType.add, text: longLine, newLineNo: 1),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        DiffView(
          diff: diff,
          layout: ChangesLayout.split,
          reviewDraftKey: 'split-scroll-review',
        ),
        size: const Size(1000, 600),
      ),
    );
    await tester.tap(find.text('lib/split_scroll.dart'));
    await tester.pumpAndSettle();

    final leftGutter = find.byKey(const ValueKey('split-left-fixed-gutter'));
    final scrolls = find.byKey(const ValueKey('diff-horizontal-scroll'));
    expect(scrolls, findsNWidgets(2));
    final leftScroll = scrolls.first;
    final gutterOrigin = tester.getTopLeft(leftGutter);
    expect(tester.getTopLeft(leftScroll).dx, tester.getTopRight(leftGutter).dx);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: leftScroll, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    final viewport = find.byKey(const ValueKey('split-left-code-viewport'));
    final codeLine = find.byKey(
      const ValueKey('split-line-left-lib/split_scroll.dart:old:1'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      Offset(
        tester.getTopLeft(viewport).dx + 40,
        tester.getCenter(codeLine).dy,
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('review-add-lib/split_scroll.dart:old:1')),
    );
    await tester.pumpAndSettle();
    final thread = find.byKey(
      const ValueKey('review-thread-lib/split_scroll.dart:old:1'),
    );
    final threadOrigin = tester.getTopLeft(thread);
    expect(threadOrigin.dx, tester.getTopLeft(viewport).dx);
    expect(tester.getSize(thread).width, tester.getSize(viewport).width);

    await tester.dragFrom(
      tester.getTopLeft(viewport) + const Offset(80, 12),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(leftGutter), gutterOrigin);
    expect(tester.getTopLeft(thread), threadOrigin);
    await mouse.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wrapLines grows unified rows without horizontal scrolling', (
    tester,
  ) async {
    final longLine = List.filled(80, 'wrapped-content').join('-');
    final diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/wrapped.dart',
          status: DiffFileStatus.modified,
          additions: 1,
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
    await tester.binding.setSurfaceSize(const Size(480, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(DiffView(diff: diff, wrapLines: true), size: const Size(480, 500)),
    );
    await tester.tap(find.text('lib/wrapped.dart'));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(longLine));
    expect(text.softWrap, isTrue);
    expect(tester.getSize(find.text(longLine)).height, greaterThan(24));
    expect(find.byKey(const ValueKey('diff-horizontal-scroll')), findsNothing);
  });

  testWidgets('wrapped split rows synchronize unequal code heights', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final longLine = List.filled(80, 'removed-content').join('-');
    final diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/split_wrapped.dart',
          status: DiffFileStatus.modified,
          additions: 1,
          deletions: 1,
          hunks: [
            DiffHunk(
              header: '@@ -1 +1 @@',
              lines: [
                DiffLine(type: DiffLineType.del, text: longLine, oldLineNo: 1),
                DiffLine(
                  type: DiffLineType.add,
                  text: 'short replacement',
                  newLineNo: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        DiffView(diff: diff, layout: ChangesLayout.split, wrapLines: true),
        size: const Size(1000, 700),
      ),
    );
    await tester.tap(find.text('lib/split_wrapped.dart'));
    await tester.pumpAndSettle();

    final left = find.byKey(const ValueKey('split-wrapped-left-row-1'));
    final right = find.byKey(const ValueKey('split-wrapped-right-row-1'));
    expect(tester.getSize(left).height, tester.getSize(right).height);
    expect(tester.getSize(left).height, greaterThan(24));
    expect(find.byKey(const ValueKey('diff-horizontal-scroll')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('didUpdateWidget prunes expansion state for removed files', (
    tester,
  ) async {
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
    final controller = DiffViewController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _wrap(DiffView(diff: twoFiles, controller: controller)),
    );

    await tester.tap(find.text('lib/b.dart'));
    await tester.pumpAndSettle();
    expect(find.text('b changed'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(DiffView(diff: oneFile, controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(controller.expandedPaths, isEmpty);
    expect(find.text('b changed'), findsNothing);
    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('a changed'), findsOneWidget);
  });

  testWidgets('file actions match Paseo order without toggling the file', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      _wrap(
        DiffView(
          diff: _diff,
          onOpenFile: (path) => actions.add('open:$path'),
          onCopyPath: (path) => actions.add('copy:$path'),
          onDownload: (path) => actions.add('download:$path'),
          onAddToChat: (path) => actions.add('chat:$path'),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('diff-file-1-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Open file'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Add to chat…'), findsOneWidget);
    await tester.tap(find.text('Open file'));
    await tester.pumpAndSettle();

    expect(actions, ['open:lib/changed.dart']);
    expect(find.text('new line'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('diff-file-1-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to chat…'));
    await tester.pumpAndSettle();
    expect(actions.last, 'chat:lib/changed.dart');
    expect(find.text('new line'), findsNothing);
  });

  testWidgets('deleted file actions keep only copy path', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DiffView(
          diff: _diff,
          onOpenFile: (_) {},
          onCopyPath: (_) {},
          onDownload: (_) {},
          onAddToChat: (_) {},
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('diff-file-2-actions')));
    await tester.pumpAndSettle();

    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Open file'), findsNothing);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Add to chat…'), findsNothing);
  });

  testWidgets('secondary click opens actions without toggling the file', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(DiffView(diff: _diff, onCopyPath: (_) {})));

    await tester.tap(
      find.byKey(const ValueKey('diff-file-1')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('new line'), findsNothing);
  });

  testWidgets('expanded header stays pinned and collapse restores its anchor', (
    tester,
  ) async {
    final longLines = List.generate(
      80,
      (index) => DiffLine(
        type: DiffLineType.context,
        text: 'line $index',
        oldLineNo: index + 1,
        newLineNo: index + 1,
      ),
    );
    final diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/long.dart',
          status: DiffFileStatus.modified,
          hunks: [DiffHunk(header: '@@ -1,80 +1,80 @@', lines: longLines)],
        ),
        const DiffFile(path: 'lib/next.dart', status: DiffFileStatus.modified),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(600, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_wrap(DiffView(diff: diff)));

    await tester.tap(find.text('lib/long.dart'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('git-diff-scroll')),
      const Offset(0, -280),
    );
    await tester.pumpAndSettle();

    final scroll = tester.widget<CustomScrollView>(
      find.byKey(const ValueKey('git-diff-scroll')),
    );
    expect(scroll.controller!.offset, greaterThan(200));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('diff-file-0'))).dy,
      closeTo(
        tester.getTopLeft(find.byKey(const ValueKey('git-diff-scroll'))).dy,
        1,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('diff-file-0')));
    await tester.pumpAndSettle();

    expect(scroll.controller!.offset, closeTo(0, 1));
    expect(find.text('line 0'), findsNothing);
  });

  testWidgets('syntax tokens render in unified, split, and wrapped rows', (
    tester,
  ) async {
    const code = 'const value = 1;';
    const diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/token.dart',
          status: DiffFileStatus.modified,
          additions: 1,
          hunks: [
            DiffHunk(
              header: '@@ -0,0 +1 @@',
              lines: [
                DiffLine(type: DiffLineType.add, text: code, newLineNo: 1),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.binding.setSurfaceSize(const Size(1000, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final configuration in [
      (layout: ChangesLayout.unified, wrap: false),
      (layout: ChangesLayout.unified, wrap: true),
      (layout: ChangesLayout.split, wrap: false),
      (layout: ChangesLayout.split, wrap: true),
    ]) {
      await tester.pumpWidget(
        _wrap(
          DiffView(
            key: UniqueKey(),
            diff: diff,
            layout: configuration.layout,
            wrapLines: configuration.wrap,
          ),
        ),
      );
      await tester.tap(find.text('lib/token.dart'));
      await tester.pumpAndSettle();

      final highlighted = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.textSpan?.toPlainText() == code,
        ),
      );
      final span = highlighted.textSpan! as TextSpan;
      expect(span.toPlainText(), code);
      expect(
        span.children!
            .whereType<TextSpan>()
            .firstWhere((token) => token.text == 'const')
            .style
            ?.color,
        const Color(0xFFCF222E),
      );
    }
  });
}
