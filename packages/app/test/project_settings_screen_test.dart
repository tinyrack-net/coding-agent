import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/projects/projects.dart';
import 'package:coding_agent_app/screens/project_settings_screen.dart';
import 'package:coding_agent_app/screens/projects_settings_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
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
    await tester.ensureVisible(editNameButton);
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

DerivedProjectsResult _data({List<ProjectHostError> hostErrors = const []}) =>
    DerivedProjectsResult(
      projects: const [
        ProjectSummary(
          projectKey: 'project-app',
          projectName: 'App',
          projectCustomName: null,
          hosts: [
            ProjectHostEntry(
              serverId: 'host-a',
              serverName: 'Local',
              isOnline: true,
              repoRoot: '/repo/app',
              workspaceCount: 1,
              workspaces: [],
            ),
          ],
          totalWorkspaceCount: 1,
          hostCount: 1,
          onlineHostCount: 1,
          githubUrl: null,
        ),
      ],
      hostErrors: hostErrors,
      isLoading: false,
      isFetching: false,
    );

final class _ProjectSummaries extends ProjectSummariesNotifier {
  _ProjectSummaries(this.data);

  final DerivedProjectsResult data;

  @override
  Future<DerivedProjectsResult> build() async => data;

  @override
  Future<void> reload() async {
    state = AsyncData(data);
  }
}

typedef _Read = ReadProjectConfigResponse Function();
typedef _Write = WriteProjectConfigResponse Function();

final class _ProjectClient extends DaemonClient {
  _ProjectClient({_Read? read, _Write? write})
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
  final List<Map<String, Object?>> writes = [];
  final List<(String, String?)> renames = [];
  ProjectConfigRevision? expectedRevision;
  int readCount = 0;

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
}
