import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agent = AgentSummary(
  agentId: 'agent-1',
  title: 'Agent',
  cwd: '/repo',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1000,
);

void main() {
  test(
    'fetch request round trips frozen filter sort page and subscription',
    () {
      const request = FetchAgentsRequest(
        requestId: 'request-1',
        activeScope: true,
        filter: AgentDirectoryFilter(
          labels: {'team': 'core'},
          projectKeys: ['project-1'],
          statuses: ['idle', 'running'],
          includeArchived: false,
          requiresAttention: true,
          thinkingOptionId: null,
          hasThinkingOptionId: true,
        ),
        sort: [
          AgentDirectorySort(
            key: AgentDirectorySortKey.updatedAt,
            direction: AgentDirectorySortDirection.desc,
          ),
        ],
        limit: 200,
        cursor: '200',
        hasSubscription: true,
        subscriptionId: 'subscription-1',
      );
      final json = request.toJson();
      expect(json, {
        'type': 'fetch_agents_request',
        'requestId': 'request-1',
        'scope': 'active',
        'filter': {
          'labels': {'team': 'core'},
          'projectKeys': ['project-1'],
          'statuses': ['idle', 'running'],
          'includeArchived': false,
          'requiresAttention': true,
          'thinkingOptionId': null,
        },
        'sort': [
          {'key': 'updated_at', 'direction': 'desc'},
        ],
        'page': {'limit': 200, 'cursor': '200'},
        'subscribe': {'subscriptionId': 'subscription-1'},
      });
      final decoded = FetchAgentsRequest.fromJson(json);
      expect(decoded.activeScope, isTrue);
      expect(decoded.filter?.labels, {'team': 'core'});
      expect(decoded.filter?.hasThinkingOptionId, isTrue);
      expect(decoded.sort.single.key, AgentDirectorySortKey.updatedAt);
      expect(decoded.limit, 200);
      expect(decoded.cursor, '200');
      expect(decoded.subscriptionId, 'subscription-1');
    },
  );

  test('minimal fetch request preserves an empty subscribe object', () {
    const request = FetchAgentsRequest(
      requestId: 'request-1',
      hasSubscription: true,
    );
    expect(request.toJson(), {
      'type': 'fetch_agents_request',
      'requestId': 'request-1',
      'subscribe': <String, Object?>{},
    });
    final decoded = FetchAgentsRequest.fromJson(request.toJson());
    expect(decoded.hasSubscription, isTrue);
    expect(decoded.filter, isNull);
    expect(decoded.sort, isEmpty);
    expect(decoded.limit, isNull);
  });

  test('history request and response round trip the frozen envelopes', () {
    const request = FetchAgentHistoryRequest(
      requestId: 'history-1',
      filter: AgentDirectoryFilter(statuses: ['closed'], includeArchived: true),
      sort: [
        AgentDirectorySort(
          key: AgentDirectorySortKey.updatedAt,
          direction: AgentDirectorySortDirection.desc,
        ),
      ],
      limit: 25,
      cursor: 'cursor-1',
    );
    expect(FetchAgentHistoryRequest.fromJson(request.toJson()).toJson(), {
      'type': 'fetch_agent_history_request',
      'requestId': 'history-1',
      'filter': {
        'statuses': ['closed'],
        'includeArchived': true,
      },
      'sort': [
        {'key': 'updated_at', 'direction': 'desc'},
      ],
      'page': {'limit': 25, 'cursor': 'cursor-1'},
    });

    const archived = AgentSummary(
      agentId: 'archived-1',
      title: 'Archived',
      cwd: '/repo',
      provider: 'codex',
      model: 'gpt-5',
      mode: AgentMode.normal,
      runState: AgentRunState.closed,
      createdAtMs: 1000,
      archivedAt: '2026-07-28T00:00:00.000Z',
    );
    const response = FetchAgentHistoryResponse(
      requestId: 'history-1',
      entries: [
        AgentDirectoryEntry(agent: archived, project: {'projectKey': '/repo'}),
      ],
      pageInfo: AgentDirectoryPageInfo(
        nextCursor: null,
        prevCursor: 'cursor-1',
        hasMore: false,
      ),
    );
    final decoded = FetchAgentHistoryResponse.fromJson(response.toJson());
    expect(decoded.entries.single.agent.runState, AgentRunState.closed);
    expect(decoded.entries.single.agent.archivedAt, isNotNull);
    expect(decoded.toJson(), response.toJson());
  });

  test('single-agent request and response round trip frozen envelopes', () {
    const request = FetchAgentRequest(
      requestId: 'detail-1',
      agentId: 'Agent title',
    );
    expect(FetchAgentRequest.fromJson(request.toJson()).toJson(), {
      'type': 'fetch_agent_request',
      'requestId': 'detail-1',
      'agentId': 'Agent title',
    });

    const response = FetchAgentResponse(
      requestId: 'detail-1',
      agent: _agent,
      project: {'projectKey': '/repo'},
      error: null,
    );
    final decoded = FetchAgentResponse.fromJson(response.toJson());
    expect(decoded.agent?.agentId, 'agent-1');
    expect(decoded.project, {'projectKey': '/repo'});
    expect(decoded.error, isNull);
    expect(decoded.toJson(), response.toJson());

    final missing = FetchAgentResponse.fromJson({
      'type': 'fetch_agent_response',
      'payload': {
        'requestId': 'detail-2',
        'agent': null,
        'error': 'Agent not found: missing',
      },
    });
    expect(missing.agent, isNull);
    expect(missing.project, isNull);
    expect(missing.error, 'Agent not found: missing');
    expect(
      () => FetchAgentResponse.fromJson({
        'type': 'fetch_agent_response',
        'payload': {'requestId': 'detail-3', 'error': null},
      }),
      throwsFormatException,
    );
    expect(
      () => FetchAgentResponse.fromJson({
        'type': 'fetch_agent_response',
        'payload': {'requestId': 'detail-4', 'agent': null},
      }),
      throwsFormatException,
    );
  });

  test('response round trips entries, subscription, and page cursors', () {
    const response = FetchAgentsResponse(
      requestId: 'request-1',
      subscriptionId: 'subscription-1',
      entries: [
        AgentDirectoryEntry(
          agent: _agent,
          pendingPermissions: [
            {
              'id': 'permission-1',
              'provider': 'codex',
              'name': 'Bash',
              'kind': 'tool',
              'description': 'Run tests',
            },
          ],
          project: {
            'projectKey': 'project-1',
            'projectName': 'Repo',
            'workspaceName': null,
            'checkout': {
              'cwd': '/repo',
              'isGit': false,
              'currentBranch': null,
              'remoteUrl': null,
              'worktreeRoot': null,
              'isPaseoOwnedWorktree': false,
              'mainRepoRoot': null,
            },
          },
        ),
      ],
      pageInfo: AgentDirectoryPageInfo(
        nextCursor: '200',
        prevCursor: null,
        hasMore: true,
      ),
    );
    final decoded = FetchAgentsResponse.fromJson(response.toJson());
    expect(decoded.requestId, 'request-1');
    expect(decoded.subscriptionId, 'subscription-1');
    expect(decoded.entries.single.agent.agentId, 'agent-1');
    expect(decoded.entries.single.project['projectKey'], 'project-1');
    expect(decoded.entries.single.pendingPermissions, [
      {
        'id': 'permission-1',
        'provider': 'codex',
        'name': 'Bash',
        'kind': 'tool',
        'description': 'Run tests',
      },
    ]);
    expect(decoded.pageInfo.nextCursor, '200');
    expect(decoded.pageInfo.hasMore, isTrue);
    expect(decoded.toJson(), response.toJson());
  });

  test('rejects malformed request and response boundaries', () {
    for (final json in <Map<String, Object?>>[
      const {'type': 'wrong', 'requestId': 'request'},
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'scope': 'all',
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'page': {'limit': 0},
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'page': {'limit': 201},
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'page': {'limit': 1, 'cursor': ''},
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'sort': [
          {'key': 'bad', 'direction': 'asc'},
        ],
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'filter': {'labels': 'bad'},
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'filter': {
          'projectKeys': [1],
        },
      },
      const {
        'type': 'fetch_agents_request',
        'requestId': 'request',
        'filter': {
          'statuses': ['waiting'],
        },
      },
      const {
        'type': 'fetch_agents_response',
        'payload': {
          'requestId': 'request',
          'entries': 'bad',
          'pageInfo': {
            'nextCursor': null,
            'prevCursor': null,
            'hasMore': false,
          },
        },
      },
    ]) {
      expect(
        () => json['type'] == FetchAgentsResponse.type
            ? FetchAgentsResponse.fromJson(json)
            : FetchAgentsRequest.fromJson(json),
        throwsFormatException,
      );
    }
  });
}
