import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachment_service.dart';
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/create_flow_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/draft_session_composer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';

const _worktreePath = '/repo-wt/lucky-otter';

const _claude = ProviderSnapshotEntry(
  provider: 'claude',
  label: 'Claude',
  status: ProviderCatalogStatus.ready,
  defaultModeId: 'auto',
  models: [
    ProviderModelDefinition(
      provider: 'claude',
      id: 'sonnet',
      label: 'Sonnet',
      isDefault: true,
      defaultThinkingOptionId: 'high',
      thinkingOptions: [
        ProviderSelectOption(id: 'medium', label: 'Medium'),
        ProviderSelectOption(id: 'high', label: 'High'),
      ],
    ),
    ProviderModelDefinition(provider: 'claude', id: 'opus', label: 'Opus'),
  ],
  modes: [
    ProviderMode(id: 'plan', label: 'Plan'),
    ProviderMode(id: 'auto', label: 'Auto'),
    ProviderMode(id: 'bypassPermissions', label: 'Full access'),
  ],
);

const _deepseek = ProviderSnapshotEntry(
  provider: 'codex',
  label: 'Codex',
  status: ProviderCatalogStatus.ready,
  defaultModeId: 'auto-review',
  models: [
    ProviderModelDefinition(
      provider: 'codex',
      id: 'gpt-5',
      label: 'GPT-5',
      isDefault: true,
    ),
    ProviderModelDefinition(
      provider: 'codex',
      id: 'gpt-5-mini',
      label: 'GPT-5 mini',
    ),
  ],
  modes: [
    ProviderMode(id: 'read-only', label: 'Read only'),
    ProviderMode(id: 'auto-review', label: 'Auto review'),
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
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'local',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {'providersSnapshot': true},
    );
  }

  final requests = <(String, Map<String, Object?>)>[];
  List<ProviderSnapshotEntry> snapshotEntries = const [_claude];
  Future<GetProvidersSnapshotResponse>? snapshotFuture;
  Object? snapshotError;
  List<AgentSlashCommand> commands = const [];
  List<AgentFeature> features = const [];
  List<DirectorySuggestionEntry> directoryEntries = const [];
  ListCommandsDraftConfig? lastDraftConfig;
  String? lastDirectoryQuery;
  FutureOr<Map<String, Object?>> Function(
    String type,
    Map<String, Object?> payload,
  )
  onRequest = (type, payload) => const {};

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (snapshotError case final error?) throw error;
    if (snapshotFuture case final future?) return future;
    return GetProvidersSnapshotResponse(
      entries: snapshotEntries,
      generatedAt: 'now',
      requestId: 'snapshot',
    );
  }

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    lastDraftConfig = draftConfig;
    return ListCommandsResponse(
      agentId: agentId,
      commands: commands,
      requestId: 'commands',
    );
  }

  @override
  Future<ListProviderFeaturesResponse> listProviderFeatures({
    required ListCommandsDraftConfig draftConfig,
    Duration timeout = const Duration(seconds: 90),
  }) async => ListProviderFeaturesResponse(
    provider: draftConfig.provider,
    features: features,
    fetchedAt: 'now',
    requestId: 'features',
  );

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
    lastDirectoryQuery = query;
    return DirectorySuggestionsResponse(
      requestId: 'directory',
      directories: const [],
      entries: directoryEntries,
    );
  }

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return await onRequest(type, payload);
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
  _MemoryPreferenceStorage(this.value);

  Object? value;

  @override
  Future<Object?> read() async => value;

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    value = preferences.toJson();
  }
}

Future<ProviderContainer> pumpComposer(
  WidgetTester tester,
  FakeDaemonClient client, {
  ComposerImageAttachmentService? imageAttachmentService,
  ComposerDraftStore? draftStore,
  CreateAgentPreferencesService? preferencesService,
  void Function(String tabId)? onTabId,
  void Function(ProviderContainer container, String tabId)? onContainerReady,
  String? workspaceId,
  bool settle = true,
}) async {
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);

  // Seed the worktree's tab layout with a real draft tab (the empty
  // invariant auto-seeds one) so retarget() has a matching tabId to convert
  // in place, mirroring how a real draft tab always exists before its
  // composer is shown.
  final tabId = container
      .read(worktreeTabsProvider(_worktreePath))
      .layout
      .tabs
      .single
      .tabId;
  onTabId?.call(tabId);
  onContainerReady?.call(container, tabId);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: DraftSessionComposer(
            worktreePath: _worktreePath,
            tabId: tabId,
            workspaceId: workspaceId,
            projectPath: '/repo',
            branch: 'lucky-otter',
            isWorktree: true,
            imageAttachmentService:
                imageAttachmentService ??
                ComposerImageAttachmentService(
                  store: () async => MemoryAttachmentStore(),
                ),
            draftStore: draftStore ?? _MemoryDraftStore(),
            preferencesService: preferencesService,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return container;
}

void main() {
  testWidgets('no configured providers shows guidance instead of the form', (
    tester,
  ) async {
    final client = FakeDaemonClient()..snapshotEntries = const [];
    await pumpComposer(tester, client);

    expect(
      find.textContaining('No agent providers are available'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('draft-provider-selector')), findsNothing);
  });

  testWidgets(
    'snapshot loading, error, and unsupported host states are exact',
    (tester) async {
      final pending = Completer<GetProvidersSnapshotResponse>();
      final loadingClient = FakeDaemonClient()..snapshotFuture = pending.future;
      await pumpComposer(tester, loadingClient, settle: false);
      expect(find.byType(ProgressRing), findsOneWidget);

      final errorClient = FakeDaemonClient()
        ..snapshotError = StateError('catalog offline');
      await pumpComposer(tester, errorClient);
      expect(find.textContaining('catalog offline'), findsOneWidget);

      final unsupportedClient = FakeDaemonClient()
        ..serverInfo = const ServerInfoStatus(
          serverId: 'local',
          hostname: 'fake',
          version: '0.1.0',
          desktopManaged: false,
          features: {'providersSnapshot': false},
        );
      await pumpComposer(tester, unsupportedClient);
      expect(
        find.text('Update the host to use provider discovery.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'submitting creates the agent with the fixed worktree cwd/project/'
    'branch and retargets the draft tab in place',
    (tester) async {
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

      final createReq = client.requests.singleWhere(
        (r) => r.$1 == MessageTypes.agentCreateRequest,
      );
      expect(createReq.$2['cwd'], _worktreePath);
      expect(createReq.$2['projectPath'], '/repo');
      expect(createReq.$2['branch'], 'lucky-otter');
      expect(createReq.$2['isWorktree'], isTrue);
      expect(createReq.$2['initialPrompt'], 'do the thing');
      expect(createReq.$2['clientMessageId'], isNotEmpty);
      expect(createReq.$2['provider'], 'claude');
      expect(createReq.$2['model'], 'sonnet');
      expect(createReq.$2['modeId'], 'auto');
      expect(createReq.$2['thinkingOptionId'], 'high');
      expect(
        client.requests.any((r) => r.$1 == MessageTypes.agentPromptRequest),
        isFalse,
      );

      final layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
      final tab = layout.tabs.single;
      expect(tab.kind, WorktreeTabKind.agent);
      expect(tab.agentId, 'new-1');
      final pending = container.read(createFlowProvider).values.single;
      expect(pending.lifecycle, CreateFlowLifecycle.sent);
      expect(pending.agentId, 'new-1');
    },
  );

  testWidgets(
    'workspace submission waits for its matching active create attempt',
    (tester) async {
      final client = FakeDaemonClient();
      String? draftId;
      final container = await pumpComposer(
        tester,
        client,
        workspaceId: 'wks_test',
        settle: false,
        onContainerReady: (current, tabId) {
          draftId = tabId;
          current
              .read(workspaceDraftSubmissionProvider.notifier)
              .setPending(
                PendingWorkspaceDraftSubmission(
                  serverId: 'local',
                  workspaceId: 'wks_test',
                  workspaceDirectory: _worktreePath,
                  draftId: tabId,
                  text: 'prepared prompt',
                  images: const [],
                  cwd: _worktreePath,
                  provider: 'claude',
                  model: 'sonnet',
                  modeId: 'auto',
                  clientMessageId: 'prepared-message',
                  timestamp: 123,
                  allowEmptyText: true,
                ),
              );
        },
      );
      await tester.pump();

      expect(
        client.requests.where(
          (request) => request.$1 == MessageTypes.agentCreateRequest,
        ),
        isEmpty,
      );
      expect(
        container.read(workspaceDraftSubmissionProvider),
        contains(draftId),
      );
    },
  );

  testWidgets(
    'prepared workspace submission renders optimistically and auto-submits '
    'the original client message exactly once',
    (tester) async {
      final createCompleter = Completer<Map<String, Object?>>();
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [_claude.toJson()],
            };
          }
          if (type == MessageTypes.agentCreateRequest) {
            return createCompleter.future;
          }
          return const {};
        };
      final attachmentStore = MemoryAttachmentStore();
      final metadata = await attachmentStore.save(
        id: 'prepared-image',
        mimeType: 'image/png',
        fileName: 'prepared.png',
        bytes: base64Decode(_onePixelPng),
      );
      final draftStore = _MemoryDraftStore();
      String? draftId;
      final container = await pumpComposer(
        tester,
        client,
        workspaceId: 'wks_test',
        imageAttachmentService: ComposerImageAttachmentService(
          store: () async => attachmentStore,
        ),
        draftStore: draftStore,
        settle: false,
        onContainerReady: (current, tabId) {
          draftId = tabId;
          draftStore.drafts['draft:local:$tabId'] = ComposerDraft(
            text: 'prepared prompt',
            images: [metadata],
            updatedAt: 1,
          );
          current
              .read(createFlowProvider.notifier)
              .setPending(
                PendingCreateAttempt(
                  draftId: tabId,
                  serverId: 'local',
                  workspaceId: 'wks_test',
                  agentId: null,
                  clientMessageId: 'prepared-message',
                  text: 'prepared prompt',
                  timestamp: 123,
                  lifecycle: CreateFlowLifecycle.active,
                  images: [metadata],
                ),
              );
          current
              .read(workspaceDraftSubmissionProvider.notifier)
              .setPending(
                PendingWorkspaceDraftSubmission(
                  serverId: 'local',
                  workspaceId: 'wks_test',
                  workspaceDirectory: _worktreePath,
                  draftId: tabId,
                  text: 'prepared prompt',
                  images: [metadata],
                  cwd: _worktreePath,
                  provider: 'claude',
                  model: 'sonnet',
                  modeId: 'auto',
                  clientMessageId: 'prepared-message',
                  timestamp: 123,
                  allowEmptyText: true,
                ),
              );
        },
      );
      await tester.pump();

      expect(find.text('Creating agent'), findsOneWidget);
      expect(find.text('prepared prompt'), findsOneWidget);
      final requests = client.requests.where(
        (request) => request.$1 == MessageTypes.agentCreateRequest,
      );
      expect(requests, hasLength(1));
      expect(requests.single.$2['workspaceId'], 'wks_test');
      expect(requests.single.$2['clientMessageId'], 'prepared-message');
      expect(requests.single.$2['initialPrompt'], 'prepared prompt');
      expect(requests.single.$2['images'], [
        {'data': _onePixelPng, 'mimeType': 'image/png'},
      ]);
      expect(
        container.read(workspaceDraftSubmissionProvider),
        isNot(contains(draftId)),
      );

      createCompleter.complete({'agent': _createdAgent.toJson()});
      await tester.pumpAndSettle();

      expect(
        client.requests.where(
          (request) => request.$1 == MessageTypes.agentCreateRequest,
        ),
        hasLength(1),
      );
      final pending = container.read(createFlowProvider)[draftId]!;
      expect(pending.lifecycle, CreateFlowLifecycle.sent);
      expect(pending.agentId, 'new-1');
      expect(
        container
            .read(worktreeTabsProvider(_worktreePath))
            .layout
            .tabs
            .single
            .kind,
        WorktreeTabKind.agent,
      );
    },
  );

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
    final draftStore = _MemoryDraftStore();
    String? tabId;
    final container = await pumpComposer(
      tester,
      client,
      draftStore: draftStore,
      onTabId: (value) => tabId = value,
    );

    await tester.enterText(find.byType(TextBox), 'keep after failure');
    await tester.tap(find.text('Create'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to create agent'), findsOneWidget);
    final layout = container.read(worktreeTabsProvider(_worktreePath)).layout;
    expect(layout.tabs.single.kind, WorktreeTabKind.draft);
    expect(
      draftStore.drafts,
      containsPair(
        'draft:local:$tabId',
        isA<ComposerDraft>().having(
          (draft) => draft.text,
          'text',
          'keep after failure',
        ),
      ),
    );
    expect(container.read(createFlowProvider), isEmpty);
  });

  testWidgets(
    'workspace draft restores image metadata and submits image-only prompts',
    (tester) async {
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
      final attachmentStore = MemoryAttachmentStore();
      final metadata = await attachmentStore.save(
        id: 'draft-image',
        mimeType: 'image/png',
        fileName: 'draft.png',
        bytes: base64Decode(_onePixelPng),
      );
      final draftStore = _MemoryDraftStore();
      await pumpComposer(
        tester,
        client,
        imageAttachmentService: ComposerImageAttachmentService(
          store: () async => attachmentStore,
        ),
        draftStore: draftStore,
        onTabId: (tabId) {
          draftStore.drafts['draft:local:$tabId'] = ComposerDraft(
            text: '',
            images: [metadata],
            updatedAt: 1,
          );
        },
      );

      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.text('Create'));
      await tester.pump(const Duration(milliseconds: 300));

      final create = client.requests.singleWhere(
        (request) => request.$1 == MessageTypes.agentCreateRequest,
      );
      expect(create.$2.containsKey('initialPrompt'), isFalse);
      expect(create.$2['clientMessageId'], isNotEmpty);
      expect(create.$2['images'], [
        {'data': _onePixelPng, 'mimeType': 'image/png'},
      ]);
      expect(draftStore.cleared, contains(ComposerDraftLifecycle.sent));
    },
  );

  testWidgets('picked images become active workspace draft ownership', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {};
      };
    final attachmentStore = MemoryAttachmentStore();
    final draftStore = _MemoryDraftStore();
    String? tabId;
    await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
        picker: () async => [
          XFile.fromData(
            base64Decode(_onePixelPng),
            name: 'picked.png',
            path: 'picked.png',
            mimeType: 'image/png',
          ),
        ],
      ),
      draftStore: draftStore,
      onTabId: (value) => tabId = value,
    );

    await tester.tap(find.byKey(const ValueKey('draft-image-picker')));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(
      draftStore.drafts['draft:local:$tabId']?.images.single.fileName,
      'picked.png',
    );
  });

  testWidgets('a missing restored image blocks create and keeps the draft', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {};
      };
    final attachmentStore = MemoryAttachmentStore();
    final metadata = await attachmentStore.save(
      id: 'missing-on-submit',
      mimeType: 'image/png',
      fileName: 'missing.png',
      bytes: base64Decode(_onePixelPng),
    );
    final draftStore = _MemoryDraftStore();
    await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
      ),
      draftStore: draftStore,
      onTabId: (tabId) {
        draftStore.drafts['draft:local:$tabId'] = ComposerDraft(
          text: '',
          images: [metadata],
          updatedAt: 1,
        );
      },
    );
    await attachmentStore.delete(metadata);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Failed to read attached images'),
      findsOneWidget,
    );
    expect(
      client.requests.any(
        (request) => request.$1 == MessageTypes.agentCreateRequest,
      ),
      isFalse,
    );
    expect(draftStore.drafts.values.single.images, [metadata]);
  });

  testWidgets('a restored workspace image can be removed', (tester) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {};
      };
    final attachmentStore = MemoryAttachmentStore();
    final metadata = await attachmentStore.save(
      id: 'remove-draft-image',
      mimeType: 'image/png',
      fileName: 'remove.png',
      bytes: base64Decode(_onePixelPng),
    );
    final draftStore = _MemoryDraftStore();
    await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
      ),
      draftStore: draftStore,
      onTabId: (tabId) {
        draftStore.drafts['draft:local:$tabId'] = ComposerDraft(
          text: '',
          images: [metadata],
          updatedAt: 1,
        );
      },
    );

    await tester.tap(find.byIcon(FluentIcons.chrome_close));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(draftStore.drafts, isEmpty);
    expect(draftStore.cleared, contains(ComposerDraftLifecycle.abandoned));
    expect(() => attachmentStore.readBytes(metadata), throwsStateError);
  });

  testWidgets(
    'provider and model selections update the draft create controls',
    (tester) async {
      final client = FakeDaemonClient()
        ..snapshotEntries = const [_claude, _deepseek]
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [_claude.toJson(), _deepseek.toJson()],
            };
          }
          return const {};
        };
      await pumpComposer(tester, client);

      expect(
        find.byKey(const ValueKey('composer-import-agent-pill')),
        findsOneWidget,
      );
      tester
          .widget<ComboBox<String>>(
            find.byKey(const ValueKey('draft-provider-selector')),
          )
          .onChanged!('codex');
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('combined-model-selector')),
          matching: find.text('GPT-5'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('model-row-codex-gpt-5-mini')),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('combined-model-selector')),
          matching: find.text('GPT-5 mini'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('ready provider without explicit models creates with Default', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..snapshotEntries = const [
        ProviderSnapshotEntry(
          provider: 'custom',
          label: 'Custom CLI',
          status: ProviderCatalogStatus.ready,
          models: [],
          modes: [],
        ),
      ]
      ..onRequest = (type, payload) {
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpComposer(tester, client);

    expect(find.text('Default'), findsOneWidget);
    await tester.enterText(find.byType(TextBox), 'use provider default');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final request = client.requests.singleWhere(
      (request) => request.$1 == MessageTypes.agentCreateRequest,
    );
    expect(request.$2['provider'], 'custom');
    expect(request.$2['model'], '');
  });

  testWidgets('draft provider feature controls propagate resolved values', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..features = const [
        AgentFeatureToggle(
          id: 'fast_mode',
          label: 'Fast',
          value: false,
          tooltip: 'Toggle fast mode',
        ),
      ]
      ..onRequest = (type, payload) {
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    await pumpComposer(tester, client);

    final toggle = tester.widget<ToggleSwitch>(
      find.byKey(const ValueKey('draft-feature-fast_mode')),
    );
    expect(toggle.checked, isFalse);
    toggle.onChanged!(true);
    await tester.pump();
    await tester.enterText(find.byType(TextBox), 'use fast mode');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final createReq = client.requests.singleWhere(
      (request) => request.$1 == MessageTypes.agentCreateRequest,
    );
    expect(createReq.$2['features'], {'fast_mode': true});
  });

  testWidgets('restores provider-scoped feature preferences', (tester) async {
    final client = FakeDaemonClient()
      ..features = const [
        AgentFeatureToggle(id: 'fast_mode', label: 'Fast', value: false),
      ]
      ..onRequest = (type, payload) {
        if (type == MessageTypes.agentCreateRequest) {
          return {'agent': _createdAgent.toJson()};
        }
        return const {};
      };
    final preferences = CreateAgentPreferencesService(
      _MemoryPreferenceStorage({
        'provider': 'claude',
        'providerPreferences': {
          'claude': {
            'featureValues': {'fast_mode': true},
          },
        },
      }),
    );
    await pumpComposer(tester, client, preferencesService: preferences);

    expect(
      tester
          .widget<ToggleSwitch>(
            find.byKey(const ValueKey('draft-feature-fast_mode')),
          )
          .checked,
      isTrue,
    );
    await tester.enterText(find.byType(TextBox), 'restore fast mode');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final createReq = client.requests.singleWhere(
      (request) => request.$1 == MessageTypes.agentCreateRequest,
    );
    expect(createReq.$2['features'], {'fast_mode': true});
  });

  testWidgets('restores provider model mode and thinking preferences', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..snapshotEntries = const [_claude, _deepseek];
    final storage = _MemoryPreferenceStorage({
      'provider': 'codex',
      'providerPreferences': {
        'codex': {'model': 'gpt-5-mini', 'mode': 'read-only'},
      },
    });
    await pumpComposer(
      tester,
      client,
      preferencesService: CreateAgentPreferencesService(storage),
    );

    expect(
      tester
          .widget<ComboBox<String>>(
            find.byKey(const ValueKey('draft-provider-selector')),
          )
          .value,
      'codex',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('combined-model-selector')),
        matching: find.text('GPT-5 mini'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ComboBox<String>>(
            find.byKey(const ValueKey('draft-mode-selector')),
          )
          .value,
      'read-only',
    );
  });

  testWidgets('draft slash autocomplete uses the selected provider config', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review the workspace',
          argumentHint: '[path]',
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '/rev');
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('draft-command-autocomplete')), findsOne);
    expect(find.text('/review'), findsWidgets);
    expect(client.lastDraftConfig?.toJson(), {
      'provider': 'claude',
      'cwd': _worktreePath,
      'modeId': 'auto',
      'model': 'sonnet',
      'thinkingOptionId': 'high',
    });

    await tester.tap(
      find.byKey(const ValueKey('composer-command-autocomplete-review')),
    );
    await tester.pump(const Duration(milliseconds: 181));
    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller?.text,
      '/review ',
    );
  });

  testWidgets('draft autocomplete keyboard selection wraps and applies', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(name: 'first', description: '', argumentHint: ''),
        AgentSlashCommand(name: 'second', description: '', argumentHint: ''),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '/');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller?.text,
      '/second ',
    );
  });

  testWidgets('draft file autocomplete takes precedence and quotes paths', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(name: 'ignored', description: '', argumentHint: ''),
      ]
      ..directoryEntries = const [
        DirectorySuggestionEntry(
          path: 'lib/my file.dart',
          kind: DirectorySuggestionKind.file,
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'inspect @lib');
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pump();

    expect(find.byKey(const ValueKey('draft-file-autocomplete')), findsOne);
    expect(
      find.byKey(const ValueKey('draft-command-autocomplete')),
      findsNothing,
    );
    expect(client.lastDirectoryQuery, 'lib');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 181));
    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller?.text,
      'inspect "lib/my file.dart"',
    );
  });

  testWidgets('the import pill opens the workspace-scoped session sheet', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onRequest = (type, payload) {
        if (type == MessageTypes.providerListRequest) {
          return {
            'providers': [_claude.toJson()],
          };
        }
        return const {};
      };
    await pumpComposer(tester, client, workspaceId: 'workspace-1');

    await tester.tap(find.byKey(const ValueKey('composer-import-agent-pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-session-sheet')), findsOneWidget);
    expect(find.text('Update the host to import sessions.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X1r0AAAAASUVORK5CYII=';
