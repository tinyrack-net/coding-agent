import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';

/// Adapts older test doubles that implement only the legacy list request.
///
/// Production code never mixes this in; it lets unrelated widget fixtures
/// keep supplying deterministic agent snapshots while the app uses the native
/// Paseo `fetch_agents_request` API.
mixin LegacyAgentListFetchMixin on DaemonClient {
  @override
  Future<FetchAgentsResponse> fetchAgents({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    bool subscribe = false,
    String? subscriptionId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await request(
      MessageTypes.agentListRequest,
      const {},
      timeout: timeout,
    );
    final rawAgents = response['agents'];
    final agents = rawAgents is List
        ? rawAgents
              .whereType<Map>()
              .map(
                (json) =>
                    AgentSummary.fromJson(Map<String, Object?>.from(json)),
              )
              .toList()
        : const <AgentSummary>[];
    return FetchAgentsResponse(
      requestId: 'legacy-test-fixture',
      subscriptionId: subscribe
          ? (subscriptionId ?? 'legacy-test-subscription')
          : null,
      entries: [
        for (final agent in agents)
          AgentDirectoryEntry(
            agent: agent,
            project: {
              'projectKey': agent.projectPath ?? agent.cwd,
              'projectName': agent.projectPath ?? agent.cwd,
              'workspaceName': agent.branch,
              'checkout': {
                'cwd': agent.cwd,
                'isGit': agent.branch != null || agent.isWorktree,
                'currentBranch': agent.branch,
                'remoteUrl': null,
                'worktreeRoot': agent.isWorktree ? agent.cwd : null,
                'isPaseoOwnedWorktree': agent.isWorktree,
                'mainRepoRoot': agent.isWorktree ? agent.projectPath : null,
              },
            },
          ),
      ],
      pageInfo: const AgentDirectoryPageInfo(
        nextCursor: null,
        prevCursor: null,
        hasMore: false,
      ),
    );
  }
}
