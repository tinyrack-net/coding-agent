import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/core/tool_call_parsers.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/code_insets.dart';
import 'package:coding_agent_app/widgets/diff/diff_viewer.dart';
import 'package:coding_agent_app/widgets/syntax_token_styles.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {AppThemeName theme = AppThemeName.dark}) =>
    FluentApp(
      theme: buildAppTheme(theme),
      home: Center(child: child),
    );

void main() {
  test('code inset helpers match frozen geometry', () {
    expect(lineNumberGutterWidth(9, 12), 28);
    expect(lineNumberGutterWidth(999, 12), 36);
    expect(paseoCodeInsets.padding, 12);
    expect(paseoCodeInsets.extraRight, 16);
    expect(paseoCodeInsets.extraBottom, 12);
    expect(getCodeInsets(spacing4: 20).padding, 20);
    expect(getCodeInsets().padding, 12);
  });

  test('syntax colors match frozen themes and unknown styles use base', () {
    expect(
      syntaxTokenColorFor(
        'keyword',
        brightness: Brightness.dark,
        baseColor: Colors.white,
      ),
      const Color(0xFFFF7B72),
    );
    expect(
      syntaxTokenColorFor(
        'keyword',
        brightness: Brightness.light,
        baseColor: Colors.black,
      ),
      const Color(0xFFCF222E),
    );
    expect(
      syntaxTokenColorFor(
        'unknown',
        brightness: Brightness.dark,
        baseColor: Colors.white,
      ),
      Colors.white,
    );
  });

  testWidgets('renders the frozen empty label and custom override', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const DiffViewer(diffLines: [])));
    expect(find.text('No changes to display'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const DiffViewer(diffLines: [], emptyLabel: 'Nothing here')),
    );
    expect(find.text('Nothing here'), findsOneWidget);
  });

  testWidgets('renders line backgrounds, segments, tokens, and prefixes', (
    tester,
  ) async {
    const lines = [
      ToolDiffLine(type: ToolDiffLineType.header, content: '@@ -1 +1 @@'),
      ToolDiffLine(
        type: ToolDiffLineType.remove,
        content: '-old value',
        segments: [
          ToolDiffSegment(text: 'old ', changed: true),
          ToolDiffSegment(text: 'value', changed: false),
        ],
      ),
      ToolDiffLine(
        type: ToolDiffLineType.add,
        content: '+const value',
        tokens: [
          ToolDiffToken(text: 'const', style: 'keyword'),
          ToolDiffToken(text: ' value'),
        ],
      ),
      ToolDiffLine(type: ToolDiffLineType.context, content: ' same'),
    ];
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 280,
          height: 180,
          child: DiffViewer(diffLines: lines),
        ),
      ),
    );
    await tester.pump();

    Container surface(int index) => tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(ValueKey('diff-viewer-line-$index')),
            matching: find.byType(Container),
          )
          .first,
    );
    final surface1 = paseoPaletteFor(AppThemeName.dark).surface1;
    expect(surface(0).color, surface1);
    expect(surface(1).color, const Color(0x1AF85149));
    expect(surface(2).color, const Color(0x262EA043));
    expect(surface(3).color, surface1);

    final tokenLine = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('diff-viewer-line-2')),
        matching: find.byType(RichText),
      ),
    );
    expect(tokenLine.text.toPlainText(), '+const value');
    final root = tokenLine.text as TextSpan;
    expect(
      (root.children![1] as TextSpan).style?.color,
      const Color(0xFFFF7B72),
    );

    final removeLine = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('diff-viewer-line-1')),
        matching: find.byType(RichText),
      ),
    );
    final removeRoot = removeLine.text as TextSpan;
    expect(
      (removeRoot.children![1] as TextSpan).style?.backgroundColor,
      const Color(0x59F85149),
    );
  });

  testWidgets('caps vertical height and horizontally scrolls long lines', (
    tester,
  ) async {
    final longText = '+${List.filled(200, 'x').join()}';
    final lines = [
      for (var index = 0; index < 30; index++)
        ToolDiffLine(type: ToolDiffLineType.add, content: longText),
    ];
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 260,
          child: DiffViewer(diffLines: lines, maxHeight: 120),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(DiffViewer)).height, 120);
    final vertical = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('diff-viewer-vertical-scroll')),
        )
        .controller!
        .position;
    expect(vertical.maxScrollExtent, greaterThan(0));
    final horizontal = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('diff-horizontal-scroll')),
        )
        .controller!
        .position;
    expect(horizontal.maxScrollExtent, greaterThan(0));
  });

  testWidgets('fills bounded available height when requested', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SizedBox(
          width: 260,
          height: 180,
          child: DiffViewer(
            diffLines: [
              ToolDiffLine(type: ToolDiffLineType.context, content: ' same'),
            ],
            fillAvailableHeight: true,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(DiffViewer)).height, 180);
  });
}
