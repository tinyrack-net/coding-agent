import 'package:agent_daemon/src/agent/timeline_projection.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

TimelineRow row(int seq, TimelineItem item) => TimelineRow(
  seq: seq,
  timestamp: '2026-07-28T00:00:${seq.toString().padLeft(2, '0')}.000Z',
  item: item,
);

TimelineRow toolRow(int seq, ToolCallStatus status) => row(
  seq,
  ToolCallItem(
    id: 'call-1',
    toolName: 'shell',
    status: status,
    detail: status == ToolCallStatus.running
        ? const GenericDetail(input: {'cmd': 'sleep 10'})
        : const ShellDetail(command: 'sleep 10', output: 'done'),
    errorMessage: status == ToolCallStatus.error ? 'failed' : null,
    metadata: {status.name: seq},
  ),
);

void main() {
  group('projectTimelineRows', () {
    test(
      'canonical retains rows and projected merges adjacent text chunks',
      () {
        final rows = [
          row(
            1,
            const AssistantMessageItem(id: 'm1', text: 'Hel', complete: false),
          ),
          row(
            2,
            const AssistantMessageItem(id: 'm1', text: 'lo', complete: true),
          ),
          row(
            3,
            const AssistantMessageItem(id: 'm2', text: '!', complete: true),
          ),
          row(4, const ReasoningItem(id: 'r1', text: 'think', complete: false)),
          row(5, const ReasoningItem(id: 'r2', text: 'ing', complete: true)),
        ];

        expect(projectTimelineRows(rows, projected: false), hasLength(5));
        final projected = projectTimelineRows(rows, projected: true);
        expect(projected, hasLength(3));
        expect((projected[0].item as AssistantMessageItem).text, 'Hello');
        expect(projected[0].sourceSeqRanges.single.toJson(), {
          'startSeq': 1,
          'endSeq': 2,
        });
        expect(projected[0].collapsed, [TimelineProjectionKind.assistantMerge]);
        expect((projected[1].item as AssistantMessageItem).id, 'm2');
        expect((projected[2].item as ReasoningItem).text, 'thinking');
        expect(projected[2].collapsed, [TimelineProjectionKind.reasoningMerge]);
      },
    );

    test(
      'collapses discontiguous tool lifecycle and preserves typed detail',
      () {
        final projected = projectTimelineRows([
          toolRow(1, ToolCallStatus.running),
          row(2, const UserMessageItem(id: 'u1', text: 'middle')),
          toolRow(3, ToolCallStatus.success),
        ], projected: true);

        expect(projected, hasLength(2));
        final tool = projected.first;
        expect((tool.item as ToolCallItem).status, ToolCallStatus.success);
        expect((tool.item as ToolCallItem).detail, isA<ShellDetail>());
        expect((tool.item as ToolCallItem).metadata, {
          'running': 1,
          'success': 3,
        });
        expect(tool.seqStart, 1);
        expect(tool.seqEnd, 3);
        expect(tool.sourceSeqRanges.map((range) => range.toJson()), [
          {'startSeq': 1, 'endSeq': 1},
          {'startSeq': 3, 'endSeq': 3},
        ]);
        expect(tool.collapsed, [TimelineProjectionKind.toolLifecycle]);
      },
    );

    test('terminal tool error wins and later success clears the error', () {
      final failed =
          projectTimelineRows([
                toolRow(1, ToolCallStatus.running),
                toolRow(2, ToolCallStatus.error),
              ], projected: true).single.item
              as ToolCallItem;
      expect(failed.errorMessage, 'failed');

      final recovered =
          projectTimelineRows([
                toolRow(1, ToolCallStatus.error),
                toolRow(2, ToolCallStatus.success),
              ], projected: true).single.item
              as ToolCallItem;
      expect(recovered.errorMessage, isNull);
    });
  });

  group('selectProjectedTimelinePage', () {
    test('tail limit counts projected entries and expands tool overlap', () {
      final rows = [
        row(1, const UserMessageItem(id: 'u1', text: 'go')),
        for (var seq = 2; seq <= 121; seq++)
          toolRow(seq, ToolCallStatus.running),
      ];
      final page = selectProjectedTimelinePage(
        rows: rows,
        direction: 'tail',
        limit: 100,
      );
      expect(page.entries, hasLength(2));
      expect(page.startSeq, 1);
      expect(page.endSeq, 121);
      expect(page.hasNewer, isFalse);
      expect(page.entries.last.sourceSeqRanges.single.toJson(), {
        'startSeq': 2,
        'endSeq': 121,
      });
    });

    test('after includes a full tool when only its update is new', () {
      final page = selectProjectedTimelinePage(
        rows: [
          toolRow(10, ToolCallStatus.running),
          row(
            11,
            const AssistantMessageItem(
              id: 'm1',
              text: 'working',
              complete: true,
            ),
          ),
          toolRow(250, ToolCallStatus.success),
        ],
        direction: 'after',
        cursorSeq: 249,
        limit: 100,
      );
      expect(page.entries, hasLength(1));
      expect(page.entries.single.seqStart, 10);
      expect(page.entries.single.seqEnd, 250);
      expect(page.startSeq, 250);
      expect(page.endSeq, 250);
    });

    test('after cursor advances only through selected contiguous sources', () {
      final rows = [
        toolRow(1, ToolCallStatus.running),
        for (var seq = 2; seq < 500; seq++)
          row(seq, UserMessageItem(id: 'u$seq', text: 'middle $seq')),
        toolRow(500, ToolCallStatus.success),
        for (var seq = 501; seq <= 601; seq++)
          row(seq, UserMessageItem(id: 'u$seq', text: 'later $seq')),
      ];
      final page = selectProjectedTimelinePage(
        rows: rows,
        direction: 'after',
        cursorSeq: 0,
        limit: 100,
      );
      expect(page.endSeq, 100);
      expect(page.hasNewer, isTrue);
      expect(page.entries.any((entry) => entry.seqStart == 101), isFalse);
    });

    test('before overlaps a wide tool and reports both page directions', () {
      final rows = [
        toolRow(1, ToolCallStatus.running),
        for (var seq = 2; seq < 500; seq++)
          row(seq, UserMessageItem(id: 'u$seq', text: 'middle $seq')),
        toolRow(500, ToolCallStatus.success),
      ];
      final page = selectProjectedTimelinePage(
        rows: rows,
        direction: 'before',
        cursorSeq: 500,
        limit: 100,
      );
      expect(page.entries.any((entry) => entry.item is ToolCallItem), isTrue);
      expect(page.endSeq, 499);
      expect(page.hasOlder, isTrue);
      expect(page.hasNewer, isTrue);
    });

    test('empty and exhausted pages preserve frozen cursor flags', () {
      final empty = selectProjectedTimelinePage(
        rows: const [],
        direction: 'tail',
        limit: 100,
      );
      expect(empty.entries, isEmpty);
      expect(empty.startSeq, isNull);

      final exhausted = selectProjectedTimelinePage(
        rows: [row(4, const UserMessageItem(id: 'u', text: 'x'))],
        direction: 'after',
        cursorSeq: 4,
        limit: 0,
      );
      expect(exhausted.entries, isEmpty);
      expect(exhausted.hasOlder, isTrue);
      expect(exhausted.hasNewer, isFalse);
    });
  });

  test('flat-item selection returns canonical rows for projected limits', () {
    const items = <TimelineItem>[
      AssistantMessageItem(id: 'm1', text: 'a', complete: false),
      AssistantMessageItem(id: 'm1', text: 'b', complete: true),
      UserMessageItem(id: 'u1', text: 'middle'),
      ToolCallItem(
        id: 'call',
        toolName: 'shell',
        status: ToolCallStatus.running,
        detail: ShellDetail(command: 'pwd'),
      ),
      ToolCallItem(
        id: 'call',
        toolName: 'shell',
        status: ToolCallStatus.success,
        detail: ShellDetail(command: 'pwd', output: '/repo'),
      ),
    ];

    final after = selectTimelineItemsByProjectedLimit(
      items: items,
      direction: 'after',
      limit: 1,
    );
    expect(after.totalProjected, 3);
    expect(after.shownProjected, 1);
    expect(after.items, items.take(2));

    final tail = selectTimelineItemsByProjectedLimit(
      items: items,
      direction: 'tail',
      limit: 1,
    );
    expect(tail.totalProjected, 3);
    expect(tail.shownProjected, 1);
    expect(tail.items, items.skip(3));

    final all = selectTimelineItemsByProjectedLimit(
      items: items,
      direction: 'before',
      limit: 0,
    );
    expect(all.items, items);
    expect(all.shownProjected, 3);

    expect(
      () => selectTimelineItemsByProjectedLimit(
        items: items,
        direction: 'sideways',
        limit: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => selectTimelineItemsByProjectedLimit(
        items: items,
        direction: 'tail',
        limit: -1,
      ),
      throwsRangeError,
    );
  });
}
