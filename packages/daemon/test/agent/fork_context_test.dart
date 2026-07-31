// Port of the fork-context behavior in Paseo's
// `server/agent/activity-curator.ts`.
import 'package:agent_daemon/src/agent/fork_context.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

TimelineRow row(int seq, TimelineItem item) =>
    TimelineRow(seq: seq, timestamp: '', item: item);

List<TimelineRow> conversation() => [
  row(1, const UserMessageItem(id: 'u1', text: 'first question')),
  row(
    2,
    const AssistantMessageItem(id: 'a1', text: 'first answer', complete: true),
  ),
  row(3, const UserMessageItem(id: 'u2', text: 'second question')),
  row(
    4,
    const AssistantMessageItem(id: 'a2', text: 'second answer', complete: true),
  ),
];

void main() {
  test('carries the whole timeline when no boundary is given', () {
    final context = buildAgentForkContextAttachment(rows: conversation());

    expect(context.itemCount, 4);
    expect(context.boundaryCursor, isNull);
    expect(context.boundaryMessageId, isNull);
    expect(context.attachment.text, contains('first question'));
    expect(context.attachment.text, contains('second answer'));
  });

  test('wraps the body and labels assistant messages', () {
    final context = buildAgentForkContextAttachment(
      rows: conversation(),
      agentTitle: 'Port the panel',
      cwd: '/repo/worktree',
    );

    expect(context.attachment.text, startsWith('<chat-history-summary>\n'));
    expect(context.attachment.text, endsWith('\n</chat-history-summary>'));
    expect(context.attachment.text, contains('Source agent: Port the panel'));
    expect(
      context.attachment.text,
      contains('Source directory: /repo/worktree'),
    );
    expect(context.attachment.text, contains('[User] first question'));
    expect(context.attachment.text, contains('[Assistant] first answer'));
  });

  test('truncates at a cursor boundary', () {
    final context = buildAgentForkContextAttachment(
      rows: conversation(),
      cursorBoundary: const ForkCursorBoundary(
        epoch: '1',
        seq: 2,
        timelineEpoch: '1',
      ),
    );

    expect(context.itemCount, 2);
    expect(context.boundaryCursor?.seq, 2);
    expect(context.attachment.text, contains('first answer'));
    expect(context.attachment.text, isNot(contains('second question')));
  });

  test('truncates at an assistant message boundary', () {
    final context = buildAgentForkContextAttachment(
      rows: conversation(),
      boundaryMessageId: 'a1',
    );

    expect(context.itemCount, 2);
    expect(context.boundaryMessageId, 'a1');
    expect(context.attachment.text, contains('first answer'));
    expect(context.attachment.text, isNot(contains('second answer')));
  });

  test('rejects a cursor from a rebuilt timeline', () {
    expect(
      () => buildAgentForkContextAttachment(
        rows: conversation(),
        cursorBoundary: const ForkCursorBoundary(
          epoch: '1',
          seq: 2,
          timelineEpoch: '2',
        ),
      ),
      throwsA(
        isA<ForkBoundaryUnavailable>().having(
          (error) => error.message,
          'message',
          'Selected timeline position is no longer available.',
        ),
      ),
    );
  });

  test('rejects a cursor that no longer exists', () {
    expect(
      () => buildAgentForkContextAttachment(
        rows: conversation(),
        cursorBoundary: const ForkCursorBoundary(
          epoch: '1',
          seq: 99,
          timelineEpoch: '1',
        ),
      ),
      throwsA(
        isA<ForkBoundaryUnavailable>().having(
          (error) => error.message,
          'message',
          'Selected timeline position is no longer available.',
        ),
      ),
    );
  });

  test('rejects an assistant message that no longer exists', () {
    expect(
      () => buildAgentForkContextAttachment(
        rows: conversation(),
        boundaryMessageId: 'missing',
      ),
      throwsA(
        isA<ForkBoundaryUnavailable>().having(
          (error) => error.message,
          'message',
          'Selected assistant message is no longer available.',
        ),
      ),
    );
  });

  test('renders a placeholder body for an empty timeline', () {
    final context = buildAgentForkContextAttachment(rows: const []);

    expect(context.itemCount, 0);
    expect(context.attachment.text, contains('No chat history to display.'));
  });

  test('omits kinds the frozen fork context excludes', () {
    final context = buildAgentForkContextAttachment(
      rows: [
        row(1, const UserMessageItem(id: 'u1', text: 'question')),
        row(
          2,
          const ReasoningItem(
            id: 'r1',
            text: 'private thought',
            complete: true,
          ),
        ),
        row(3, const ErrorItem(id: 'e1', message: 'boom')),
        row(
          4,
          const AssistantMessageItem(id: 'a1', text: 'answer', complete: true),
        ),
      ],
    );

    expect(context.attachment.text, contains('question'));
    expect(context.attachment.text, contains('answer'));
    expect(context.attachment.text, isNot(contains('private thought')));
    expect(context.attachment.text, isNot(contains('boom')));
  });

  test('blank metadata is omitted from the header', () {
    final context = buildAgentForkContextAttachment(
      rows: conversation(),
      agentTitle: '   ',
      cwd: '',
    );

    expect(context.attachment.text, isNot(contains('Source agent:')));
    expect(context.attachment.text, isNot(contains('Source directory:')));
  });
}
