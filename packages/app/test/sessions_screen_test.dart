import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/screens/sessions_screen.dart';
import 'package:coding_agent_app/state/agent_history_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('session ordering is newest-first and stable for activity ties', () {
    final older = _entry(
      agentId: 'older',
      updatedAt: '2026-07-29T00:00:00.000Z',
    );
    final firstTie = _entry(
      agentId: 'first-tie',
      updatedAt: '2026-07-30T00:00:00.000Z',
    );
    final secondTie = _entry(
      agentId: 'second-tie',
      updatedAt: '2026-07-30T00:00:00.000Z',
    );

    expect(
      sortSessionsByLatestActivity([
        older,
        firstTie,
        secondTie,
      ]).map((entry) => entry.agent.agentId),
      ['first-tie', 'second-tie', 'older'],
    );
  });

  testWidgets('renders archived sessions and loads the next page', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(
        entries: [_entry()],
        nextCursorByServerId: const {'server-a': 'next'},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [agentHistoryProvider.overrideWith(() => notifier)],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Archived session'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Load more'), findsOneWidget);

    await tester.tap(find.text('Load more'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(notifier.loadMoreCount, 1);
  });

  testWidgets('empty state preserves the frozen sessions copy', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(const AgentHistoryState()),
          ),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
  });

  testWidgets('empty-state back navigates to the frozen open-project route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/sessions',
      routes: [
        GoRoute(path: '/sessions', builder: (_, _) => const SessionsScreen()),
        GoRoute(
          path: '/open-project',
          builder: (_, _) => const Text('Open project route'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(const AgentHistoryState()),
          ),
        ],
        child: FluentApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open project route'), findsOneWidget);
  });

  testWidgets('session press navigates to its host agent route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/sessions',
      routes: [
        GoRoute(path: '/sessions', builder: (_, _) => const SessionsScreen()),
        GoRoute(
          path: '/h/:serverId/agent/:agentId',
          builder: (_, state) => Text(
            'Agent ${state.pathParameters['serverId']}/'
            '${state.pathParameters['agentId']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(AgentHistoryState(entries: [_entry()])),
          ),
        ],
        child: FluentApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent-row-server-a-archived')));
    await tester.pumpAndSettle();
    expect(find.text('Agent server-a/archived'), findsOneWidget);
  });

  testWidgets('filters sessions by host and renders active fallback titles', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(
        entries: [
          _entry(),
          _entry(
            serverId: 'server-b',
            serverLabel: 'Remote',
            agentId: 'active-id',
            title: '',
            runState: AgentRunState.running,
          ),
        ],
        nextCursorByServerId: const {'server-b': 'next'},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_TwoHostRegistry.new),
          hostConnectionStateProvider.overrideWith(
            (ref, serverId) => Stream.value(DaemonConnectionState.connected),
          ),
          agentHistoryProvider.overrideWith(() => notifier),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Archived session'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('sessions-host-filter-trigger')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-filter-option-server-b')));
    await tester.pumpAndSettle();

    expect(find.text('Archived session'), findsNothing);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);
    await tester.tap(find.text('Load more'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(notifier.lastLoadMoreServerId, 'server-b');
  });

  testWidgets('shows the retry state and dispatches retry', (tester) async {
    final notifier = _ErrorHistoryNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [agentHistoryProvider.overrideWith(() => notifier)],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unable to load sessions'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(notifier.reloadCount, 1);
  });

  testWidgets('shows loading and disables load more while paging', (
    tester,
  ) async {
    final pending = _PendingHistoryNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [agentHistoryProvider.overrideWith(() => pending)],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pump();
    expect(find.byType(ProgressRing), findsOneWidget);

    pending.complete(
      AgentHistoryState(
        entries: [_entry()],
        nextCursorByServerId: const {'server-a': 'next'},
        loadingMore: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final button = tester.widget<Button>(find.byType(Button));
    expect(button.onPressed, isNull);
    expect(find.text('Loading...'), findsOneWidget);
    expect(find.byType(ProgressRing), findsNothing);
  });

  testWidgets('long press archives a non-running session immediately', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(
        entries: [_entry(runState: AgentRunState.idle, archived: false)],
      ),
    );
    final client = _ArchiveClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(() => notifier),
          hostRuntimeClientsProvider.overrideWithValue({'server-a': client}),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('agent-row-server-a-archived')),
    );
    await tester.pumpAndSettle();

    expect(client.requests.single.$1, MessageTypes.agentArchiveRequest);
    expect(client.requests.single.$2, {'agentId': 'archived'});
    expect(notifier.reloadCount, 1);
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('offline long press shows a disabled host-offline sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(
              AgentHistoryState(
                entries: [
                  _entry(runState: AgentRunState.idle, archived: false),
                ],
              ),
            ),
          ),
          hostRuntimeClientsProvider.overrideWithValue(const {}),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('agent-row-server-a-archived')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Host offline'), findsOneWidget);
    final archive = tester.widget<FilledButton>(
      find.byKey(const ValueKey('agent-action-archive')),
    );
    expect(archive.onPressed, isNull);
  });

  testWidgets('running session requires confirmation before archive', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(
        entries: [_entry(runState: AgentRunState.running, archived: false)],
      ),
    );
    final client = _ArchiveClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentHistoryProvider.overrideWith(() => notifier),
          hostRuntimeClientsProvider.overrideWithValue({'server-a': client}),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('agent-row-server-a-archived')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This agent is still running. Archiving it will stop the agent.',
      ),
      findsOneWidget,
    );
    expect(client.requests, isEmpty);

    await tester.tap(find.byKey(const ValueKey('agent-action-archive')));
    await tester.pumpAndSettle();
    expect(client.requests.single.$1, MessageTypes.agentArchiveRequest);
    expect(notifier.reloadCount, 1);
  });

  testWidgets('pull refresh preserves the list and dispatches manual refresh', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(entries: [_entry(attention: true)]),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [agentHistoryProvider.overrideWith(() => notifier)],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived session'), findsOneWidget);
    expect(find.text('Attention'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(notifier.refreshCount, 1);
    expect(find.text('Archived session'), findsOneWidget);
  });

  testWidgets('selected-host failure renders retry instead of empty state', (
    tester,
  ) async {
    final notifier = _HistoryNotifier(
      AgentHistoryState(
        entries: [_entry()],
        failedServerIds: const {'server-b'},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_TwoHostRegistry.new),
          hostConnectionStateProvider.overrideWith(
            (ref, serverId) => Stream.value(DaemonConnectionState.connected),
          ),
          agentHistoryProvider.overrideWith(() => notifier),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('sessions-host-filter-trigger')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-filter-option-server-b')));
    await tester.pumpAndSettle();

    expect(find.text('Unable to load sessions'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('No sessions for this host'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(notifier.lastRefreshServerId, 'server-b');
  });

  testWidgets('removed host selection resets permanently to all hosts', (
    tester,
  ) async {
    late _MutableHostRegistry registry;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(
            () => registry = _MutableHostRegistry(),
          ),
          hostConnectionStateProvider.overrideWith(
            (ref, serverId) => Stream.value(DaemonConnectionState.connected),
          ),
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(
              AgentHistoryState(
                entries: [
                  _entry(),
                  _entry(
                    serverId: 'server-b',
                    serverLabel: 'Remote',
                    agentId: 'remote',
                  ),
                ],
              ),
            ),
          ),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('sessions-host-filter-trigger')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-filter-option-server-b')));
    await tester.pumpAndSettle();
    expect(find.text('Archived session'), findsOneWidget);

    registry.removeRemote();
    await tester.pumpAndSettle();
    registry.restoreRemote();
    await tester.pumpAndSettle();

    expect(find.text('All hosts'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-row-server-a-archived')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('agent-row-server-b-remote')),
      findsOneWidget,
    );
  });

  testWidgets('compact host filter keeps frozen 12px inset and 32px height', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_TwoHostRegistry.new),
          hostConnectionStateProvider.overrideWith(
            (ref, serverId) => Stream.value(DaemonConnectionState.connected),
          ),
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(AgentHistoryState(entries: [_entry()])),
          ),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final trigger = tester.getRect(
      find.byKey(const ValueKey('sessions-host-filter-trigger')),
    );
    expect(trigger.left, 12);
    expect(trigger.height, 32);
  });
}

final class _HistoryNotifier extends AgentHistoryNotifier {
  _HistoryNotifier(this.initial);

  final AgentHistoryState initial;
  int loadMoreCount = 0;
  int reloadCount = 0;
  int refreshCount = 0;
  String? lastRefreshServerId;
  String? lastLoadMoreServerId;

  @override
  Future<AgentHistoryState> build() async => initial;

  @override
  Future<void> loadMore({String? serverId}) async {
    loadMoreCount++;
    lastLoadMoreServerId = serverId;
  }

  @override
  Future<void> reload() async {
    reloadCount++;
  }

  @override
  Future<void> refreshPreservingData({String? serverId}) async {
    refreshCount++;
    lastRefreshServerId = serverId;
  }
}

final class _ErrorHistoryNotifier extends AgentHistoryNotifier {
  int reloadCount = 0;

  @override
  Future<AgentHistoryState> build() async => throw StateError('offline');

  @override
  Future<void> reload() async {
    reloadCount++;
  }
}

final class _PendingHistoryNotifier extends AgentHistoryNotifier {
  final _completer = Completer<AgentHistoryState>();

  @override
  Future<AgentHistoryState> build() => _completer.future;

  void complete(AgentHistoryState state) => _completer.complete(state);
}

final class _TwoHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      _host('server-a', 'Local', 'localhost:6868'),
      _host('server-b', 'Remote', 'remote.example:6868'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

final class _MutableHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => _state(true);

  void removeRemote() => state = _state(false);

  void restoreRemote() => state = _state(true);

  HostRegistryState _state(bool includeRemote) => HostRegistryState(
    hosts: [
      _host('server-a', 'Local', 'localhost:6868'),
      if (includeRemote) _host('server-b', 'Remote', 'remote.example:6868'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

HostProfile _host(String serverId, String label, String endpoint) =>
    HostProfile(
      serverId: serverId,
      label: label,
      connections: [
        DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
      ],
      preferredConnectionId: 'direct:$endpoint',
      createdAt: '2026-07-28T00:00:00.000Z',
      updatedAt: '2026-07-28T00:00:00.000Z',
    );

AgentHistoryEntry _entry({
  String serverId = 'server-a',
  String serverLabel = 'Local',
  String agentId = 'archived',
  String title = 'Archived session',
  AgentRunState runState = AgentRunState.closed,
  bool archived = true,
  bool attention = false,
  String? updatedAt,
}) => AgentHistoryEntry(
  serverId: serverId,
  serverLabel: serverLabel,
  agent: AgentSummary(
    agentId: agentId,
    title: title,
    cwd: '/repo',
    provider: 'codex',
    model: 'gpt-5',
    mode: AgentMode.normal,
    runState: runState,
    createdAtMs: 1,
    updatedAt: updatedAt,
    requiresAttention: attention,
    archivedAt: archived ? '2026-07-28T00:00:00.000Z' : null,
  ),
  project: const {
    'projectKey': '/repo',
    'projectName': 'Project',
    'workspaceName': 'Workspace',
    'checkout': {'currentBranch': 'main'},
  },
);

final class _ArchiveClient extends DaemonClient {
  _ArchiveClient() : super(uri: Uri.parse('ws://archive-test'));

  final List<(String, Map<String, Object?>)> requests = [];

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return const {};
  }
}
