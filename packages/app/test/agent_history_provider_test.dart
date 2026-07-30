import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agent_history_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history batch keeps successful hosts and forwards cursors', () async {
    final good = _HistoryClient([
      _page(
        agentId: 'older',
        updatedAt: '2026-07-28T00:00:00.000Z',
        nextCursor: 'next-a',
        hasMore: true,
      ),
    ]);
    final failed = _HistoryClient(const [], fail: true);

    final page = await fetchAgentHistoryBatch([
      AgentHistoryHost(
        serverId: 'server-a',
        serverLabel: 'Local',
        client: good,
      ),
      AgentHistoryHost(
        serverId: 'server-b',
        serverLabel: 'Remote',
        client: failed,
      ),
    ]);
    expect(page.entries.single.agent.agentId, 'older');
    expect(page.entries.single.serverLabel, 'Local');
    expect(page.entries.single.pendingPermissionCount, 2);
    expect(page.nextCursorByServerId, {'server-a': 'next-a'});
    expect(page.failedServerIds, {'server-b'});
    expect(good.cursors, [null]);

    final next = await fetchAgentHistoryBatch(
      [
        AgentHistoryHost(
          serverId: 'server-a',
          serverLabel: 'Local',
          client: good..pages.add(_page(agentId: 'next')),
        ),
        AgentHistoryHost(
          serverId: 'server-b',
          serverLabel: 'Remote',
          client: failed,
        ),
      ],
      cursorByServerId: const {'server-a': 'next-a'},
    );
    expect(next.entries.single.agent.agentId, 'next');
    expect(next.failedServerIds, isEmpty);
    expect(good.cursors, [null, 'next-a']);
  });

  test('history batch fails only when every selected host fails', () async {
    await expectLater(
      fetchAgentHistoryBatch([
        AgentHistoryHost(
          serverId: 'server-a',
          serverLabel: 'Local',
          client: _HistoryClient(const [], fail: true),
        ),
      ]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'No connected hosts could load agent history',
        ),
      ),
    );
  });

  test('history batch is stable for no hosts and deterministic ties', () async {
    expect((await fetchAgentHistoryBatch(const [])).entries, isEmpty);

    final clientA = _HistoryClient([
      _page(agentId: 'z', updatedAt: 'not-a-date'),
    ]);
    final clientB = _HistoryClient([
      _page(agentId: 'a', updatedAt: 'not-a-date'),
    ]);
    final page = await fetchAgentHistoryBatch([
      AgentHistoryHost(serverId: 'server-b', serverLabel: 'B', client: clientB),
      AgentHistoryHost(serverId: 'server-a', serverLabel: 'A', client: clientA),
    ]);

    expect(page.entries.map((entry) => entry.serverId), [
      'server-a',
      'server-b',
    ]);
    expect(
      page.entries.first.activityAt,
      DateTime.fromMillisecondsSinceEpoch(1),
    );
    final copied = page.copyWith(loadingMore: true);
    expect(copied.entries, same(page.entries));
    expect(copied.nextCursorByServerId, same(page.nextCursorByServerId));
    expect(copied.failedServerIds, same(page.failedServerIds));
    expect(copied.loadingMore, isTrue);
  });

  test('notifier reloads and merges pages without duplicate agents', () async {
    final client = _HistoryClient([
      _page(
        agentId: 'first',
        updatedAt: '2026-07-28T01:00:00.000Z',
        nextCursor: 'next',
        hasMore: true,
      ),
      _page(
        agentId: 'first',
        updatedAt: '2026-07-28T02:00:00.000Z',
        nextCursor: 'last',
        hasMore: true,
      ),
      _page(agentId: 'second'),
    ]);
    final container = _historyContainer(client);
    addTearDown(container.dispose);

    final initial = await container.read(agentHistoryProvider.future);
    expect(initial.entries.single.agent.agentId, 'first');
    expect(initial.hasMore, isTrue);

    await container.read(agentHistoryProvider.notifier).loadMore();
    final merged = container.read(agentHistoryProvider).requireValue;
    expect(merged.entries, hasLength(1));
    expect(merged.entries.single.agent.updatedAt, '2026-07-28T02:00:00.000Z');
    expect(merged.loadingMore, isFalse);

    await container.read(agentHistoryProvider.notifier).reload();
    expect(
      container
          .read(agentHistoryProvider)
          .requireValue
          .entries
          .single
          .agent
          .agentId,
      'second',
    );
  });

  test(
    'load-more guards and failure preserve already loaded history',
    () async {
      final client = _HistoryClient([
        _page(agentId: 'first', nextCursor: 'next', hasMore: true),
      ]);
      final container = _historyContainer(client);
      addTearDown(container.dispose);

      final initial = await container.read(agentHistoryProvider.future);
      client.fail = true;
      await container.read(agentHistoryProvider.notifier).loadMore();
      final afterFailure = container.read(agentHistoryProvider).requireValue;
      expect(afterFailure.entries, initial.entries);
      expect(afterFailure.loadingMore, isFalse);

      container.read(agentHistoryProvider.notifier).state = const AsyncData(
        AgentHistoryState(loadingMore: true),
      );
      await container.read(agentHistoryProvider.notifier).loadMore();
      container.read(agentHistoryProvider.notifier).state = const AsyncData(
        AgentHistoryState(),
      );
      await container.read(agentHistoryProvider.notifier).loadMore();
      expect(client.cursors, [null, 'next']);
    },
  );

  test('notifier returns an empty state when no host is connected', () async {
    final container = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(_HistoryRegistry.new),
        hostRuntimeClientsProvider.overrideWithValue(const {}),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(agentHistoryProvider.future)).entries,
      isEmpty,
    );
  });

  test(
    'manual refresh preserves visible history when its host fails',
    () async {
      final client = _HistoryClient([_page(agentId: 'visible')]);
      final container = _historyContainer(client);
      addTearDown(container.dispose);

      final initial = await container.read(agentHistoryProvider.future);
      client.fail = true;
      await container
          .read(agentHistoryProvider.notifier)
          .refreshPreservingData();

      final refreshed = container.read(agentHistoryProvider).requireValue;
      expect(refreshed.entries, initial.entries);
      expect(refreshed.failedServerIds, {'server-a'});
    },
  );

  test(
    'host-scoped refresh replaces only that host and preserves cursors',
    () async {
      final first = _HistoryClient([
        _page(agentId: 'a-before', nextCursor: 'a-next', hasMore: true),
        _page(agentId: 'a-after'),
      ]);
      final second = _HistoryClient([
        _page(agentId: 'b-stays', nextCursor: 'b-next', hasMore: true),
      ]);
      final container = ProviderContainer(
        overrides: [
          hostRegistryProvider.overrideWith(_TwoHistoryRegistry.new),
          hostRuntimeClientsProvider.overrideWithValue({
            'server-a': first,
            'server-b': second,
          }),
          hostConnectionStateProvider.overrideWith(
            (ref, serverId) => Stream.value(DaemonConnectionState.connected),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(agentHistoryProvider.future);
      await container
          .read(agentHistoryProvider.notifier)
          .refreshPreservingData(serverId: 'server-a');

      final refreshed = container.read(agentHistoryProvider).requireValue;
      expect(refreshed.entries.map((entry) => entry.agent.agentId).toSet(), {
        'a-after',
        'b-stays',
      });
      expect(refreshed.nextCursorByServerId, {'server-b': 'b-next'});
      expect(first.cursors, [null, null]);
      expect(second.cursors, [null]);
    },
  );
}

final class _HistoryClient extends DaemonClient {
  _HistoryClient(List<FetchAgentHistoryResponse> pages, {this.fail = false})
    : pages = [...pages],
      super(uri: Uri.parse('ws://history-test'));

  final List<FetchAgentHistoryResponse> pages;
  bool fail;
  final List<String?> cursors = [];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<FetchAgentHistoryResponse> fetchAgentHistory({
    AgentDirectoryFilter? filter,
    List<AgentDirectorySort> sort = const [],
    int limit = 200,
    String? cursor,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    cursors.add(cursor);
    if (fail) throw StateError('offline');
    return pages.removeAt(0);
  }
}

ProviderContainer _historyContainer(_HistoryClient client) => ProviderContainer(
  overrides: [
    hostRegistryProvider.overrideWith(_HistoryRegistry.new),
    hostRuntimeClientsProvider.overrideWithValue({'server-a': client}),
    hostConnectionStateProvider.overrideWith(
      (ref, serverId) => Stream.value(DaemonConnectionState.connected),
    ),
  ],
);

final class _HistoryRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      HostProfile(
        serverId: 'server-a',
        label: 'Local',
        connections: const [
          DirectTcpHostConnection(
            id: 'direct:localhost:6868',
            endpoint: 'localhost:6868',
          ),
        ],
        preferredConnectionId: 'direct:localhost:6868',
        createdAt: '2026-07-28T00:00:00.000Z',
        updatedAt: '2026-07-28T00:00:00.000Z',
      ),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

final class _TwoHistoryRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      _historyHost('server-a', 'Local', 'localhost:6868'),
      _historyHost('server-b', 'Remote', 'remote.example:6868'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

HostProfile _historyHost(String id, String label, String endpoint) =>
    HostProfile(
      serverId: id,
      label: label,
      connections: [
        DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
      ],
      preferredConnectionId: 'direct:$endpoint',
      createdAt: '2026-07-28T00:00:00.000Z',
      updatedAt: '2026-07-28T00:00:00.000Z',
    );

FetchAgentHistoryResponse _page({
  String agentId = 'agent',
  String updatedAt = '2026-07-28T01:00:00.000Z',
  String? nextCursor,
  bool hasMore = false,
}) => FetchAgentHistoryResponse(
  requestId: 'history',
  entries: [
    AgentDirectoryEntry(
      agent: AgentSummary(
        agentId: agentId,
        title: agentId,
        cwd: '/repo',
        provider: 'codex',
        model: 'gpt-5',
        mode: AgentMode.normal,
        runState: AgentRunState.closed,
        createdAtMs: 1,
        updatedAt: updatedAt,
        archivedAt: '2026-07-28T00:00:00.000Z',
      ),
      project: const {'projectKey': '/repo'},
      pendingPermissions: const [
        {'id': 'permission-1'},
        {'id': 'permission-2'},
      ],
    ),
  ],
  pageInfo: AgentDirectoryPageInfo(
    nextCursor: nextCursor,
    prevCursor: null,
    hasMore: hasMore,
  ),
);
