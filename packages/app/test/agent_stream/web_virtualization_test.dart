import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/web_virtualization.dart';
import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port of Paseo's `agent-stream/web-virtualization.test.ts`.
TimelineDisplayItem userMessage(String id) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
);

TimelineDisplayItem assistantMessage(String id) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: id, complete: true),
);

TimelineDisplayItem toolCall(String id) => TimelineDisplayItem(
  item: ToolCallItem(
    id: id,
    toolName: 'test_tool',
    status: ToolCallStatus.success,
    detail: const GenericDetail(input: {}),
  ),
);

TimelineDisplayItem thought(String id) => TimelineDisplayItem(
  item: ReasoningItem(id: id, text: id, complete: true),
);

List<IndexedStreamItem> indexEntries(List<TimelineDisplayItem> items) => [
  for (var index = 0; index < items.length; index += 1)
    IndexedStreamItem(item: items[index], index: index),
];

void main() {
  tearDown(setWebVirtualizationOverrides);

  group('findMountedWindowStart', () {
    test('keeps all items mounted when the chat is below the threshold', () {
      final items = [userMessage('u1'), assistantMessage('a1')];

      expect(findMountedWindowStart(items: items, minMountedCount: 50), 0);
    });

    test('rewinds to the previous user boundary when the cutoff lands inside a '
        'turn', () {
      final items = <TimelineDisplayItem>[];
      for (var index = 0; index < 30; index += 1) {
        items
          ..add(userMessage('u$index'))
          ..add(toolCall('t$index'))
          ..add(assistantMessage('a$index'));
      }

      expect(findMountedWindowStart(items: items, minMountedCount: 50), 39);
    });
  });

  group('splitWebVirtualizedHistory', () {
    test(
      'splits older entries into the virtualized section and keeps the recent '
      'window mounted',
      () {
        final items = <TimelineDisplayItem>[];
        for (var index = 0; index < 30; index += 1) {
          items
            ..add(userMessage('u$index'))
            ..add(assistantMessage('a$index'));
        }

        final window = splitWebVirtualizedHistory(
          entries: indexEntries(items),
          minMountedCount: 50,
        );

        expect(window.virtualizedEntries, hasLength(10));
        expect(window.virtualizedEntries.first.item.item.id, 'u0');
        expect(window.virtualizedEntries.last.item.item.id, 'a4');
        expect(window.mountedEntries.first.item.item.id, 'u5');
        expect(window.mountedEntries, hasLength(50));
      },
    );

    test('retains each entry original history index across the split', () {
      final items = <TimelineDisplayItem>[];
      for (var index = 0; index < 30; index += 1) {
        items
          ..add(userMessage('u$index'))
          ..add(assistantMessage('a$index'));
      }

      final window = splitWebVirtualizedHistory(
        entries: indexEntries(items),
        minMountedCount: 50,
      );

      expect(window.virtualizedEntries.map((entry) => entry.index).toList(), [
        for (var index = 0; index < 10; index += 1) index,
      ]);
      expect(window.mountedEntries.first.index, 10);
      expect(window.mountedEntries.last.index, 59);
    });
  });

  group('estimateStreamItemHeight', () {
    test('uses compact estimates for collapsed tool sequence rows', () {
      expect(estimateStreamItemHeight(toolCall('tool')), 40);
      expect(estimateStreamItemHeight(thought('thought')), 40);
    });

    test('uses a larger estimate for user messages with image attachments', () {
      final display = TimelineDisplayItem(
        item: const UserMessageItem(id: 'u-image', text: 'image'),
        userMessage: OptimisticUserMessage(
          id: 'u-image',
          text: 'image',
          timestamp: 1,
          images: const [
            AttachmentMetadata(
              id: 'att-1',
              mimeType: 'image/png',
              storageType: AttachmentStorageType.desktopFile,
              storageKey: '/tmp/screenshot.png',
              createdAt: 1,
            ),
          ],
          attachments: const [],
        ),
      );

      expect(estimateStreamItemHeight(display), 220);
      expect(estimateStreamItemHeight(userMessage('u-plain')), 96);
    });

    test('uses the injected assistant height estimate when available', () {
      expect(
        estimateStreamItemHeight(
          assistantMessage('a1'),
          assistantHeightEstimator: (_) => 640,
        ),
        640,
      );
      expect(
        estimateStreamItemHeight(
          assistantMessage('a1'),
          assistantHeightEstimator: (_) => null,
        ),
        220,
      );
      expect(estimateStreamItemHeight(assistantMessage('a1')), 220);
    });

    test('uses per-kind estimates for the remaining stream item kinds', () {
      expect(
        estimateStreamItemHeight(
          const TimelineDisplayItem(
            item: TodoItem(id: 'todo', items: []),
          ),
        ),
        144,
      );
      expect(
        estimateStreamItemHeight(
          const TimelineDisplayItem(
            item: ErrorItem(id: 'activity', message: 'boom'),
          ),
        ),
        88,
      );
      expect(
        estimateStreamItemHeight(
          const TimelineDisplayItem(
            item: CompactionItem(
              id: 'compaction',
              status: CompactionStatus.completed,
            ),
          ),
        ),
        72,
      );
      expect(
        estimateStreamItemHeight(
          const TimelineDisplayItem(
            item: TurnItem(id: 'turn', phase: TurnPhase.completed),
          ),
        ),
        120,
      );
    });
  });

  group('web virtualization test overrides', () {
    test(
      'uses defaults unless explicit positive integer overrides are present',
      () {
        setWebVirtualizationOverrides();
        expect(
          getWebPartialVirtualizationThreshold(),
          defaultWebPartialVirtualizationThreshold,
        );
        expect(
          getWebMountedRecentStreamItems(),
          defaultWebMountedRecentStreamItems,
        );

        setWebVirtualizationOverrides(
          partialVirtualizationThreshold: 6,
          mountedRecentStreamItems: 4,
        );
        expect(getWebPartialVirtualizationThreshold(), 6);
        expect(getWebMountedRecentStreamItems(), 4);
      },
    );

    test('rejects non-positive and non-finite overrides', () {
      setWebVirtualizationOverrides(
        partialVirtualizationThreshold: 0,
        mountedRecentStreamItems: -3,
      );
      expect(
        getWebPartialVirtualizationThreshold(),
        defaultWebPartialVirtualizationThreshold,
      );
      expect(
        getWebMountedRecentStreamItems(),
        defaultWebMountedRecentStreamItems,
      );

      setWebVirtualizationOverrides(
        partialVirtualizationThreshold: double.nan,
        mountedRecentStreamItems: double.infinity,
      );
      expect(
        getWebPartialVirtualizationThreshold(),
        defaultWebPartialVirtualizationThreshold,
      );
      expect(
        getWebMountedRecentStreamItems(),
        defaultWebMountedRecentStreamItems,
      );
    });

    test('truncates fractional overrides toward zero', () {
      setWebVirtualizationOverrides(
        partialVirtualizationThreshold: 7.9,
        mountedRecentStreamItems: 3.2,
      );
      expect(getWebPartialVirtualizationThreshold(), 7);
      expect(getWebMountedRecentStreamItems(), 3);
    });
  });
}
