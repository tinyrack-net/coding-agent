import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _worktreePath = '/repo-a-wt/lucky-otter';

const _agent1 = AgentSummary(
  agentId: 'a1',
  title: 'Agent one',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _agent2 = AgentSummary(
  agentId: 'a2',
  title: 'Agent two',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 200,
);

/// Scriptable fake answering `terminal.list.request`; everything else is a
/// no-op empty response (agents are seeded directly via `.upsert()`).
class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({this.liveTerminalIds = const []})
      : super(uri: Uri.parse('ws://fake'));

  final List<String> liveTerminalIds;
  Object? terminalListError;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.disconnected;

  @override
  Stream<DaemonConnectionState> get connectionState => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.terminalListRequest) {
      final error = terminalListError;
      if (error != null) throw error;
      return {
        'terminals': [
          for (final id in liveTerminalIds)
            {'terminalId': id, 'cwd': _worktreePath, 'shell': 'bash'},
        ],
      };
    }
    return const {};
  }
}

/// Creates a container and waits for `worktreeTabLayoutsProvider`'s own
/// async `SharedPreferences` load to finish, so the family provider's very
/// first `build()` sees whatever was persisted rather than a still-empty
/// blob.
Future<ProviderContainer> makeContainer({FakeDaemonClient? client}) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client ?? FakeDaemonClient()),
    ],
  );
  addTearDown(container.dispose);
  container.read(worktreeTabLayoutsProvider);
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a worktree with no persisted layout and no live agents seeds one '
      'draft tab', () async {
    final container = await makeContainer();

    final state = container.read(worktreeTabsProvider(_worktreePath));

    expect(state.terminalsVerified, isTrue);
    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.draft);
    expect(state.layout.activeTabId, state.layout.tabs.single.tabId);
  });

  test('reconciliation adds a tab for a live agent missing from the '
      'persisted layout, and does not seed a draft alongside it', () async {
    final container = await makeContainer();
    container.read(agentsProvider.notifier).upsert(_agent1);

    final state = container.read(worktreeTabsProvider(_worktreePath));

    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.agent);
    expect(state.layout.tabs.single.agentId, 'a1');
  });

  test('reconciliation drops a persisted agent tab whose agent is no '
      'longer live', () async {
    SharedPreferences.setMockInitialValues({
      'worktree.tabLayouts': jsonEncode({
        _worktreePath: {
          'tabs': [
            {'tabId': 't1', 'kind': 'agent', 'agentId': 'gone'},
          ],
          'activeTabId': 't1',
        },
      }),
    });
    final container = await makeContainer();

    final state = container.read(worktreeTabsProvider(_worktreePath));

    // The dead agent tab is dropped, and since that leaves nothing, a draft
    // tab is seeded in its place.
    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.draft);
  });

  test(
      'a pending terminal tab is not treated as final until '
      'terminal.list.request resolves, and a dead one is dropped '
      'afterwards', () async {
    SharedPreferences.setMockInitialValues({
      'worktree.tabLayouts': jsonEncode({
        _worktreePath: {
          'tabs': [
            {
              'tabId': 't1',
              'kind': 'terminal',
              'lastKnownTerminalId': 'term-dead',
            },
          ],
          'activeTabId': 't1',
        },
      }),
    });
    final container =
        await makeContainer(client: FakeDaemonClient(liveTerminalIds: []));

    final initial = container.read(worktreeTabsProvider(_worktreePath));
    expect(initial.terminalsVerified, isFalse);
    expect(initial.layout.tabs.single.tabId, 't1');

    await Future<void>.delayed(const Duration(milliseconds: 10));

    final settled = container.read(worktreeTabsProvider(_worktreePath));
    expect(settled.terminalsVerified, isTrue);
    expect(settled.layout.tabs, hasLength(1));
    expect(settled.layout.tabs.single.kind, WorktreeTabKind.draft);
  });

  test('a pending terminal tab survives verification when it is still '
      'live on the daemon', () async {
    SharedPreferences.setMockInitialValues({
      'worktree.tabLayouts': jsonEncode({
        _worktreePath: {
          'tabs': [
            {
              'tabId': 't1',
              'kind': 'terminal',
              'lastKnownTerminalId': 'term-alive',
            },
          ],
          'activeTabId': 't1',
        },
      }),
    });
    final container = await makeContainer(
      client: FakeDaemonClient(liveTerminalIds: ['term-alive']),
    );
    container.read(worktreeTabsProvider(_worktreePath));

    await Future<void>.delayed(const Duration(milliseconds: 10));

    final settled = container.read(worktreeTabsProvider(_worktreePath));
    expect(settled.terminalsVerified, isTrue);
    expect(settled.layout.tabs, hasLength(1));
    expect(settled.layout.tabs.single.kind, WorktreeTabKind.terminal);
    expect(settled.layout.tabs.single.lastKnownTerminalId, 'term-alive');
  });

  test('addTab(draft) and addTab(terminal) append and activate a new tab',
      () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final before =
        container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(before, hasLength(1)); // the seeded draft

    final newTabId = notifier.addTab(WorktreeTabKind.terminal);

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(state.layout.tabs, hasLength(2));
    expect(state.layout.activeTabId, newTabId);
    expect(
      state.layout.tabs.where((t) => t.kind == WorktreeTabKind.terminal),
      hasLength(1),
    );
  });

  test(
      'retarget converts a draft tab into an agent tab in place when no '
      'reconciliation race intervenes', () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final draftTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .single
        .tabId;
    final secondTabId = notifier.addTab(WorktreeTabKind.terminal);

    // Simulates the real flow: `agentActionsProvider.create()` resolves
    // (upserting the new agent) immediately before `retarget` is called.
    container.read(agentsProvider.notifier).upsert(_agent1);
    notifier.retarget(draftTabId, 'a1');

    final tabs =
        container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(tabs.map((t) => t.tabId), [draftTabId, secondTabId]);
    expect(tabs.first.kind, WorktreeTabKind.agent);
    expect(tabs.first.agentId, 'a1');
  });

  test('retarget deduplicates instead of double-adding when reconciliation '
      'already added a tab for the agent', () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final draftTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .single
        .tabId;

    // Upsert, then force a rebuild (as an actively-watching widget would)
    // before retarget runs, so reconciliation adds its own tab for 'a1'
    // ahead of time.
    container.read(agentsProvider.notifier).upsert(_agent1);
    container.read(worktreeTabsProvider(_worktreePath));
    notifier.retarget(draftTabId, 'a1');

    final tabs =
        container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    expect(
      tabs.where((t) => t.kind == WorktreeTabKind.agent && t.agentId == 'a1'),
      hasLength(1),
    );
    expect(tabs.where((t) => t.kind == WorktreeTabKind.draft), isEmpty);
  });

  test('closeTab removes a tab and re-seeds a draft when that was the '
      'last one', () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final initialDraftId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .single
        .tabId;

    notifier.closeTab(initialDraftId);

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.draft);
    expect(state.layout.tabs.single.tabId, isNot(initialDraftId));
  });

  test('closeTab on one of several tabs leaves the others untouched',
      () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final draftTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .single
        .tabId;
    final terminalTabId = notifier.addTab(WorktreeTabKind.terminal);

    notifier.closeTab(draftTabId);

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.tabId, terminalTabId);
  });

  test('focusAgent activates an existing agent tab without duplicating it',
      () async {
    final container = await makeContainer();
    container.read(agentsProvider.notifier).upsert(_agent1);
    container.read(agentsProvider.notifier).upsert(_agent2);
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    final tabs =
        container.read(worktreeTabsProvider(_worktreePath)).layout.tabs;
    final a2Tab = tabs.firstWhere((t) => t.agentId == 'a2');

    notifier.focusAgent('a2');

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(state.layout.tabs, hasLength(2));
    expect(state.layout.activeTabId, a2Tab.tabId);
  });

  test('showDiffTab inserts a diff tab once and reactivates it on repeat '
      'calls', () async {
    final container = await makeContainer();
    final notifier =
        container.read(worktreeTabsProvider(_worktreePath).notifier);
    notifier.addTab(WorktreeTabKind.terminal);

    notifier.showDiffTab();
    final firstDiffTabId =
        container.read(worktreeTabsProvider(_worktreePath)).layout.activeTabId;

    notifier.setActiveTab(
      container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .first
          .tabId,
    );
    notifier.showDiffTab();

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      state.layout.tabs.where((t) => t.kind == WorktreeTabKind.diff),
      hasLength(1),
    );
    expect(state.layout.activeTabId, firstDiffTabId);
  });

  test('the reconciled layout is persisted and survives a fresh container',
      () async {
    final container1 = await makeContainer();
    final notifier1 =
        container1.read(worktreeTabsProvider(_worktreePath).notifier);
    notifier1.addTab(WorktreeTabKind.terminal);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final container2 = await makeContainer();
    final state = container2.read(worktreeTabsProvider(_worktreePath));

    expect(state.layout.tabs, hasLength(2));
  });
}
