import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/screens/host_workspace_route_screen.dart';
import 'package:coding_agent_app/screens/home_shell.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:coding_agent_app/state/workspace_recovery_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/legacy_agent_list_fetch_mixin.dart';

void main() {
  testWidgets('resolves workspace id to directory and applies file intent', (
    tester,
  ) async {
    final client = DaemonClient(uri: Uri.parse('ws://host.example:6868'));
    addTearDown(client.dispose);
    late ProviderContainer container;
    var consumed = 0;
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
          worktreeTabLayoutsHydratedProvider.overrideWith(_HydratedLayouts.new),
          workspaceCatalogProvider.overrideWithValue(
            AsyncData([_workspace('workspace-1', r'C:\repo\worktree')]),
          ),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return FluentApp(
              home: HostWorkspaceRouteScreen(
                serverId: 'server-a',
                workspaceId: 'workspace-1',
                openIntent: const FileWorkspaceOpenIntent('src/index.dart'),
                onOpenIntentConsumed: () => consumed++,
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(selectedWorktreeProvider), r'C:\repo\worktree');
    final layout = container
        .read(worktreeTabsProvider(r'C:\repo\worktree'))
        .layout;
    expect(
      layout.tabs.where(
        (tab) =>
            tab.kind == WorktreeTabKind.file &&
            tab.filePath == 'src/index.dart',
      ),
      hasLength(1),
    );
    expect(consumed, 1);
  });

  testWidgets('shows recoverable not-found state', (tester) async {
    final client = DaemonClient(uri: Uri.parse('ws://host.example:6868'));
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
          workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'missing',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Workspace not found'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open projects'), findsOneWidget);
  });

  testWidgets('keeps missing and cached workspace routes distinct offline', (
    tester,
  ) async {
    final client = DaemonClient(uri: Uri.parse('ws://host.example:6868'));
    addTearDown(client.dispose);
    for (final catalog in <List<WorkspaceDescriptor>>[
      const [],
      [_workspace('workspace-1', r'C:\repo\worktree')],
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            hostRegistryProvider.overrideWith(_ActiveRegistry.new),
            daemonClientProvider.overrideWithValue(client),
            connectionStateProvider.overrideWithValue(
              const AsyncData(DaemonConnectionState.disconnected),
            ),
            workspaceCatalogProvider.overrideWithValue(AsyncData(catalog)),
          ],
          child: const FluentApp(
            home: HostWorkspaceRouteScreen(
              serverId: 'server-a',
              workspaceId: 'workspace-1',
            ),
          ),
        ),
      );
      await tester.pump();
      if (catalog.isEmpty) {
        expect(find.text('Host A is offline'), findsOneWidget);
        expect(find.text('Manage host'), findsOneWidget);
      } else {
        expect(find.text('Host A is offline'), findsNothing);
        expect(find.byType(WorkspaceDeckPane), findsOneWidget);
      }
    }
  });

  testWidgets('recovers a missing workspace selected by agent deep link', (
    tester,
  ) async {
    final restoreGate = Completer<void>();
    final transport = _RouteRecoveryTransport(restoreGate);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          connectionStateProvider.overrideWithValue(
            const AsyncData(DaemonConnectionState.connected),
          ),
          workspaceRecoveryCapabilityProvider.overrideWithValue(true),
          workspaceRecoveryLoadingDelayProvider.overrideWithValue(
            Duration.zero,
          ),
          workspaceRecoveryTransportProvider.overrideWithValue(transport),
          workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
            openIntent: AgentWorkspaceOpenIntent('agent-1'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Workspace archived'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pump();
    expect(find.text('Restoring workspace'), findsOneWidget);
    expect(find.text('Restoring...'), findsOneWidget);

    restoreGate.complete();
    await tester.pump();
    await tester.pump();
    expect(transport.operations, [
      'restore:workspace-1',
      'agent:agent-1',
      'workspaces',
    ]);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('offers Unarchive when the archived workspace still exists', (
    tester,
  ) async {
    final transport = _StaticRecoveryTransport(
      const RecoverableWorkspaceState(
        workspaceId: 'workspace-1',
        workspaceName: 'Existing workspace',
        action: 'unarchive',
        branch: 'feature',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          connectionStateProvider.overrideWithValue(
            const AsyncData(DaemonConnectionState.connected),
          ),
          workspaceRecoveryCapabilityProvider.overrideWithValue(true),
          workspaceRecoveryLoadingDelayProvider.overrideWithValue(
            Duration.zero,
          ),
          workspaceRecoveryTransportProvider.overrideWithValue(transport),
          workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
            openIntent: AgentWorkspaceOpenIntent('agent-1'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Workspace archived'), findsOneWidget);
    expect(
      find.text(
        'Existing workspace is archived. Unarchive it to open it again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Unarchive'), findsOneWidget);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('shows authoritative recovery error and retry states', (
    tester,
  ) async {
    final transport = _RouteRecoveryTransport(
      Completer<void>()..complete(),
      restoreError: StateError('Project root is missing'),
    );
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          connectionStateProvider.overrideWithValue(
            const AsyncData(DaemonConnectionState.connected),
          ),
          workspaceRecoveryCapabilityProvider.overrideWithValue(true),
          workspaceRecoveryLoadingDelayProvider.overrideWithValue(
            Duration.zero,
          ),
          workspaceRecoveryTransportProvider.overrideWithValue(transport),
          workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
            openIntent: AgentWorkspaceOpenIntent('agent-1'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Restore'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Project root is missing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('renders every non-actionable workspace recovery state', (
    tester,
  ) async {
    final cases =
        <
          ({
            bool supported,
            WorkspaceRecoveryState inspection,
            Object? error,
            String title,
            String detail,
          })
        >[
          (
            supported: false,
            inspection: const UnavailableWorkspaceState(
              workspaceId: 'workspace-1',
              reason: 'unused',
              message: 'unused',
            ),
            error: null,
            title: 'Update your host to restore this workspace',
            detail: 'This host does not support workspace recovery.',
          ),
          (
            supported: true,
            inspection: const UnavailableWorkspaceState(
              workspaceId: 'workspace-1',
              reason: 'workspace_not_found',
              message: 'This workspace is no longer known to the host.',
            ),
            error: null,
            title: 'Workspace unavailable',
            detail: 'This workspace is no longer known to the host.',
          ),
          (
            supported: true,
            inspection: const RecoverableWorkspaceState(
              workspaceId: 'workspace-1',
              workspaceName: 'Feature branch',
              action: 'repair_from_snapshot',
              branch: 'feature',
            ),
            error: null,
            title: 'Workspace unavailable',
            detail: 'Update Tinyrack to recover this workspace.',
          ),
          (
            supported: true,
            inspection: const UnavailableWorkspaceState(
              workspaceId: 'workspace-1',
              reason: 'unused',
              message: 'unused',
            ),
            error: StateError('transport closed'),
            title: "Couldn't check workspace",
            detail: 'transport closed',
          ),
        ];

    for (final recoveryCase in cases) {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            hostRegistryProvider.overrideWith(_ActiveRegistry.new),
            connectionStateProvider.overrideWithValue(
              const AsyncData(DaemonConnectionState.connected),
            ),
            workspaceRecoveryCapabilityProvider.overrideWithValue(
              recoveryCase.supported,
            ),
            workspaceRecoveryTransportProvider.overrideWithValue(
              _StaticRecoveryTransport(
                recoveryCase.inspection,
                error: recoveryCase.error,
              ),
            ),
            workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
          ],
          child: const FluentApp(
            home: HostWorkspaceRouteScreen(
              serverId: 'server-a',
              workspaceId: 'workspace-1',
              openIntent: AgentWorkspaceOpenIntent('agent-1'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text(recoveryCase.title), findsOneWidget);
      expect(find.text(recoveryCase.detail), findsOneWidget);
    }
  });

  testWidgets('shows host, catalog, and catalog-error progress states', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [hostRegistryProvider.overrideWith(_LoadingRegistry.new)],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
          ),
        ),
      ),
    );
    expect(find.text('Loading hosts…'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          workspaceCatalogProvider.overrideWithValue(const AsyncLoading()),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
          ),
        ),
      ),
    );
    expect(find.text('Loading workspace…'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          workspaceCatalogProvider.overrideWithValue(
            AsyncError(StateError('catalog failed'), StackTrace.empty),
          ),
        ],
        child: const FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
          ),
        ),
      ),
    );
    expect(find.text('Could not load workspace'), findsOneWidget);
    expect(find.textContaining('catalog failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('activates a saved route host before loading its workspace', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_InactiveRegistry.new),
          workspaceCatalogProvider.overrideWithValue(const AsyncLoading()),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return const FluentApp(
              home: HostWorkspaceRouteScreen(
                serverId: 'server-a',
                workspaceId: 'workspace-1',
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('Connecting to host…'), findsOneWidget);
    await tester.pump();
    expect(container.read(hostRegistryProvider).activeServerId, 'server-a');
  });

  testWidgets('does not consume an intent before layout hydration', (
    tester,
  ) async {
    var consumed = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          connectionStateProvider.overrideWithValue(
            const AsyncData(DaemonConnectionState.connected),
          ),
          worktreeTabLayoutsHydratedProvider.overrideWith(
            _UnhydratedLayouts.new,
          ),
          workspaceCatalogProvider.overrideWithValue(
            AsyncData([_workspace('workspace-1', r'C:\repo\worktree')]),
          ),
        ],
        child: FluentApp(
          home: HostWorkspaceRouteScreen(
            serverId: 'server-a',
            workspaceId: 'workspace-1',
            openIntent: const FileWorkspaceOpenIntent('src/index.dart'),
            onOpenIntentConsumed: () => consumed++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Loading workspace layout…'), findsOneWidget);
    expect(consumed, 0);
  });

  testWidgets('executes agent, terminal, draft, and setup open intents', (
    tester,
  ) async {
    final client = _NoNetworkDaemonClient();
    addTearDown(client.dispose);
    for (final intent in const <WorkspaceOpenIntent>[
      AgentWorkspaceOpenIntent('agent-1'),
      TerminalWorkspaceOpenIntent('terminal-1'),
      DraftWorkspaceOpenIntent('draft-1'),
      SetupWorkspaceOpenIntent('workspace-1'),
    ]) {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            hostRegistryProvider.overrideWith(_ActiveRegistry.new),
            daemonClientProvider.overrideWithValue(client),
            daemonClientFactoryProvider.overrideWithValue((_) => client),
            connectionStateProvider.overrideWith((ref) => const Stream.empty()),
            worktreeTabLayoutsHydratedProvider.overrideWith(
              _HydratedLayouts.new,
            ),
            workspaceCatalogProvider.overrideWithValue(
              AsyncData([_workspace('workspace-1', r'C:\repo\worktree')]),
            ),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return FluentApp(
                home: HostWorkspaceRouteScreen(
                  serverId: 'server-a',
                  workspaceId: 'workspace-1',
                  openIntent: intent,
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final activeTab = container
          .read(worktreeTabsProvider(r'C:\repo\worktree'))
          .layout
          .tabs
          .where(
            (tab) =>
                tab.tabId ==
                container
                    .read(worktreeTabsProvider(r'C:\repo\worktree'))
                    .layout
                    .activeTabId,
          )
          .single;
      expect(activeTab.kind, switch (intent) {
        AgentWorkspaceOpenIntent() => WorktreeTabKind.agent,
        TerminalWorkspaceOpenIntent() => WorktreeTabKind.terminal,
        DraftWorkspaceOpenIntent() => WorktreeTabKind.draft,
        SetupWorkspaceOpenIntent() => WorktreeTabKind.setup,
        _ => throw StateError('unexpected test intent'),
      });
      if (intent case AgentWorkspaceOpenIntent(:final agentId)) {
        expect(
          container
              .read(worktreeTabsProvider(r'C:\repo\worktree'))
              .layout
              .pinnedAgentIds,
          {agentId},
        );
      }
    }
  });

  testWidgets('redirects a removed host route to open project', (tester) async {
    final router = GoRouter(
      initialLocation: '/h/removed/workspace/workspace-1',
      routes: [
        GoRoute(
          path: '/h/:serverId/workspace/:workspaceId',
          builder: (context, state) => HostWorkspaceRouteScreen(
            serverId: state.pathParameters['serverId']!,
            workspaceId: state.pathParameters['workspaceId']!,
          ),
        ),
        GoRoute(
          path: '/open-project',
          builder: (context, state) =>
              const Center(child: Text('Open project target')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostRegistryProvider.overrideWith(_ActiveRegistry.new)],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open project target'), findsOneWidget);
  });
}

class _ActiveRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host()],
    activeServerId: 'server-a',
    loaded: true,
  );
}

final class _NoNetworkDaemonClient extends DaemonClient
    with LegacyAgentListFetchMixin {
  _NoNetworkDaemonClient() : super(uri: Uri.parse('ws://test.invalid'));

  @override
  Future<void> connect() async {}

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async => const {'agents': <Object?>[]};
}

class _LoadingRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState();
}

class _HydratedLayouts extends WorktreeTabLayoutsHydrationNotifier {
  @override
  bool build() => true;
}

class _UnhydratedLayouts extends WorktreeTabLayoutsHydrationNotifier {
  @override
  bool build() => false;

  @override
  void markHydrated() {}
}

class _InactiveRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host(), _hostB()],
    activeServerId: 'server-b',
    loaded: true,
  );
}

HostProfile _host() {
  const connection = DirectTcpHostConnection(
    id: 'direct:host.example:6868',
    endpoint: 'host.example:6868',
  );
  return const HostProfile(
    serverId: 'server-a',
    label: 'Host A',
    connections: [connection],
    preferredConnectionId: 'direct:host.example:6868',
    createdAt: '2026-07-27T00:00:00.000Z',
    updatedAt: '2026-07-27T00:00:00.000Z',
  );
}

HostProfile _hostB() {
  const connection = DirectTcpHostConnection(
    id: 'direct:b.example:6868',
    endpoint: 'b.example:6868',
  );
  return const HostProfile(
    serverId: 'server-b',
    label: 'Host B',
    connections: [connection],
    preferredConnectionId: 'direct:b.example:6868',
    createdAt: '2026-07-27T00:00:00.000Z',
    updatedAt: '2026-07-27T00:00:00.000Z',
  );
}

WorkspaceDescriptor _workspace(String id, String directory) =>
    WorkspaceDescriptor(
      id: id,
      projectId: 'project-1',
      projectDisplayName: 'Project',
      projectRootPath: r'C:\repo',
      workspaceDirectory: directory,
      projectKind: WorkspaceProjectKind.git,
      workspaceKind: WorkspaceKind.worktree,
      name: id,
      status: WorkspaceStateBucket.done,
      activityAt: null,
    );

final class _RouteRecoveryTransport implements WorkspaceRecoveryTransport {
  _RouteRecoveryTransport(this.restoreGate, {this.restoreError});

  final Completer<void> restoreGate;
  final Object? restoreError;
  final List<String> operations = [];

  @override
  Future<WorkspaceRecoveryState> inspect(String workspaceId) async =>
      RecoverableWorkspaceState(
        workspaceId: workspaceId,
        workspaceName: 'Feature branch',
        action: 'restore',
        branch: 'feature',
      );

  @override
  Future<void> restore(String workspaceId) async {
    operations.add('restore:$workspaceId');
    await restoreGate.future;
    if (restoreError case final error?) throw error;
  }

  @override
  Future<void> refreshAgent(String agentId) async {
    operations.add('agent:$agentId');
  }

  @override
  Future<void> refreshWorkspaces() async {
    operations.add('workspaces');
  }
}

final class _StaticRecoveryTransport implements WorkspaceRecoveryTransport {
  _StaticRecoveryTransport(this.inspection, {this.error});

  final WorkspaceRecoveryState inspection;
  final Object? error;

  @override
  Future<WorkspaceRecoveryState> inspect(String workspaceId) async {
    if (error case final value?) throw value;
    return inspection;
  }

  @override
  Future<void> refreshAgent(String agentId) async {}

  @override
  Future<void> refreshWorkspaces() async {}

  @override
  Future<void> restore(String workspaceId) async {}
}
