import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/terminal/agent_hook_installer.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter client lists recent provider-native sessions', () async {
    final temp = Directory.systemTemp.createTempSync(
      'tinyrack-flutter-provider-sessions-e2e-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: temp.path),
      host: '127.0.0.1',
      port: 0,
      dataDir: temp.path,
      agentClients: {'claude': _TestAgentClient()},
      hookInstallOptions: AgentHookInstallOptions(
        configDir: '${temp.path}${Platform.pathSeparator}provider-hooks',
        homeDir: temp.path,
        environment: const {},
      ),
      log: (_) {},
    );
    addTearDown(handle.stop);
    final client = DaemonClient(
      uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
    );
    addTearDown(client.dispose);
    await client.connect();

    final source = Directory('${temp.path}${Platform.pathSeparator}src')
      ..createSync();
    File(
      '${source.path}${Platform.pathSeparator}message.dart',
    ).writeAsStringSync('');
    final suggestions = await client.getDirectorySuggestions(
      cwd: temp.path,
      query: 'mess',
      includeFiles: true,
      includeDirectories: true,
      limit: 50,
    );
    expect(suggestions.error, isNull);
    expect(suggestions.directories, isEmpty);
    expect(suggestions.entries.single.toJson(), {
      'path': 'src/message.dart',
      'kind': 'file',
    });

    expect(client.serverInfo?.features['importSessionWorkspaceTarget'], isTrue);
    final pushedSnapshot = client.providersSnapshotUpdates.first.timeout(
      const Duration(seconds: 5),
    );
    final refresh = await client.refreshProvidersSnapshot(
      cwd: temp.path,
      providers: const ['claude'],
    );
    expect(refresh.acknowledged, isTrue);
    final pushed = await pushedSnapshot;
    expect(pushed.cwd, temp.path);
    expect(pushed.entries.map((entry) => entry.provider), contains('claude'));
    final providers = await client.fetchProvidersSnapshot(cwd: temp.path);
    expect(
      providers.entries.map((entry) => entry.provider),
      contains('claude'),
    );

    final response = await client.fetchRecentProviderSessions(
      cwd: temp.path,
      providers: const ['claude'],
      limit: 5,
    );

    expect(response.entries, hasLength(1));
    expect(response.entries.single.providerId, 'claude');
    expect(response.entries.single.providerLabel, 'Claude');
    expect(response.entries.single.providerHandleId, 'native-session');
    expect(response.filteredAlreadyImportedCount, isNull);
    final imported = await client.importProviderSession(
      providerId: 'claude',
      providerHandleId: 'native-session',
      cwd: temp.path,
      labels: const {'source': 'recent'},
    );
    expect(imported.agentId, imported.agent?.agentId);
    expect(imported.timelineSize, 1);
    expect(imported.agent?.sessionId, 'native-session');
    expect(imported.agent?.workspaceId, isNotEmpty);
    expect(imported.agent?.labels, {'source': 'recent'});
    final commands = await client.listCommands(agentId: imported.agentId!);
    expect(commands.error, isNull);
    expect(commands.commands.single.name, 'review');
    await expectLater(
      client.importProviderSession(
        providerId: 'claude',
        providerHandleId: 'native-session',
        cwd: temp.path,
        workspaceId: imported.agent!.workspaceId,
      ),
      throwsA(
        isA<DaemonRpcException>().having(
          (error) => error.error.message,
          'message',
          'Provider session is already imported: native-session',
        ),
      ),
    );
    await client.request(MessageTypes.agentArchiveRequest, {
      'agentId': imported.agentId,
    });
    final reactivated = await client.importProviderSession(
      providerId: 'claude',
      providerHandleId: 'native-session',
      cwd: temp.path,
      workspaceId: imported.agent!.workspaceId,
    );
    expect(reactivated.agentId, imported.agentId);
    expect(reactivated.agent?.archivedAt, isNull);
    await expectLater(
      client.fetchRecentProviderSessions(since: 'invalid'),
      throwsA(
        isA<DaemonRpcException>().having(
          (error) => error.error.code,
          'code',
          'invalid_since',
        ),
      ),
    );
  });

  test(
    'Flutter client shares one Paseo v2 session for legacy and config RPC',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-flutter-v2-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final hookOptions = AgentHookInstallOptions(
        configDir: '${temp.path}${Platform.pathSeparator}provider-hooks',
        homeDir: temp.path,
        environment: const {},
      );
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        hookInstallOptions: hookOptions,
        log: (_) {},
      );
      addTearDown(handle.stop);

      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      expect(client.currentState, DaemonConnectionState.connected);
      expect(client.serverHello?.daemonVersion, daemonVersion);
      final serverInfoUpdate = client.serverInfoUpdates.first.timeout(
        const Duration(seconds: 5),
      );
      handle.server.updateServerCapabilities(const {
        'voice': {
          'dictation': {'enabled': false, 'reason': 'Disabled'},
          'voice': {'enabled': true, 'reason': ''},
        },
      });
      final updatedInfo = await serverInfoUpdate;
      expect(updatedInfo.capabilities, client.serverInfo?.capabilities);
      expect(((updatedInfo.capabilities['voice'] as Map)['dictation'] as Map), {
        'enabled': false,
        'reason': 'Disabled',
      });
      expect(
        (await client.request(
          MessageTypes.providerListRequest,
          const {},
        ))['providers'],
        isA<List>(),
      );
      expect(
        (await client.getDaemonConfig()).enableTerminalAgentHooks,
        isFalse,
      );

      await client.requestSessionMessage(
        const FetchWorkspacesRequest(
          requestId: 'subscribe-workspaces',
          limit: 200,
          hasSubscription: true,
        ).toJson(),
      );
      final projectUpdateFuture = client.directoryUpdateEvents.firstWhere(
        (event) => event is ProjectDirectoryEvent,
      );
      await client.requestSessionMessage(
        ProjectAddRequest(cwd: temp.path, requestId: 'add-project').toJson(),
      );
      expect(await projectUpdateFuture, isA<ProjectDirectoryEvent>());

      final changedFuture = client.daemonConfigChanges.first;
      final patched = await client.patchDaemonConfig(
        const MutableDaemonConfigPatch(
          injectMcpIntoAgents: true,
          browserToolsEnabled: true,
          autoArchiveAfterMerge: true,
          enableTerminalAgentHooks: true,
          appendSystemPrompt: 'Always keep replies concise.',
          terminalProfiles: [
            TerminalProfile(
              id: 'codex',
              name: 'Codex',
              command: 'codex',
              args: ['--search'],
            ),
          ],
        ),
      );
      expect(patched.enableTerminalAgentHooks, isTrue);
      expect(patched.injectMcpIntoAgents, isTrue);
      expect(patched.browserToolsEnabled, isTrue);
      expect(patched.autoArchiveAfterMerge, isTrue);
      expect(patched.appendSystemPrompt, 'Always keep replies concise.');
      expect(patched.terminalProfiles!.single.args, ['--search']);
      final changed = await changedFuture;
      expect(changed.config.toJson(), patched.toJson());
      expect(registeredAgentHooksAreInstalled(options: hookOptions), isTrue);
      expect(
        File(
          '${temp.path}${Platform.pathSeparator}config.json',
        ).readAsStringSync(),
        contains('Always keep replies concise.'),
      );
    },
  );

  test(
    'Flutter client receives native agent_stream from the Dart daemon',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-flutter-agent-stream-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final seededRegistries = WorkspaceRegistries(dataDir: temp.path);
      await seededRegistries.initialize();
      await seededRegistries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'project-unavailable',
          rootPath: '${temp.path}${Platform.pathSeparator}unavailable',
          kind: PersistedProjectKind.nonGit,
          displayName: 'Unavailable project',
          createdAt: '2026-07-28T00:00:00.000Z',
          updatedAt: '2026-07-28T00:00:00.000Z',
        ),
      );
      await seededRegistries.workspaces.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'workspace-unavailable',
          projectId: 'project-unavailable',
          cwd: '${temp.path}${Platform.pathSeparator}unavailable',
          kind: PersistedWorkspaceKind.directory,
          displayName: 'Unavailable workspace',
          createdAt: '2026-07-28T00:00:00.000Z',
          updatedAt: '2026-07-28T00:00:00.000Z',
        ),
      );
      await AgentStore(dataDir: temp.path).save(
        const PersistedAgent(
          summary: AgentSummary(
            agentId: 'unavailable-agent',
            title: 'Unavailable persisted',
            cwd: 'unavailable',
            provider: 'removed-provider',
            model: 'removed-model',
            mode: AgentMode.normal,
            runState: AgentRunState.closed,
            createdAtMs: 1,
            workspaceId: 'workspace-unavailable',
            archivedAt: '2026-07-28T00:00:00.000Z',
          ),
          archived: true,
          epoch: 1,
          lastSeq: 0,
          items: [],
        ),
      );
      await AgentStore(dataDir: temp.path).save(
        const PersistedAgent(
          summary: AgentSummary(
            agentId: 'internal-agent',
            title: 'Hidden system task',
            cwd: 'unavailable',
            provider: 'test',
            model: 'fake',
            mode: AgentMode.normal,
            runState: AgentRunState.idle,
            createdAtMs: 2,
            workspaceId: 'workspace-unavailable',
          ),
          archived: false,
          epoch: 1,
          lastSeq: 0,
          items: [],
          internal: true,
        ),
      );
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'test': _TestAgentClient()},
        log: (_) {},
      );
      addTearDown(handle.stop);

      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      final unavailable = await client.fetchAgent('Unavailable persisted');
      expect(unavailable?.agent.providerUnavailable, isTrue);
      expect(unavailable?.project?['projectKey'], 'project-unavailable');
      await expectLater(
        client.fetchAgent('Hidden system task'),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'Agent not found: Hidden system task',
          ),
        ),
      );
      final initialDirectory = await client.fetchAgents(subscribe: true);
      expect(initialDirectory.entries, isEmpty);
      expect(initialDirectory.subscriptionId, isNotEmpty);
      final opened = OpenProjectResponse.fromJson(
        await client.requestSessionMessage(
          OpenProjectRequest(
            cwd: temp.path,
            requestId: 'open-agent-workspace',
          ).toJson(),
        ),
      );
      final workspace = opened.workspace!;
      final userMessageFuture = client.agentStreamEvents.firstWhere(
        (payload) => payload.item is UserMessageItem,
      );
      final directoryFuture = client.directoryUpdateEvents
          .firstWhere((event) => event is AgentUpsertDirectoryEvent)
          .then((event) => event as AgentUpsertDirectoryEvent);
      final response = await client.request(MessageTypes.agentCreateRequest, {
        'cwd': temp.path,
        'provider': 'test',
        'model': 'fake',
        'mode': 'normal',
        'workspaceId': workspace.id,
        'projectPath': temp.path,
        'branch': 'main',
        'isWorktree': false,
        'initialPrompt': 'Native stream proof',
        'clientMessageId': 'native-stream-message',
      });
      final agent = AgentSummary.fromJson(
        response['agent'] as Map<String, Object?>,
      );
      final streamed = await userMessageFuture;
      final directory = await directoryFuture;
      final item = streamed.item;

      expect(streamed.agentId, agent.agentId);
      expect(directory.agent.agentId, agent.agentId);
      expect(directory.agent.cwd, temp.path);
      expect(streamed.seq, greaterThan(0));
      expect(streamed.epoch, greaterThanOrEqualTo(0));
      expect(item, isA<UserMessageItem>());
      expect((item as UserMessageItem).id, 'native-stream-message');
      expect(item.text, 'Native stream proof');

      final secondResponse = await client
          .request(MessageTypes.agentCreateRequest, {
            'cwd': temp.path,
            'provider': 'test',
            'model': 'fake',
            'mode': 'normal',
            'workspaceId': workspace.id,
            'projectPath': temp.path,
            'branch': 'main',
            'isWorktree': false,
            'title': 'Second',
          });
      final second = AgentSummary.fromJson(
        secondResponse['agent'] as Map<String, Object?>,
      );
      final legacyClient = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
        appVersion: '0.1.44',
      );
      addTearDown(legacyClient.dispose);
      await legacyClient.connect();
      expect((await legacyClient.fetchAgents()).entries, isEmpty);
      await expectLater(
        legacyClient.fetchAgent(agent.agentId),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'Agent not found: ${agent.agentId}',
          ),
        ),
      );
      final firstPage = await client.fetchAgents(
        sort: const [
          AgentDirectorySort(
            key: AgentDirectorySortKey.createdAt,
            direction: AgentDirectorySortDirection.asc,
          ),
        ],
        limit: 1,
      );
      expect(firstPage.entries, hasLength(1));
      expect(firstPage.pageInfo.hasMore, isTrue);
      expect(firstPage.pageInfo.nextCursor, isNotNull);
      final firstCursor = firstPage.pageInfo.nextCursor!;
      final cursorPayload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(firstCursor))),
              )
              as Map<String, Object?>;
      expect(cursorPayload['sort'], [
        {'key': 'created_at', 'direction': 'asc'},
      ]);
      expect(cursorPayload['values'], {'created_at': isA<int>()});
      expect(cursorPayload['id'], firstPage.entries.single.agent.agentId);
      await expectLater(
        client.fetchAgents(
          sort: const [
            AgentDirectorySort(
              key: AgentDirectorySortKey.updatedAt,
              direction: AgentDirectorySortDirection.desc,
            ),
          ],
          limit: 1,
          cursor: firstCursor,
        ),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'fetch_agents cursor does not match current sort',
          ),
        ),
      );
      await expectLater(
        client.fetchAgents(limit: 1, cursor: '0'),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'Invalid fetch_agents cursor',
          ),
        ),
      );
      expect(client.currentState, DaemonConnectionState.connected);
      final secondPage = await client.fetchAgents(
        sort: const [
          AgentDirectorySort(
            key: AgentDirectorySortKey.createdAt,
            direction: AgentDirectorySortDirection.asc,
          ),
        ],
        limit: 1,
        cursor: firstCursor,
      );
      expect(secondPage.pageInfo.hasMore, isFalse);
      expect(
        {
          firstPage.entries.single.agent.agentId,
          secondPage.entries.single.agent.agentId,
        },
        {agent.agentId, second.agentId},
      );

      final projectFiltered = await client.fetchAgents(
        filter: AgentDirectoryFilter(
          projectKeys: [workspace.projectId],
          requiresAttention: false,
          thinkingOptionId: null,
          hasThinkingOptionId: true,
        ),
      );
      expect(projectFiltered.entries, hasLength(2));
      final firstStatus = switch (firstPage.entries.single.agent.runState) {
        AgentRunState.initializing => 'initializing',
        AgentRunState.idle => 'idle',
        AgentRunState.running || AgentRunState.awaitingPermission => 'running',
        AgentRunState.error => 'error',
        AgentRunState.closed => 'closed',
      };
      final statusFiltered = await client.fetchAgents(
        filter: AgentDirectoryFilter(statuses: [firstStatus]),
      );
      expect(
        statusFiltered.entries.map((entry) => entry.agent.agentId).toSet(),
        contains(firstPage.entries.single.agent.agentId),
      );
      final missingProject = await client.fetchAgents(
        filter: const AgentDirectoryFilter(projectKeys: ['missing-project']),
      );
      expect(missingProject.entries, isEmpty);

      final filteredSubscription = await client.fetchAgents(
        filter: const AgentDirectoryFilter(projectKeys: ['missing-project']),
        subscribe: true,
        subscriptionId: 'replaceable-subscription',
      );
      expect(filteredSubscription.subscriptionId, 'replaceable-subscription');
      final filteredRemoveFuture = client.directoryUpdateEvents
          .firstWhere((event) => event is AgentRemoveDirectoryEvent)
          .then((event) => event as AgentRemoveDirectoryEvent);
      final filteredCreate = await client
          .request(MessageTypes.agentCreateRequest, {
            'cwd': temp.path,
            'provider': 'test',
            'model': 'fake',
            'mode': 'normal',
            'workspaceId': workspace.id,
            'projectPath': temp.path,
            'branch': 'main',
            'isWorktree': false,
            'title': 'Filtered out',
          });
      final filteredAgent = AgentSummary.fromJson(
        filteredCreate['agent'] as Map<String, Object?>,
      );
      expect((await filteredRemoveFuture).agentId, filteredAgent.agentId);

      final replacement = await client.fetchAgents(
        filter: AgentDirectoryFilter(projectKeys: [workspace.projectId]),
        subscribe: true,
        subscriptionId: 'replaceable-subscription',
      );
      expect(replacement.subscriptionId, 'replaceable-subscription');
      final replacementUpsertFuture = client.directoryUpdateEvents
          .firstWhere((event) => event is AgentUpsertDirectoryEvent)
          .then((event) => event as AgentUpsertDirectoryEvent);
      final replacementCreate = await client
          .request(MessageTypes.agentCreateRequest, {
            'cwd': temp.path,
            'provider': 'test',
            'model': 'fake',
            'mode': 'normal',
            'workspaceId': workspace.id,
            'projectPath': temp.path,
            'branch': 'main',
            'isWorktree': false,
            'title': 'Included after replacement',
          });
      final replacementAgent = AgentSummary.fromJson(
        replacementCreate['agent'] as Map<String, Object?>,
      );
      final replacementUpsert = await replacementUpsertFuture;
      expect(replacementUpsert.agent.agentId, replacementAgent.agentId);
      expect(replacementUpsert.project?['projectKey'], workspace.projectId);

      await client.request(MessageTypes.agentArchiveRequest, {
        'agentId': filteredAgent.agentId,
      });
      await client.request(MessageTypes.agentArchiveRequest, {
        'agentId': replacementAgent.agentId,
      });
      final archivedDetail = await client.fetchAgent('Filtered out');
      expect(archivedDetail?.agent.agentId, filteredAgent.agentId);
      expect(archivedDetail?.agent.runState, AgentRunState.closed);
      expect(archivedDetail?.agent.archivedAt, isNotNull);
      expect(archivedDetail?.project?['projectKey'], workspace.projectId);
      final prefixDetail = await client.fetchAgent(
        agent.agentId.substring(0, 8),
      );
      expect(prefixDetail?.agent.agentId, agent.agentId);
      await expectLater(
        client.fetchAgent('missing-agent'),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.message,
            'message',
            'Agent not found: missing-agent',
          ),
        ),
      );
      final historyFirst = await client.fetchAgentHistory(
        filter: AgentDirectoryFilter(projectKeys: [workspace.projectId]),
        sort: const [
          AgentDirectorySort(
            key: AgentDirectorySortKey.updatedAt,
            direction: AgentDirectorySortDirection.desc,
          ),
        ],
        limit: 1,
      );
      expect(historyFirst.entries, hasLength(1));
      expect(historyFirst.entries.single.agent.runState, AgentRunState.closed);
      expect(historyFirst.entries.single.agent.archivedAt, isNotNull);
      expect(historyFirst.pageInfo.hasMore, isTrue);
      final historySecond = await client.fetchAgentHistory(
        filter: AgentDirectoryFilter(projectKeys: [workspace.projectId]),
        sort: const [
          AgentDirectorySort(
            key: AgentDirectorySortKey.updatedAt,
            direction: AgentDirectorySortDirection.desc,
          ),
        ],
        limit: 1,
        cursor: historyFirst.pageInfo.nextCursor,
      );
      expect(historySecond.entries, hasLength(1));
      expect(historySecond.entries.single.agent.runState, AgentRunState.closed);
      expect(
        {
          historyFirst.entries.single.agent.agentId,
          historySecond.entries.single.agent.agentId,
        },
        {filteredAgent.agentId, replacementAgent.agentId},
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

final class _TestAgentClient implements AgentClient, ImportableAgentClient {
  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async => [
    ImportableProviderSession(
      providerHandleId: 'native-session',
      cwd: options?.cwd ?? Directory.current.path,
      title: 'Imported conversation',
      firstPromptPreview: 'First prompt',
      lastPromptPreview: 'Last prompt',
      lastActivityAt: DateTime.utc(2026, 7, 28),
    ),
  ];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async => _TestAgentSession(
    restoredHistory: sessionId == null
        ? null
        : const [UserMessageItem(id: 'imported', text: 'Imported history')],
  );
}

final class _TestAgentSession
    implements
        AgentSession,
        HistoryRestoringAgentSession,
        CommandListingAgentSession {
  _TestAgentSession({this.restoredHistory});

  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  final List<TimelineItem>? restoredHistory;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> dispose() => _events.close();

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<List<AgentSlashCommand>> listCommands() async => const [
    AgentSlashCommand(
      name: 'review',
      description: 'Review changes',
      argumentHint: '<path>',
      kind: AgentSlashCommandKind.skill,
    ),
  ];
}
