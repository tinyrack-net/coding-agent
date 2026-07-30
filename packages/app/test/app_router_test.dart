import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/screens/host_connections_settings_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/last_workspace_route_selection.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('consumes open intent by replacing URL exactly once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _RouterDaemonClient();
    addTearDown(client.dispose);
    final initial = buildHostWorkspaceOpenRoute(
      'server-a',
      'workspace-1',
      'draft:new',
    );
    final router = buildAppRouter(initialLocation: initial);
    addTearDown(router.dispose);
    late ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
          desktopShellProvider.overrideWithValue(false),
          worktreeTabLayoutsHydratedProvider.overrideWith(_HydratedLayouts.new),
          workspaceCatalogProvider.overrideWithValue(AsyncData([_workspace()])),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return FluentApp.router(routerConfig: router);
          },
        ),
      ),
    );
    for (var index = 0; index < 8; index++) {
      await tester.pump(const Duration(milliseconds: 5));
    }

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server-a/workspace/workspace-1',
    );
    final preferences = await SharedPreferences.getInstance();
    expect(
      parseLastWorkspaceRouteSelection(
        preferences.getString(lastWorkspaceRouteSelectionStorageKey),
      ),
      isA<HostWorkspaceRoute>()
          .having((selection) => selection.serverId, 'serverId', 'server-a')
          .having(
            (selection) => selection.workspaceId,
            'workspaceId',
            'workspace-1',
          ),
    );
    final provider = worktreeTabsProvider(r'C:\repo\worktree');
    expect(
      container
          .read(provider)
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.draft),
      hasLength(2),
    );

    router.go('/projects');
    await tester.pump();
    router.go('/h/server-a/workspace/workspace-1');
    for (var index = 0; index < 4; index++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(
      container
          .read(provider)
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.draft),
      hasLength(2),
    );
  });

  testWidgets('cold agent route resolves to its workspace open intent', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _RouterDaemonClient();
    addTearDown(client.dispose);
    final router = buildAppRouter(
      initialLocation: 'coding-agent://h/server-a/agent/agent-1',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
          desktopShellProvider.overrideWithValue(false),
          worktreeTabLayoutsHydratedProvider.overrideWith(_HydratedLayouts.new),
          workspaceCatalogProvider.overrideWithValue(AsyncData([_workspace()])),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 5));
    }

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server-a/workspace/workspace-1',
    );
  });

  testWidgets('cached agent route opens while its host is offline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _RouterDaemonClient(
      state: DaemonConnectionState.disconnected,
    );
    addTearDown(client.dispose);
    final router = buildAppRouter(initialLocation: '/h/server-a/agent/agent-1');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          agentDirectoryReplicaStoreProvider.overrideWith(
            _SeededAgentReplicaStore.new,
          ),
          daemonClientProvider.overrideWithValue(client),
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
          daemonClientFactoryProvider.overrideWithValue((_) => client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.disconnected),
          ),
          desktopShellProvider.overrideWithValue(false),
          worktreeTabLayoutsHydratedProvider.overrideWith(_HydratedLayouts.new),
          workspaceCatalogProvider.overrideWithValue(AsyncData([_workspace()])),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    for (var index = 0; index < 8; index++) {
      await tester.pump(const Duration(milliseconds: 5));
    }

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server-a/workspace/workspace-1',
    );
    expect(client.fetchAgentCalls, 0);
  });

  testWidgets('offline agent route can retry or manage its host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _RouterDaemonClient(
      state: DaemonConnectionState.disconnected,
    );
    addTearDown(client.dispose);
    final router = buildAppRouter(initialLocation: '/h/server-a/agent/agent-1');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
          daemonClientFactoryProvider.overrideWithValue((_) => client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.disconnected),
          ),
          desktopShellProvider.overrideWithValue(false),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Host A is offline'), findsOneWidget);
    expect(find.text('Host status: Offline'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(client.connectCalls, 1);

    final manageHostButton = tester.widget<Button>(
      find.widgetWithText(Button, 'Manage host'),
    );
    manageHostButton.onPressed!();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(HostConnectionsSettingsScreen), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(HostConnectionsSettingsScreen), findsNothing);
    expect(find.text('Host A is offline'), findsOneWidget);
  });

  testWidgets(
    'host-scoped open-project deep link waits for registry then canonicalizes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _RouterDaemonClient();
      addTearDown(client.dispose);
      final router = buildAppRouter(
        initialLocation: 'coding-agent://h/server-a/open-project',
      );
      addTearDown(router.dispose);
      late ProviderContainer container;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostRegistryProvider.overrideWith(_DeferredRegistry.new),
            daemonClientProvider.overrideWithValue(client),
            connectionStateProvider.overrideWith(
              (ref) => Stream.value(DaemonConnectionState.connected),
            ),
            desktopShellProvider.overrideWithValue(false),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return FluentApp.router(routerConfig: router);
            },
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('host-open-project-loading')),
        findsOneWidget,
      );
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/h/server-a/open-project',
      );

      (container.read(hostRegistryProvider.notifier) as _DeferredRegistry)
          .completeLoading();
      await tester.pump();
      await tester.pump();

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/open-project',
      );
    },
  );

  testWidgets(
    'agent without a workspace falls back through host open-project',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _RouterDaemonClient(workspaceId: null);
      addTearDown(client.dispose);
      final router = buildAppRouter(
        initialLocation: '/h/server-a/agent/agent-1',
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostRegistryProvider.overrideWith(_ActiveRegistry.new),
            daemonClientProvider.overrideWithValue(client),
            hostDaemonClientProvider.overrideWith((ref, serverId) => client),
            connectionStateProvider.overrideWith(
              (ref) => Stream.value(DaemonConnectionState.connected),
            ),
            desktopShellProvider.overrideWithValue(false),
          ],
          child: FluentApp.router(routerConfig: router),
        ),
      );
      for (var index = 0; index < 10; index++) {
        await tester.pump(const Duration(milliseconds: 5));
      }

      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/open-project',
      );
    },
  );

  testWidgets('encoded host and agent IDs survive a custom-scheme cold start', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = _RouterDaemonClient();
    addTearDown(client.dispose);
    final router = buildAppRouter(
      initialLocation: 'coding-agent://h/server%2Fmain/agent/agent%20one',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_EncodedActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          hostDaemonClientProvider.overrideWith((ref, serverId) => client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
          desktopShellProvider.overrideWithValue(false),
          worktreeTabLayoutsHydratedProvider.overrideWith(_HydratedLayouts.new),
          workspaceCatalogProvider.overrideWithValue(AsyncData([_workspace()])),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 5));
    }

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server%2Fmain/workspace/workspace-1',
    );
  });
}

final class _RouterDaemonClient extends DaemonClient
    with LegacyAgentListFetchMixin {
  _RouterDaemonClient({
    this.workspaceId = 'workspace-1',
    this.state = DaemonConnectionState.connected,
  }) : super(uri: Uri.parse('ws://fake'));

  final String? workspaceId;
  final DaemonConnectionState state;
  int connectCalls = 0;
  int fetchAgentCalls = 0;

  @override
  DaemonConnectionState get currentState => state;

  @override
  Stream<DaemonConnectionState> get connectionState => Stream.value(state);

  @override
  Future<void> connect() async {
    connectCalls += 1;
  }

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<AgentFetchResult?> fetchAgent(
    String agentId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    fetchAgentCalls += 1;
    return AgentFetchResult(
      agent: _agent(agentId: agentId, workspaceId: workspaceId),
      project: null,
    );
  }

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async => switch (type) {
    MessageTypes.agentListRequest => const {'agents': []},
    MessageTypes.providerListRequest => const {'providers': []},
    MessageTypes.projectListRequest => const {'projects': []},
    _ => const {},
  };
}

final class _SeededAgentReplicaStore
    extends AgentDirectoryReplicaStoreNotifier {
  @override
  Map<String, Map<String, AgentSummary>> build() => {
    'server-a': {'agent-1': _agent()},
  };
}

AgentSummary _agent({
  String agentId = 'agent-1',
  String? workspaceId = 'workspace-1',
}) => AgentSummary(
  agentId: agentId,
  title: 'Agent',
  cwd: r'C:\repo\worktree',
  provider: 'codex',
  model: 'gpt-5.4',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  workspaceId: workspaceId,
);

final class _ActiveRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState(
    hosts: [
      HostProfile(
        serverId: 'server-a',
        label: 'Host A',
        connections: [
          DirectTcpHostConnection(
            id: 'direct:host.example:6868',
            endpoint: 'host.example:6868',
          ),
        ],
        preferredConnectionId: 'direct:host.example:6868',
        createdAt: '2026-07-27T00:00:00.000Z',
        updatedAt: '2026-07-27T00:00:00.000Z',
      ),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

final class _DeferredRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState();

  void completeLoading() {
    state = const HostRegistryState(
      hosts: [
        HostProfile(
          serverId: 'server-a',
          label: 'Host A',
          connections: [
            DirectTcpHostConnection(
              id: 'direct:host.example:6868',
              endpoint: 'host.example:6868',
            ),
          ],
          preferredConnectionId: 'direct:host.example:6868',
          createdAt: '2026-07-27T00:00:00.000Z',
          updatedAt: '2026-07-27T00:00:00.000Z',
        ),
      ],
      activeServerId: 'server-a',
      loaded: true,
    );
  }
}

final class _EncodedActiveRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState(
    hosts: [
      HostProfile(
        serverId: 'server/main',
        label: 'Encoded host',
        connections: [
          DirectTcpHostConnection(
            id: 'direct:host.example:6868',
            endpoint: 'host.example:6868',
          ),
        ],
        preferredConnectionId: 'direct:host.example:6868',
        createdAt: '2026-07-27T00:00:00.000Z',
        updatedAt: '2026-07-27T00:00:00.000Z',
      ),
    ],
    activeServerId: 'server/main',
    loaded: true,
  );
}

final class _HydratedLayouts extends WorktreeTabLayoutsHydrationNotifier {
  @override
  bool build() => true;
}

WorkspaceDescriptor _workspace() => const WorkspaceDescriptor(
  id: 'workspace-1',
  projectId: 'project-1',
  projectDisplayName: 'Project',
  projectRootPath: r'C:\repo',
  workspaceDirectory: r'C:\repo\worktree',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: 'Feature branch',
  status: WorkspaceStateBucket.done,
  activityAt: null,
);
