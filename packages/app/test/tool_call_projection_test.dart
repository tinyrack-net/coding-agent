import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_overview.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallItem toolCall(
  String id,
  ToolCallDetail detail, {
  String? name,
  ToolCallStatus status = ToolCallStatus.success,
}) => ToolCallItem(
  id: id,
  toolName: name ?? detail.kind,
  status: status,
  detail: detail,
  errorMessage: status == ToolCallStatus.error ? 'boom' : null,
);

AssistantMessageItem assistant(String id) =>
    AssistantMessageItem(id: id, text: id, complete: true);

ToolCallDetailProjection project({
  ToolCallDetailLevel level = ToolCallDetailLevel.overview,
  List<TimelineItem>? tail,
  List<TimelineItem>? head,
  bool isTurnActive = false,
  PreparedToolCallHistory? preparedHistory,
}) {
  final effectiveTail = tail ?? <TimelineItem>[];
  return projectToolCallDetailLevel(
    level: level,
    tail: effectiveTail,
    head: head ?? <TimelineItem>[],
    preparedHistory:
        preparedHistory ?? prepareToolCallHistory(level, effectiveTail),
    isTurnActive: isTurnActive,
  );
}

void main() {
  test('passes detailed timelines through without grouping work', () {
    final tail = <TimelineItem>[
      toolCall('1', const ShellDetail(command: 'one')),
    ];
    final head = <TimelineItem>[
      toolCall('2', const ShellDetail(command: 'two')),
    ];

    final prepared = prepareToolCallHistory(ToolCallDetailLevel.detailed, tail);
    final result = project(
      level: ToolCallDetailLevel.detailed,
      tail: tail,
      head: head,
      preparedHistory: prepared,
    );

    expect(prepared, isNull);
    expect(identical(result.tail, tail), isTrue);
    expect(identical(result.head, head), isTrue);
    expect(result.groupsByHostId, isEmpty);
  });

  test('keeps one stable overview host as a live run grows', () {
    final first = toolCall('1', const ShellDetail(command: 'one'));
    final second = toolCall('2', const ReadDetail(path: '/repo/a.ts'));
    final prepared = prepareToolCallHistory(
      ToolCallDetailLevel.overview,
      const [],
    );

    final single = project(
      head: [first],
      isTurnActive: true,
      preparedHistory: prepared,
    );
    expect(single.head, [first]);
    expect(single.groupsByHostId['1']?.run.calls, [first]);
    expect(single.groupsByHostId['1']?.run.isSealed, isFalse);

    final grouped = project(
      head: [first, second],
      isTurnActive: true,
      preparedHistory: prepared,
    );
    expect(grouped.head.single.id, first.id);
    expect(grouped.head.single, isA<ToolCallItem>());
    expect((grouped.head.single as ToolCallItem).detail, second.detail);
    expect(grouped.groupsByHostId['1']?.run.calls, [first, second]);
    expect(grouped.groupsByHostId['1']?.run.latest, same(second));
    expect(grouped.groupsByHostId['1']?.run.isSealed, isFalse);
  });

  test('keeps a group loading while any call is active', () {
    final result = project(
      head: [
        toolCall(
          '1',
          const ShellDetail(command: 'slow'),
          status: ToolCallStatus.running,
        ),
        toolCall('2', const ShellDetail(command: 'done')),
      ],
      isTurnActive: true,
    );

    expect(result.groupsByHostId['1']?.isLoading, isTrue);
    expect(result.groupsByHostId['1']?.summary.commandCount, 2);
  });

  test('seals only at visible boundaries or when the turn ends', () {
    final calls = <ToolCallItem>[
      toolCall('1', const ShellDetail(command: 'one')),
      toolCall('2', const ReadDetail(path: '/repo/a.ts')),
      toolCall('3', const EditDetail(path: '/repo/a.ts')),
    ];
    final prepared = prepareToolCallHistory(
      ToolCallDetailLevel.overview,
      const [],
    );

    final active = project(
      head: calls,
      isTurnActive: true,
      preparedHistory: prepared,
    );
    expect(active.groupsByHostId['1']?.run.isSealed, isFalse);

    final bounded = project(
      head: [...calls, assistant('answer')],
      isTurnActive: true,
      preparedHistory: prepared,
    );
    expect(bounded.groupsByHostId['1']?.run.isSealed, isTrue);
    expect(bounded.head.last, isA<AssistantMessageItem>());

    final ended = project(
      head: calls,
      isTurnActive: false,
      preparedHistory: prepared,
    );
    expect(ended.groupsByHostId['1']?.run.isSealed, isTrue);
  });

  test('running retained calls stay live before lifecycle catches up', () {
    final calls = <TimelineItem>[
      for (var index = 1; index <= 4; index++)
        toolCall(
          '$index',
          ShellDetail(command: '$index'),
          status: ToolCallStatus.running,
        ),
    ];

    final result = project(tail: calls);

    expect(result.groupsByHostId['1']?.run.isSealed, isFalse);
    expect(result.groupsByHostId['1']?.isLoading, isTrue);
    expect(result.groupsByHostId['1']?.summary.commandCount, 4);
  });

  test('summarizes unique files and all count-based categories', () {
    final result = project(
      head: [
        toolCall('1', const EditDetail(path: '/repo/a.ts')),
        toolCall('2', const EditDetail(path: '/repo/a.ts')),
        toolCall('3', const WriteDetail(path: '/repo/b.ts')),
        toolCall('4', const ShellDetail(command: 'dart test')),
        toolCall('5', const ShellDetail(command: 'dart analyze')),
        toolCall('6', const ReadDetail(path: '/repo/a.ts')),
        toolCall('7', const ReadDetail(path: '/repo/b.ts')),
        toolCall('8', const SearchDetail(query: 'TODO')),
        toolCall('9', const GenericDetail(input: {}), name: 'custom_tool'),
      ],
    );

    final summary = result.groupsByHostId['1']!.summary;
    expect(summary.editedFileCount, 2);
    expect(summary.commandCount, 2);
    expect(summary.readFileCount, 2);
    expect(summary.searchCount, 1);
    expect(summary.otherToolCount, 1);
    expect(summary.tinyrackCallCount, 0);
    expect(
      formatToolCallOverviewSummary(summary),
      'Edited 2 files, ran 2 commands, read 2 files, searched 1 time, '
      'and used 1 other tool',
    );
  });

  test('classifies direct search and Paseo-compatible runtime names', () {
    const unknown = GenericDetail(input: {});
    final result = project(
      head: [
        toolCall('1', unknown, name: 'brave-search_brave_web_search'),
        toolCall('2', unknown, name: 'brave-search_brave_llm_context'),
        toolCall('3', unknown, name: 'paseo_list_providers'),
        toolCall('4', unknown, name: 'paseo_list_worktrees'),
        toolCall('5', unknown, name: 'mcp__paseo__list_agents'),
        toolCall('6', unknown, name: 'mcp__exa__web_search'),
      ],
    );

    final summary = result.groupsByHostId['1']!.summary;
    expect(summary.searchCount, 3);
    expect(summary.tinyrackCallCount, 3);
    expect(summary.otherToolCount, 0);
    expect(
      formatToolCallOverviewSummary(summary),
      'Searched 3 times and called Tinyrack 3 times',
    );
  });

  test('reuses prepared history and reports cross-boundary updates', () {
    final historical = <TimelineItem>[
      toolCall('1', const ShellDetail(command: 'one')),
      toolCall('2', const ShellDetail(command: 'two')),
    ];
    final tail = <TimelineItem>[assistant('before'), ...historical];
    final prepared = prepareToolCallHistory(
      ToolCallDetailLevel.overview,
      tail,
    )!;
    final head = <TimelineItem>[
      toolCall('3', const ReadDetail(path: '/repo/a.ts')),
      toolCall(
        '4',
        const EditDetail(path: '/repo/a.ts'),
        status: ToolCallStatus.running,
      ),
    ];

    final result = project(
      tail: tail,
      head: head,
      isTurnActive: true,
      preparedHistory: prepared,
    );

    expect(identical(result.tail, prepared.grouped.tail), isTrue);
    expect(result.head, isEmpty);
    expect(result.groupsByHostId['1']?.run.calls, [...historical, ...head]);
    expect(
      result.historyGroupUpdatesByHostId['1'],
      same(result.groupsByHostId['1']),
    );
  });

  test('preserves prepared history identity for assistant-only updates', () {
    final tail = <TimelineItem>[
      assistant('before'),
      toolCall('1', const ShellDetail(command: 'one')),
      toolCall('2', const ReadDetail(path: '/repo/a.ts')),
    ];
    final prepared = prepareToolCallHistory(
      ToolCallDetailLevel.overview,
      tail,
    )!;

    final first = project(
      tail: tail,
      head: [assistant('answer')],
      isTurnActive: true,
      preparedHistory: prepared,
    );
    final second = project(
      tail: tail,
      head: [
        const AssistantMessageItem(
          id: 'answer',
          text: 'answer grows',
          complete: false,
        ),
      ],
      isTurnActive: true,
      preparedHistory: prepared,
    );

    expect(identical(first.tail, prepared.grouped.tail), isTrue);
    expect(identical(second.tail, prepared.grouped.tail), isTrue);
    expect(
      identical(first.groupsByHostId, prepared.grouped.groupsByHostId),
      isTrue,
    );
    expect(
      identical(second.groupsByHostId, prepared.grouped.groupsByHostId),
      isTrue,
    );
    expect(first.historyGroupUpdatesByHostId, isEmpty);
    expect(second.historyGroupUpdatesByHostId, isEmpty);
  });

  test('leaves plans and spoken messages outside overview groups', () {
    final shell = toolCall('1', const ShellDetail(command: 'one'));
    final plan = toolCall('2', const PlanDetail(text: 'Plan'));
    final speak = toolCall('3', const GenericDetail(input: {}), name: 'speak');

    final result = project(head: [shell, plan, speak]);

    expect(result.head, [shell, plan, speak]);
    expect(result.groupsByHostId.keys, ['1']);
    expect(result.groupsByHostId['1']?.run.calls, [shell]);
  });
}
