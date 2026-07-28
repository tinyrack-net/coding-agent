import 'package:agent_daemon/src/providers/paseo/acp_history.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('coalesces ACP replay chunks and preserves stable message ids', () {
    final projector = AcpHistoryProjector(uuid: const Uuid());
    projector
      ..addUpdate({
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': 'hello'},
      })
      ..addUpdate({
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'image', 'data': 'AA==', 'mimeType': 'image/png'},
      })
      ..addUpdate({
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'assistant-1',
        'content': {'type': 'text', 'text': 'Loaded'},
      })
      ..addUpdate({
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'assistant-1',
        'content': {'type': 'text', 'text': ' response'},
      })
      ..addUpdate({
        'sessionUpdate': 'agent_thought_chunk',
        'messageId': 'thought-1',
        'content': {'type': 'text', 'text': 'Reasoning'},
      });

    final history = projector.finish();
    expect(history, hasLength(3));
    expect(
      history[0],
      isA<UserMessageItem>().having(
        (item) => item.text,
        'text',
        'hello[image]',
      ),
    );
    expect(
      history[1],
      isA<AssistantMessageItem>()
          .having((item) => item.id, 'id', 'assistant-1')
          .having((item) => item.text, 'text', 'Loaded response')
          .having((item) => item.complete, 'complete', isTrue),
    );
    expect(
      history[2],
      isA<ReasoningItem>()
          .having((item) => item.id, 'id', 'thought-1')
          .having((item) => item.text, 'text', 'Reasoning'),
    );
  });

  test('merges tool snapshots and maps plan entries', () {
    final projector = AcpHistoryProjector();
    projector
      ..addUpdate({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'tool-1',
        'title': 'Read source',
        'kind': 'read',
        'status': 'pending',
        'rawInput': {'path': 'README.md'},
      })
      ..addUpdate({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool-1',
        'status': 'completed',
        'rawOutput': {'text': 'done'},
      })
      ..addUpdate({
        'sessionUpdate': 'plan',
        'id': 'plan-1',
        'entries': [
          {'content': 'Inspect', 'status': 'completed'},
          {'content': 'Implement', 'status': 'pending'},
        ],
      });

    final history = projector.finish();
    expect(
      history[0],
      isA<ToolCallItem>()
          .having((item) => item.id, 'id', 'tool-1')
          .having((item) => item.toolName, 'tool name', 'read')
          .having((item) => item.status, 'status', ToolCallStatus.success)
          .having((item) => (item.detail as GenericDetail).output, 'output', {
            'text': 'done',
          }),
    );
    expect((history[1] as TodoItem).items, [
      isA<TodoEntry>()
          .having((item) => item.text, 'text', 'Inspect')
          .having((item) => item.completed, 'completed', isTrue),
      isA<TodoEntry>()
          .having((item) => item.text, 'text', 'Implement')
          .having((item) => item.completed, 'completed', isFalse),
    ]);
  });

  test('maps every frozen ACP content block placeholder', () {
    expect(
      acpContentBlockText({
        'type': 'resource_link',
        'uri': 'file:///tmp/a',
        'title': 'A',
      }),
      'A',
    );
    expect(
      acpContentBlockText({
        'type': 'resource',
        'resource': {'uri': 'file:///tmp/a', 'mimeType': 'application/pdf'},
      }),
      '[resource:application/pdf]',
    );
    expect(acpContentBlockText({'type': 'audio', 'data': 'AA=='}), '[audio]');
    expect(acpContentBlockText({'type': 'unknown'}), isEmpty);
  });
}
