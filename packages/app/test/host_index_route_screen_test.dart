import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/screens/host_index_route_screen.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/last_workspace_route_selection.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'frozen host-index policy preserves unknown until missing is proven',
    () {
      const selection = HostWorkspaceRoute(
        serverId: 'server-a',
        workspaceId: 'workspace-1',
      );
      expect(
        resolveWorkspaceSelectionStatus(
          hasHydratedWorkspaces: false,
          workspaceExists: false,
        ),
        WorkspaceSelectionStatus.unknown,
      );
      expect(
        resolveHostIndexRoute(
          serverId: 'server-a',
          workspaceSelection: selection,
          workspaceSelectionStatus: WorkspaceSelectionStatus.unknown,
        ),
        '/h/server-a/workspace/workspace-1',
      );
      expect(
        resolveHostIndexRoute(
          serverId: 'server-a',
          workspaceSelection: selection,
          workspaceSelectionStatus: WorkspaceSelectionStatus.missing,
        ),
        '/open-project',
      );
      expect(
        resolveHostIndexRoute(
          serverId: 'server-b',
          workspaceSelection: selection,
          workspaceSelectionStatus: WorkspaceSelectionStatus.exists,
        ),
        '/open-project',
      );
    },
  );

  test('selection store persists the host and opaque workspace id', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(lastWorkspaceRouteSelectionProvider.future);

    await container
        .read(lastWorkspaceRouteSelectionProvider.notifier)
        .remember(
          const HostWorkspaceRoute(
            serverId: 'server/main',
            workspaceId: 'team/setup:id#1',
          ),
        );

    final selection = container.read(lastWorkspaceRouteSelectionProvider).value;
    expect(selection?.serverId, 'server/main');
    expect(selection?.workspaceId, 'team/setup:id#1');
    final preferences = await SharedPreferences.getInstance();
    expect(
      parseLastWorkspaceRouteSelection(
        preferences.getString(lastWorkspaceRouteSelectionStorageKey),
      )?.workspaceId,
      'team/setup:id#1',
    );
  });

  testWidgets('waits for selection hydration before choosing a leaf', (
    tester,
  ) async {
    final hydration = Completer<HostWorkspaceRoute?>();
    final harness = await _pumpHostIndex(
      tester,
      selectionNotifier: _TestSelectionNotifier.pending(hydration.future),
      catalog: AsyncData([_workspace()]),
    );
    addTearDown(harness.router.dispose);

    expect(harness.location, '/h/server-a');
    expect(find.text('Loading workspace selection…'), findsOneWidget);

    hydration.complete(
      const HostWorkspaceRoute(
        serverId: 'server-a',
        workspaceId: 'workspace-1',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(harness.location, '/h/server-a/workspace/workspace-1');
    expect(find.text('workspace'), findsOneWidget);
  });

  testWidgets('cold restore hydrates the persisted same-host selection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      lastWorkspaceRouteSelectionStorageKey:
          '{"serverId":"server-a","workspaceId":"workspace-1"}',
    });
    final router = GoRouter(
      initialLocation: '/h/server-a',
      routes: [
        GoRoute(
          path: '/h/:serverId',
          builder: (context, state) =>
              HostIndexRouteScreen(serverId: state.pathParameters['serverId']!),
        ),
        GoRoute(
          path: '/h/:serverId/workspace/:workspaceId',
          builder: (context, state) => const Text('workspace'),
        ),
        GoRoute(
          path: '/open-project',
          builder: (context, state) => const Text('projects'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_ActiveRegistry.new),
          workspaceCatalogProvider.overrideWithValue(AsyncData([_workspace()])),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    for (var index = 0; index < 4; index++) {
      await tester.pump();
    }

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/h/server-a/workspace/workspace-1',
    );
  });

  testWidgets('restores same-host selection while catalog is unknown', (
    tester,
  ) async {
    final harness = await _pumpHostIndex(
      tester,
      selectionNotifier: _TestSelectionNotifier.value(
        const HostWorkspaceRoute(
          serverId: 'server-a',
          workspaceId: 'workspace-1',
        ),
      ),
      catalog: const AsyncLoading(),
    );
    addTearDown(harness.router.dispose);
    await tester.pump();

    expect(harness.location, '/h/server-a/workspace/workspace-1');
  });

  testWidgets('opens projects when hydrated catalog proves selection missing', (
    tester,
  ) async {
    final harness = await _pumpHostIndex(
      tester,
      selectionNotifier: _TestSelectionNotifier.value(
        const HostWorkspaceRoute(
          serverId: 'server-a',
          workspaceId: 'workspace-missing',
        ),
      ),
      catalog: const AsyncData([]),
    );
    addTearDown(harness.router.dispose);
    await tester.pump();

    expect(harness.location, '/open-project');
    expect(find.text('projects'), findsOneWidget);
  });

  testWidgets('does not restore another host selection', (tester) async {
    final harness = await _pumpHostIndex(
      tester,
      selectionNotifier: _TestSelectionNotifier.value(
        const HostWorkspaceRoute(
          serverId: 'server-b',
          workspaceId: 'workspace-1',
        ),
      ),
      catalog: AsyncData([_workspace()]),
    );
    addTearDown(harness.router.dispose);
    await tester.pump();

    expect(harness.location, '/open-project');
  });
}

Future<_HostIndexHarness> _pumpHostIndex(
  WidgetTester tester, {
  required _TestSelectionNotifier selectionNotifier,
  required AsyncValue<List<WorkspaceDescriptor>> catalog,
}) async {
  final router = GoRouter(
    initialLocation: '/h/server-a',
    routes: [
      GoRoute(
        path: '/h/:serverId',
        builder: (context, state) =>
            HostIndexRouteScreen(serverId: state.pathParameters['serverId']!),
      ),
      GoRoute(
        path: '/h/:serverId/workspace/:workspaceId',
        builder: (context, state) => const Text('workspace'),
      ),
      GoRoute(
        path: '/open-project',
        builder: (context, state) => const Text('projects'),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const Text('welcome'),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hostRegistryProvider.overrideWith(_ActiveRegistry.new),
        lastWorkspaceRouteSelectionProvider.overrideWith(
          () => selectionNotifier,
        ),
        workspaceCatalogProvider.overrideWithValue(catalog),
      ],
      child: FluentApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return _HostIndexHarness(router);
}

final class _HostIndexHarness {
  const _HostIndexHarness(this.router);

  final GoRouter router;

  String get location => router.routeInformationProvider.value.uri.toString();
}

final class _TestSelectionNotifier extends LastWorkspaceRouteSelectionNotifier {
  _TestSelectionNotifier.value(HostWorkspaceRoute? value)
    : _future = Future.value(value);

  _TestSelectionNotifier.pending(Future<HostWorkspaceRoute?> future)
    : _future = future;

  final Future<HostWorkspaceRoute?> _future;

  @override
  Future<HostWorkspaceRoute?> build() => _future;
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
