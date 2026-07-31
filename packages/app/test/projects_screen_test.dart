import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/hosts/host_chooser.dart';
import 'package:coding_agent_app/import_sessions/import_session_dialog.dart';
import 'package:coding_agent_app/screens/projects_screen.dart';
import 'package:coding_agent_app/state/add_project_flow_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/widgets/add_project_flow_host.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

const _project = ProjectInfo(path: '/repo', name: 'repo', isGitRepo: true);
const _directoryProject = ProjectInfo(
  path: '/notes',
  name: 'notes',
  isGitRepo: false,
);

const _mainWorktree = WorktreeInfo(
  path: '/repo',
  branch: 'main',
  projectPath: '/repo',
  isMain: true,
);

const _idleWorktree = WorktreeInfo(
  path: '/repo-wt/idle',
  branch: 'idle-branch',
  projectPath: '/repo',
);

const _ownedWorktree = WorktreeInfo(
  path: '/repo-wt/owned',
  branch: 'owned-branch',
  projectPath: '/repo',
);

const _owner = AgentSummary(
  agentId: 'agent-1',
  title: 'Owner agent',
  cwd: '/repo-wt/owned',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
  projectPath: '/repo',
  branch: 'owned-branch',
  isWorktree: true,
);

const _importedAgent = AgentSummary(
  agentId: 'imported-agent',
  title: 'Imported conversation',
  cwd: '/imported/repo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  workspaceId: 'imported-workspace',
);

class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient({ServerInfoStatus? info})
    : super(uri: Uri.parse('ws://fake')) {
    serverInfo = info;
  }

  final requests = <(String, Map<String, Object?>)>[];
  final sessionRequests = <Map<String, Object?>>[];
  Map<String, Object?> Function(String type, Map<String, Object?> payload)
  onRequest = (type, payload) => const {};
  Map<String, Object?> Function(Map<String, Object?> message) onSessionRequest =
      (message) => const {};
  ProjectAddResponse projectAddResponse = const ProjectAddResponse(
    requestId: 'project-add',
    project: WorkspaceProjectDescriptor(
      projectId: 'imported-project',
      projectDisplayName: 'repo',
      projectRootPath: '/imported/repo',
      projectKind: WorkspaceProjectKind.git,
    ),
    error: null,
  );
  final projectAddPaths = <String>[];

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return onRequest(type, payload);
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sessionRequests.add(message);
    return onSessionRequest(message);
  }

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => GetProvidersSnapshotResponse(
    entries: const [
      ProviderSnapshotEntry(
        provider: 'claude',
        status: ProviderCatalogStatus.ready,
        label: 'Claude',
      ),
    ],
    generatedAt: '2026-01-01T00:00:00.000Z',
    requestId: 'snapshot',
  );

  @override
  Future<FetchRecentProviderSessionsResponse> fetchRecentProviderSessions({
    String? cwd,
    List<String>? providers,
    String? since,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async => const FetchRecentProviderSessionsResponse(
    requestId: 'sessions',
    entries: [
      RecentProviderSessionDescriptor(
        providerId: 'claude',
        providerLabel: 'Claude',
        providerHandleId: 'session-1',
        cwd: '/imported/repo',
        title: 'Imported conversation',
        firstPromptPreview: 'First prompt',
        lastPromptPreview: 'Latest prompt',
        lastActivityAt: '2026-01-01T00:00:00.000Z',
      ),
    ],
  );

  @override
  Future<ImportAgentStatusResponse> importProviderSession({
    required String providerId,
    required String providerHandleId,
    required String cwd,
    String? workspaceId,
    Map<String, String>? labels,
    Duration timeout = const Duration(seconds: 60),
  }) async => const ImportAgentStatusResponse(
    requestId: 'import',
    status: 'agent_resumed',
    agentId: 'imported-agent',
    agent: _importedAgent,
  );

  @override
  Future<ProjectAddResponse> addProject({
    required String cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    projectAddPaths.add(cwd);
    return projectAddResponse;
  }
}

class _SeededHostRegistry extends HostRegistryNotifier {
  _SeededHostRegistry(this.hosts, this.activeServerId);

  final List<HostProfile> hosts;
  final String? activeServerId;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: hosts,
    activeServerId: activeServerId,
    loaded: true,
  );
}

class _SeededDaemonLifecycle extends DaemonLifecycleNotifier {
  _SeededDaemonLifecycle(this.status);

  final DaemonStatus? status;

  @override
  Future<DaemonStatus?> build() async => status;
}

Future<ProviderContainer> pumpProjectsScreen(
  WidgetTester tester,
  FakeDaemonClient client, {
  HostProfile? activeHost,
  List<HostProfile>? hosts,
  Map<String, FakeDaemonClient> hostClients = const {},
  DaemonStatus? daemonStatus,
  bool mountAddProjectFlow = false,
}) async {
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      if (hosts != null || activeHost != null)
        hostRegistryProvider.overrideWith(
          () =>
              _SeededHostRegistry(hosts ?? [activeHost!], activeHost?.serverId),
        ),
      for (final entry in hostClients.entries)
        hostDaemonClientProvider(entry.key).overrideWithValue(entry.value),
      if (activeHost != null && !hostClients.containsKey(activeHost.serverId))
        hostDaemonClientProvider(activeHost.serverId).overrideWithValue(client),
      daemonLifecycleProvider.overrideWith(
        () => _SeededDaemonLifecycle(daemonStatus),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            const ProjectsScreen(),
            if (mountAddProjectFlow) const AddProjectFlowHost(),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('global Add Project preserves the two-host chooser', (
    tester,
  ) async {
    final activeClient =
        FakeDaemonClient(
            info: const ServerInfoStatus(
              serverId: 'server-a',
              hostname: 'Host A',
              version: '0.2.0',
              desktopManaged: false,
            ),
          )
          ..onRequest = (type, payload) => switch (type) {
            MessageTypes.projectListRequest => {'projects': <Object?>[]},
            _ => const {},
          };
    final otherClient = FakeDaemonClient(
      info: const ServerInfoStatus(
        serverId: 'server-b',
        hostname: 'Host B',
        version: '0.2.0',
        desktopManaged: false,
      ),
    );
    const activeHost = HostProfile(
      serverId: 'server-a',
      label: 'Host A',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:a.example:6868',
          endpoint: 'a.example:6868',
        ),
      ],
      preferredConnectionId: 'direct:a.example:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    const otherHost = HostProfile(
      serverId: 'server-b',
      label: 'Host B',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:b.example:6868',
          endpoint: 'b.example:6868',
        ),
      ],
      preferredConnectionId: 'direct:b.example:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    final container = await pumpProjectsScreen(
      tester,
      activeClient,
      activeHost: activeHost,
      hosts: const [activeHost, otherHost],
      hostClients: {
        activeHost.serverId: activeClient,
        otherHost.serverId: otherClient,
      },
      mountAddProjectFlow: true,
    );

    expect(find.byKey(const ValueKey('open-project-submit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-project-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      container.read(addProjectFlowProvider).request?.preferredHostId,
      isNull,
    );
    expect(
      find.byKey(const ValueKey('add-project-flow-page-host')),
      findsOneWidget,
    );
    expect(find.text('Host A'), findsOneWidget);
    expect(find.text('Host B'), findsOneWidget);
    expect(activeClient.sessionRequests, isEmpty);
    expect(otherClient.sessionRequests, isEmpty);
  });

  testWidgets('renders the frozen launch tiles and keeps the catalog visible', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) => switch (type) {
        MessageTypes.projectListRequest => {
          'projects': [_directoryProject.toJson()],
        },
        _ => const {},
      };
    await pumpProjectsScreen(tester, client);

    expect(find.text('Add a project'), findsOneWidget);
    expect(find.text('Open a folder on your machine'), findsOneWidget);
    expect(find.text('Import session'), findsOneWidget);
    expect(find.text('Bring in recent external CLI sessions'), findsOneWidget);
    expect(find.text('Setup providers'), findsOneWidget);
    expect(find.text('Configure Claude Code, Codex, and more'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-project-pair-device')),
      findsNothing,
    );
    expect(find.text('Registered projects'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
  });

  testWidgets('Setup providers routes to the only selected host', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) => switch (type) {
        MessageTypes.projectListRequest => {'projects': <Object?>[]},
        _ => const {},
      };
    const host = HostProfile(
      serverId: 'server-a',
      label: 'Remote host',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:example.test:6868',
          endpoint: 'example.test:6868',
        ),
      ],
      preferredConnectionId: 'direct:example.test:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        hostRegistryProvider.overrideWith(
          () => _SeededHostRegistry(const [host], host.serverId),
        ),
        hostDaemonClientProvider(host.serverId).overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/open-project',
      routes: [
        GoRoute(
          path: '/open-project',
          builder: (_, _) => const ProjectsScreen(),
        ),
        GoRoute(
          path: '/settings/hosts/:serverId/providers',
          builder: (_, state) => Text(
            'providers:${state.pathParameters['serverId']}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('open-project-setup-providers')),
    );
    await tester.pumpAndSettle();

    expect(find.text('providers:server-a'), findsOneWidget);
  });

  testWidgets('Import session opens against the only selected host', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) => switch (type) {
        MessageTypes.projectListRequest => {'projects': <Object?>[]},
        _ => const {},
      };
    const host = HostProfile(
      serverId: 'server-a',
      label: 'Remote host',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:example.test:6868',
          endpoint: 'example.test:6868',
        ),
      ],
      preferredConnectionId: 'direct:example.test:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    await pumpProjectsScreen(tester, client, activeHost: host);

    await tester.tap(find.byKey(const ValueKey('open-project-import-session')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSessionDialog), findsOneWidget);
    expect(find.text('Update the host to import sessions.'), findsOneWidget);
  });

  for (final shouldRegister in [true, false]) {
    testWidgets(
      'Import session ${shouldRegister ? 'registers the selected host project '
                'before navigation' : 'surfaces project registration failure '
                'without navigation'}',
      (tester) async {
        final activeClient =
            FakeDaemonClient(
                info: const ServerInfoStatus(
                  serverId: 'server-a',
                  hostname: 'Host A',
                  version: '0.2.0',
                  desktopManaged: false,
                  features: {
                    'providersSnapshot': true,
                    'importSessionWorkspaceTarget': true,
                  },
                ),
              )
              ..onRequest = (type, payload) => switch (type) {
                MessageTypes.projectListRequest => {'projects': <Object?>[]},
                _ => const {},
              };
        final selectedClient =
            FakeDaemonClient(
                info: const ServerInfoStatus(
                  serverId: 'server-b',
                  hostname: 'Host B',
                  version: '0.2.0',
                  desktopManaged: false,
                  features: {
                    'providersSnapshot': true,
                    'importSessionWorkspaceTarget': true,
                  },
                ),
              )
              ..onRequest = (type, payload) => switch (type) {
                MessageTypes.projectListRequest => {'projects': <Object?>[]},
                _ => const {},
              };
        if (!shouldRegister) {
          selectedClient.projectAddResponse = const ProjectAddResponse(
            requestId: 'project-add',
            project: null,
            error: 'directory rejected',
          );
        }
        const activeHost = HostProfile(
          serverId: 'server-a',
          label: 'Host A',
          connections: [
            DirectTcpHostConnection(
              id: 'direct:a.example:6868',
              endpoint: 'a.example:6868',
            ),
          ],
          preferredConnectionId: 'direct:a.example:6868',
          createdAt: '2026-01-01T00:00:00.000Z',
          updatedAt: '2026-01-01T00:00:00.000Z',
        );
        const selectedHost = HostProfile(
          serverId: 'server-b',
          label: 'Host B',
          connections: [
            DirectTcpHostConnection(
              id: 'direct:b.example:6868',
              endpoint: 'b.example:6868',
            ),
          ],
          preferredConnectionId: 'direct:b.example:6868',
          createdAt: '2026-01-01T00:00:00.000Z',
          updatedAt: '2026-01-01T00:00:00.000Z',
        );
        final container = ProviderContainer(
          overrides: [
            daemonClientProvider.overrideWithValue(activeClient),
            hostRegistryProvider.overrideWith(
              () => _SeededHostRegistry(const [
                activeHost,
                selectedHost,
              ], activeHost.serverId),
            ),
            hostDaemonClientProvider(
              activeHost.serverId,
            ).overrideWithValue(activeClient),
            hostDaemonClientProvider(
              selectedHost.serverId,
            ).overrideWithValue(selectedClient),
            daemonLifecycleProvider.overrideWith(
              () => _SeededDaemonLifecycle(null),
            ),
          ],
        );
        addTearDown(container.dispose);
        final router = GoRouter(
          initialLocation: '/open-project',
          routes: [
            GoRoute(
              path: '/open-project',
              builder: (_, _) => const HostChooserHost(child: ProjectsScreen()),
            ),
            GoRoute(
              path: '/h/:serverId/workspace/:workspaceId',
              builder: (_, state) => Text(
                'workspace:${state.pathParameters['serverId']}',
                textDirection: TextDirection.ltr,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: FluentApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('open-project-import-session')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('host-chooser-row-server-b')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('import-session-session-claude-session-1')),
        );
        await tester.pumpAndSettle();

        expect(activeClient.projectAddPaths, isEmpty);
        expect(selectedClient.projectAddPaths, ['/imported/repo']);
        if (shouldRegister) {
          expect(find.text('workspace:server-b'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('import-session-project-error')),
            findsNothing,
          );
        } else {
          expect(
            router.routeInformationProvider.value.uri.path,
            '/open-project',
          );
          expect(
            find.byKey(const ValueKey('import-session-project-error')),
            findsOneWidget,
          );
          expect(find.textContaining('directory rejected'), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
        }
      },
    );
  }

  testWidgets('Pair device targets the authoritative desktop-managed daemon '
      'among two loopback hosts', (tester) async {
    final unmanagedClient = FakeDaemonClient(
      info: const ServerInfoStatus(
        serverId: 'server-unmanaged',
        hostname: 'Standalone',
        version: '0.2.0',
        desktopManaged: false,
      ),
    );
    unmanagedClient.onRequest = (type, payload) => switch (type) {
      MessageTypes.projectListRequest => {'projects': <Object?>[]},
      _ => const {},
    };
    final managedClient = FakeDaemonClient(
      info: const ServerInfoStatus(
        serverId: 'server-managed',
        hostname: 'Desktop daemon',
        version: '0.2.0',
        desktopManaged: true,
      ),
    );
    managedClient.onRequest = (type, payload) => switch (type) {
      MessageTypes.projectListRequest => {'projects': <Object?>[]},
      _ => const {},
    };
    managedClient.onSessionRequest = (message) => {
      'type': DaemonGetPairingOfferResponse.type,
      'payload': {
        'requestId': message['requestId'],
        'url': 'https://app.example/#offer=fixture',
        'qr': '█▀█',
        'relayEnabled': true,
      },
    };
    const unmanagedHost = HostProfile(
      serverId: 'server-unmanaged',
      label: 'Standalone',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:127.0.0.1:6868',
          endpoint: '127.0.0.1:6868',
        ),
      ],
      preferredConnectionId: 'direct:127.0.0.1:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    const managedHost = HostProfile(
      serverId: 'server-managed',
      label: 'Desktop daemon',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:127.0.0.1:6969',
          endpoint: '127.0.0.1:6969',
        ),
      ],
      preferredConnectionId: 'direct:127.0.0.1:6969',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    await pumpProjectsScreen(
      tester,
      unmanagedClient,
      activeHost: unmanagedHost,
      hosts: const [unmanagedHost, managedHost],
      hostClients: {
        unmanagedHost.serverId: unmanagedClient,
        managedHost.serverId: managedClient,
      },
      daemonStatus: const DaemonStatus(
        health: DaemonHealth.running,
        hello: ServerHello(
          daemonVersion: '0.2.0',
          protocolVersion: 1,
          desktopManaged: true,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-project-pair-device')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('open-project-pair-device-modal')),
      findsOneWidget,
    );
    expect(find.text('https://app.example/#offer=fixture'), findsOneWidget);
    expect(
      managedClient.sessionRequests.single['type'],
      DaemonGetPairingOfferRequest.type,
    );
    expect(unmanagedClient.sessionRequests, isEmpty);
  });

  testWidgets('Pair device stays hidden for remote-only hosts', (tester) async {
    final client =
        FakeDaemonClient(
            info: const ServerInfoStatus(
              serverId: 'server-remote',
              hostname: 'Remote',
              version: '0.2.0',
              desktopManaged: false,
            ),
          )
          ..onRequest = (type, payload) => switch (type) {
            MessageTypes.projectListRequest => {'projects': <Object?>[]},
            _ => const {},
          };
    const host = HostProfile(
      serverId: 'server-remote',
      label: 'Remote',
      connections: [
        DirectTcpHostConnection(
          id: 'direct:example.test:6868',
          endpoint: 'example.test:6868',
        ),
      ],
      preferredConnectionId: 'direct:example.test:6868',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    await pumpProjectsScreen(
      tester,
      client,
      activeHost: host,
      hostClients: {host.serverId: client},
    );

    expect(
      find.byKey(const ValueKey('open-project-pair-device')),
      findsNothing,
    );
  });

  testWidgets('catalog keeps a newly registered non-git directory visible', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) => switch (type) {
        MessageTypes.projectListRequest => {
          'projects': [_directoryProject.toJson()],
        },
        _ => const {},
      };
    await pumpProjectsScreen(tester, client);

    expect(find.text('notes'), findsOneWidget);
    expect(find.text('/notes'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-/notes')), findsOneWidget);
    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.worktreeListRequest,
      ),
      isEmpty,
    );
  });

  testWidgets('lists git projects and expands to show worktrees, marking '
      'the one in use by an agent', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.agentListRequest) {
          return {
            'agents': [_owner.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_project.toJson()],
          };
        }
        if (type == MessageTypes.worktreeListRequest) {
          return {
            'worktrees': [
              _mainWorktree.toJson(),
              _idleWorktree.toJson(),
              _ownedWorktree.toJson(),
            ],
          };
        }
        return const {};
      };
    await pumpProjectsScreen(tester, client);

    expect(find.text('repo'), findsOneWidget);

    await tester.tap(find.text('repo'));
    await tester.pumpAndSettle();

    expect(find.text('idle-branch'), findsOneWidget);
    expect(find.text('owned-branch'), findsOneWidget);
    expect(find.textContaining('in use by "Owner agent"'), findsOneWidget);

    // The main worktree has no archive/open actions.
    final mainTile = find.widgetWithText(ListTile, 'main');
    expect(tester.widget<ListTile>(mainTile).trailing, isNull);
  });

  testWidgets('archiving an idle worktree requests worktree.archive', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_project.toJson()],
          };
        }
        if (type == MessageTypes.worktreeListRequest) {
          return {
            'worktrees': [_mainWorktree.toJson(), _idleWorktree.toJson()],
          };
        }
        return const {};
      };
    await pumpProjectsScreen(tester, client);

    await tester.tap(find.text('repo'));
    await tester.pumpAndSettle();

    final archiveAction = find.byWidgetPredicate(
      (w) => w is Tooltip && w.message == 'Archive worktree',
    );
    await tester.ensureVisible(archiveAction);
    await tester.tap(archiveAction);
    await tester.pumpAndSettle();

    final archived = client.requests.singleWhere(
      (r) => r.$1 == MessageTypes.worktreeArchiveRequest,
    );
    expect(archived.$2['path'], '/repo-wt/idle');
  });
}
