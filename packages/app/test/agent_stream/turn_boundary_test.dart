// Port of Paseo's `agent-stream/turn-boundary.test.ts`.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/agent_stream/turn_boundary.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:flutter_test/flutter_test.dart';

TimelineDisplayItem userMessage(String id) => TimelineDisplayItem(
  item: UserMessageItem(id: id, text: id),
);

TimelineDisplayItem assistantMessage(
  String id, {
  String? messageId,
  StreamTimelinePosition? timelineCursor,
}) => TimelineDisplayItem(
  item: AssistantMessageItem(id: id, text: id, complete: true),
  messageId: messageId,
  timelineCursor: timelineCursor,
);

void main() {
  test('forks a failed assistant turn from its timeline cursor without a '
      'provider message id', () {
    final failedTurn = assistantMessage(
      'assistant-error',
      timelineCursor: const StreamTimelinePosition(
        epoch: 'timeline-1',
        seq: 42,
      ),
    );

    expect(
      resolveAssistantTurnForkBoundary(
        items: [userMessage('user-1'), failedTurn],
        startIndex: 1,
        supportsTimelineCursor: true,
      ),
      const AssistantTurnForkBoundary.fromCursor(
        StreamTimelinePosition(epoch: 'timeline-1', seq: 42),
      ),
    );
  });

  test('includes the provider message id with a supported timeline cursor', () {
    final selected = assistantMessage(
      'assistant-1',
      messageId: 'msg-assistant-1',
      timelineCursor: const StreamTimelinePosition(
        epoch: 'timeline-1',
        seq: 42,
      ),
    );

    expect(
      resolveAssistantTurnForkBoundary(
        items: [selected],
        startIndex: 0,
        supportsTimelineCursor: true,
      ),
      const AssistantTurnForkBoundary.fromCursor(
        StreamTimelinePosition(epoch: 'timeline-1', seq: 42),
        boundaryMessageId: 'msg-assistant-1',
      ),
    );
  });

  test('falls back to the provider message id when timeline cursors are '
      'unsupported', () {
    final selected = assistantMessage(
      'assistant-1',
      messageId: 'msg-assistant-1',
      timelineCursor: const StreamTimelinePosition(
        epoch: 'timeline-1',
        seq: 42,
      ),
    );

    expect(
      resolveAssistantTurnForkBoundary(
        items: [selected],
        startIndex: 0,
        supportsTimelineCursor: false,
      ),
      const AssistantTurnForkBoundary.fromMessageId('msg-assistant-1'),
    );
  });

  test('does not borrow a provider message id from another assistant in the '
      'same turn', () {
    expect(
      resolveAssistantTurnForkBoundary(
        items: [
          userMessage('user-1'),
          assistantMessage('assistant-1', messageId: 'msg-assistant-1'),
          assistantMessage('assistant-2'),
        ],
        startIndex: 2,
        supportsTimelineCursor: false,
      ),
      isNull,
    );
  });

  test('requires the selected item to be an assistant message', () {
    expect(
      resolveAssistantTurnForkBoundary(
        items: [
          userMessage('user-1'),
          assistantMessage('assistant-1', messageId: 'msg-assistant-1'),
        ],
        startIndex: 0,
        supportsTimelineCursor: false,
      ),
      isNull,
    );
  });

  test('does not offer an unavailable boundary', () {
    expect(
      resolveAssistantTurnForkBoundary(
        items: [assistantMessage('assistant-1')],
        startIndex: 0,
        supportsTimelineCursor: false,
      ),
      isNull,
    );
  });

  test('rejects an out-of-range start index', () {
    final items = [assistantMessage('assistant-1', messageId: 'msg-1')];

    expect(
      resolveAssistantTurnForkBoundary(
        items: items,
        startIndex: -1,
        supportsTimelineCursor: false,
      ),
      isNull,
    );
    expect(
      resolveAssistantTurnForkBoundary(
        items: items,
        startIndex: 1,
        supportsTimelineCursor: false,
      ),
      isNull,
    );
  });
}
