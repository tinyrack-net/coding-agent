import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
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

const _sameWorkspaceChild = AgentSummary(
  agentId: 'child',
  title: 'Managed child',
  cwd: _worktreePath,
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 300,
  workspaceId: 'workspace-a',
  parentAgentId: 'a1',
);

const _workspaceParent = AgentSummary(
  agentId: 'a1',
  title: 'Parent',
  cwd: _worktreePath,
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
  workspaceId: 'workspace-a',
);

const _crossWorkspaceParent = AgentSummary(
  agentId: 'a1',
  title: 'Parent',
  cwd: '/parent',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
  workspaceId: 'workspace-a',
);

const _crossWorkspaceChild = AgentSummary(
  agentId: 'child',
  title: 'Managed child',
  cwd: _worktreePath,
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.running,
  createdAtMs: 300,
  workspaceId: 'workspace-b',
  parentAgentId: 'a1',
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
        createdAt: '2026-07-29T00:00:00.000Z',
        updatedAt: '2026-07-29T00:00:00.000Z',
      ),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

WorkspaceDescriptor _workspace(String id, String directory) =>
    WorkspaceDescriptor(
      id: id,
      projectId: 'project-a',
      projectDisplayName: 'Project A',
      projectRootPath: '/repo-a',
      workspaceDirectory: directory,
      projectKind: WorkspaceProjectKind.git,
      workspaceKind: WorkspaceKind.worktree,
      name: id,
      status: WorkspaceStateBucket.done,
      activityAt: null,
    );

/// Creates a container and waits for `worktreeTabLayoutsProvider`'s own
/// async `SharedPreferences` load to finish, so the family provider's very
/// first `build()` sees whatever was persisted rather than a still-empty
/// blob.
Future<ProviderContainer> makeContainer({
  FakeDaemonClient? client,
  String? persistenceKey,
}) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client ?? FakeDaemonClient()),
      if (persistenceKey != null)
        worktreeTabPersistenceKeyProvider.overrideWith(
          (ref, worktreePath) => persistenceKey,
        ),
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

  test('workspace catalog resolves the canonical server/workspace key', () {
    final container = ProviderContainer(
      overrides: [hostRegistryProvider.overrideWith(_ActiveRegistry.new)],
    );
    addTearDown(container.dispose);
    container.read(workspaceCatalogCacheProvider.notifier).replace('server-a', [
      _workspace('workspace-a', _worktreePath),
    ]);

    expect(
      container.read(worktreeTabPersistenceKeyProvider(_worktreePath)),
      'server-a:workspace-a',
    );
  });

  test(
    'canonical persistence migrates and removes the directory key',
    () async {
      SharedPreferences.setMockInitialValues({
        'worktree.tabLayouts': jsonEncode({
          _worktreePath: {
            'tabs': [
              {'tabId': 'legacy-draft', 'kind': 'draft'},
            ],
            'activeTabId': 'legacy-draft',
          },
        }),
      });
      final container = await makeContainer(
        persistenceKey: 'server-a:workspace-a',
      );

      final state = container.read(worktreeTabsProvider(_worktreePath));
      expect(state.layout.tabs.single.tabId, 'legacy-draft');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final stored =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  'worktree.tabLayouts',
                )!,
              )
              as Map<String, Object?>;
      expect(stored, contains('server-a:workspace-a'));
      expect(stored, isNot(contains(_worktreePath)));
    },
  );

  test('late catalog hydration preserves the in-memory layout while switching '
      'to the canonical key', () async {
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(FakeDaemonClient()),
        hostRegistryProvider.overrideWith(_ActiveRegistry.new),
      ],
    );
    addTearDown(container.dispose);
    container.read(worktreeTabLayoutsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final before = container.read(worktreeTabsProvider(_worktreePath));
    final draftId = before.layout.tabs.single.tabId;

    container.read(workspaceCatalogCacheProvider.notifier).replace('server-a', [
      _workspace('workspace-a', _worktreePath),
    ]);

    final after = container.read(worktreeTabsProvider(_worktreePath));
    expect(after.layout.tabs.single.tabId, draftId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final stored =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                'worktree.tabLayouts',
              )!,
            )
            as Map<String, Object?>;
    expect(stored, contains('server-a:workspace-a'));
    expect(stored, isNot(contains(_worktreePath)));
  });

  test('refocusing the already active pane is a no-op', () async {
    final container = await makeContainer();
    final provider = worktreeTabsProvider(_worktreePath);
    final state = container.read(provider);
    var notifications = 0;
    final subscription = container.listen(
      provider,
      (_, _) => notifications += 1,
    );
    addTearDown(subscription.close);

    container
        .read(provider.notifier)
        .focusPaneById(state.layout.paneLayout!.focusedPaneId!);

    expect(notifications, 0);
    expect(container.read(provider), same(state));
  });

  test(
    'provider subagent tabs are addressable, deduplicated, and persisted',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );

      notifier.focusProviderSubagent('parent', 'child');
      notifier.focusProviderSubagent('parent', 'child');
      final tabs = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.providerSubagent)
          .toList();
      expect(tabs, hasLength(1));
      expect(tabs.single.parentAgentId, 'parent');
      expect(tabs.single.subagentId, 'child');
      expect(WorktreeTab.fromJson(tabs.single.toJson()), tabs.single);
    },
  );

  test('reconciliation adds a tab for a live agent missing from the '
      'persisted layout, and does not seed a draft alongside it', () async {
    final container = await makeContainer();
    container.read(agentsProvider.notifier).upsert(_agent1);

    final state = container.read(worktreeTabsProvider(_worktreePath));

    expect(state.layout.tabs, hasLength(1));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.agent);
    expect(state.layout.tabs.single.agentId, 'a1');
  });

  test('reconciliation auto-opens only workspace root agents', () async {
    final container = await makeContainer();
    container.read(agentsProvider.notifier).upsert(_workspaceParent);
    container.read(agentsProvider.notifier).upsert(_sameWorkspaceChild);

    var state = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      state.layout.tabs.where((tab) => tab.kind == WorktreeTabKind.agent),
      hasLength(1),
    );
    expect(state.layout.tabs.single.agentId, 'a1');

    container
        .read(worktreeTabsProvider(_worktreePath).notifier)
        .focusAgent('child');
    state = container.read(worktreeTabsProvider(_worktreePath));
    expect(
      state.layout.tabs
          .where((tab) => tab.kind == WorktreeTabKind.agent)
          .map((tab) => tab.agentId),
      containsAll(['a1', 'child']),
    );
  });

  test('cross-workspace managed child is auto-opened as a root', () async {
    final container = await makeContainer();
    container.read(agentsProvider.notifier).upsert(_crossWorkspaceParent);
    container.read(agentsProvider.notifier).upsert(_crossWorkspaceChild);

    final state = container.read(worktreeTabsProvider(_worktreePath));
    expect(state.layout.tabs.single.kind, WorktreeTabKind.agent);
    expect(state.layout.tabs.single.agentId, 'child');
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
    'pinned agent survives catalog gaps, persists, and unpins on close',
    () async {
      SharedPreferences.setMockInitialValues({
        'worktree.tabLayouts': jsonEncode({
          _worktreePath: {
            'tabs': [
              {
                'tabId': 'agent:archived',
                'kind': 'agent',
                'agentId': 'archived',
              },
            ],
            'activeTabId': 'agent:archived',
            'pinnedAgentIds': ['archived'],
          },
        }),
      });
      final container = await makeContainer();
      final provider = worktreeTabsProvider(_worktreePath);

      var layout = container.read(provider).layout;
      expect(layout.tabs.single.agentId, 'archived');
      expect(layout.pinnedAgentIds, {'archived'});
      expect(WorktreeTabLayout.fromJson(layout.toJson()), layout);

      container.read(provider.notifier).closeTab('agent:archived');
      layout = container.read(provider).layout;
      expect(layout.tabs.single.kind, WorktreeTabKind.draft);
      expect(layout.pinnedAgentIds, isEmpty);
    },
  );

  test('a pending terminal tab is not treated as final until '
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
    final container = await makeContainer(
      client: FakeDaemonClient(liveTerminalIds: []),
    );

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

  test(
    'addTab(draft) and addTab(terminal) append and activate a new tab',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      final before = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs;
      expect(before, hasLength(1)); // the seeded draft

      final newTabId = notifier.addTab(WorktreeTabKind.terminal);

      final state = container.read(worktreeTabsProvider(_worktreePath));
      expect(state.layout.tabs, hasLength(2));
      expect(state.layout.activeTabId, newTabId);
      expect(
        state.layout.tabs.where((t) => t.kind == WorktreeTabKind.terminal),
        hasLength(1),
      );
    },
  );

  test(
    'route open targets are identity-stable and draft:new is fresh',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );

      final terminalId = notifier.focusOpenIntentTarget(
        const WorkspaceTerminalTabTarget(terminalId: 'terminal-1'),
      );
      expect(
        notifier.focusOpenIntentTarget(
          const WorkspaceTerminalTabTarget(terminalId: 'terminal-1'),
        ),
        terminalId,
      );
      final setupId = notifier.focusOpenIntentTarget(
        const WorkspaceSetupTabTarget(workspaceId: 'workspace-1'),
      );
      expect(
        notifier.focusOpenIntentTarget(
          const WorkspaceSetupTabTarget(workspaceId: 'workspace-1'),
        ),
        setupId,
      );
      final draftOne = notifier.focusOpenIntentTarget(
        const WorkspaceDraftTabTarget(draftId: 'new'),
      );
      final draftTwo = notifier.focusOpenIntentTarget(
        const WorkspaceDraftTabTarget(draftId: 'new'),
      );

      final state = container.read(worktreeTabsProvider(_worktreePath));
      expect(draftOne, isNot(draftTwo));
      expect(
        state.layout.tabs
            .where((tab) => tab.kind == WorktreeTabKind.terminal)
            .single
            .lastKnownTerminalId,
        'terminal-1',
      );
      expect(
        state.layout.tabs
            .where((tab) => tab.kind == WorktreeTabKind.setup)
            .single
            .setupWorkspaceId,
        'workspace-1',
      );
      expect(
        state.layout.tabs.where((tab) => tab.kind == WorktreeTabKind.draft),
        hasLength(3),
      );
    },
  );

  test('retarget converts a draft tab into an agent tab in place when no '
      'reconciliation race intervenes', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
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

    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    expect(tabs.map((t) => t.tabId), [draftTabId, secondTabId]);
    expect(tabs.first.kind, WorktreeTabKind.agent);
    expect(tabs.first.agentId, 'a1');
  });

  test('retarget deduplicates instead of double-adding when reconciliation '
      'already added a tab for the agent', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
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

    final tabs = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs;
    expect(
      tabs.where((t) => t.kind == WorktreeTabKind.agent && t.agentId == 'a1'),
      hasLength(1),
    );
    expect(tabs.where((t) => t.kind == WorktreeTabKind.draft), isEmpty);
  });

  test('closeTab removes a tab and re-seeds a draft when that was the '
      'last one', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
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

  test('closeTab on one of several tabs leaves the others untouched', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
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

  test(
    'focusAgent activates an existing agent tab without duplicating it',
    () async {
      final container = await makeContainer();
      container.read(agentsProvider.notifier).upsert(_agent1);
      container.read(agentsProvider.notifier).upsert(_agent2);
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      final tabs = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs;
      final a2Tab = tabs.firstWhere((t) => t.agentId == 'a2');

      notifier.focusAgent('a2');

      final state = container.read(worktreeTabsProvider(_worktreePath));
      expect(state.layout.tabs, hasLength(2));
      expect(state.layout.activeTabId, a2Tab.tabId);
    },
  );

  test(
    'focusAgent pin is idempotent and survives unrelated layout updates',
    () async {
      final container = await makeContainer();
      final provider = worktreeTabsProvider(_worktreePath);
      final notifier = container.read(provider.notifier);

      notifier.focusAgent('deep-linked', pin: true);
      notifier.focusAgent('deep-linked', pin: true);
      notifier.addTab(WorktreeTabKind.terminal);

      final layout = container.read(provider).layout;
      expect(layout.pinnedAgentIds, {'deep-linked'});
      expect(
        layout.tabs.where((tab) => tab.agentId == 'deep-linked'),
        hasLength(1),
      );
    },
  );

  test('showDiffTab inserts a diff tab once and reactivates it on repeat '
      'calls', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    notifier.addTab(WorktreeTabKind.terminal);

    notifier.showDiffTab();
    final firstDiffTabId = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .activeTabId;

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
    expect(firstDiffTabId, 'working_diff');
  });

  test('commit diff tabs reuse SHA identity but remain runtime-only', () async {
    const persistenceKey = 'server-a:workspace-a';
    final container = await makeContainer(persistenceKey: persistenceKey);
    final provider = worktreeTabsProvider(_worktreePath);
    final notifier = container.read(provider.notifier);

    notifier.showCommitDiffTab(' abcdef0123456789 ');
    notifier.showCommitDiffTab('abcdef0123456789');
    notifier.showCommitDiffTab('fedcba9876543210');

    final runtime = container.read(provider).layout;
    final commits = runtime.tabs
        .where((tab) => tab.kind == WorktreeTabKind.commitDiff)
        .toList();
    expect(commits, hasLength(2));
    expect(commits.first.tabId, 'commit_diff_abcdef0123456789');
    expect(commits.first.commitSha, 'abcdef0123456789');
    expect(runtime.activeTabId, 'commit_diff_fedcba9876543210');
    expect(
      notifier.focusOpenIntentTarget(
        const WorkspaceCommitDiffTabTarget(sha: 'abcdef0123456789'),
      ),
      'commit_diff_abcdef0123456789',
    );
    expect(
      container.read(provider).layout.activeTabId,
      'commit_diff_abcdef0123456789',
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    final persisted = container.read(
      worktreeTabLayoutsProvider,
    )[persistenceKey]!;
    expect(
      persisted.tabs.where((tab) => tab.kind == WorktreeTabKind.commitDiff),
      isEmpty,
    );
    expect(
      jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          'worktree.tabLayouts',
        )!,
      ).toString(),
      isNot(contains('commitDiff')),
    );
  });

  test(
    'working diff open intents update the singleton focus request',
    () async {
      final container = await makeContainer();
      final provider = worktreeTabsProvider(_worktreePath);
      final notifier = container.read(provider.notifier);

      final firstId = notifier.focusOpenIntentTarget(
        const WorkspaceWorkingDiffTabTarget(
          focusPath: 'lib/first.dart',
          focusRequestId: 1,
        ),
      );
      final secondId = notifier.focusOpenIntentTarget(
        const WorkspaceWorkingDiffTabTarget(
          focusPath: 'lib/second.dart',
          focusRequestId: 2,
        ),
      );
      var diffTabs = container
          .read(provider)
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.diff)
          .toList();

      expect(firstId, 'working_diff');
      expect(secondId, firstId);
      expect(diffTabs, hasLength(1));
      expect(diffTabs.single.diffFocusPath, 'lib/second.dart');
      expect(diffTabs.single.diffFocusRequestId, 2);
      expect(
        workspaceTabTargetsEqual(
          diffTabs.single.workspaceTarget!,
          const WorkspaceWorkingDiffTabTarget(
            focusPath: 'lib/second.dart',
            focusRequestId: 2,
          ),
        ),
        isTrue,
      );
      expect(WorktreeTab.fromJson(diffTabs.single.toJson()), diffTabs.single);

      notifier.showDiffTab(focusPath: r' lib\third.dart ', focusRequestId: -1);
      diffTabs = container
          .read(provider)
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.diff)
          .toList();
      expect(diffTabs.single.diffFocusPath, 'lib/third.dart');
      expect(diffTabs.single.diffFocusRequestId, isNull);

      notifier.showDiffTab();
      diffTabs = container
          .read(provider)
          .layout
          .tabs
          .where((tab) => tab.kind == WorktreeTabKind.diff)
          .toList();
      expect(diffTabs.single.diffFocusPath, isNull);
      expect(diffTabs.single.diffFocusRequestId, isNull);
    },
  );

  test('openFile reuses path identity and advances line navigation', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );

    notifier.openFile(
      const WorkspaceFileLocation(path: r'lib\main.dart', lineStart: 4),
    );
    final first = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .singleWhere((tab) => tab.kind == WorktreeTabKind.file);
    expect(first.filePath, 'lib/main.dart');
    expect(first.tabId, 'file_lib/main.dart');
    expect(first.lineStart, 4);
    expect(first.fileNavigationRevision, 0);

    notifier.openFile(
      const WorkspaceFileLocation(
        path: 'lib/main.dart',
        lineStart: 8,
        lineEnd: 10,
      ),
    );
    final state = container.read(worktreeTabsProvider(_worktreePath));
    final files = state.layout.tabs
        .where((tab) => tab.kind == WorktreeTabKind.file)
        .toList();
    expect(files, hasLength(1));
    expect(files.single.tabId, first.tabId);
    expect(files.single.lineStart, 8);
    expect(files.single.lineEnd, 10);
    expect(files.single.fileNavigationRevision, 1);
    expect(state.layout.activeTabId, first.tabId);

    notifier.openFile(const WorkspaceFileLocation(path: 'lib/main.dart'));
    final cleared = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .singleWhere((tab) => tab.kind == WorktreeTabKind.file);
    expect(cleared.lineStart, isNull);
    expect(cleared.lineEnd, isNull);
    expect(cleared.fileNavigationRevision, 2);
  });

  test(
    'side file open splits right and reuses the resulting side pane',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );

      notifier.openFileInSidePane(
        const WorkspaceFileLocation(path: 'lib/main.dart'),
      );
      var layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      var panes = collectWorkspacePanes(layout.paneLayout!.root);
      expect(panes, hasLength(2));
      final firstFile = layout.tabs.singleWhere(
        (tab) => tab.kind == WorktreeTabKind.file,
      );
      final sidePane = findWorkspacePaneContainingTab(
        layout.paneLayout!.root,
        firstFile.tabId,
      )!;
      expect(sidePane.id, isNot('pane_root'));
      expect(layout.paneLayout!.focusedPaneId, sidePane.id);

      notifier.focusPaneById('pane_root');
      notifier.openFileInSidePane(
        const WorkspaceFileLocation(path: 'test/app_test.dart'),
      );
      layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      panes = collectWorkspacePanes(layout.paneLayout!.root);
      expect(panes, hasLength(2));
      final secondFile = layout.tabs.singleWhere(
        (tab) => tab.filePath == 'test/app_test.dart',
      );
      expect(
        findWorkspacePaneContainingTab(
          layout.paneLayout!.root,
          secondFile.tabId,
        )!.id,
        sidePane.id,
      );
    },
  );

  test('side open of an existing file keeps its original pane', () async {
    final container = await makeContainer();
    final notifier = container.read(
      worktreeTabsProvider(_worktreePath).notifier,
    );
    notifier.openFile(const WorkspaceFileLocation(path: 'lib/main.dart'));
    final original = container
        .read(worktreeTabsProvider(_worktreePath))
        .layout
        .tabs
        .singleWhere((tab) => tab.kind == WorktreeTabKind.file);

    notifier.openFileInSidePane(
      const WorkspaceFileLocation(path: 'lib/main.dart', lineStart: 9),
    );
    final layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
    expect(collectWorkspacePanes(layout.paneLayout!.root), hasLength(1));
    expect(layout.activeTabId, original.tabId);
    expect(
      layout.tabs.singleWhere((tab) => tab.tabId == original.tabId).lineStart,
      9,
    );
  });

  test(
    'the reconciled layout is persisted and survives a fresh container',
    () async {
      final container1 = await makeContainer();
      final notifier1 = container1.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      notifier1.addTab(WorktreeTabKind.terminal);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final container2 = await makeContainer();
      final state = container2.read(worktreeTabsProvider(_worktreePath));

      expect(state.layout.tabs, hasLength(2));
    },
  );

  test(
    'pane notifier actions split, focus, move, and enforce max depth',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );

      notifier.focusPane(WorkspacePaneDirection.left);
      notifier.moveActiveTab(WorkspacePaneDirection.left);
      notifier.focusPaneById('missing');

      final rightPane = notifier.splitFocusedPane(
        WorkspaceSplitDirection.horizontal,
      );
      expect(rightPane, isNotNull);
      expect(notifier.focusedPaneTabs(), hasLength(1));

      notifier.focusPane(WorkspacePaneDirection.left);
      var layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(layout.paneLayout!.focusedPaneId, 'pane_root');
      notifier.focusPaneById(rightPane!);
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .focusedPaneId,
        rightPane,
      );

      notifier.focusPane(WorkspacePaneDirection.left);
      notifier.moveActiveTab(WorkspacePaneDirection.right);
      layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      expect(collectWorkspacePanes(layout.paneLayout!.root), hasLength(1));

      final downPane = notifier.splitFocusedPane(
        WorkspaceSplitDirection.vertical,
      );
      expect(downPane, isNotNull);
      notifier.focusPane(WorkspacePaneDirection.up);
      notifier.moveActiveTab(WorkspacePaneDirection.down);
      notifier.focusPane(WorkspacePaneDirection.up);
      notifier.moveActiveTab(WorkspacePaneDirection.down);
      expect(
        collectWorkspacePanes(
          container
              .read(worktreeTabsProvider(_worktreePath))
              .layout
              .paneLayout!
              .root,
        ),
        hasLength(1),
      );

      for (
        var index = 0;
        index < WorkspacePaneLayout.maxTreeDepth - 1;
        index++
      ) {
        expect(
          notifier.splitFocusedPane(
            index.isEven
                ? WorkspaceSplitDirection.horizontal
                : WorkspaceSplitDirection.vertical,
          ),
          isNotNull,
        );
      }
      expect(
        notifier.splitFocusedPane(WorkspaceSplitDirection.vertical),
        isNull,
      );
    },
  );

  test(
    'pane resize, reorder, and indexed cross-pane move are persisted',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      final firstId = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .tabs
          .single
          .tabId;
      final secondId = notifier.addTab(WorktreeTabKind.terminal);
      final rightPane = notifier.splitFocusedPane(
        WorkspaceSplitDirection.horizontal,
      )!;
      var paneLayout = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .paneLayout!;
      final group = paneLayout.root as WorkspacePaneGroup;

      notifier.resizeSplit(group.id, const [.7, .3]);
      paneLayout = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .paneLayout!;
      expect((paneLayout.root as WorkspacePaneGroup).sizes, const [.7, .3]);

      notifier.reorderTabsInPane('pane_root', [secondId]);
      expect(
        findWorkspacePane(
          container
              .read(worktreeTabsProvider(_worktreePath))
              .layout
              .paneLayout!
              .root,
          'pane_root',
        )!.tabIds,
        [secondId, firstId],
      );

      notifier.moveTabToPaneIndex(
        tabId: firstId,
        targetPaneId: rightPane,
        insertionIndex: 0,
      );
      final state = container.read(worktreeTabsProvider(_worktreePath));
      expect(
        findWorkspacePane(
          state.layout.paneLayout!.root,
          rightPane,
        )!.tabIds.first,
        firstId,
      );
      expect(state.layout.activeTabId, firstId);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final restoredContainer = await makeContainer();
      final restored = restoredContainer
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .paneLayout!;
      expect((restored.root as WorkspacePaneGroup).sizes, const [.7, .3]);
      expect(
        findWorkspacePane(restored.root, rightPane)!.tabIds.first,
        firstId,
      );
    },
  );

  test(
    'edge split moves the active tab into a positioned persisted pane',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      final tabId = container
          .read(worktreeTabsProvider(_worktreePath))
          .layout
          .activeTabId!;

      expect(
        notifier.splitTabAtPosition(
          tabId: tabId,
          targetPaneId: 'pane_root',
          position: WorkspaceSplitDropPosition.left,
        ),
        isNotNull,
      );
      final state = container.read(worktreeTabsProvider(_worktreePath));
      final group = state.layout.paneLayout!.root as WorkspacePaneGroup;
      expect(group.direction, WorkspaceSplitDirection.horizontal);
      expect(
        findWorkspacePaneContainingTab(group, tabId)!.id,
        state.layout.paneLayout!.focusedPaneId,
      );
      expect(
        notifier.splitTabAtPosition(
          tabId: tabId,
          targetPaneId: 'pane_root',
          position: WorkspaceSplitDropPosition.center,
        ),
        isNull,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final restoredContainer = await makeContainer();
      expect(
        collectWorkspacePanes(
          restoredContainer
              .read(worktreeTabsProvider(_worktreePath))
              .layout
              .paneLayout!
              .root,
        ),
        hasLength(2),
      );
    },
  );

  test(
    'nested pane focus restoration ignores stale and invalid tokens',
    () async {
      final container = await makeContainer();
      final notifier = container.read(
        worktreeTabsProvider(_worktreePath).notifier,
      );
      final rightPane = notifier.splitFocusedPane(
        WorkspaceSplitDirection.horizontal,
      )!;
      notifier.focusPaneById('pane_root');

      final outerToken = notifier.unfocusPane();
      final innerToken = notifier.unfocusPane();
      expect(outerToken, isNotNull);
      expect(innerToken, isNotNull);
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .focusedPaneId,
        isNull,
      );
      notifier.restorePaneFocus('invalid');
      notifier.restorePaneFocus(outerToken);
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .focusedPaneId,
        isNull,
      );
      notifier.restorePaneFocus(innerToken);
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .focusedPaneId,
        'pane_root',
      );

      final staleToken = notifier.unfocusPane();
      notifier.focusPaneById(rightPane);
      notifier.restorePaneFocus(staleToken);
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .paneLayout!
            .focusedPaneId,
        rightPane,
      );
    },
  );
}
