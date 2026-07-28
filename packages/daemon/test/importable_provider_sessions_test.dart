import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/server/importable_provider_sessions.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

final class _ImportableClient implements AgentClient, ImportableAgentClient {
  _ImportableClient(this.sessions);

  final List<ImportableProviderSession> sessions;
  ListImportableSessionsOptions? options;
  Object? error;

  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async {
    this.options = options;
    if (error case final error?) throw error;
    return sessions;
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) => throw UnimplementedError();
}

PersistedAgent _agent({
  required String id,
  required String provider,
  required String handle,
  required bool archived,
}) => PersistedAgent(
  summary: AgentSummary(
    agentId: id,
    title: id,
    cwd: '/repo',
    provider: provider,
    model: 'model',
    mode: AgentMode.normal,
    runState: archived ? AgentRunState.closed : AgentRunState.idle,
    createdAtMs: 1,
    sessionId: handle,
    archivedAt: archived ? '2026-07-01T00:00:00.000Z' : null,
  ),
  archived: archived,
  epoch: 1,
  lastSeq: 0,
  items: const [],
);

ImportableProviderSession _session(
  String handle,
  String prompt,
  String timestamp, {
  String cwd = '/repo',
}) => ImportableProviderSession(
  providerHandleId: handle,
  cwd: cwd,
  title: prompt,
  firstPromptPreview: prompt,
  lastPromptPreview: prompt,
  lastActivityAt: DateTime.parse(timestamp),
);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('importable_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('filters, sorts, limits, labels, and excludes active imports', () async {
    final store = AgentStore(dataDir: temp.path, debounce: Duration.zero);
    await store.save(
      _agent(
        id: 'active',
        provider: 'claude',
        handle: 'already-imported',
        archived: false,
      ),
    );
    await store.save(
      _agent(
        id: 'archived',
        provider: 'claude',
        handle: 'archived-import',
        archived: true,
      ),
    );
    final claude = _ImportableClient([
      _session(
        'metadata',
        '  Generate metadata for a coding agent based on the user prompt. x',
        '2026-07-28T05:00:00Z',
      ),
      _session('already-imported', 'active', '2026-07-28T04:00:00Z'),
      _session('older', 'older', '2026-07-28T02:00:00Z'),
      _session(
        'archived-import',
        'archived is importable',
        '2026-07-28T03:00:00Z',
      ),
      _session('too-old', 'too old', '2026-07-01T00:00:00Z'),
    ]);
    final manager = AgentManager(clients: {'claude': claude}, store: store);
    await manager.load();

    final result = await listImportableProviderSessions(
      request: const FetchRecentProviderSessionsRequest(
        requestId: 'request-1',
        cwd: '/repo',
        providers: ['claude'],
        since: '2026-07-28T02:00:00Z',
        limit: 2,
      ),
      manager: manager,
      providerLabel: (provider) => 'Claude Code',
    );

    expect(result.entries.map((entry) => entry.providerHandleId), [
      'archived-import',
      'older',
    ]);
    expect(result.entries.first.providerLabel, 'Claude Code');
    expect(result.filteredAlreadyImportedCount, 1);
    expect(claude.options?.limit, 3);
    expect(claude.options?.cwd, '/repo');
  });

  test('isolates unsupported and failing provider discovery', () async {
    final failing = _ImportableClient([])..error = StateError('missing');
    final manager = AgentManager(
      clients: {'claude': failing, 'plain': _PlainClient()},
      store: AgentStore(dataDir: temp.path),
    );

    final result = await listImportableProviderSessions(
      request: const FetchRecentProviderSessionsRequest(requestId: 'request-1'),
      manager: manager,
      providerLabel: (provider) => provider,
    );

    expect(result.entries, isEmpty);
    expect(result.filteredAlreadyImportedCount, 0);
  });

  test('rejects invalid since with the frozen rpc error', () async {
    final manager = AgentManager(
      clients: const {},
      store: AgentStore(dataDir: temp.path),
    );

    expect(
      () => listImportableProviderSessions(
        request: const FetchRecentProviderSessionsRequest(
          requestId: 'request-1',
          since: 'not-a-date',
        ),
        manager: manager,
        providerLabel: (provider) => provider,
      ),
      throwsA(
        isA<ImportSessionsRequestException>()
            .having((error) => error.code, 'code', 'invalid_since')
            .having(
              (error) => error.message,
              'message',
              'Invalid recent provider sessions since',
            ),
      ),
    );
  });
}

final class _PlainClient implements AgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) => throw UnimplementedError();
}
