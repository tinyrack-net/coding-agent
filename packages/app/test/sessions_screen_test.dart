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

void main() {
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

  testWidgets('filters sessions by host and renders active fallback titles', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_TwoHostRegistry.new),
          agentHistoryProvider.overrideWith(
            () => _HistoryNotifier(
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
              ),
            ),
          ),
        ],
        child: FluentApp(theme: buildAppTheme(), home: const SessionsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Archived session'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);

    await tester.tap(find.byType(ComboBox<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();

    expect(find.text('Archived session'), findsNothing);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Remote'), findsWidgets);
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
    expect(find.byType(ProgressRing), findsOneWidget);
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
}

final class _HistoryNotifier extends AgentHistoryNotifier {
  _HistoryNotifier(this.initial);

  final AgentHistoryState initial;
  int loadMoreCount = 0;
  int reloadCount = 0;

  @override
  Future<AgentHistoryState> build() async => initial;

  @override
  Future<void> loadMore() async {
    loadMoreCount++;
  }

  @override
  Future<void> reload() async {
    reloadCount++;
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
