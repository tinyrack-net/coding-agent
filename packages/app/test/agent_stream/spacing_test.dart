// Port of Paseo's `agent-stream/spacing.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/spacing.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

TimelineDisplayItem assistantBlock({
  required String id,
  required String blockGroupId,
  String text = '',
}) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: text, complete: true),
  blockGroupId: blockGroupId,
);

TimelineDisplayItem assistant(String id) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: id, complete: true),
);

TimelineDisplayItem toolCallBlock(String id) => TimelineDisplayItem(
  item: ToolCallItem(
    id: id,
    toolName: 'bash',
    status: ToolCallStatus.running,
    detail: const GenericDetail(input: {}),
  ),
);

TimelineDisplayItem user(String id) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
);

TimelineDisplayItem reasoning(String id) => TimelineDisplayItem(
  item: ReasoningItem(id: id, text: id, complete: true),
);

TimelineDisplayItem todo(String id) => TimelineDisplayItem(
  item: TodoItem(id: id, items: const []),
);

void main() {
  group('isSameAssistantBlockGroup', () {
    test(
      'returns true for two assistant blocks with the same blockGroupId',
      () {
        expect(
          isSameAssistantBlockGroup(
            item: assistantBlock(id: 'a', blockGroupId: 'group-1'),
            other: assistantBlock(id: 'b', blockGroupId: 'group-1'),
          ),
          isTrue,
        );
      },
    );

    test('returns false for blocks from different groups', () {
      expect(
        isSameAssistantBlockGroup(
          item: assistantBlock(id: 'a', blockGroupId: 'group-1'),
          other: assistantBlock(id: 'b', blockGroupId: 'group-2'),
        ),
        isFalse,
      );
    });

    test('returns false when one item is not an assistant message', () {
      expect(
        isSameAssistantBlockGroup(
          item: assistantBlock(id: 'a', blockGroupId: 'group-1'),
          other: toolCallBlock('tc-1'),
        ),
        isFalse,
      );
    });

    test('returns false for null neighbors', () {
      expect(
        isSameAssistantBlockGroup(
          item: assistantBlock(id: 'a', blockGroupId: 'group-1'),
        ),
        isFalse,
      );
    });

    test('returns false when neither block carries a group id', () {
      expect(
        isSameAssistantBlockGroup(item: assistant('a'), other: assistant('b')),
        isFalse,
      );
    });
  });

  group('getAssistantBlockSpacing', () {
    test('returns normal for non-assistant items', () {
      expect(
        getAssistantBlockSpacing(item: toolCallBlock('tc-1')),
        AssistantBlockSpacing.normal,
      );
    });

    test('returns normal when no same-group neighbors exist', () {
      expect(
        getAssistantBlockSpacing(
          item: assistantBlock(id: 'a', blockGroupId: 'group-1'),
        ),
        AssistantBlockSpacing.normal,
      );
    });

    test(
      'returns compactTop when the item above is in the same block group',
      () {
        expect(
          getAssistantBlockSpacing(
            item: assistantBlock(id: 'item', blockGroupId: 'group-1'),
            aboveItem: assistantBlock(id: 'above', blockGroupId: 'group-1'),
          ),
          AssistantBlockSpacing.compactTop,
        );
      },
    );

    test(
      'returns compactBottom when the item below is in the same block group',
      () {
        expect(
          getAssistantBlockSpacing(
            item: assistantBlock(id: 'item', blockGroupId: 'group-1'),
            belowItem: assistantBlock(id: 'below', blockGroupId: 'group-1'),
          ),
          AssistantBlockSpacing.compactBottom,
        );
      },
    );

    test(
      'returns compactBoth when both neighbors are in the same block group',
      () {
        expect(
          getAssistantBlockSpacing(
            item: assistantBlock(id: 'item', blockGroupId: 'group-1'),
            aboveItem: assistantBlock(id: 'above', blockGroupId: 'group-1'),
            belowItem: assistantBlock(id: 'below', blockGroupId: 'group-1'),
          ),
          AssistantBlockSpacing.compactBoth,
        );
      },
    );

    test('spans the history/live-head boundary: tail gets compactBottom, head '
        'gets compactTop', () {
      final tailBlock = assistantBlock(
        id: 'group-1:block:0',
        blockGroupId: 'group-1',
        text: 'First paragraph',
      );
      final headBlock = assistantBlock(
        id: 'group-1:head',
        blockGroupId: 'group-1',
        text: 'Second paragraph',
      );

      expect(
        getAssistantBlockSpacing(item: tailBlock, belowItem: headBlock),
        AssistantBlockSpacing.compactBottom,
      );
      expect(
        getAssistantBlockSpacing(item: headBlock, aboveItem: tailBlock),
        AssistantBlockSpacing.compactTop,
      );
    });
  });

  group('getGapBetweenStreamItems', () {
    test('returns no gap when either side is missing', () {
      expect(getGapBetweenStreamItems(null, assistant('a')), PaseoSpacing.s0);
      expect(getGapBetweenStreamItems(assistant('a'), null), PaseoSpacing.s0);
    });

    test('tightens consecutive user messages', () {
      expect(getGapBetweenStreamItems(user('u1'), user('u2')), PaseoSpacing.s1);
    });

    test('runs tool sequence rows together', () {
      expect(
        getGapBetweenStreamItems(toolCallBlock('t1'), reasoning('r1')),
        PaseoSpacing.s0,
      );
      expect(
        getGapBetweenStreamItems(reasoning('r1'), todo('todo-1')),
        PaseoSpacing.s0,
      );
    });

    test('separates a user message from the tool sequence it starts', () {
      expect(
        getGapBetweenStreamItems(user('u1'), toolCallBlock('t1')),
        PaseoSpacing.s4,
      );
    });

    test('tightens the seam between assistant text and tool rows', () {
      expect(
        getGapBetweenStreamItems(assistant('a1'), toolCallBlock('t1')),
        PaseoSpacing.s1,
      );
      expect(
        getGapBetweenStreamItems(toolCallBlock('t1'), assistant('a1')),
        PaseoSpacing.s1,
      );
    });

    test('uses the block gap between same-group assistant blocks', () {
      expect(
        getGapBetweenStreamItems(
          assistantBlock(id: 'a', blockGroupId: 'group-1'),
          assistantBlock(id: 'b', blockGroupId: 'group-1'),
        ),
        PaseoSpacing.s3,
      );
    });

    test('falls back to the default gap', () {
      expect(
        getGapBetweenStreamItems(assistant('a1'), user('u1')),
        PaseoSpacing.s4,
      );
      expect(
        getGapBetweenStreamItems(assistant('a1'), assistant('a2')),
        PaseoSpacing.s4,
      );
    });
  });
}
