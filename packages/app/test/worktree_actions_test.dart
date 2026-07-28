import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/worktree_actions.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/fluent/toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

const _worktreeAgent = AgentSummary(
  agentId: 'agent-1',
  title: 'Worktree agent',
  cwd: '/repo-worktrees/feature',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  projectPath: '/repo',
  branch: 'feature',
  isWorktree: true,
);

class _FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  _FakeDaemonClient({this.agents = const [_worktreeAgent]})
    : super(uri: Uri.parse('ws://fake'));

  final List<AgentSummary> agents;
  final requests = <(String, Map<String, Object?>)>[];
  bool conflictOnce = false;
  Object? archiveError;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState => const Stream.empty();

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.agentListRequest) {
      return {'agents': agents.map((agent) => agent.toJson()).toList()};
    }
    if (type == MessageTypes.worktreeListRequest) {
      return {'worktrees': <Object?>[]};
    }
    if (type == MessageTypes.worktreeArchiveRequest) {
      if (conflictOnce && payload['force'] != true) {
        conflictOnce = false;
        throw DaemonRpcException(
          const RpcError(
            code: RpcErrorCodes.conflict,
            message: 'uncommitted changes',
          ),
        );
      }
      if (archiveError case final error?) throw error;
    }
    return const {};
  }
}

Future<ProviderContainer> _pumpAction(
  WidgetTester tester, {
  required _FakeDaemonClient client,
  required Future<void> Function(BuildContext, WidgetRef) action,
}) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: Builder(
          builder: (context) => Consumer(
            builder: (context, ref, _) => Button(
              onPressed: () => action(context, ref),
              child: const Text('Run action'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  tearDown(AppToast.dismissCurrent);

  testWidgets('archiving the final worktree agent offers removal', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    final container = await _pumpAction(
      tester,
      client: client,
      action: (context, ref) =>
          archiveAgentWithWorktreeConfirm(context, ref, _worktreeAgent),
    );
    container.read(agentsProvider.notifier).upsert(_worktreeAgent);

    await tester.tap(find.text('Run action'));
    await tester.pumpAndSettle();
    expect(find.text('Delete worktree?'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.agentArchiveRequest,
      ),
      hasLength(1),
    );
    expect(
      client.requests.where(
        (request) => request.$1 == MessageTypes.worktreeArchiveRequest,
      ),
      hasLength(1),
    );
  });

  testWidgets('a shared worktree is retained after one agent is archived', (
    tester,
  ) async {
    const other = AgentSummary(
      agentId: 'agent-2',
      title: 'Other',
      cwd: '/repo-worktrees/feature',
      provider: 'codex',
      model: 'gpt',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 2,
    );
    final client = _FakeDaemonClient(agents: const [_worktreeAgent, other]);
    final container = await _pumpAction(
      tester,
      client: client,
      action: (context, ref) =>
          archiveAgentWithWorktreeConfirm(context, ref, _worktreeAgent),
    );
    container.read(agentsProvider.notifier)
      ..upsert(_worktreeAgent)
      ..upsert(other);

    await tester.tap(find.text('Run action'));
    await tester.pumpAndSettle();

    expect(find.text('Delete worktree?'), findsNothing);
    expect(
      client.requests.any(
        (request) => request.$1 == MessageTypes.worktreeArchiveRequest,
      ),
      isFalse,
    );
  });

  testWidgets('dirty worktree removal confirms and retries with force', (
    tester,
  ) async {
    final client = _FakeDaemonClient()..conflictOnce = true;
    await _pumpAction(
      tester,
      client: client,
      action: (context, ref) => archiveWorktreeWithConfirm(
        context,
        ref,
        '/repo',
        '/repo-worktrees/feature',
      ),
    );

    await tester.tap(find.text('Run action'));
    await tester.pumpAndSettle();
    expect(find.text('Uncommitted changes'), findsOneWidget);

    await tester.tap(find.text('Discard and remove'));
    await tester.pumpAndSettle();

    final removals = client.requests
        .where((request) => request.$1 == MessageTypes.worktreeArchiveRequest)
        .toList();
    expect(removals, hasLength(2));
    expect(removals.first.$2.containsKey('force'), isFalse);
    expect(removals.last.$2['force'], isTrue);
  });

  testWidgets('non-conflict worktree failures are shown as a toast', (
    tester,
  ) async {
    final client = _FakeDaemonClient()
      ..archiveError = DaemonRpcException(
        const RpcError(code: RpcErrorCodes.internal, message: 'broken'),
      );
    await _pumpAction(
      tester,
      client: client,
      action: (context, ref) => archiveWorktreeWithConfirm(
        context,
        ref,
        '/repo',
        '/repo-worktrees/feature',
      ),
    );

    await tester.tap(find.text('Run action'));
    await tester.pump();
    expect(find.text('Failed to remove worktree: broken'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
