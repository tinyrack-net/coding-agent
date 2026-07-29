import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('pending projection keeps only the latest state per request', () {
    const agent = AgentSummary(
      agentId: 'agent',
      title: 'Agent',
      cwd: '/repo',
      provider: 'codex',
      model: 'gpt',
      mode: AgentMode.normal,
      runState: AgentRunState.running,
      createdAtMs: 1,
    );
    expect(
      PaseoAgentSnapshotCodec.encodePendingPermissions(agent, const [
        PermissionItem(
          id: 'permission',
          permissionId: 'permission-1',
          toolName: 'Bash',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'dart test'),
        ),
        PermissionItem(
          id: 'permission',
          permissionId: 'permission-1',
          toolName: 'Bash',
          status: PermissionStatus.allowed,
          detail: ShellDetail(command: 'dart test'),
        ),
      ]),
      isEmpty,
    );
  });

  test('projects AgentSummary to the frozen AgentSnapshot payload shape', () {
    const summary = AgentSummary(
      agentId: 'agent-1',
      title: 'Port parity',
      cwd: r'C:\repo',
      provider: 'codex',
      model: 'gpt-5.2-codex',
      mode: AgentMode.plan,
      runState: AgentRunState.awaitingPermission,
      createdAtMs: 1000,
      updatedAt: '2026-07-28T01:02:03.000Z',
      sessionId: 'thread-1',
      workspaceId: 'workspace-1',
      lastUsage: AgentUsage(inputTokens: 12, outputTokens: 3),
      requiresAttention: true,
      attentionReason: AgentAttentionReason.permission,
      attentionTimestamp: '2026-07-28T01:02:04.000Z',
      archivedAt: '2026-07-28T02:00:00.000Z',
      thinkingOptionId: 'high',
      lastUserMessageAt: '2026-07-28T01:01:00.000Z',
      lastError: 'temporary provider error',
      labels: {'origin': 'schedule'},
    );

    final payload = PaseoAgentSnapshotCodec.encode(
      summary,
      pendingPermissions: const [
        PermissionItem(
          id: 'permission-row',
          permissionId: 'permission-1',
          toolName: 'shell',
          status: PermissionStatus.pending,
          detail: ShellDetail(command: 'pwd'),
        ),
        PermissionItem(
          id: 'resolved-row',
          permissionId: 'permission-2',
          toolName: 'write',
          status: PermissionStatus.allowed,
          detail: WriteDetail(path: 'a.txt'),
        ),
      ],
      capabilities: const {
        'supportsStreaming': true,
        'supportsSessionPersistence': true,
      },
      availableModes: const [
        {'id': 'plan', 'label': 'Plan mode'},
      ],
      features: const [
        {
          'type': 'toggle',
          'id': 'fast_mode',
          'label': 'Fast mode',
          'value': true,
        },
      ],
      currentModeId: 'plan',
    );
    expect(payload['id'], 'agent-1');
    expect(payload['workspaceId'], 'workspace-1');
    expect(payload['createdAt'], '1970-01-01T00:00:01.000Z');
    expect(payload['updatedAt'], '2026-07-28T01:02:03.000Z');
    expect(payload['lastUserMessageAt'], '2026-07-28T01:01:00.000Z');
    expect(payload['status'], 'closed');
    expect(payload['currentModeId'], 'plan');
    expect(payload['thinkingOptionId'], 'high');
    expect(payload['effectiveThinkingOptionId'], 'high');
    expect(payload['persistence'], {
      'provider': 'codex',
      'sessionId': 'thread-1',
    });
    expect(payload['runtimeInfo'], {
      'provider': 'codex',
      'sessionId': 'thread-1',
      'model': 'gpt-5.2-codex',
      'thinkingOptionId': 'high',
      'modeId': 'plan',
    });
    expect(payload['lastUsage'], {'inputTokens': 12, 'outputTokens': 3});
    expect(payload['lastError'], 'temporary provider error');
    expect(payload['labels'], {'origin': 'schedule'});
    expect(payload['pendingPermissions'], [
      {
        'id': 'permission-1',
        'provider': 'codex',
        'name': 'shell',
        'kind': 'tool',
        'detail': {'type': 'shell', 'command': 'pwd'},
      },
    ]);
    expect(payload['capabilities'], {
      'supportsStreaming': true,
      'supportsSessionPersistence': true,
    });
    expect(payload['availableModes'], [
      {'id': 'plan', 'label': 'Plan mode'},
    ]);
    expect(payload['features'], [
      {
        'type': 'toggle',
        'id': 'fast_mode',
        'label': 'Fast mode',
        'value': true,
      },
    ]);
    expect(payload['requiresAttention'], isTrue);
    expect(payload['attentionReason'], 'permission');
    expect(payload['providerUnavailable'], isFalse);
  });

  test('maps empty optionals and every remaining state and mode', () {
    for (final pair in const [
      (AgentRunState.initializing, 'initializing'),
      (AgentRunState.idle, 'idle'),
      (AgentRunState.running, 'running'),
      (AgentRunState.error, 'error'),
      (AgentRunState.closed, 'closed'),
    ]) {
      final payload = PaseoAgentSnapshotCodec.encode(
        AgentSummary(
          agentId: pair.$2,
          title: ' ',
          cwd: '/repo',
          provider: 'claude',
          model: '',
          mode: pair.$1 == AgentRunState.initializing
              ? AgentMode.normal
              : AgentMode.fullAccess,
          runState: pair.$1,
          createdAtMs: 0,
        ),
      );
      expect(payload['status'], pair.$2);
      expect(payload['model'], isNull);
      expect(payload['title'], isNull);
      expect(payload['persistence'], isNull);
      expect(payload['lastUserMessageAt'], isNull);
      expect(payload.containsKey('lastError'), isFalse);
      expect(payload['labels'], isEmpty);
      expect(
        payload['currentModeId'],
        pair.$1 == AgentRunState.initializing ? 'normal' : 'full-access',
      );
    }
    final unavailable = PaseoAgentSnapshotCodec.encode(
      const AgentSummary(
        agentId: 'unavailable',
        title: '',
        cwd: '/repo',
        provider: 'removed-provider',
        model: '',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
      ),
      providerUnavailable: true,
    );
    expect(unavailable['providerUnavailable'], isTrue);
    final decodedUnavailable = PaseoAgentSnapshotCodec.decode(unavailable);
    expect(decodedUnavailable.providerUnavailable, isTrue);
    expect(
      PaseoAgentSnapshotCodec.encode(decodedUnavailable)['providerUnavailable'],
      isTrue,
    );
    expect(
      AgentSummary.fromJson(decodedUnavailable.toJson()).providerUnavailable,
      isTrue,
    );
  });
}
