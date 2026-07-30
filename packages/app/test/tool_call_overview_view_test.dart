import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_overview.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_overview_view.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:coding_agent_app/widgets/timeline_item_tile.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders aggregate label, loading state, and bounded details', (
    tester,
  ) async {
    const call = ToolCallItem(
      id: 'tool-1',
      toolName: 'Bash',
      status: ToolCallStatus.running,
      detail: ShellDetail(command: 'dart test'),
    );
    final projection = projectToolCallDetailLevel(
      level: ToolCallDetailLevel.overview,
      tail: const [],
      head: const [call],
      preparedHistory: prepareToolCallHistory(
        ToolCallDetailLevel.overview,
        const [],
      ),
      isTurnActive: true,
    );
    final group = projection.groupsByHostId['tool-1']!;

    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: ToolCallOverviewGroupView(
            group: group,
            children: const [Text('dart test')],
          ),
        ),
      ),
    );

    expect(find.text('Ran 1 command'), findsOneWidget);
    expect(find.byType(ProgressRing), findsOneWidget);
    final bounded = tester.widget<ConstrainedBox>(
      find
          .descendant(
            of: find.byType(ToolCallOverviewGroupView),
            matching: find.byType(ConstrainedBox),
          )
          .last,
    );
    expect(bounded.constraints.maxHeight, toolCallGroupMaxHeight);

    await tester.tap(find.text('Ran 1 command'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('dart test'), findsOneWidget);
  });

  testWidgets(
    'retained idle group starts full-speed header and child loading animations',
    (tester) async {
      const completed = ToolCallItem(
        id: 'tool-1',
        toolName: 'Bash',
        status: ToolCallStatus.success,
        detail: ShellDetail(command: 'dart analyze'),
      );
      const running = ToolCallItem(
        id: 'tool-2',
        toolName: 'Read',
        status: ToolCallStatus.running,
        detail: ReadDetail(path: 'lib/main.dart'),
      );
      final prepared = prepareToolCallHistory(
        ToolCallDetailLevel.overview,
        const [completed],
      )!;

      ToolCallDetailProjection projection(List<TimelineItem> head) =>
          projectToolCallDetailLevel(
            level: ToolCallDetailLevel.overview,
            tail: const [completed],
            head: head,
            preparedHistory: prepared,
            isTurnActive: true,
          );

      Widget appFor(ToolCallDetailProjection current) {
        final group = current.groupsByHostId['tool-1']!;
        return FluentApp(
          home: ScaffoldPage(
            content: ToolCallOverviewGroupView(
              key: const ValueKey('retained-tool-call-group'),
              group: group,
              children: [
                for (final call in group.run.calls)
                  TimelineItemTile(item: call),
              ],
            ),
          ),
        );
      }

      await tester.pumpWidget(appFor(projection(const [])));
      final retainedState = tester.state(
        find.byKey(const ValueKey('retained-tool-call-group')),
      );
      expect(find.byType(ProgressRing), findsNothing);

      await tester.pumpWidget(appFor(projection(const [running])));
      expect(
        tester.state(find.byKey(const ValueKey('retained-tool-call-group'))),
        same(retainedState),
      );
      expect(find.byType(ProgressRing), findsNWidgets(2));
      expect(
        tester
            .widgetList<ProgressRing>(find.byType(ProgressRing))
            .map((ring) => ring.semanticLabel),
        unorderedEquals(['Loading grouped tool calls', 'Loading tool call']),
      );

      final paints = find.descendant(
        of: find.byType(ProgressRing),
        matching: find.byType(CustomPaint),
      );
      final before = [
        for (final element in paints.evaluate())
          (element.widget as CustomPaint).painter,
      ];
      await tester.pump(const Duration(milliseconds: 250));
      final after = [
        for (final element in paints.evaluate())
          (element.widget as CustomPaint).painter,
      ];

      expect(after, hasLength(2));
      expect(identical(before[0], after[0]), isFalse);
      expect(identical(before[1], after[1]), isFalse);
    },
  );

  test('formats empty, two-part, and Oxford-comma summaries', () {
    const empty = ToolCallOverviewSummary(
      editedFileCount: 0,
      commandCount: 0,
      readFileCount: 0,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );
    const two = ToolCallOverviewSummary(
      editedFileCount: 1,
      commandCount: 1,
      readFileCount: 0,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );
    const three = ToolCallOverviewSummary(
      editedFileCount: 1,
      commandCount: 1,
      readFileCount: 1,
      searchCount: 0,
      otherToolCount: 0,
      tinyrackCallCount: 0,
    );

    expect(formatToolCallOverviewSummary(empty), '');
    expect(
      formatToolCallOverviewSummary(two),
      'Edited 1 file and ran 1 command',
    );
    expect(
      formatToolCallOverviewSummary(three),
      'Edited 1 file, ran 1 command, and read 1 file',
    );
  });
}
