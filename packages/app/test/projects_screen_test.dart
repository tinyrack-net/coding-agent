import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/projects_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = ProjectInfo(path: '/repo', name: 'repo', isGitRepo: true);

const _mainWorktree =
    WorktreeInfo(path: '/repo', branch: 'main', projectPath: '/repo', isMain: true);

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

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  Map<String, Object?> Function(String type, Map<String, Object?> payload)
      onRequest = (type, payload) => const {};

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
}

Future<ProviderContainer> pumpProjectsScreen(
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
      child: const MaterialApp(home: ProjectsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
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
    expect(
      tester.widget<ListTile>(mainTile).trailing,
      isNull,
    );
  });

  testWidgets('archiving an idle worktree requests worktree.archive',
      (tester) async {
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

    await tester.tap(find.byTooltip('Archive worktree'));
    await tester.pumpAndSettle();

    final archived = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.worktreeArchiveRequest);
    expect(archived.$2['path'], '/repo-wt/idle');
  });
}
