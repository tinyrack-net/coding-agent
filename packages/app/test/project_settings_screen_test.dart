import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/projects/projects.dart';
import 'package:coding_agent_app/screens/project_settings_screen.dart';
import 'package:coding_agent_app/screens/projects_settings_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/project_summaries_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('project list renders host errors and navigable project rows', (
    tester,
  ) async {
    final client = _ProjectClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      _app(
        client: client,
        data: _data(
          hostErrors: const [
            ProjectHostError(
              serverId: 'host-b',
              serverName: 'Laptop',
              message: 'offline',
            ),
          ],
        ),
        child: const ProjectsSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('projects-list')), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
    expect(find.text('Laptop could not load projects'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    expect(find.bySemanticsLabel('Edit project App'), findsOneWidget);
  });

  testWidgets('loads, edits, and saves the full project config form', (
    tester,
  ) async {
    final client = _ProjectClient(
      read: () => const ReadProjectConfigSuccess(
        requestId: 'read',
        repoRoot: '/repo/app',
        config: {
          'worktree': {'setup': 'npm install'},
          'metadataGeneration': {
            'branchName': {'instructions': 'feat/<slug>'},
          },
          'future': true,
        },
        revision: ProjectConfigRevision(mtimeMs: 10, size: 20),
      ),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      _app(
        client: client,
        data: _data(),
        child: const ProjectSettingsScreen(projectKey: 'project-app'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('worktree-group')), findsOneWidget);
    expect(find.byKey(const Key('scripts-group')), findsOneWidget);
    expect(find.byKey(const Key('metadata-group')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('worktree-setup-input')),
      'pnpm install',
    );
    await tester.enterText(
      find.byKey(const Key('metadata-prompt-pullRequest-input')),
      'Include risk notes.',
    );

    final addScriptButton = find.byKey(const Key('scripts-add-button'));
    await tester.ensureVisible(addScriptButton);
    await tester.pumpAndSettle();
    await tester.tap(addScriptButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('script-edit-modal')), findsOneWidget);
    await tester.tap(find.byKey(const Key('script-edit-save')));
    await tester.pump();
    expect(find.byKey(const Key('script-edit-name-error')), findsOneWidget);
    expect(find.byKey(const Key('script-edit-command-error')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('script-edit-name')), 'dev');
    await tester.enterText(
      find.byKey(const Key('script-edit-command')),
      'pnpm dev',
    );
    await tester.tap(find.byKey(const Key('script-edit-service-toggle')));
    await tester.tap(find.byKey(const Key('script-edit-save')));
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const Key('save-button'));
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(client.writes, hasLength(1));
    final config = client.writes.single;
    expect(config['future'], true);
    expect((config['worktree'] as Map)['setup'], 'pnpm install');
    expect((config['scripts'] as Map)['dev'], {
      'command': 'pnpm dev',
      'type': 'service',
    });
    expect(
      ((config['metadataGeneration'] as Map)['pullRequest']
          as Map)['instructions'],
      'Include risk notes.',
    );
    expect(client.expectedRevision?.toJson(), {'mtimeMs': 10, 'size': 20});

    final editNameButton = find.byKey(const Key('project-name-edit-button'));
    await tester.scrollUntilVisible(
      editNameButton,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(editNameButton),
      alignment: 0.2,
    );
    await tester.pumpAndSettle();
    await tester.tap(editNameButton);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('project-name-input')), 'Web');
    await tester.tap(find.byKey(const Key('project-name-save-button')));
    await tester.pumpAndSettle();
    expect(client.renames, [('project-app', 'Web')]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('stale writes block saving until the user reloads', (
    tester,
  ) async {
    final client = _ProjectClient(
      read: () => const ReadProjectConfigSuccess(
        requestId: 'read',
        repoRoot: '/repo/app',
        config: {},
        revision: ProjectConfigRevision(mtimeMs: 1, size: 2),
      ),
      write: () => const WriteProjectConfigFailure(
        requestId: 'write',
        repoRoot: '/repo/app',
        error: ProjectConfigStale(
          currentRevision: ProjectConfigRevision(mtimeMs: 2, size: 3),
        ),
      ),
    );
    addTearDown(client.dispose);
    await tester.pumpWidget(
      _app(
        client: client,
        data: _data(),
        child: const ProjectSettingsScreen(projectKey: 'project-app'),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const Key('save-button'));
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stale-callout')), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('save-button')),
    );
    expect(save.onPressed, isNull);
    final reloadButton = find.text('Reload');
    await tester.ensureVisible(reloadButton);
    await tester.pumpAndSettle();
    await tester.tap(reloadButton);
    await tester.pumpAndSettle();
    expect(client.readCount, 2);
    expect(find.byKey(const Key('stale-callout')), findsNothing);
  });

  testWidgets('invalid configs and missing editable targets show recovery UI', (
    tester,
  ) async {
    final invalid = _ProjectClient(
      read: () => const ReadProjectConfigFailure(
        requestId: 'read',
        repoRoot: '/repo/app',
        error: ProjectConfigInvalid(),
      ),
    );
    addTearDown(invalid.dispose);
    await tester.pumpWidget(
      _app(
        client: invalid,
        data: _data(),
        child: const ProjectSettingsScreen(projectKey: 'project-app'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('invalid-callout')), findsOneWidget);

    await tester.pumpWidget(
      _app(
        client: invalid,
        data: const DerivedProjectsResult(
          projects: [],
          hostErrors: [],
          isLoading: false,
          isFetching: false,
        ),
        child: const ProjectSettingsScreen(projectKey: 'missing'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-settings-no-target')), findsOneWidget);
  });

  testWidgets('connected host loss replaces the form with recovery UI', (
    tester,
  ) async {
    final client = _ProjectClient();
    final summaries = _ProjectSummaries(_data());
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSummariesProvider.overrideWith(() => summaries),
          hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
        ],
        child: const FluentApp(
          home: ProjectSettingsScreen(projectKey: 'project-app'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worktree-group')), findsOneWidget);
    expect(find.bySemanticsLabel('Host Local'), findsOneWidget);

    summaries.publish(_data(hostOnline: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('project-settings-no-target')), findsOneWidget);
    expect(find.byKey(const Key('worktree-group')), findsNothing);
  });

  testWidgets('host picker switches the editable project replica', (
    tester,
  ) async {
    final local = _ProjectClient();
    final remote = _ProjectClient();
    addTearDown(local.dispose);
    addTearDown(remote.dispose);
    final data = _data(
      hosts: const [
        ProjectHostEntry(
          serverId: 'host-a',
          serverName: 'Local',
          isOnline: true,
          repoRoot: '/repo/app',
          workspaceCount: 1,
          workspaces: [],
        ),
        ProjectHostEntry(
          serverId: 'host-b',
          serverName: 'Remote',
          isOnline: true,
          repoRoot: '/remote/app',
          workspaceCount: 1,
          workspaces: [],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSummariesProvider.overrideWith(() => _ProjectSummaries(data)),
          hostRuntimeClientsProvider.overrideWithValue({
            'host-a': local,
            'host-b': remote,
          }),
        ],
        child: const FluentApp(
          home: ProjectSettingsScreen(projectKey: 'project-app'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(local.readCount, 1);
    expect(remote.readCount, 0);
    await tester.tap(find.byKey(const Key('project-settings-host-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();

    expect(remote.readCount, 1);
    expect(find.text('Remote'), findsWidgets);
  });

  testWidgets('project settings remain usable at compact mobile width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = _ProjectClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(
      _app(
        client: client,
        data: _data(),
        child: const ProjectSettingsScreen(projectKey: 'project-app'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('project-settings-project-app')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('project-name-edit-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registered project deep link restores the settings screen', (
    tester,
  ) async {
    final client = _ProjectClient();
    addTearDown(client.dispose);
    final route = buildProjectSettingsRoute('project-app');
    final router = buildAppRouter(initialLocation: route);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSummariesProvider.overrideWith(
            () => _ProjectSummaries(_data()),
          ),
          hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.toString(), route);
    expect(
      find.byKey(const ValueKey('project-settings-project-app')),
      findsOneWidget,
    );
    expect(find.text('Projects'), findsWidgets);
  });

  testWidgets('project list row navigates to its registered settings route', (
    tester,
  ) async {
    final client = _ProjectClient();
    addTearDown(client.dispose);
    final router = buildAppRouter(initialLocation: '/settings/projects');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectSummariesProvider.overrideWith(
            () => _ProjectSummaries(_data()),
          ),
          hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('project-row-project-app')));
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.toString(),
      buildProjectSettingsRoute('project-app'),
    );
    expect(
      find.byKey(const ValueKey('project-settings-project-app')),
      findsOneWidget,
    );
  });

  testWidgets(
    'zero-workspace project settings applies the live rename upsert',
    (tester) async {
      final client = _ProjectClient(
        emptyProject: const WorkspaceProjectDescriptor(
          projectId: 'project-empty',
          projectDisplayName: 'Empty project',
          projectRootPath: '/repo/empty',
          projectKind: WorkspaceProjectKind.git,
        ),
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostRegistryProvider.overrideWith(_ProjectHostRegistry.new),
            hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
            hostConnectionStateProvider.overrideWith(
              (ref, serverId) => const Stream<DaemonConnectionState>.empty(),
            ),
          ],
          child: const FluentApp(
            home: ProjectSettingsScreen(projectKey: 'project-empty'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Empty project'), findsOneWidget);
      expect(find.byKey(const Key('project-name-edit-button')), findsOneWidget);
      expect(client.activeDirectoryUpdateListeners, 1);
      expect(client.hasRawDirectoryUpdateListener, isTrue);
      final fetchesBeforeRename = client.workspaceFetchCount;

      await tester.tap(find.byKey(const Key('project-name-edit-button')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('project-name-input')),
        'Renamed empty project',
      );
      await tester.tap(find.byKey(const Key('project-name-save-button')));
      await tester.pumpAndSettle();
      expect(client.renames, [('project-empty', 'Renamed empty project')]);
      expect(client.activeDirectoryUpdateListeners, 1);
      expect(client.workspaceFetchCount, greaterThan(fetchesBeforeRename));
      expect(client.hasRawDirectoryUpdateListener, isTrue);

      client.emitProjectUpdate(
        const WorkspaceProjectDescriptor(
          projectId: 'project-empty',
          projectDisplayName: 'Renamed empty project',
          projectCustomName: 'Renamed empty project',
          projectRootPath: '/repo/empty',
          projectKind: WorkspaceProjectKind.git,
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectSettingsScreen)),
      );
      expect(
        container
            .read(projectSummariesProvider)
            .value!
            .projects
            .single
            .projectName,
        'Renamed empty project',
      );
      expect(find.text('Renamed empty project'), findsOneWidget);
      expect(find.byKey(const Key('project-name-edit-button')), findsOneWidget);
      expect(find.byKey(const Key('project-settings-no-target')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    },
  );
}

Widget _app({
  required _ProjectClient client,
  required DerivedProjectsResult data,
  required Widget child,
}) => ProviderScope(
  overrides: [
    projectSummariesProvider.overrideWith(() => _ProjectSummaries(data)),
    hostRuntimeClientsProvider.overrideWithValue({'host-a': client}),
  ],
  child: FluentApp(home: child),
);

DerivedProjectsResult _data({
  List<ProjectHostError> hostErrors = const [],
  bool hostOnline = true,
  List<ProjectHostEntry>? hosts,
}) {
  final resolvedHosts =
      hosts ??
      [
        ProjectHostEntry(
          serverId: 'host-a',
          serverName: 'Local',
          isOnline: hostOnline,
          repoRoot: '/repo/app',
          workspaceCount: 1,
          workspaces: const [],
        ),
      ];
  return DerivedProjectsResult(
    projects: [
      ProjectSummary(
        projectKey: 'project-app',
        projectName: 'App',
        projectCustomName: null,
        hosts: resolvedHosts,
        totalWorkspaceCount: resolvedHosts.fold(
          0,
          (total, host) => total + host.workspaceCount,
        ),
        hostCount: resolvedHosts.length,
        onlineHostCount: resolvedHosts.where((host) => host.isOnline).length,
        githubUrl: null,
      ),
    ],
    hostErrors: hostErrors,
    isLoading: false,
    isFetching: false,
  );
}

final class _ProjectSummaries extends ProjectSummariesNotifier {
  _ProjectSummaries(this.data);

  DerivedProjectsResult data;

  @override
  Future<DerivedProjectsResult> build() async => data;

  @override
  Future<void> reload() async {
    state = AsyncData(data);
  }

  void publish(DerivedProjectsResult value) {
    data = value;
    state = AsyncData(value);
  }
}

typedef _Read = ReadProjectConfigResponse Function();
typedef _Write = WriteProjectConfigResponse Function();

final class _ProjectClient extends DaemonClient {
  _ProjectClient({_Read? read, _Write? write, this.emptyProject})
    : _read =
          read ??
          (() => const ReadProjectConfigSuccess(
            requestId: 'read',
            repoRoot: '/repo/app',
            config: {},
            revision: null,
          )),
      _write =
          write ??
          (() => const WriteProjectConfigSuccess(
            requestId: 'write',
            repoRoot: '/repo/app',
            config: {},
            revision: ProjectConfigRevision(mtimeMs: 20, size: 30),
          )),
      super(uri: Uri.parse('ws://fake'));

  final _Read _read;
  final _Write _write;
  final WorkspaceProjectDescriptor? emptyProject;
  final StreamController<DirectoryUpdateEvent> _directoryUpdates =
      StreamController<DirectoryUpdateEvent>.broadcast();
  int activeDirectoryUpdateListeners = 0;
  int workspaceFetchCount = 0;
  final List<Map<String, Object?>> writes = [];
  final List<(String, String?)> renames = [];
  ProjectConfigRevision? expectedRevision;
  int readCount = 0;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<DirectoryUpdateEvent> get directoryUpdateEvents =>
      _CountingStream<DirectoryUpdateEvent>(
        _directoryUpdates.stream,
        onListen: () => activeDirectoryUpdateListeners++,
        onCancel: () => activeDirectoryUpdateListeners--,
      );

  bool get hasRawDirectoryUpdateListener => _directoryUpdates.hasListener;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (message['type'] == 'fetch_workspaces_request') {
      workspaceFetchCount++;
      return FetchWorkspacesResponse(
        requestId: message['requestId']! as String,
        entries: const [],
        emptyProjects: [?emptyProject],
        pageInfo: const WorkspacePageInfo(
          nextCursor: null,
          prevCursor: null,
          hasMore: false,
        ),
      ).toJson();
    }
    return super.requestSessionMessage(message, timeout: timeout);
  }

  void emitProjectUpdate(WorkspaceProjectDescriptor project) {
    _directoryUpdates.add(ProjectDirectoryEvent(ProjectUpsertUpdate(project)));
  }

  @override
  Future<ReadProjectConfigResponse> readProjectConfig(
    String repoRoot, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    readCount++;
    return _read();
  }

  @override
  Future<WriteProjectConfigResponse> writeProjectConfig({
    required String repoRoot,
    required Map<String, Object?> config,
    required ProjectConfigRevision? expectedRevision,
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    writes.add(config);
    this.expectedRevision = expectedRevision;
    final response = _write();
    if (response case WriteProjectConfigSuccess()) {
      return WriteProjectConfigSuccess(
        requestId: response.requestId,
        repoRoot: response.repoRoot,
        config: config,
        revision: response.revision,
      );
    }
    return response;
  }

  @override
  Future<ProjectRenameResponse> renameProject(
    String projectId,
    String? customName, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    renames.add((projectId, customName));
    return ProjectRenameResponse(
      requestId: 'rename',
      projectId: projectId,
      accepted: true,
      customName: customName,
      error: null,
    );
  }

  @override
  Future<ProjectIconResponse> requestProjectIcon(
    String cwd, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async => ProjectIconResponse(
    cwd: cwd,
    icon: null,
    error: null,
    requestId: requestId ?? 'icon',
  );

  @override
  void dispose() {
    unawaited(_directoryUpdates.close());
    super.dispose();
  }
}

final class _ProjectHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState(
    hosts: [
      HostProfile(
        serverId: 'host-a',
        label: 'Local',
        connections: [
          DirectTcpHostConnection(
            id: 'direct:127.0.0.1:6868',
            endpoint: '127.0.0.1:6868',
          ),
        ],
        preferredConnectionId: 'direct:127.0.0.1:6868',
        createdAt: '2026-07-30T00:00:00.000Z',
        updatedAt: '2026-07-30T00:00:00.000Z',
      ),
    ],
    activeServerId: 'host-a',
    loaded: true,
  );
}

final class _CountingStream<T> extends Stream<T> {
  const _CountingStream(
    this.source, {
    required this.onListen,
    required this.onCancel,
  });

  final Stream<T> source;
  final void Function() onListen;
  final void Function() onCancel;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    var active = true;
    void finish() {
      if (!active) return;
      active = false;
      onCancel();
    }

    onListen();
    final subscription = source.listen(
      onData,
      onError: onError,
      onDone: () {
        finish();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    return _CountingSubscription<T>(subscription, finish);
  }
}

final class _CountingSubscription<T> implements StreamSubscription<T> {
  const _CountingSubscription(this.delegate, this.onCancel);

  final StreamSubscription<T> delegate;
  final void Function() onCancel;

  @override
  Future<void> cancel() {
    onCancel();
    return delegate.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => delegate.onData(handleData);

  @override
  void onError(Function? handleError) => delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => delegate.pause(resumeSignal);

  @override
  void resume() => delegate.resume();

  @override
  bool get isPaused => delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => delegate.asFuture(futureValue);
}
