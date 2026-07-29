import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/sidebar/workspace_agent_activity.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSummary agent({
  required String id,
  required String updatedAt,
  String? workspaceId,
  AgentRunState status = AgentRunState.idle,
  String? attentionTimestamp,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
  String? archivedAt,
  String? parentAgentId,
}) => AgentSummary(
  agentId: id,
  title: id,
  cwd: '/repo/$workspaceId',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: status,
  createdAtMs: DateTime.parse(updatedAt).millisecondsSinceEpoch,
  updatedAt: updatedAt,
  workspaceId: workspaceId,
  requiresAttention: requiresAttention,
  attentionReason: attentionReason,
  attentionTimestamp: attentionTimestamp,
  archivedAt: archivedAt,
  parentAgentId: parentAgentId,
);

void main() {
  test('keeps the latest active root agent for each workspace', () {
    final index = buildWorkspaceAgentActivityIndex({
      'older': agent(
        id: 'older',
        workspaceId: 'workspace-a',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
      'permission': agent(
        id: 'permission',
        workspaceId: 'workspace-a',
        status: AgentRunState.awaitingPermission,
        updatedAt: '2026-06-01T10:01:00.000Z',
      ),
      'attention': agent(
        id: 'attention',
        workspaceId: 'workspace-b',
        updatedAt: '2026-06-01T10:00:00.000Z',
        attentionTimestamp: '2026-06-01T10:02:00.000Z',
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
      ),
    });

    expect(index['workspace-a']?.agentId, 'permission');
    expect(index['workspace-a']?.status, WorkspaceStateBucket.needsInput);
    expect(
      index['workspace-a']?.enteredAt,
      DateTime.parse('2026-06-01T10:01:00.000Z'),
    );
    expect(index['workspace-b']?.agentId, 'attention');
    expect(index['workspace-b']?.status, WorkspaceStateBucket.attention);
    expect(
      index['workspace-b']?.enteredAt,
      DateTime.parse('2026-06-01T10:02:00.000Z'),
    );
  });

  test('ignores archived and same-workspace child agents', () {
    final index = buildWorkspaceAgentActivityIndex({
      'root': agent(
        id: 'root',
        workspaceId: 'workspace-a',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
      'child': agent(
        id: 'child',
        workspaceId: 'workspace-a',
        status: AgentRunState.awaitingPermission,
        updatedAt: '2026-06-01T10:03:00.000Z',
        parentAgentId: 'root',
      ),
      'archived': agent(
        id: 'archived',
        workspaceId: 'workspace-a',
        status: AgentRunState.error,
        updatedAt: '2026-06-01T10:04:00.000Z',
        archivedAt: '2026-06-01T10:04:00.000Z',
      ),
    });

    expect(index['workspace-a']?.agentId, 'root');
    expect(index['workspace-a']?.status, WorkspaceStateBucket.running);
  });

  test('treats a cross-workspace subagent as its workspace root activity', () {
    final index = buildWorkspaceAgentActivityIndex({
      'parent': agent(
        id: 'parent',
        workspaceId: 'workspace-a',
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
      'child': agent(
        id: 'child',
        workspaceId: 'workspace-b',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:03:00.000Z',
        parentAgentId: 'parent',
      ),
    });

    expect(index['workspace-a']?.agentId, 'parent');
    expect(index['workspace-a']?.status, WorkspaceStateBucket.done);
    expect(index['workspace-b']?.agentId, 'child');
    expect(index['workspace-b']?.status, WorkspaceStateBucket.running);
  });

  test('preserves entry and index identity while status is unchanged', () {
    final previous = buildWorkspaceAgentActivityIndex({
      'root': agent(
        id: 'root',
        workspaceId: 'workspace-a',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
    });
    final next = buildWorkspaceAgentActivityIndex({
      'root': agent(
        id: 'root',
        workspaceId: 'workspace-a',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:05:00.000Z',
      ),
    }, previous: previous);

    expect(identical(next, previous), isTrue);
    expect(
      next['workspace-a']?.enteredAt,
      DateTime.parse('2026-06-01T10:00:00.000Z'),
    );
  });

  test('records a new entry when the selected agent status changes', () {
    final previous = buildWorkspaceAgentActivityIndex({
      'root': agent(
        id: 'root',
        workspaceId: 'workspace-a',
        status: AgentRunState.running,
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
    });
    final next = buildWorkspaceAgentActivityIndex({
      'root': agent(
        id: 'root',
        workspaceId: 'workspace-a',
        status: AgentRunState.awaitingPermission,
        updatedAt: '2026-06-01T10:05:00.000Z',
      ),
    }, previous: previous);

    expect(identical(next, previous), isFalse);
    expect(next['workspace-a']?.status, WorkspaceStateBucket.needsInput);
    expect(
      next['workspace-a']?.enteredAt,
      DateTime.parse('2026-06-01T10:05:00.000Z'),
    );
  });

  test('selects the newest indexed workspace represented by a row', () {
    final agents = [
      agent(
        id: 'a',
        workspaceId: 'workspace-a',
        updatedAt: '2026-06-01T10:00:00.000Z',
      ),
      agent(
        id: 'b',
        workspaceId: 'workspace-b',
        updatedAt: '2026-06-01T10:02:00.000Z',
      ),
    ];
    final index = buildWorkspaceAgentActivityIndex({
      for (final value in agents) value.agentId: value,
    });

    expect(latestWorkspaceActivityForAgents(agents, index)?.agentId, 'b');
  });

  test(
    'controller retains stable index identity across directory refreshes',
    () {
      final controller = WorkspaceAgentActivityIndexController();
      final first = controller.update({
        'root': agent(
          id: 'root',
          workspaceId: 'workspace-a',
          status: AgentRunState.running,
          updatedAt: '2026-06-01T10:00:00.000Z',
        ),
      });
      final second = controller.update({
        'root': agent(
          id: 'root',
          workspaceId: 'workspace-a',
          status: AgentRunState.running,
          updatedAt: '2026-06-01T10:01:00.000Z',
        ),
      });

      expect(identical(first, second), isTrue);
    },
  );
}
