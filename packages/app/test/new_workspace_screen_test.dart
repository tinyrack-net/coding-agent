import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachment_service.dart';
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/create_flow_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/add_project_flow_host.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

const _codex = ProviderInfo(
  id: ProviderId.openai,
  displayName: 'Codex',
  configured: true,
  models: [
    ProviderModel(id: 'sonnet', displayName: 'Sonnet'),
    ProviderModel(id: 'opus', displayName: 'Opus'),
  ],
);

const _claudeSnapshot = ProviderSnapshotEntry(
  provider: 'claude',
  status: ProviderCatalogStatus.ready,
  label: 'Claude',
  defaultModeId: 'auto',
  models: [
    ProviderModelDefinition(
      provider: 'claude',
      id: 'sonnet',
      label: 'Sonnet',
      isDefault: true,
      defaultThinkingOptionId: 'high',
      thinkingOptions: [
        ProviderSelectOption(id: 'off', label: 'Off'),
        ProviderSelectOption(id: 'high', label: 'High', isDefault: true),
      ],
    ),
    ProviderModelDefinition(provider: 'claude', id: 'opus', label: 'Opus'),
  ],
  modes: [
    ProviderMode(id: 'plan', label: 'Plan'),
    ProviderMode(id: 'auto', label: 'Auto'),
    ProviderMode(id: 'full-access', label: 'Full access'),
  ],
);

const _codexSnapshot = ProviderSnapshotEntry(
  provider: 'codex',
  status: ProviderCatalogStatus.ready,
  label: 'Codex',
  models: [
    ProviderModelDefinition(
      provider: 'codex',
      id: 'gpt-5',
      label: 'GPT-5',
      isDefault: true,
    ),
  ],
  modes: [ProviderMode(id: 'auto', label: 'Auto')],
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
const _plainProject = ProjectInfo(
  path: '/scratch',
  name: 'scratch',
  isGitRepo: false,
);

const _worktree = WorktreeInfo(
  path: '/repo-wt/lucky-otter',
  branch: 'lucky-otter',
  projectPath: '/repo',
);

/// Scriptable fake: `onRequest` decides responses per message type; every
/// call is recorded for assertions.
class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'fake',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {
        'providersSnapshot': true,
        'projectAdd': true,
        'stableProjectIdentity': true,
        'projectGithubClone': true,
      },
    );
  }

  final requests = <(String, Map<String, Object?>)>[];
  List<ProviderSnapshotEntry> providerSnapshots = const [_claudeSnapshot];
  List<AgentFeature> providerFeatures = const [];
  FetchRecentProviderSessionsResponse recentSessions =
      const FetchRecentProviderSessionsResponse(
        requestId: 'recent',
        entries: [],
      );
  ImportAgentStatusResponse importResponse = const ImportAgentStatusResponse(
    requestId: 'import',
    status: 'agent_resumed',
    agentId: 'new-1',
    agent: _createdAgent,
  );
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
  Future<DirectorySuggestionsResponse> getDirectorySuggestions({
    required String query,
    String? cwd,
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async => const DirectorySuggestionsResponse(
    directories: [],
    entries: [],
    requestId: 'suggestions',
  );

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => GetProvidersSnapshotResponse(
    entries: providerSnapshots,
    generatedAt: '2026-07-28T00:00:00.000Z',
    requestId: 'snapshot',
  );

  @override
  Future<ListProviderFeaturesResponse> listProviderFeatures({
    required ListCommandsDraftConfig draftConfig,
    Duration timeout = const Duration(seconds: 90),
  }) async => ListProviderFeaturesResponse(
    provider: draftConfig.provider,
    features: providerFeatures,
    fetchedAt: '2026-07-28T00:00:00.000Z',
    requestId: 'features',
  );

  @override
  Future<FetchRecentProviderSessionsResponse> fetchRecentProviderSessions({
    String? cwd,
    List<String>? providers,
    String? since,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async => recentSessions;

  @override
  Future<ImportAgentStatusResponse> importProviderSession({
    required String providerId,
    required String providerHandleId,
    required String cwd,
    String? workspaceId,
    Map<String, String>? labels,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final agent = importResponse.agent;
    if (agent != null) {
      _agents
        ..removeWhere((candidate) => candidate.agentId == agent.agentId)
        ..add(agent);
    }
    return importResponse;
  }

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

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type'] as String? ?? '';
    requests.add((type, message));
    final scripted = onRequest(type, message);
    if (scripted.isNotEmpty) return scripted;
    if (type != 'workspace.create.request') return const {};
    final source = message['source'] as Map<String, Object?>;
    final isWorktree = source['kind'] == 'worktree';
    final branch = source['branchName'] as String?;
    final cwd = isWorktree ? _worktree.path : source['path'] as String;
    return WorkspaceCreateResponse(
      requestId: message['requestId'] as String,
      workspace: WorkspaceDescriptor(
        id: 'wks_test',
        projectId: 'prj_test',
        projectDisplayName: 'repo',
        projectRootPath: '/repo',
        workspaceDirectory: cwd,
        projectKind: WorkspaceProjectKind.git,
        workspaceKind: isWorktree
            ? WorkspaceKind.worktree
            : WorkspaceKind.localCheckout,
        name: branch ?? 'main',
        status: WorkspaceStateBucket.done,
        activityAt: null,
        gitRuntime: WorkspaceGitRuntime(
          currentBranch: branch ?? 'main',
          isPaseoOwnedWorktree: isWorktree,
        ),
      ),
      setupTerminalId: null,
      error: null,
    ).toJson();
  }
}

final class _MemoryDraftStore implements ComposerDraftStore {
  final drafts = <String, ComposerDraft>{};
  final cleared = <ComposerDraftLifecycle>[];

  @override
  Future<ComposerDraft?> load(String draftKey) async => drafts[draftKey];

  @override
  Future<void> save(String draftKey, ComposerDraft draft) async {
    drafts[draftKey] = draft;
  }

  @override
  Future<void> clear(
    String draftKey, {
    required ComposerDraftLifecycle lifecycle,
  }) async {
    drafts.remove(draftKey);
    cleared.add(lifecycle);
  }

  @override
  Future<Set<String>> collectActiveAttachmentIds() async => {
    for (final draft in drafts.values)
      if (draft.lifecycle == ComposerDraftLifecycle.active)
        for (final image in draft.images) image.id,
  };
}

final class _MemoryPreferenceStorage implements CreateAgentPreferenceStorage {
  _MemoryPreferenceStorage([this.value]);

  Object? value;

  @override
  Future<Object?> read() async => value;

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    value = preferences.toJson();
  }
}

Future<ProviderContainer> pumpNewWorkspaceScreen(
  WidgetTester tester,
  FakeDaemonClient client, {
  ComposerImageAttachmentService? imageAttachmentService,
  ComposerDraftStore? draftStore,
  CreateAgentPreferencesService? preferencesService,
}) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            NewWorkspaceScreen(
              imageAttachmentService:
                  imageAttachmentService ??
                  ComposerImageAttachmentService(
                    store: () async => MemoryAttachmentStore(),
                  ),
              draftStore: draftStore ?? _MemoryDraftStore(),
              preferencesService:
                  preferencesService ??
                  CreateAgentPreferencesService(_MemoryPreferenceStorage()),
            ),
            const AddProjectFlowHost(),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('no providers available shows guidance instead of the form', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..providerSnapshots = const []
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return const {'providers': []};
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(
      find.textContaining('No agent providers are available'),
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

  testWidgets('global import opens without requiring a project', (
    tester,
  ) async {
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

    await tester.tap(find.byKey(const ValueKey('open-project-import-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-session-sheet')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('global import selects the imported cwd and agent tab', (
    tester,
  ) async {
    const importedAgent = AgentSummary(
      agentId: 'imported-global',
      title: 'Imported global',
      cwd: '/imported/repo',
      provider: 'claude',
      model: 'sonnet',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 2,
      workspaceId: 'workspace-imported',
    );
    final client = FakeDaemonClient()
      ..serverInfo = const ServerInfoStatus(
        serverId: 'fake',
        hostname: 'fake',
        version: '0.2.0',
        desktopManaged: false,
        features: {
          'providersSnapshot': true,
          'importSessionWorkspaceTarget': true,
        },
      )
      ..providerSnapshots = const [
        ProviderSnapshotEntry(
          provider: 'claude',
          status: ProviderCatalogStatus.ready,
          label: 'Claude',
        ),
      ]
      ..recentSessions = const FetchRecentProviderSessionsResponse(
        requestId: 'recent',
        entries: [
          RecentProviderSessionDescriptor(
            providerId: 'claude',
            providerLabel: 'Claude',
            providerHandleId: 'native-global',
            cwd: '/imported/repo',
            title: 'Imported global',
            firstPromptPreview: 'Continue this work',
            lastPromptPreview: 'Continue this work',
            lastActivityAt: '2026-07-28T00:00:00.000Z',
          ),
        ],
      )
      ..importResponse = const ImportAgentStatusResponse(
        requestId: 'import',
        status: 'agent_resumed',
        agentId: 'imported-global',
        agent: importedAgent,
      )
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_codex.toJson()],
          };
        }
        return const {'projects': []};
      };
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: FluentApp(
          home: Builder(
            builder: (context) => Center(
              child: Button(
                onPressed: () => Navigator.of(context).push(
                  FluentPageRoute<void>(
                    builder: (_) => NewWorkspaceScreen(
                      imageAttachmentService: ComposerImageAttachmentService(
                        store: () async => MemoryAttachmentStore(),
                      ),
                      draftStore: _MemoryDraftStore(),
                    ),
                  ),
                ),
                child: const Text('Open new workspace'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open new workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-project-import-session')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('import-session-session-claude-native-global')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open new workspace'), findsOneWidget);
    expect(container.read(selectedWorktreeProvider), importedAgent.cwd);
    final storedAgent = container.read(agentsProvider)[importedAgent.agentId];
    expect(storedAgent?.agentId, importedAgent.agentId);
    expect(storedAgent?.cwd, importedAgent.cwd);
    final tabs = container.read(worktreeTabsProvider(importedAgent.cwd)).layout;
    expect(
      tabs.tabs
          .where((tab) => tab.agentId == importedAgent.agentId)
          .single
          .tabId,
      tabs.activeTabId,
    );
  });

  testWidgets('with a git project: submitting prepares the workspace draft '
      'auto-submit handoff', (tester) async {
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
    final container = await pumpNewWorkspaceScreen(tester, client);

    expect(find.text('repo'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);

    await tester.enterText(find.byType(TextBox).last, 'fix the login bug');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final workspaceCreated = client.requests.singleWhere(
      (r) => r.$1 == 'workspace.create.request',
    );
    expect(
      (workspaceCreated.$2['source'] as Map<String, Object?>)['kind'],
      'directory',
    );
    expect(workspaceCreated.$2['firstAgentContext'], {
      'prompt': 'fix the login bug',
    });
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
    final submission = container
        .read(workspaceDraftSubmissionProvider)
        .values
        .single;
    expect(submission.workspaceId, 'wks_test');
    expect(submission.workspaceDirectory, '/repo');
    expect(submission.text, 'fix the login bug');
    expect(submission.provider, 'claude');
    expect(submission.model, 'sonnet');
    expect(submission.modeId, 'auto');
    expect(submission.thinkingOptionId, 'high');
    final pending = container.read(createFlowProvider)[submission.draftId]!;
    expect(pending.clientMessageId, submission.clientMessageId);
    expect(pending.lifecycle, CreateFlowLifecycle.active);
    expect(container.read(selectedWorktreeProvider), '/repo');
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentPromptRequest),
      isFalse,
    );
  });

  testWidgets(
    'restores provider form preferences and submits changed feature values',
    (tester) async {
      final storage = _MemoryPreferenceStorage({
        'provider': 'claude',
        'providerPreferences': {
          'claude': {
            'model': 'sonnet',
            'mode': 'plan',
            'thinkingByModel': {'sonnet': 'off'},
            'featureValues': {'fast_mode': true},
          },
        },
        'isolation': 'local',
      });
      final preferencesService = CreateAgentPreferencesService(storage);
      final client = FakeDaemonClient()
        ..providerFeatures = const [
          AgentFeatureToggle(id: 'fast_mode', label: 'Fast mode', value: false),
        ]
        ..onRequest = (type, payload) {
          if (type == MessageTypes.projectListRequest) {
            return {
              'projects': [_gitProject.toJson()],
            };
          }
          return const {};
        };
      final container = await pumpNewWorkspaceScreen(
        tester,
        client,
        preferencesService: preferencesService,
      );

      expect(
        tester
            .widget<ComboBox<String>>(
              find.byKey(const ValueKey('new-workspace-provider-selector')),
            )
            .value,
        'claude',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('combined-model-selector')),
          matching: find.text('Sonnet'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('favorite-model-claude-sonnet')),
      );
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((storage.value as Map)['favoriteModels'], [
        {'provider': 'claude', 'modelId': 'sonnet'},
      ]);
      expect(
        tester
            .widget<ComboBox<String>>(
              find.byKey(const ValueKey('new-workspace-mode-selector')),
            )
            .value,
        'plan',
      );
      expect(
        tester
            .widget<ComboBox<String>>(
              find.byKey(const ValueKey('new-workspace-thinking-selector')),
            )
            .value,
        'off',
      );
      final featureFinder = find.byKey(
        const ValueKey('new-workspace-feature-fast_mode'),
      );
      expect(tester.widget<ToggleSwitch>(featureFinder).checked, isTrue);

      await tester.tap(featureFinder);
      await tester.pumpAndSettle();
      expect(tester.widget<ToggleSwitch>(featureFinder).checked, isFalse);
      await tester.enterText(find.byType(TextBox).last, 'continue');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final submission = container
          .read(workspaceDraftSubmissionProvider)
          .values
          .single;
      expect(submission.provider, 'claude');
      expect(submission.model, 'sonnet');
      expect(submission.modeId, 'plan');
      expect(submission.thinkingOptionId, 'off');
      expect(submission.featureValues, {'fast_mode': false});
      expect(
        (storage.value
            as Map)['providerPreferences']['claude']['featureValues'],
        {'fast_mode': false},
      );
    },
  );

  testWidgets('provider, mode, and thinking changes persist per provider', (
    tester,
  ) async {
    final storage = _MemoryPreferenceStorage({});
    final client = FakeDaemonClient()
      ..providerSnapshots = const [_claudeSnapshot, _codexSnapshot]
      ..onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_gitProject.toJson()],
          };
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(
      tester,
      client,
      preferencesService: CreateAgentPreferencesService(storage),
    );

    await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-browser-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-provider-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-row-codex-gpt-5')));
    await tester.pumpAndSettle();
    expect((storage.value as Map)['provider'], 'codex');
    expect(
      (storage.value as Map)['providerPreferences']['codex']['model'],
      'gpt-5',
    );

    tester
        .widget<ComboBox<String>>(
          find.byKey(const ValueKey('new-workspace-provider-selector')),
        )
        .onChanged!('claude');
    await tester.pumpAndSettle();
    tester
        .widget<ComboBox<String>>(
          find.byKey(const ValueKey('new-workspace-mode-selector')),
        )
        .onChanged!('full-access');
    await tester.pump();
    tester
        .widget<ComboBox<String>>(
          find.byKey(const ValueKey('new-workspace-thinking-selector')),
        )
        .onChanged!('off');
    await tester.pump();

    expect(
      (storage.value as Map)['providerPreferences']['claude']['mode'],
      'full-access',
    );
    expect(
      (storage.value
          as Map)['providerPreferences']['claude']['thinkingByModel']['sonnet'],
      'off',
    );
  });

  testWidgets('switching Isolation to "New worktree" reveals the "Start from" '
      'picker; submitting delegates automatic naming to the daemon', (
    tester,
  ) async {
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

    final worktreeCreated = client.requests.singleWhere(
      (r) => r.$1 == 'workspace.create.request',
    );
    final source = worktreeCreated.$2['source'] as Map<String, Object?>;
    expect(source['cwd'], '/repo');
    expect(source['refName'], 'main');
    expect(source['action'], 'branch-off');
    expect(source.containsKey('branchName'), isFalse);
    expect(source.containsKey('worktreeSlug'), isFalse);

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
  });

  testWidgets('picking a branch in "Start from" uses it as baseRef', (
    tester,
  ) async {
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

    final worktreeCreated = client.requests.singleWhere(
      (r) => r.$1 == 'workspace.create.request',
    );
    expect(
      (worktreeCreated.$2['source'] as Map<String, Object?>)['refName'],
      'feature/x',
    );
  });

  testWidgets('the project picker lists all projects and hides isolation '
      'for a non-git project', (tester) async {
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

  testWidgets('remembered worktree isolation falls back to local for non-git', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_plainProject.toJson()],
          };
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(
      tester,
      client,
      preferencesService: CreateAgentPreferencesService(
        _MemoryPreferenceStorage({
          'provider': 'claude',
          'providerPreferences': {
            'claude': {'model': 'sonnet'},
          },
          'isolation': 'worktree',
        }),
      ),
    );

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final request = client.requests.singleWhere(
      (request) => request.$1 == 'workspace.create.request',
    );
    expect(request.$2['source'], {'kind': 'directory', 'path': '/scratch'});
  });

  testWidgets('ready provider without explicit models submits Default', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..providerSnapshots = const [
        ProviderSnapshotEntry(
          provider: 'custom',
          label: 'Custom CLI',
          status: ProviderCatalogStatus.ready,
          models: [],
          modes: [],
        ),
      ]
      ..onRequest = (type, payload) {
        if (type == MessageTypes.projectListRequest) {
          return {
            'projects': [_plainProject.toJson()],
          };
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    expect(find.text('Default'), findsOneWidget);
    final create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create'),
    );
    expect(create.onPressed, isNotNull);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any(
        (request) => request.$1 == 'workspace.create.request',
      ),
      isTrue,
    );
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

    await tester.tap(find.text('Search for directory'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('add-project-flow-input')),
      '/scratch',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('add-project-flow-path-/scratch')),
    );
    await tester.pump(const Duration(milliseconds: 150));

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
        if (type == 'workspace.create.request') {
          throw StateError('daemon rejected the request');
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.enterText(find.byType(TextBox).last, 'create me');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to create worktree'), findsOneWidget);
    expect(find.byType(NewWorkspaceScreen), findsOneWidget);
  });

  testWidgets('a workspace response without a workspace surfaces its error', (
    tester,
  ) async {
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
        if (type == 'workspace.create.request') {
          return WorkspaceCreateResponse(
            requestId: payload['requestId'] as String,
            workspace: null,
            setupTerminalId: null,
            error: 'base branch is missing',
          ).toJson();
        }
        return const {};
      };
    await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('base branch is missing'), findsOneWidget);
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
  });

  testWidgets('submitting with an empty prompt does not send agent.prompt', (
    tester,
  ) async {
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
    final container = await pumpNewWorkspaceScreen(tester, client);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentPromptRequest),
      isFalse,
    );
    expect(
      client.requests.any((r) => r.$1 == MessageTypes.agentCreateRequest),
      isFalse,
    );
    final workspaceCreate = client.requests.singleWhere(
      (request) => request.$1 == 'workspace.create.request',
    );
    expect(workspaceCreate.$2.containsKey('firstAgentContext'), isFalse);
    expect(container.read(createFlowProvider), isEmpty);
    expect(container.read(workspaceDraftSubmissionProvider), isEmpty);
  });

  testWidgets('new-workspace draft restores and atomically submits images', (
    tester,
  ) async {
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
    final attachmentStore = MemoryAttachmentStore();
    final metadata = await attachmentStore.save(
      id: 'new-workspace-image',
      mimeType: 'image/png',
      fileName: 'context.png',
      bytes: base64Decode(_onePixelPng),
    );
    final draftStore = _MemoryDraftStore()
      ..drafts[newWorkspaceComposerDraftKey] = ComposerDraft(
        text: 'restored new workspace prompt',
        images: [metadata],
        updatedAt: 1,
      );
    final container = await pumpNewWorkspaceScreen(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
      ),
      draftStore: draftStore,
    );

    expect(find.text('restored new workspace prompt'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      client.requests.any(
        (request) => request.$1 == MessageTypes.agentCreateRequest,
      ),
      isFalse,
    );
    final workspaceCreate = client.requests.singleWhere(
      (request) => request.$1 == 'workspace.create.request',
    );
    expect(workspaceCreate.$2['firstAgentContext'], {
      'prompt': 'restored new workspace prompt',
      'images': [
        {'data': _onePixelPng, 'mimeType': 'image/png'},
      ],
    });
    final submission = container
        .read(workspaceDraftSubmissionProvider)
        .values
        .single;
    expect(submission.text, 'restored new workspace prompt');
    expect(submission.images, [metadata]);
    final pending = container.read(createFlowProvider)[submission.draftId]!;
    expect(pending.images, [metadata]);
    expect(pending.clientMessageId, submission.clientMessageId);
    expect(draftStore.drafts['draft:fake:${submission.draftId}']?.images, [
      metadata,
    ]);
    expect(draftStore.cleared, contains(ComposerDraftLifecycle.sent));
  });

  testWidgets('picked new-workspace images persist and can be removed', (
    tester,
  ) async {
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
        return const {};
      };
    final attachmentStore = MemoryAttachmentStore();
    final draftStore = _MemoryDraftStore();
    await pumpNewWorkspaceScreen(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
        picker: () async => [
          XFile.fromData(
            base64Decode(_onePixelPng),
            name: 'picked-context.png',
            path: 'picked-context.png',
            mimeType: 'image/png',
          ),
        ],
      ),
      draftStore: draftStore,
    );

    await tester.tap(find.byKey(const ValueKey('new-workspace-image-picker')));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    final metadata =
        draftStore.drafts[newWorkspaceComposerDraftKey]!.images.single;
    expect(metadata.fileName, 'picked-context.png');

    await tester.tap(find.byIcon(FluentIcons.chrome_close));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(draftStore.drafts, isEmpty);
    expect(draftStore.cleared, contains(ComposerDraftLifecycle.abandoned));
    expect(() => attachmentStore.readBytes(metadata), throwsStateError);
  });
}

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X1r0AAAAASUVORK5CYII=';
