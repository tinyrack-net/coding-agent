import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/add_project_flow/model.dart';
import 'package:coding_agent_app/add_project_flow/project_picker_options.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/add_project_flow_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/add_project_flow_host.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = AddProjectHost(
  serverId: 'server-a',
  label: 'Local',
  canAddProject: true,
  canBrowse: false,
  canCloneGithubRepositories: true,
  canSearchGithubRepositories: true,
  canCreateDirectory: true,
);

final class _FlowClient extends DaemonClient {
  _FlowClient() : super(uri: Uri.parse('ws://127.0.0.1:6868')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'server-a',
      hostname: 'Local',
      version: '0.2.0',
      desktopManaged: true,
      features: {
        'projectAdd': true,
        'stableProjectIdentity': true,
        'projectGithubClone': true,
        'workspaceGithubRepositorySearch': true,
        'projectCreateDirectory': true,
      },
    );
  }

  final directoryQueries = <String>[];
  final addedPaths = <String>[];
  final githubQueries = <String>[];
  ProjectGithubCloneRequest? cloneRequest;
  ProjectCreateDirectoryRequest? createDirectoryRequest;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<ProjectAddResponse> addProject({
    required String cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    addedPaths.add(cwd);
    return ProjectAddResponse(
      requestId: 'add',
      project: WorkspaceProjectDescriptor(
        projectId: 'project-add',
        projectDisplayName: 'scratch',
        projectRootPath: cwd,
        projectKind: WorkspaceProjectKind.nonGit,
      ),
      error: null,
    );
  }

  @override
  Future<DirectorySuggestionsResponse> getDirectorySuggestions({
    required String query,
    String? cwd,
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    directoryQueries.add(query);
    return const DirectorySuggestionsResponse(
      directories: [r'C:\workspace'],
      entries: [
        DirectorySuggestionEntry(
          path: r'C:\workspace',
          kind: DirectorySuggestionKind.directory,
        ),
      ],
      requestId: 'directory',
    );
  }

  @override
  Future<ProjectCreateDirectoryResponse> createProjectDirectory({
    required String parentPath,
    required String name,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    createDirectoryRequest = ProjectCreateDirectoryRequest(
      parentPath: parentPath,
      name: name,
      requestId: 'create',
    );
    final path = '$parentPath\\$name';
    return ProjectCreateDirectoryResponse(
      requestId: 'create',
      directoryPath: path,
      project: WorkspaceProjectDescriptor(
        projectId: 'project-created',
        projectDisplayName: name,
        projectRootPath: path,
        projectKind: WorkspaceProjectKind.nonGit,
      ),
      error: null,
      errorCode: null,
    );
  }

  @override
  Future<WorkspaceGithubSearchRepositoriesResponse> searchGithubRepositories({
    required String query,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    githubQueries.add(query);
    return const WorkspaceGithubSearchRepositoriesResponse(
      status: WorkspaceGithubSearchStatus.success,
      requestId: 'search',
      repositories: [
        GithubRepository(
          id: 'R_account',
          name: 'account-repo',
          nameWithOwner: 'owner/account-repo',
          description: 'Account project',
          visibility: GithubRepositoryVisibility.private,
          updatedAt: '2026-07-30T00:00:00Z',
          cloneUrl: 'git@github.com:owner/account-repo.git',
        ),
      ],
      available: true,
      error: null,
    );
  }

  @override
  Future<ProjectGithubCloneResponse> cloneGithubProject({
    required String repo,
    required String targetDirectory,
    ProjectGithubCloneProtocol? cloneProtocol,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    cloneRequest = ProjectGithubCloneRequest(
      requestId: 'clone',
      repo: repo,
      targetDirectory: targetDirectory,
      cloneProtocol: cloneProtocol,
    );
    return const ProjectGithubCloneResponse(
      requestId: 'clone',
      repo: 'owner/repo',
      checkoutPath: r'C:\workspace\repo',
      project: WorkspaceProjectDescriptor(
        projectId: 'project-1',
        projectDisplayName: 'repo',
        projectRootPath: r'C:\workspace\repo',
        projectKind: WorkspaceProjectKind.git,
      ),
      error: null,
    );
  }
}

void main() {
  test('global store replaces requests and resolves close results', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(addProjectFlowProvider.notifier);

    final first = notifier.open(preferredHostId: ' server-a ');
    expect(
      container.read(addProjectFlowProvider).request?.preferredHostId,
      'server-a',
    );
    final firstId = container.read(addProjectFlowProvider).request!.id;
    final second = notifier.open();
    expect(await first, isNull);
    expect(container.read(addProjectFlowProvider).request!.id, firstId + 1);

    const result = AddProjectFlowResult(
      serverId: 'server-a',
      project: ProjectInfo(path: '/repo', name: 'repo', isGitRepo: true),
    );
    notifier.close(result);
    expect(await second, same(result));
    expect(container.read(addProjectFlowProvider).request, isNull);
  });

  test('working-directory and picker options preserve frozen ordering', () {
    expect(
      buildWorkingDirectorySuggestions(
        recommendedPaths: const [
          '/Users/me/projects/paseo-desktop',
          '/Users/me/documents',
        ],
        serverPaths: const [
          '/Users/me/projects/paseo-plan',
          '/Users/me/projects/paseo-desktop',
        ],
        query: 'pso',
      ),
      const [
        '/Users/me/projects/paseo-desktop',
        '/Users/me/projects/paseo-plan',
      ],
    );
    expect(isOpenableProjectPath(r'C:\Users\mo\src'), isTrue);
    expect(isOpenableProjectPath('repo/sub'), isFalse);
    final options = buildProjectPickerOptions(
      recommendedPaths: const ['/repo/api'],
      serverPaths: const ['/repo/api'],
      query: '/repo',
    );
    expect(options.map((option) => option.kind), [
      ProjectPickerOptionKind.path,
      ProjectPickerOptionKind.suggestion,
    ]);
    expect(options.map((option) => option.path), ['/repo', '/repo/api']);
  });

  testWidgets('global host mounts one keyed flow and backdrop closes it', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FluentApp(
          home: Stack(
            fit: StackFit.expand,
            children: [SizedBox.expand(), AddProjectFlowHost()],
          ),
        ),
      ),
    );

    final result = container
        .read(addProjectFlowProvider.notifier)
        .open(preferredHostId: 'server-a');
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('add-project-flow-page-method')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(await result, isNull);
    expect(find.byKey(const ValueKey('add-project-flow')), findsNothing);
  });

  testWidgets('directory search registers and returns the selected project', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    AddProjectFlowResult? result;
    await _pumpDialog(tester, client, onAdded: (value) => result = value);

    expect(
      find.byKey(const ValueKey('add-project-flow-page-method')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-method-directory-search')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.byKey(const ValueKey('add-project-flow-page-directory-search')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      r'C:\scratch',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.directoryQueries, [r'C:\scratch']);
    await tester.tap(
      find.byKey(const ValueKey(r'add-project-flow-path-C:\scratch')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.addedPaths, [r'C:\scratch']);
    expect(result?.serverId, 'server-a');
    expect(result?.project.path, r'C:\scratch');
  });

  testWidgets('manual GitHub choice clones with the selected protocol', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    AddProjectFlowResult? result;
    await _pumpDialog(tester, client, onAdded: (value) => result = value);

    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-method-github')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      'owner/repo',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey('add-project-flow-repository-manual:https:owner/repo'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'add-project-flow-path-C:\workspace\repo')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.cloneRequest?.repo, 'owner/repo');
    expect(
      client.cloneRequest?.cloneProtocol,
      ProjectGithubCloneProtocol.https,
    );
    expect(result?.project.path, r'C:\workspace\repo');
    expect(result?.project.isGitRepo, isTrue);
  });

  testWidgets('GitHub account search includes daemon repositories', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    await _pumpDialog(tester, client, onAdded: (_) {});

    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-method-github')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      'account',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(client.githubQueries, ['account']);
    expect(
      find.byKey(const ValueKey('add-project-flow-repository-R_account')),
      findsOneWidget,
    );
    expect(find.text('Account project'), findsOneWidget);
  });

  testWidgets('new directory creates and returns the registered project', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    AddProjectFlowResult? result;
    await _pumpDialog(tester, client, onAdded: (value) => result = value);

    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-method-new-directory')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      r'C:\workspace',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(r'add-project-flow-path-C:\workspace')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      'new-project',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.createDirectoryRequest?.parentPath, r'C:\workspace');
    expect(client.createDirectoryRequest?.name, 'new-project');
    expect(result?.project.path, r'C:\workspace\new-project');
  });

  testWidgets('empty host flow routes through the Add host action', (
    tester,
  ) async {
    var closed = 0;
    var addHost = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: FluentApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              const SizedBox.expand(),
              AddProjectFlowDialog(
                request: const AddProjectFlowRequest(id: 1),
                hostsOverride: const [],
                clientsOverride: const {},
                recommendedPathsOverride: const {},
                onClose: () => closed += 1,
                onAddHost: () => addHost += 1,
                onAdded: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('add-project-flow-add-host')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(closed, 1);
    expect(addHost, 1);
  });

  testWidgets('keyboard Escape navigates back then closes the flow', (
    tester,
  ) async {
    final client = _FlowClient();
    addTearDown(client.dispose);
    var closed = 0;
    await _pumpDialog(
      tester,
      client,
      onAdded: (_) {},
      onClose: () => closed += 1,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Add project: method',
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-method-directory-search')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.byKey(const ValueKey('add-project-flow-page-directory-search')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('add-project-flow-page-method')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });
}

Future<void> _pumpDialog(
  WidgetTester tester,
  DaemonClient client, {
  required ValueChanged<AddProjectFlowResult> onAdded,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: FluentApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            const SizedBox.expand(),
            AddProjectFlowDialog(
              request: const AddProjectFlowRequest(
                id: 1,
                preferredHostId: 'server-a',
              ),
              hostsOverride: const [_host],
              clientsOverride: {'server-a': client},
              recommendedPathsOverride: const {
                'server-a': [r'C:\workspace\existing'],
              },
              onClose: onClose ?? () {},
              onAdded: onAdded,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}
