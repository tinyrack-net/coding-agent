import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/draft_session_composer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _worktreePath = '/repo-wt/lucky-otter';

const _claude = ProviderInfo(
  id: 'openai',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.openai.example/v1',
  displayName: 'Claude',
  configured: true,
  models: [
    ProviderModel(id: 'sonnet', displayName: 'Sonnet'),
    ProviderModel(id: 'opus', displayName: 'Opus'),
  ],
);

const _createdAgent = AgentSummary(
  agentId: 'new-1',
  title: 'Agent',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  projectPath: '/repo',
  branch: 'lucky-otter',
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

Future<ProviderContainer> pumpComposer(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);

  // Seed the worktree's tab layout with a real draft tab (the empty
  // invariant auto-seeds one) so retarget() has a matching tabId to convert
  // in place, mirroring how a real draft tab always exists before its
  // composer is shown.
  final tabId =
      container.read(worktreeTabsProvider(_worktreePath)).layout.tabs.single.tabId;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: DraftSessionComposer(
            worktreePath: _worktreePath,
            tabId: tabId,
            projectPath: '/repo',
            branch: 'lucky-otter',
            isWorktree: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('no configured providers shows guidance instead of the form',
      (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return const {'providers': []};
        }
        return const {};
      };
    await pumpComposer(tester, client);

    expect(find.textContaining('No providers are configured'), findsOneWidget);
    expect(find.byType(ComboBox<String>), findsNothing);
  });

  testWidgets(
      'submitting creates the agent with the fixed worktree cwd/project/'
      'branch and retargets the draft tab in place', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    final container = await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'do the thing');
    await tester.tap(find.text('Create'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final createReq = client.requests
        .singleWhere((r) => r.$1 == MessageTypes.agentCreateRequest);
    expect(createReq.$2['cwd'], _worktreePath);
    expect(createReq.$2['projectPath'], '/repo');
    expect(createReq.$2['branch'], 'lucky-otter');
    expect(createReq.$2['isWorktree'], isTrue);

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentPromptRequest),
      isTrue,
    );

    final layout =
        container.read(worktreeTabsProvider(_worktreePath)).layout;
    final tab = layout.tabs.single;
    expect(tab.kind, WorktreeTabKind.agent);
    expect(tab.agentId, 'new-1');
  });

  testWidgets('a create failure surfaces an inline error and leaves the '
      'draft tab untouched', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        if (type == MessageTypes.agentCreateRequest) {
          throw StateError('daemon unavailable');
        }
        return const {};
      };
    final container = await pumpComposer(tester, client);

    await tester.tap(find.text('Create'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to create agent'), findsOneWidget);
    final layout =
        container.read(worktreeTabsProvider(_worktreePath)).layout;
    expect(layout.tabs.single.kind, WorktreeTabKind.draft);
  });
}
