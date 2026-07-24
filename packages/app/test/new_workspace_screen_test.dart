import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _codex = ProviderInfo(
  id: ProviderId.openai,
  displayName: 'Codex',
  configured: true,
  models: [
    ProviderModel(id: 'sonnet', displayName: 'Sonnet'),
    ProviderModel(id: 'opus', displayName: 'Opus'),
  ],
);

const _createdAgent = AgentSummary(
  agentId: 'new-1',
  title: 'Agent',
  cwd: '/repo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
);

const _gitProject = ProjectInfo(path: '/repo', name: 'repo', isGitRepo: true);
const _plainProject = ProjectInfo(path: '/scratch', name: 'scratch', isGitRepo: false);

const _worktree = WorktreeInfo(
  path: '/repo-wt/lucky-otter',
  branch: 'lucky-otter',
  projectPath: '/repo',
);

/// Scriptable fake: `onRequest` decides responses per message type; every
/// call is recorded for assertions.
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  Map<String, Object?> Function(String type, Map<String, Object?> payload)
      onRequest = (type, payload) => const {};

  /// Agents known so far, mirrored so the connect-triggered
  /// `agent.list.request` doesn't race a just-created agent out of state.
  final List<AgentSummary> _agents = [];

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
    if (type == MessageTypes.agentListRequest) {
      return {'agents': _agents.map((a) => a.toJson()).toList()};
    }
    requests.add((type, payload));
    final result = onRequest(type, payload);
    if (type == MessageTypes.agentCreateRequest) {
      final agentJson = result['agent'] as Map<String, Object?>?;
      if (agentJson != null) _agents.add(AgentSummary.fromJson(agentJson));
    }
    return result;
  }
}

Future<ProviderContainer> pumpNewWorkspaceScreen(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: NewWorkspaceScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('no providers available shows guidance instead of the form',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return const {'providers': []};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(
      find.textContaining('No providers are configured yet'),
      findsOneWidget,
    );
    expect(find.text('Create'), findsNothing);
  });

  testWidgets('shows the "New workspace" title and no projects available '
      'blocks Create', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        return const {'projects': []};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(find.text('New workspace'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create'),
    );
    expect(createButton.onPressed, isNull);
  });

  testWidgets(
      'with a git project: defaults to Local isolation, and submitting '
      'creates a plain (non-worktree) agent and sends the prompt',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(find.text('repo'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      'fix the login bug',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final created = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(created.$2['cwd'], '/repo');
    expect(created.$2.containsKey('isWorktree'), isFalse);
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.worktreeCreateRequest),
      isFalse,
    );

    final prompted = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentPromptRequest);
    expect(prompted.$2['agentId'], 'new-1');
    expect(prompted.$2['text'], 'fix the login bug');
  });

  testWidgets(
      'switching Isolation to "New worktree" reveals the "Start from" '
      'picker; submitting creates a worktree with an auto-generated branch',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.branchListRequest) {
          return const BranchListResponse(
            branches: ['main', 'feature/x'],
            currentBranch: 'main',
          ).toJson();
        }
        if (type == MessageTypes.worktreeCreateRequest) {
          return {'worktree': _worktree.toJson()};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('Isolation'), findsOneWidget);
    await tester.tap(find.text('New worktree'));
    await tester.pumpAndSettle();

    expect(find.text('New worktree'), findsOneWidget);
    // Defaults to the project's current branch until the user picks one.
    expect(find.text('main'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final worktreeCreated = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.worktreeCreateRequest);
    expect(worktreeCreated.$2['projectPath'], '/repo');
    expect(worktreeCreated.$2['baseRef'], 'main');
    final branch = worktreeCreated.$2['branch'] as String;
    expect(branch, matches(RegExp(r'^[a-z]+-[a-z]+$')));

    final agentCreated = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(agentCreated.$2['cwd'], _worktree.path);
    expect(agentCreated.$2['projectPath'], '/repo');
    expect(agentCreated.$2['branch'], branch);
    expect(agentCreated.$2['isWorktree'], isTrue);
  });

  testWidgets('picking a branch in "Start from" uses it as baseRef',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.branchListRequest) {
          return const BranchListResponse(
            branches: ['main', 'feature/x'],
            currentBranch: 'main',
          ).toJson();
        }
        if (type == MessageTypes.worktreeCreateRequest) {
          return {'worktree': _worktree.toJson()};
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New worktree'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    expect(find.text('Start from'), findsOneWidget);
    await tester.tap(find.text('feature/x'));
    await tester.pumpAndSettle();

    expect(find.text('feature/x'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final worktreeCreated = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.worktreeCreateRequest);
    expect(worktreeCreated.$2['baseRef'], 'feature/x');
  });

  testWidgets(
      'the project picker lists all projects and switching resets '
      'isolation to Local', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson(), _plainProject.toJson()],
          };
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(find.text('repo'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);

    await tester.tap(find.text('repo'));
    await tester.pumpAndSettle();
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('scratch'), findsOneWidget);

    await tester.tap(find.text('scratch'));
    await tester.pumpAndSettle();

    expect(find.text('scratch'), findsOneWidget);
    // A non-git project has no Isolation picker at all.
    expect(find.text('Local'), findsNothing);
  });

  testWidgets('adding a project via the picker footer registers and '
      'selects it', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.projectAddRequest) {
          return {'project': _plainProject.toJson()};
        }
        return const {};
      };
    final container = await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('repo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add project'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Project path'),
      '/scratch',
    );
    // Deliberately avoid pumping after tapping Add: the dialog's local
    // `TextEditingController` is disposed as soon as the pop resolves, and
    // pumping through the exit animation's intermediate frames rebuilds the
    // (now-disposed) TextField mid-flight, tripping a debug-only framework
    // assertion (see the same documented pattern in the old
    // new_agent_screen_test.dart). `tester.tap` already settles the gesture
    // and the fake client resolves synchronously, so the project.add
    // request has already landed by this point.
    await tester.tap(find.text('Add'));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.projectAddRequest),
      isTrue,
    );
    expect(
      container.read(projectsProvider).value?.map((p) => p.path),
      contains('/scratch'),
    );
  });

  testWidgets('a failed create shows an inline error message', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.agentCreateRequest) {
          throw StateError('daemon rejected the request');
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to create worktree'), findsOneWidget);
    expect(find.byType(NewWorkspaceScreen), findsOneWidget);
  });

  testWidgets('submitting with an empty prompt does not send agent.prompt',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentPromptRequest),
      isFalse,
    );
  });
}
