import 'dart:io';

import 'package:agent_daemon/src/server/daemon_diagnostics.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('daemon-diagnostics-test-');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  test('collects deterministic product and runtime sections', () async {
    File(
      '${home.path}${Platform.pathSeparator}daemon.log',
    ).writeAsStringSync('normal line\nAuthorization: bearer-secret\n');
    final diagnostic = await collectDaemonDiagnostics(
      _options(
        home,
        listAgents: () => [_agent()],
        listProjects: () async => [_project()],
        listWorkspaces: () async => [_workspace()],
        listProviders: () async => const [
          ProviderAvailabilityV2(provider: 'codex', available: true),
          ProviderAvailabilityV2(
            provider: 'claude',
            available: false,
            error: 'missing',
          ),
        ],
        webSocketRuntime: _runtimeSnapshot,
      ),
    );

    expect(diagnostic, startsWith('Tinyrack diagnostics'));
    expect(diagnostic, contains('Server ID: server-1'));
    expect(diagnostic, contains('By provider: codex=1'));
    expect(diagnostic, contains('Projects: 1 active / 1 total'));
    expect(diagnostic, contains('Free: 1.0 MiB / 2.0 MiB'));
    expect(diagnostic, contains('Workspaces by kind: worktree=1'));
    expect(diagnostic, contains('Available: 1'));
    expect(diagnostic, contains('Unavailable: claude (missing)'));
    expect(
      diagnostic,
      contains('Sessions: active=2, externalKeys=1, reconnectGrace=0'),
    );
    expect(
      diagnostic,
      contains(
        'Latency: diagnostics.request count=2 p50=4ms max=7ms total=11ms',
      ),
    );
    expect(
      diagnostic,
      contains('Inbound session requests: diagnostics.request=2'),
    );
    expect(diagnostic, contains('git: git version test'));
    expect(diagnostic, contains('normal line'));
    expect(diagnostic, contains('Authorization: [redacted]'));
    expect(diagnostic, isNot(contains('bearer-secret')));
    expect(diagnostic, isNot(contains('127.0.0.1:6868')));
    expect(diagnostic, isNot(contains('relay.example.test:443')));
  });

  test('isolates section, tool, and missing log failures', () async {
    final logs = <String>[];
    final diagnostic = await collectDaemonDiagnostics(
      _options(
        home,
        listProviders: () => Future.error(StateError('catalog failed')),
        webSocketRuntime: () => const {},
        runTool: (_, __) => Future.error(StateError('missing tool')),
        log: logs.add,
      ),
    );

    expect(diagnostic, contains('Providers\n  Error:'));
    expect(
      diagnostic,
      contains('Status: no runtime metrics window has been flushed yet'),
    );
    expect(diagnostic, contains('git: error:'));
    expect(diagnostic, contains('Daemon log tail'));
    expect(diagnostic, contains('Error:'));
    expect(logs, hasLength(2));
  });

  test('redacts deep links, query secrets, assignments, and endpoints', () {
    final redacted = redactDiagnostic(
      'coding-agent://pair?token=value\n'
      'url=https://host/path?secret=hidden&ok=1\n'
      'api_key = "api-value"\n'
      'Authorization: Bearer-value\n'
      'listen=10.0.0.1:6868 relay.example:443 public.example:443',
      listen: '10.0.0.1:6868',
      relayEndpoint: 'relay.example:443',
      relayPublicEndpoint: 'public.example:443',
    );
    expect(redacted, isNot(contains('value')));
    expect(redacted, isNot(contains('hidden')));
    expect(redacted, isNot(contains('api-value')));
    expect(redacted, isNot(contains('Bearer-value')));
    expect('[redacted]'.allMatches(redacted).length, greaterThanOrEqualTo(6));
  });
}

DaemonDiagnosticsOptions _options(
  Directory home, {
  List<AgentSummary> Function()? listAgents,
  Future<List<PersistedProjectRecord>> Function()? listProjects,
  Future<List<PersistedWorkspaceRecord>> Function()? listWorkspaces,
  Future<List<ProviderAvailabilityV2>> Function()? listProviders,
  Map<String, Object?> Function()? webSocketRuntime,
  DiagnosticToolRunner? runTool,
  DiagnosticDiskStatsReader? readDiskStats,
  void Function(String)? log,
}) => DaemonDiagnosticsOptions(
  home: home.path,
  serverId: 'server-1',
  daemonVersion: '0.2.0',
  listen: '127.0.0.1:6868',
  relayEnabled: true,
  relayEndpoint: 'relay.example.test:443',
  relayPublicEndpoint: 'relay.example.test:443',
  relayUseTls: true,
  relayPublicUseTls: true,
  startedAt: DateTime.utc(2026, 7, 27, 0, 0),
  now: () => DateTime.utc(2026, 7, 27, 1, 2, 3),
  environment: const {'Path': r'C:\tools', 'ComSpec': r'C:\cmd.exe'},
  listAgents: listAgents ?? () => const [],
  listProjects: listProjects ?? () async => const [],
  listWorkspaces: listWorkspaces ?? () async => const [],
  listProviders: listProviders ?? () async => const [],
  webSocketRuntime: webSocketRuntime ?? () => const {},
  runTool:
      runTool ??
      (executable, arguments) async =>
          ProcessResult(1, 0, '$executable version test', ''),
  readDiskStats:
      readDiskStats ??
      (_) async => (freeBytes: 1024 * 1024, totalBytes: 2 * 1024 * 1024),
  log: log,
);

Map<String, Object?> _runtimeSnapshot() => {
  'collectedAt': '2026-07-27T01:00:00.000Z',
  'windowMs': 60000,
  'uptimeSeconds': 120,
  'final': false,
  'sessions': {
    'activeConnections': 2,
    'externalSessionKeys': 1,
    'reconnectGraceSessions': 0,
  },
  'sockets': {'activeSockets': 2, 'pendingConnections': 0},
  'memory': {
    'rss': 1024,
    'heapUsed': 2048,
    'heapTotal': 4096,
    'external': 512,
    'arrayBuffers': 256,
  },
  'runtime': {
    'inflightRequests': 1,
    'peakInflightRequests': 3,
    'terminalSubscriptionCount': 2,
    'terminalDirectorySubscriptionCount': 1,
    'checkoutDiffTargetCount': 1,
    'checkoutDiffSubscriptionCount': 1,
    'checkoutDiffWatcherCount': 1,
    'checkoutDiffFallbackRefreshTargetCount': 0,
  },
  'bufferedAmount': {'p95': 128, 'max': 256},
  'eventLoopDelay': {'p50Ms': 1, 'p99Ms': 3, 'maxMs': 5},
  'latency': [
    {
      'type': 'diagnostics.request',
      'count': 2,
      'minMs': 4,
      'maxMs': 7,
      'p50Ms': 4,
      'totalMs': 11,
    },
  ],
  'inboundMessageTypesTop': [
    ['session', 2],
  ],
  'inboundSessionRequestTypesTop': [
    ['diagnostics.request', 2],
  ],
  'outboundMessageTypesTop': [
    ['session_message', 2],
  ],
  'outboundSessionMessageTypesTop': [
    ['diagnostics.response', 2],
  ],
  'outboundAgentStreamTypesTop': const <Object>[],
  'outboundAgentStreamAgentsTop': const <Object>[],
  'outboundBinaryFrameTypesTop': const <Object>[],
  'counters': {'helloNew': 2, 'validationFailed': 0},
  'agents': {
    'total': 1,
    'withActiveForegroundTurn': 1,
    'byLifecycle': {'active': 1},
    'timelineStats': {'totalItems': 5, 'maxItemsPerAgent': 5},
  },
};

AgentSummary _agent() => const AgentSummary(
  agentId: 'agent-1',
  title: 'Agent',
  cwd: r'C:\repo',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 1,
  requiresAttention: true,
  attentionReason: AgentAttentionReason.permission,
);

PersistedProjectRecord _project() => const PersistedProjectRecord(
  projectId: 'project-1',
  rootPath: r'C:\repo',
  kind: PersistedProjectKind.git,
  displayName: 'repo',
  customName: null,
  createdAt: '2026-07-27T00:00:00.000Z',
  updatedAt: '2026-07-27T00:00:00.000Z',
  archivedAt: null,
);

PersistedWorkspaceRecord _workspace() => const PersistedWorkspaceRecord(
  workspaceId: 'workspace-1',
  projectId: 'project-1',
  cwd: r'C:\repo-worktree',
  kind: PersistedWorkspaceKind.worktree,
  displayName: 'feature',
  title: null,
  branch: 'feature',
  worktreeRoot: r'C:\repo-worktree',
  baseBranch: 'main',
  isPaseoOwnedWorktree: true,
  mainRepoRoot: r'C:\repo',
  createdAt: '2026-07-27T00:00:00.000Z',
  updatedAt: '2026-07-27T00:00:00.000Z',
  archivedAt: null,
  pinnedAt: null,
);
