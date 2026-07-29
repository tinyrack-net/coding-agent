import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
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
    final router = buildAppRouter(initialLocation: '/h/server-a/agent/agent-1');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
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
}

final class _RouterDaemonClient extends DaemonClient
    with LegacyAgentListFetchMixin {
  _RouterDaemonClient() : super(uri: Uri.parse('ws://fake'));

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<AgentFetchResult?> fetchAgent(
    String agentId, {
    Duration timeout = const Duration(seconds: 60),
  }) async => AgentFetchResult(
    agent: AgentSummary(
      agentId: agentId,
      title: 'Agent',
      cwd: r'C:\repo\worktree',
      provider: 'codex',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 1,
      workspaceId: 'workspace-1',
    ),
    project: null,
  );

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
