import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agent = AgentSummary(
  agentId: 'agent-1',
  title: 'Native',
  cwd: '/repo',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.plan,
  runState: AgentRunState.running,
  createdAtMs: 1000,
  workspaceId: 'workspace-1',
  sessionId: 'session-1',
  labels: {'source': 'test'},
);

void main() {
  test('decodes the frozen agent directory upsert and lifecycle events', () {
    final upsert = DirectoryUpdateEvent.fromJson({
      'type': 'agent_update',
      'payload': {
        'kind': 'upsert',
        'agent': PaseoAgentSnapshotCodec.encode(_agent),
        'project': null,
      },
    });
    expect(upsert, isA<AgentUpsertDirectoryEvent>());
    final decoded = (upsert as AgentUpsertDirectoryEvent).agent;
    expect(decoded.agentId, _agent.agentId);
    expect(decoded.workspaceId, _agent.workspaceId);
    expect(decoded.sessionId, _agent.sessionId);
    expect(decoded.mode, AgentMode.plan);
    expect(decoded.runState, AgentRunState.running);
    expect(decoded.labels, _agent.labels);

    expect(
      DirectoryUpdateEvent.fromJson(const {
        'type': 'agent_update',
        'payload': {'kind': 'remove', 'agentId': 'agent-1'},
      }),
      isA<AgentRemoveDirectoryEvent>(),
    );
    expect(
      DirectoryUpdateEvent.fromJson(const {
        'type': 'agent_deleted',
        'payload': {'agentId': 'agent-1', 'requestId': 'delete-1'},
      }),
      isA<AgentDeletedDirectoryEvent>(),
    );
    expect(
      DirectoryUpdateEvent.fromJson(const {
        'type': 'agent_archived',
        'payload': {
          'agentId': 'agent-1',
          'archivedAt': '2026-07-28T00:00:00.000Z',
          'requestId': 'archive-1',
        },
      }),
      isA<AgentArchivedDirectoryEvent>(),
    );
  });

  test('decodes workspace and project updates through typed codecs', () {
    final workspace = DirectoryUpdateEvent.fromJson({
      'type': 'workspace_update',
      'payload': {'kind': 'upsert', 'workspace': _workspace('workspace-1')},
    });
    expect(
      (workspace as WorkspaceDirectoryEvent).update,
      isA<WorkspaceUpsertUpdate>(),
    );

    final project = DirectoryUpdateEvent.fromJson(const {
      'type': 'project.update',
      'payload': {'kind': 'remove', 'projectId': 'project-1'},
    });
    expect(
      (project as ProjectDirectoryEvent).update,
      isA<ProjectRemoveUpdate>(),
    );
    expect(
      (DirectoryUpdateEvent.fromJson(const {
                'type': 'workspace_update',
                'payload': {'kind': 'remove', 'id': 'workspace-1'},
              })
              as WorkspaceDirectoryEvent)
          .update,
      isA<WorkspaceRemoveUpdate>(),
    );
    expect(
      (DirectoryUpdateEvent.fromJson(const {
                'type': 'project.update',
                'payload': {
                  'kind': 'upsert',
                  'project': {
                    'projectId': 'project-1',
                    'projectDisplayName': 'Project',
                    'projectRootPath': '/repo',
                    'projectKind': 'git',
                  },
                },
              })
              as ProjectDirectoryEvent)
          .update,
      isA<ProjectUpsertUpdate>(),
    );
  });

  test('rejects malformed directory update boundaries', () {
    for (final json in <Map<String, Object?>>[
      const {'type': 'unknown', 'payload': <String, Object?>{}},
      const {
        'type': 'agent_update',
        'payload': {'kind': 'remove', 'agentId': ''},
      },
      const {
        'type': 'agent_archived',
        'payload': {'agentId': 'agent-1', 'archivedAt': 'now'},
      },
      const {
        'type': 'agent_update',
        'payload': {'kind': 'unknown'},
      },
      const {'type': 'agent_deleted', 'payload': 'bad'},
    ]) {
      expect(() => DirectoryUpdateEvent.fromJson(json), throwsFormatException);
    }
  });

  test('decodes every snapshot state and optional runtime field', () {
    final base = PaseoAgentSnapshotCodec.encode(_agent);
    for (final entry in const [
      ('initializing', AgentRunState.initializing),
      ('idle', AgentRunState.idle),
      ('running', AgentRunState.running),
      ('error', AgentRunState.error),
      ('closed', AgentRunState.closed),
    ]) {
      final decoded = PaseoAgentSnapshotCodec.decode({
        ...base,
        'status': entry.$1,
      });
      expect(decoded.runState, entry.$2);
    }

    final awaiting = PaseoAgentSnapshotCodec.decode({
      ...base,
      'status': 'running',
      'pendingPermissions': [
        {
          'id': 'permission-1',
          'provider': 'codex',
          'name': 'shell',
          'kind': 'tool',
          'detail': {'type': 'shell', 'command': 'pwd'},
        },
      ],
    });
    expect(awaiting.runState, AgentRunState.awaitingPermission);

    final enriched = PaseoAgentSnapshotCodec.decode({
      ...base,
      'model': null,
      'currentModeId': 'full-access',
      'persistence': null,
      'runtimeInfo': {
        'provider': 'codex',
        'sessionId': 'runtime-session',
        'model': 'runtime-model',
        'thinkingOptionId': 'high',
      },
      'features': [
        {
          'type': 'toggle',
          'id': 'web-search',
          'label': 'Web search',
          'value': true,
        },
      ],
      'lastUsage': {'inputTokens': 3, 'outputTokens': 2},
      'requiresAttention': true,
      'attentionReason': 'permission',
      'attentionTimestamp': '2026-07-28T00:00:00.000Z',
      'archivedAt': '2026-07-28T01:00:00.000Z',
      'lastUserMessageAt': '2026-07-28T00:30:00.000Z',
      'lastError': 'failed',
      'managedBy': {'kind': 'agent', 'agentId': 'parent-1'},
    });
    expect(enriched.model, 'runtime-model');
    expect(enriched.mode, AgentMode.fullAccess);
    expect(enriched.sessionId, 'runtime-session');
    expect(enriched.thinkingOptionId, 'high');
    expect(enriched.featureValues, {'web-search': true});
    expect(enriched.lastUsage?.inputTokens, 3);
    expect(enriched.parentAgentId, 'parent-1');
    expect(enriched.requiresAttention, isTrue);
    expect(enriched.attentionReason, AgentAttentionReason.permission);
    expect(enriched.archivedAt, isNotNull);
    expect(enriched.lastError, 'failed');
  });

  test('rejects malformed snapshot boundaries', () {
    final base = PaseoAgentSnapshotCodec.encode(_agent);
    for (final mutation in <Map<String, Object?>>[
      {'createdAt': 'not-a-date'},
      {'status': 'unknown'},
      {'pendingPermissions': 'bad'},
      {'labels': 'bad'},
      {
        'labels': {'bad': 1},
      },
      {'features': 'bad'},
      {
        'features': ['bad'],
      },
      {
        'features': [
          {'id': '', 'value': true},
        ],
      },
      {'requiresAttention': 'yes'},
      {'attentionReason': 1},
      {'attentionReason': 'unknown'},
      {'persistence': 'bad'},
    ]) {
      expect(
        () => PaseoAgentSnapshotCodec.decode({...base, ...mutation}),
        throwsFormatException,
      );
    }
  });
}

Map<String, Object?> _workspace(String id) => {
  'id': id,
  'projectId': 'project-1',
  'projectDisplayName': 'Project',
  'projectRootPath': '/repo',
  'workspaceDirectory': '/repo/$id',
  'projectKind': 'git',
  'workspaceKind': 'worktree',
  'name': id,
  'status': 'done',
  'activityAt': null,
  'scripts': <Object?>[],
};
