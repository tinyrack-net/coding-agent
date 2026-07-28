import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('sub-agent tool detail and canceled status round-trip', () {
    const item = ToolCallItem(
      id: 'call-1',
      toolName: 'Sub-agent',
      status: ToolCallStatus.canceled,
      detail: SubAgentDetail(
        subAgentType: 'Research / Investigator',
        description: 'research/investigator',
        childSessionId: 'child-1',
        log: 'Read lib/main.dart',
        actions: [
          SubAgentAction(index: 0, toolName: 'read', summary: 'lib/main.dart'),
        ],
      ),
    );

    final decoded = TimelineItem.fromJson(item.toJson()) as ToolCallItem;
    expect(decoded.status, ToolCallStatus.canceled);
    final detail = decoded.detail as SubAgentDetail;
    expect(detail.subAgentType, 'Research / Investigator');
    expect(detail.childSessionId, 'child-1');
    expect(detail.actions.single.toJson(), {
      'index': 0,
      'toolName': 'read',
      'summary': 'lib/main.dart',
    });
  });

  test('provider subagent descriptor and every update variant round-trip', () {
    const descriptor = ProviderSubagentDescriptor(
      id: 'child-1',
      parentAgentId: 'parent-1',
      provider: 'codex',
      title: 'Explore',
      description: 'Inspect routing',
      status: ProviderSubagentStatus.running,
      createdAt: '2026-07-26T00:00:00.000Z',
      updatedAt: '2026-07-26T00:01:00.000Z',
      toolCallId: 'call-1',
      cwd: 'C:/repo',
    );
    expect(
      ProviderSubagentDescriptor.fromJson(descriptor.toJson()).toJson(),
      descriptor.toJson(),
    );

    final updates = <ProviderSubagentUpdate>[
      const ProviderSubagentUpsert(subagent: descriptor),
      const ProviderSubagentTimelineUpdate(
        parentAgentId: 'parent-1',
        subagentId: 'child-1',
        provider: 'codex',
        item: AssistantMessageItem(
          id: 'message-1',
          text: 'Found it.',
          complete: true,
        ),
        timestamp: '2026-07-26T00:02:00.000Z',
        seq: 4,
        epoch: 'epoch-1',
      ),
      const ProviderSubagentRemove(
        parentAgentId: 'parent-1',
        subagentId: 'child-1',
      ),
    ];
    for (final update in updates) {
      expect(
        ProviderSubagentUpdate.fromJson(update.toJson()).toJson(),
        update.toJson(),
      );
    }
    expect(
      () => ProviderSubagentUpdate.fromJson({'kind': 'future'}),
      throwsFormatException,
    );
  });

  test('provider subagent timeline row round-trips', () {
    const row = ProviderSubagentTimelineRow(
      item: ReasoningItem(id: 'r', text: 'thinking', complete: false),
      timestamp: '2026-07-26T00:00:00.000Z',
      seq: 7,
    );
    expect(
      ProviderSubagentTimelineRow.fromJson(row.toJson()).toJson(),
      row.toJson(),
    );
  });

  test('provider subagent timeline page round-trips cursor metadata', () {
    const response = ProviderSubagentTimelineResponse(
      parentAgentId: 'parent',
      subagentId: 'child',
      provider: 'codex',
      direction: ProviderSubagentTimelineDirection.before,
      epoch: 'epoch-1',
      reset: false,
      staleCursor: false,
      gap: false,
      window: ProviderSubagentTimelineWindow(minSeq: 1, maxSeq: 8, nextSeq: 9),
      hasOlder: true,
      hasNewer: true,
      rows: [
        ProviderSubagentTimelineRow(
          item: ErrorItem(id: 'e', message: 'failed'),
          timestamp: '2026-07-26T00:00:00.000Z',
          seq: 4,
        ),
      ],
    );
    expect(
      ProviderSubagentTimelineResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
    expect(
      const ProviderSubagentTimelineCursor(epoch: 'epoch-1', seq: 4).toJson(),
      {'epoch': 'epoch-1', 'seq': 4},
    );
    expect(
      () => ProviderSubagentTimelineCursor.fromJson({
        'epoch': 'epoch-1',
        'seq': -1,
      }),
      throwsFormatException,
    );
    expect(
      () => ProviderSubagentTimelineCursor.fromJson({'epoch': '', 'seq': 0}),
      throwsFormatException,
    );
  });
}
