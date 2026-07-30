import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'agent/agent_manager.dart';
import 'agent/create_agent_lifecycle_dispatch.dart';
import 'agent/create_agent_intent.dart';
import 'agent/create_agent_mode.dart';
import 'agent/create_agent_title.dart';
import 'agent/agent_store.dart';
import 'agent/timeline_projection.dart';
import 'agent/timeline_store.dart';
import 'agent/runtime_mcp_config.dart';
import 'chat/chat_service.dart';
import 'forge/forge_action_service.dart';
import 'forge/checkout_refresh_service.dart';
import 'forge/checkout_pr_status_service.dart';
import 'forge/forge_check_details_service.dart';
import 'forge/workspace_forge_status_service.dart';
import 'forge/forge_resolver.dart';
import 'forge/forge_search_service.dart';
import 'forge/pull_request_timeline_service.dart';
import 'git/git_service.dart';
import 'git/workspace_rpc.dart';
import 'hub/relationship_controller.dart';
import 'hub/relationship_remote.dart';
import 'hub/relationship_retry.dart';
import 'loop/loop_agent_runtime.dart';
import 'loop/loop_service.dart';
import 'providers/agent_client.dart';
import 'providers/native/credential_store.dart';
import 'providers/native/native_client.dart';
import 'providers/native/openai_compatible_backend.dart';
import 'providers/native/provider_catalog.dart';
import 'providers/paseo/codex_agent_client.dart';
import 'providers/paseo/claude_agent_client.dart';
import 'providers/paseo/generic_acp_agent_client.dart';
import 'providers/paseo/provider_catalog_registry.dart';
import 'providers/paseo/provider_catalog_v2_service.dart';
import 'providers/paseo/provider_launch_config.dart';
import 'providers/paseo/provider_manifest.dart';
import 'providers/provider_registry.dart';
import 'server/rpc_router.dart';
import 'server/agent_attention_policy.dart';
import 'server/agent_mcp_http.dart';
import 'server/agent_directory_pager.dart';
import 'server/agent_directory_subscription.dart';
import 'server/agent_project_placement.dart';
import 'server/agent_config_service.dart';
import 'server/agent_commands_service.dart';
import 'server/connection.dart';
import 'server/daemon_config_store.dart';
import 'server/daemon_config.dart';
import 'server/daemon_diagnostics.dart';
import 'server/daemon_identity.dart';
import 'server/file_explorer_service.dart';
import 'server/file_transfer_service.dart';
import 'server/project_config_service.dart';
import 'server/provider_visibility.dart';
import 'server/hostnames.dart';
import 'server/importable_provider_sessions.dart';
import 'server/pairing_offer.dart';
import 'server/public_static.dart';
import 'server/relay_transport.dart';
import 'server/terminal_activity_route.dart';
import 'server/trusted_proxies.dart';
import 'server/web_ui.dart';
import 'server/voice_session_v2_service.dart';
import 'server/ws_server.dart';
import 'schedule/schedule_agent_runner.dart';
import 'schedule/schedule_service.dart';
import 'store/project_store.dart';
import 'terminal/terminal_manager.dart';
import 'terminal/terminal_rpc.dart';
import 'terminal/terminal_v2_service.dart';
import 'terminal/agent_hook_installer.dart';
import 'terminal/terminal_agent_hook_setting.dart';
import 'workspace/workspace_registry.dart';
import 'workspace/service_proxy_http.dart';
import 'workspace/service_proxy_route_registry.dart';
import 'workspace/service_proxy_standalone.dart';
import 'workspace/script_health_monitor.dart';
import 'workspace/checkout_status_service.dart';
import 'workspace/checkout_diff_service.dart';
import 'workspace/polling_workspace_git_backend.dart';
import 'workspace/project_github_clone_service.dart';
import 'workspace/github_repository_search_service.dart';
import 'workspace/workspace_script_runtime_store.dart';
import 'workspace/workspace_scripts_service.dart';
import 'workspace/workspace_setup_service.dart';
import 'workspace/worktree_terminal_bootstrap_service.dart';
import 'workspace/workspace_v2_service.dart';
import 'workspace/workspace_auto_name.dart';
import 'workspace/worktree_branch_name_generator.dart';
import 'voice/voice_bridge_registry.dart';
import 'voice/speech_provider.dart';
import 'voice/speech_readiness.dart';
import 'voice/speech_runtime.dart';
import 'voice/turn_detection_provider.dart';
import 'voice/voice_session.dart';

class DaemonServerHandle {
  DaemonServerHandle({
    required this.server,
    required this.lock,
    required this.manager,
    required this.terminals,
    required this.configStore,
    required this.pairingOffer,
    required this.relayTransport,
    required this.hubRelationships,
    required this.loops,
    required this.schedules,
    required this.voiceBridge,
    required this.serviceProxyStandalone,
    required this.stop,
  });

  final WsServer server;
  final PidLock lock;
  final AgentManager manager;
  final TerminalManager terminals;
  final DaemonConfigStore configStore;
  final LocalPairingOffer pairingOffer;
  final RelayTransportController? relayTransport;
  final HubRelationshipController hubRelationships;
  final LoopService loops;
  final ScheduleService schedules;
  final VoiceBridgeRegistry voiceBridge;
  final ServiceProxyStandaloneServer? serviceProxyStandalone;
  final Future<void> Function() stop;
}

Future<DaemonServerHandle> startDaemonServer({
  required DaemonPaths paths,
  String host = '127.0.0.1',
  int port = 6868,
  String? token,
  String? passwordHash,
  List<String> allowedOrigins = const [],
  HostnamesConfig hostnames,
  TrustedProxiesConfig trustedProxies = defaultTrustedProxies,
  bool webUiEnabled = false,
  String? webUiDistDir,
  String staticDir = 'public',
  String? serviceProxyPublicBaseUrl,
  String? serviceProxyListen,
  Duration downloadTokenTtl = const Duration(minutes: 1),
  String? dataDir,
  bool desktopManaged = true,
  bool enableTerminalAgentHooks = false,
  DaemonRelayConfig? relayConfig,
  HubRelationshipRemote? hubRelationshipRemote,
  HubRelationshipClock hubRelationshipClock =
      const SystemHubRelationshipClock(),
  HubRelationshipRetryPolicy? hubRelationshipRetryPolicy,
  String appBaseUrl = defaultTinyrackAppBaseUrl,
  AgentHookInstallOptions hookInstallOptions = const AgentHookInstallOptions(),
  Map<String, AgentClient>? agentClients,
  ProjectGithubCloneRunner? projectGithubCloneRunner,
  GithubCommandRunner? githubCommandRunner,
  TextToSpeechResolver? resolveVoiceTts,
  SpeechToTextResolver? resolveVoiceStt,
  SpeechToTextResolver? resolveDictationStt,
  TurnDetectionResolver? resolveVoiceTurnDetection,
  SpeechReadinessSnapshot Function()? getSpeechReadiness,
  SpeechService? speechService,
  SpeechLogger? speechLogger,
  String sttLanguage = 'en',
  String dictationLanguage = 'en',
  bool agentMcpEnabled = true,
  bool? injectMcpIntoAgents,
  Duration agentMcpWaitTimeout = const Duration(seconds: 30),
  void Function(String)? log,
  void Function()? onShutdownRequested,
}) async {
  log ??= (msg) => stdout.writeln('${DateTime.now().toIso8601String()} $msg');
  final startedAt = DateTime.now();
  final agentMcpAuthToken = const Uuid().v4();

  final lock = PidLock(paths.lockFile);
  try {
    await lock.acquire(
      PidLockData(
        pid: pid,
        startedAtMs: startedAt.millisecondsSinceEpoch,
        host: host,
        port: port,
        version: daemonVersion,
        desktopManaged: desktopManaged,
      ),
    );
  } on LockHeldException catch (e) {
    log('already running (pid ${e.existing.pid} port ${e.existing.port})');
    rethrow;
  }

  final configStore = DaemonConfigStore.load(
    home: paths.dataDir,
    enableTerminalAgentHooks: enableTerminalAgentHooks,
  );
  final serverId = getOrCreateServerId(paths.dataDir, log: log);
  final daemonKeyPair = loadOrCreateDaemonKeyPair(paths.dataDir, log: log);
  final effectiveRelay = relayConfig;
  final pairingOffer = await generateLocalPairingOffer(
    tinyrackHome: paths.dataDir,
    relayEnabled: effectiveRelay?.enabled ?? false,
    relayEndpoint: effectiveRelay?.endpoint ?? defaultTinyrackRelayEndpoint,
    relayPublicEndpoint: effectiveRelay?.publicEndpoint,
    relayUseTls: effectiveRelay?.useTls,
    relayPublicUseTls: effectiveRelay?.publicUseTls,
    appBaseUrl: appBaseUrl,
    includeQr: false,
    log: log,
  );
  final stopTerminalAgentHookSetting = applyTerminalAgentHookSetting(
    store: configStore,
    installOptions: hookInstallOptions,
    onWarning: (provider, error) =>
        log!('failed to update ${provider.name} terminal hooks: $error'),
    onUninstallWarning: (error) =>
        log!('failed to remove terminal activity hooks: $error'),
  );

  final credentials = CredentialStore(dataDir: dataDir);
  final nativeBackends = {
    for (final entry in ProviderCatalog.all)
      entry.id: OpenAiCompatibleBackend(catalogEntry: entry),
  };
  final registry = ProviderRegistry(credentials, nativeBackends);
  late final PaseoProviderCatalogRegistry paseoProviderCatalog;
  GenericAcpAgentClient? genericAcpClient(PaseoProviderDefinition definition) {
    if (!definition.enabledByDefault ||
        (definition.source != 'custom' && definition.id != 'copilot')) {
      return null;
    }
    return GenericAcpAgentClient(
      provider: definition.id,
      command: definition.command,
      commandArgs: definition.commandArgs,
      environment: definition.environment,
      providerParams: definition.providerParams,
      fallbackModes: [for (final mode in definition.modes) mode.mode],
      resolveCommand: () => paseoProviderCatalog.resolveCommand(definition),
    );
  }

  paseoProviderCatalog = PaseoProviderCatalogRegistry(
    configResolver: () => configStore.config,
    catalogProbe: (definition, cwd) async =>
        genericAcpClient(definition)?.fetchCatalog(cwd: cwd),
  );

  late final WsServer server;
  late final WorkspaceV2Service workspaceV2;
  late final CreateAgentLifecycleDispatch createAgentLifecycle;
  late final WorkspaceRegistries workspaceRegistries;
  late final LoopService loops;
  late final ScheduleService schedules;
  late final FileBackedChatService chat;
  late final AgentManager manager;
  final voiceBridge = VoiceBridgeRegistry();
  final agentDirectorySubscriptions = <String, AgentDirectorySubscription>{};
  manager = AgentManager(
    clients:
        agentClients ??
        {
          'claude': ClaudeAgentClient(
            runtimeSettingsResolver: () => providerRuntimeSettingsFromOverride(
              configStore.config.providers['claude'],
            ),
          ),
          'codex': CodexAgentClient(
            runtimeSettingsResolver: () => providerRuntimeSettingsFromOverride(
              configStore.config.providers['codex'],
            ),
          ),
          for (final entry in ProviderCatalog.all)
            entry.id.name: NativeClient(
              providerId: entry.id,
              backend: nativeBackends[entry.id]!,
              credentials: credentials,
            ),
        },
    clientResolver: agentClients == null
        ? (provider) {
            final definition = paseoProviderCatalog.definition(provider);
            return definition == null ? null : genericAcpClient(definition);
          }
        : null,
    providerIdsResolver: agentClients == null
        ? () => paseoProviderCatalog.definitions
              .where(
                (definition) =>
                    definition.enabledByDefault &&
                    (definition.source == 'custom' ||
                        definition.id == 'copilot'),
              )
              .map((definition) => definition.id)
        : null,
    mcpAuthToken: agentMcpAuthToken,
    injectMcpIntoAgents:
        injectMcpIntoAgents ?? configStore.config.injectMcpIntoAgents,
    appendSystemPrompt: configStore.config.appendSystemPrompt,
    store: AgentStore(dataDir: dataDir),
    onStream: (payload) => server.broadcast(
      RpcEvent(type: MessageTypes.agentStreamEvent, payload: payload.toJson()),
      v2Message: PaseoAgentStreamCodec.encode(payload),
      legacyV2Capability: 'tinyrackLegacyTimelineV1',
    ),
    onState: (payload) {
      final legacyEvent = RpcEvent(
        type: MessageTypes.agentStateEvent,
        payload: payload.toJson(),
      );
      server.broadcast(legacyEvent, v2ConnectionIds: const {});
      unawaited(() async {
        // State events can only originate from a loaded provider session, so
        // their provider is available by construction.
        final snapshot = payload.agent;
        final project = await buildAgentProjectPlacement(
          snapshot,
          workspaceRegistries,
        );
        final entry = project == null
            ? null
            : AgentDirectoryEntry(
                agent: snapshot,
                project: project,
                pendingPermissions: _pendingPermissionPayloads(
                  manager,
                  snapshot,
                ),
              );
        for (final subscription in agentDirectorySubscriptions.entries) {
          final connection = server.connectionById(subscription.key);
          if (connection == null) continue;
          final matches =
              entry != null &&
              _matchesAgentDirectoryFilter(entry, subscription.value.filter);
          subscription.value.add(
            matches
                ? AgentDirectoryUpsert(agent: snapshot, project: entry.project)
                : AgentDirectoryRemove(payload.agent.agentId),
            providerVisible: isProviderVisibleToClient(
              snapshot.provider,
              connection.appVersion,
            ),
            emit: (update) =>
                _emitAgentDirectoryUpdate(server, subscription.key, update),
          );
        }
      }());
      unawaited(workspaceV2.onAgentStateChanged(payload.agent.workspaceId));
    },
    onPermissionRequested: (agentId, permissionId, toolName, detail) =>
        server.broadcast(
          RpcEvent(
            type: MessageTypes.permissionRequestedEvent,
            payload: {
              'agentId': agentId,
              'permissionId': permissionId,
              'toolName': toolName,
              'detail': detail.toJson(),
            },
          ),
        ),
    onPermissionResolved: (permissionId, decision) => server.broadcast(
      RpcEvent(
        type: MessageTypes.permissionResolvedEvent,
        payload: {'permissionId': permissionId, 'decision': decision.name},
      ),
    ),
    onAttention: (agentId, reason, timestamp) {
      broadcastAgentAttention(
        server: server,
        agentId: agentId,
        reason: reason,
        timestamp: timestamp,
      );
    },
    onArchived: (agentId) => schedules.completeForAgent(agentId),
    onDeleted: (agent) async {
      await schedules.completeForAgent(agent.agentId);
      for (final subscription in agentDirectorySubscriptions.entries) {
        subscription.value.add(
          AgentDirectoryRemove(agent.agentId),
          providerVisible: true,
          emit: (update) =>
              _emitAgentDirectoryUpdate(server, subscription.key, update),
        );
      }
      await workspaceV2.onAgentStateChanged(agent.workspaceId);
    },
    onProviderSubagentUpdate: (update) => server.broadcast(
      RpcEvent(
        type: MessageTypes.providerSubagentUpdateEvent,
        payload: update.toJson(),
      ),
    ),
  );
  await manager.load();
  final agentConfig = AgentConfigService(manager);

  final router = RpcRouter()
    ..on(MessageTypes.providerListRequest, (_, __) async {
      final providers = await registry.list();
      return ProviderListResponse(providers: providers).toJson();
    })
    ..on(MessageTypes.providerCredentialSetRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      final apiKey = _requireString(payload, 'apiKey');
      await credentials.set(providerId.name, apiKey);
      return const <String, Object?>{};
    })
    ..on(MessageTypes.providerCredentialClearRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      await credentials.clear(providerId.name);
      return const <String, Object?>{};
    })
    ..on(MessageTypes.providerCredentialTestRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      final apiKey =
          (payload['apiKey'] as String?) ??
          await credentials.get(providerId.name);
      if (apiKey == null || apiKey.isEmpty) {
        return const ProviderCredentialTestResult(
          ok: false,
          error: 'no API key given',
        ).toJson();
      }
      final ok = await nativeBackends[providerId]!.testCredential(apiKey);
      return ProviderCredentialTestResult(
        ok: ok,
        error: ok ? null : 'API key rejected by provider',
      ).toJson();
    })
    ..on(MessageTypes.agentCreateRequest, (_, payload) async {
      final cwd = payload['cwd'] as String?;
      if (cwd == null || cwd.isEmpty) {
        throw RpcException(RpcErrorCodes.invalidPayload, 'cwd is required');
      }
      final workspaceId = payload['workspaceId'] as String?;
      final initialPrompt = payload['initialPrompt'] as String?;
      final clientMessageId = payload['clientMessageId'] as String?;
      final images = AgentPromptImage.normalizeList(payload['images']);
      final attachments = AgentAttachment.normalizeList(payload['attachments']);
      String? createdWorkspaceId;
      String? createdAgentId;
      try {
        final lifecycleFields = CreateAgentLifecycleFields.fromJson(payload);
        final createdWorkspace = await createAgentLifecycle
            .createWorktreeForRequest(
              cwd: cwd,
              target: lifecycleFields.worktree,
              initialPrompt: initialPrompt ?? '',
              legacyGitOptions: payload['git'] is Map
                  ? GitSetupOptions.fromJson(
                      Map<String, Object?>.from(payload['git']! as Map),
                    )
                  : null,
              legacyWorktreeName: payload['worktreeName'] as String?,
            );
        createdWorkspaceId = createdWorkspace?.workspaceId;
        final rawLabels = payload['labels'];
        if (rawLabels != null &&
            (rawLabels is! Map ||
                rawLabels.keys.any((key) => key is! String) ||
                rawLabels.values.any((value) => value is! String))) {
          throw const FormatException('labels must contain string values');
        }
        final labels = rawLabels == null
            ? const <String, String>{}
            : Map<String, String>.from(rawLabels as Map);
        final callerAgentId = payload['callerAgentId'] as String?;
        final caller = callerAgentId == null
            ? null
            : manager.get(callerAgentId);
        if (callerAgentId != null && caller == null) {
          throw StateError('Caller agent $callerAgentId not found');
        }
        final intent = await resolveCreateAgentIntent(
          explicitWorkspaceId: createdWorkspace?.workspaceId ?? workspaceId,
          caller: caller == null
              ? null
              : CreateAgentCaller(
                  id: caller.agentId,
                  cwd: caller.cwd,
                  workspaceId: caller.workspaceId,
                ),
          labels: labels,
          resolveWorkspace: (workspaceId) async {
            final workspace = await workspaceV2
                .requireActiveAutomationWorkspace(workspaceId);
            return CreateAgentPlacement(
              workspaceId: workspace.workspaceId,
              cwd: workspace.cwd,
            );
          },
          createWorkspace: () async {
            final workspace = await workspaceV2.createAutomationWorkspace(
              DirectoryWorkspaceCreateSource(path: cwd),
              firstAgentContext: initialPrompt?.trim().isNotEmpty == true
                  ? {'prompt': initialPrompt!.trim()}
                  : null,
            );
            createdWorkspaceId = workspace.workspaceId;
            return CreateAgentPlacement(
              workspaceId: workspace.workspaceId,
              cwd: workspace.cwd,
            );
          },
        );
        final resolvedWorkspace =
            createdWorkspace ??
            await workspaceV2.requireActiveAutomationWorkspace(
              intent.workspaceId,
            );
        final provider =
            (payload['provider'] as String?) ?? ProviderId.openai.name;
        final legacyParentAgentId = payload['parentAgentId'] as String?;
        final parentAgentId = intent.parentAgentId ?? legacyParentAgentId;
        final parent = parentAgentId == null
            ? null
            : manager.get(parentAgentId);
        final requestedFeatures = payload['features'] is Map
            ? Map<String, Object?>.from(payload['features']! as Map)
            : const <String, Object?>{};
        final resolvedConfig = await paseoProviderCatalog
            .resolveCreateAgentConfig(
              AgentCreateConfigRequest(
                cwd: intent.cwd,
                targetProvider: provider,
                requestedMode: payload['modeId'] as String?,
                featureValues: requestedFeatures,
                parent: parent == null
                    ? null
                    : paseoProviderCatalog.createAgentModeParent(parent),
                unattended: false,
              ),
            );
        final titles = resolveCreateAgentTitles(
          configTitle: payload['title'] as String?,
          initialPrompt: initialPrompt,
        );
        final rawEnvironment = payload['env'];
        if (rawEnvironment != null &&
            (rawEnvironment is! Map ||
                rawEnvironment.keys.any((key) => key is! String) ||
                rawEnvironment.values.any((value) => value is! String))) {
          throw const FormatException('env must contain string values');
        }
        final environment = rawEnvironment == null
            ? const <String, String>{}
            : Map<String, String>.from(rawEnvironment as Map);
        final agent = await manager.createAgent(
          cwd: intent.cwd,
          provider: provider,
          model: (payload['model'] as String?) ?? '',
          mode: _parseMode(payload['mode']),
          modeId: resolvedConfig.modeId,
          thinkingOptionId: payload['thinkingOptionId'] as String?,
          featureValues: resolvedConfig.featureValues,
          systemPrompt: payload['systemPrompt'] as String?,
          mcpServers: payload['mcpServers'] is Map
              ? Map<String, Object?>.from(payload['mcpServers']! as Map)
              : const {},
          environment: environment,
          title: titles.provisionalTitle,
          workspaceId: intent.workspaceId,
          projectPath:
              resolvedWorkspace.mainRepoRoot ??
              payload['projectPath'] as String?,
          branch: resolvedWorkspace.branch ?? payload['branch'] as String?,
          isWorktree:
              resolvedWorkspace.isPaseoOwnedWorktree ||
              payload['isWorktree'] == true,
          parentAgentId: parentAgentId,
          labels: intent.labels,
        );
        createdAgentId = agent.agentId;
        createAgentLifecycle.registerAutoArchiveIfRequested(
          autoArchive: lifecycleFields.autoArchive,
          agentId: agent.agentId,
          createdWorkspaceId: createdWorkspaceId,
        );
        Future<void> startInitialPrompt() => manager.prompt(
          agent.agentId,
          initialPrompt ?? '',
          images: images,
          attachments: attachments,
          clientMessageId: clientMessageId,
          outputSchema: payload['outputSchema'] is Map
              ? Map<String, Object?>.from(payload['outputSchema']! as Map)
              : null,
        );

        final hasInitialContent =
            (initialPrompt?.isNotEmpty ?? false) ||
            images.isNotEmpty ||
            attachments.isNotEmpty;
        final continuationStarted = workspaceV2.startAgentContinuation(
          agent,
          onReady: hasInitialContent ? startInitialPrompt : null,
        );
        if (hasInitialContent && !continuationStarted) {
          unawaited(startInitialPrompt());
        }
        return {'agent': agent.toJson()};
      } catch (_) {
        await workspaceV2.cancelAgentContinuation(workspaceId);
        await createAgentLifecycle.cleanupCreatedWorktreeAfterFailedAgentCreate(
          createdWorkspaceId: createdWorkspaceId,
          createdAgentId: createdAgentId,
        );
        rethrow;
      }
    })
    ..on(MessageTypes.agentListRequest, (_, __) {
      return {'agents': manager.list().map((a) => a.toJson()).toList()};
    })
    ..on(MessageTypes.agentPromptRequest, (_, payload) {
      final agentId = _requireString(payload, 'agentId');
      final text = _requireString(payload, 'text');
      final images = AgentPromptImage.normalizeList(payload['images']);
      final attachments = AgentAttachment.normalizeList(payload['attachments']);
      unawaited(
        manager.prompt(agentId, text, images: images, attachments: attachments),
      );
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentInterruptRequest, (_, payload) async {
      await manager.interrupt(_requireString(payload, 'agentId'));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentSetModeRequest, (_, payload) async {
      final agent = await manager.setMode(
        _requireString(payload, 'agentId'),
        _parseMode(payload['mode']),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentRenameRequest, (_, payload) async {
      final agent = await manager.rename(
        _requireString(payload, 'agentId'),
        _requireString(payload, 'title'),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentArchiveRequest, (_, payload) async {
      final agentId = _requireString(payload, 'agentId');
      await manager.archive(agentId);
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentDetachRequest, (_, payload) async {
      final agent = await manager.detach(_requireString(payload, 'agentId'));
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentAttentionClearRequest, (_, payload) async {
      final agent = await manager.clearAttention(
        _requireString(payload, 'agentId'),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentTimelineFetchRequest, (_, payload) {
      return manager
          .fetchTimeline(
            _requireString(payload, 'agentId'),
            epoch: (payload['epoch'] as num?)?.toInt(),
            afterSeq: (payload['afterSeq'] as num?)?.toInt(),
          )
          .toJson();
    })
    ..on(MessageTypes.providerSubagentListRequest, (_, payload) {
      final parentAgentId = _requireString(payload, 'parentAgentId');
      return {
        'parentAgentId': parentAgentId,
        'subagents': manager.providerSubagents
            .list(parentAgentId)
            .map((subagent) => subagent.toJson())
            .toList(),
        'error': null,
      };
    })
    ..on(MessageTypes.providerSubagentTimelineRequest, (_, payload) {
      final parentAgentId = _requireString(payload, 'parentAgentId');
      final subagentId = _requireString(payload, 'subagentId');
      final cursorJson = payload['cursor'];
      if (cursorJson != null && cursorJson is! Map) {
        throw RpcException(
          RpcErrorCodes.invalidPayload,
          'cursor must be an object',
        );
      }
      final ProviderSubagentTimelineCursor? cursor;
      try {
        cursor = cursorJson == null
            ? null
            : ProviderSubagentTimelineCursor.fromJson(
                (cursorJson as Map).cast<String, Object?>(),
              );
      } on Object {
        throw RpcException(
          RpcErrorCodes.invalidPayload,
          'cursor requires a non-empty epoch and non-negative integer seq',
        );
      }
      final directionValue = payload['direction'];
      if (directionValue != null && directionValue is! String) {
        throw RpcException(
          RpcErrorCodes.invalidPayload,
          'direction must be tail, before, or after',
        );
      }
      final directionName =
          directionValue as String? ?? (cursor == null ? 'tail' : 'after');
      final ProviderSubagentTimelineDirection direction;
      try {
        direction = ProviderSubagentTimelineDirection.values.byName(
          directionName,
        );
      } on ArgumentError {
        throw RpcException(
          RpcErrorCodes.invalidPayload,
          'direction must be tail, before, or after',
        );
      }
      final rawLimit = payload['limit'];
      if (rawLimit != null &&
          (rawLimit is! num || rawLimit < 0 || rawLimit.toInt() != rawLimit)) {
        throw RpcException(
          RpcErrorCodes.invalidPayload,
          'limit must be a non-negative integer',
        );
      }
      final page = manager.providerSubagents.fetchTimeline(
        parentAgentId,
        subagentId,
        direction: direction,
        cursor: cursor,
        limit:
            (rawLimit as num?)?.toInt() ??
            (direction == ProviderSubagentTimelineDirection.after ? 0 : 200),
      );
      if (page == null) {
        return ProviderSubagentTimelineResponse(
          parentAgentId: parentAgentId,
          subagentId: subagentId,
          provider: null,
          direction: direction,
          epoch: '',
          reset: false,
          staleCursor: false,
          gap: false,
          window: const ProviderSubagentTimelineWindow(
            minSeq: 0,
            maxSeq: 0,
            nextSeq: 0,
          ),
          hasOlder: false,
          hasNewer: false,
          rows: const [],
          error: 'Provider subagent not found',
        ).toJson();
      }
      return ProviderSubagentTimelineResponse(
        parentAgentId: parentAgentId,
        subagentId: subagentId,
        provider: page.descriptor.provider,
        direction: page.direction,
        epoch: page.epoch,
        reset: page.reset,
        staleCursor: page.staleCursor,
        gap: page.gap,
        window: page.window,
        hasOlder: page.hasOlder,
        hasNewer: page.hasNewer,
        rows: page.rows,
      ).toJson();
    })
    ..on(MessageTypes.agentConversationClearRequest, (_, payload) async {
      // Optional agentId scopes the wipe to one agent; missing/empty means
      // "clear every agent the daemon has loaded".
      final agentId = payload['agentId'] as String?;
      final cleared = await manager.clearConversations(
        agentId: (agentId == null || agentId.isEmpty) ? null : agentId,
      );
      return AgentConversationClearResponse(cleared: cleared).toJson();
    })
    ..on(MessageTypes.permissionRespondRequest, (_, payload) async {
      await manager.respondPermission(
        _requireString(payload, 'permissionId'),
        _requireString(payload, 'decision'),
      );
      return const <String, Object?>{};
    });

  final rootDataDir = dataDir ?? ProjectStore.defaultDataDir();
  // The temporary v1 adapter cannot share projects.json: Paseo v2 persists a
  // top-level array while the MVP store used a {projects: [...]} object.
  final projectStore = ProjectStore(dataDir: p.join(rootDataDir, 'v1-adapter'));
  final gitService = GitService(dataDir: rootDataDir);
  registerWorkspaceHandlers(router, projects: projectStore, git: gitService);
  workspaceRegistries = WorkspaceRegistries(dataDir: rootDataDir);
  await workspaceRegistries.initialize();
  final projectGithubClone = ProjectGithubCloneService(
    registries: workspaceRegistries,
    runClone: projectGithubCloneRunner,
  );
  final githubRepositorySearch = WorkspaceGithubRepositorySearchService(
    runner: githubCommandRunner,
  );
  final projectConfig = ProjectConfigService(
    projects: workspaceRegistries.projects,
  );
  final downloadTokens = DownloadTokenStore(ttl: downloadTokenTtl);
  final fileTransfers = WorkspaceFileTransferService(
    home: paths.dataDir,
    downloadTokens: downloadTokens,
  );
  final fileExplorer = WorkspaceFileExplorerService();
  final serviceProxyRoutes = ServiceProxyRouteRegistry(
    publicBaseUrl: serviceProxyPublicBaseUrl,
  );
  final serviceProxyHttp = ServiceProxyHttpHandler(routes: serviceProxyRoutes);
  final serviceProxyStandalone = serviceProxyListen == null
      ? null
      : ServiceProxyStandaloneServer(proxy: serviceProxyHttp);
  final forgeResolver = ForgeResolver();
  final forgeStatus = WorkspaceForgeStatusService(resolver: forgeResolver);
  final workspaceGitObserverBackend = PollingWorkspaceGitBackend(
    forgeStatus: forgeStatus,
  );
  final checkoutStatus = CheckoutStatusService(
    loadSnapshot: workspaceGitObserverBackend.getSnapshot,
    resolveWorkspace: (cwd) =>
        resolveCheckoutStatusWorkspace(workspaceRegistries.workspaces, cwd),
  );
  final checkoutDiff = CheckoutDiffService(
    git: gitService,
    backend: workspaceGitObserverBackend,
  );
  final forgeSearch = ForgeSearchService(resolver: forgeResolver);
  final pullRequestTimeline = PullRequestTimelineService(
    resolver: forgeResolver,
  );
  final forgeActions = ForgeActionService(
    resolver: forgeResolver,
    statusService: forgeStatus,
  );
  final checkoutPrStatus = CheckoutPrStatusService(statusService: forgeStatus);
  final checkoutRefresh = CheckoutRefreshService(
    statusService: forgeStatus,
    refreshObserver: workspaceGitObserverBackend.refreshNow,
  );
  final forgeCheckDetails = ForgeCheckDetailsService(resolver: forgeResolver);

  late final WorkspaceScriptsService workspaceScripts;
  final terminals = TerminalManager(
    sendBinary: (connectionId, bytes) {
      server.connectionById(connectionId)?.sendBinary(bytes);
    },
    onExited: (terminalId, exitCode) {
      server.broadcast(
        RpcEvent(
          type: MessageTypes.terminalExitedEvent,
          payload: {'terminalId': terminalId, 'exitCode': exitCode},
        ),
      );
      unawaited(workspaceScripts.onTerminalExited(terminalId, exitCode));
    },
    onWorkspaceContributionChanged: (workspaceId) {
      unawaited(workspaceV2.onTerminalStateChanged(workspaceId));
    },
    onActivityChanged: (transition) {
      broadcastTerminalAttention(server: server, transition: transition);
    },
    onStreamExited: (connectionId, terminalId) {
      server.connectionById(connectionId)?.sendJson({
        'type': 'session',
        'message': TerminalStreamExit(terminalId: terminalId).toJson(),
      });
    },
    getTerminalActivityUrl: () {
      final activityHost = switch (host) {
        '0.0.0.0' || '::' => '127.0.0.1',
        _ => host,
      };
      return Uri(
        scheme: 'http',
        host: activityHost,
        port: server.port,
        path: '/api/terminal-activity',
      ).toString();
    },
  );
  registerTerminalHandlers(router, terminals: terminals);

  server = WsServer(
    router: router,
    token: token,
    passwordHash: passwordHash,
    allowedOrigins: allowedOrigins,
    hostnames: hostnames,
    desktopManaged: desktopManaged,
    terminalActivityHandler: TerminalActivityRoute(terminals).call,
    publicStaticHandler: PublicStaticHandler(staticDir).call,
    fileDownloadHandler: FileDownloadHandler(downloadTokens).call,
    serviceProxyHandler: serviceProxyHttp.call,
    agentMcpHandler: agentMcpEnabled
        ? AgentMcpHttpHandler(
            manager: manager,
            providerCatalog: paseoProviderCatalog,
            workspaceService: () => workspaceV2,
            workspaceScripts: () => workspaceScripts,
            schedules: () => schedules,
            terminals: terminals,
            voiceBridge: voiceBridge,
            capabilityToken: agentMcpAuthToken,
            passwordHash: passwordHash,
            agentWaitTimeout: agentMcpWaitTimeout,
          ).call
        : null,
    webUiHandler: DaemonWebUi(
      enabled: webUiEnabled,
      distDir: webUiDistDir,
      label: Platform.localHostname,
      trustedProxies: trustedProxies,
    ).call,
    serverId: serverId,
  );
  late final ScriptHealthMonitor scriptHealth;
  workspaceScripts = WorkspaceScriptsService(
    workspaces: workspaceRegistries.workspaces,
    terminals: terminals,
    runtimeStore: WorkspaceScriptRuntimeStore(),
    broadcast: server.broadcastV2,
    serviceProxy: serviceProxyRoutes,
    daemonPort: () => server.port,
    daemonListenHost: host,
    serviceProxyPublicBaseUrl: serviceProxyPublicBaseUrl,
    resolveHealth: (hostname) => scriptHealth.getHealthForHostname(hostname),
    invalidateHealth: (workspaceId) =>
        scriptHealth.invalidateWorkspace(workspaceId),
    branchObserverBackend: workspaceGitObserverBackend,
    log: log,
  );
  scriptHealth = ScriptHealthMonitor(
    serviceProxy: serviceProxyRoutes,
    onChange: (workspaceId, _) =>
        unawaited(workspaceScripts.emitStatusUpdate(workspaceId)),
  );
  final workspaceSetup = WorkspaceSetupService(
    broadcast: server.broadcastV2,
    registerEnvironment: terminals.registerCwdEnvironment,
  );
  final terminalBootstrap = WorktreeTerminalBootstrapService.forManager(
    terminals,
  );
  final branchNameGenerator = WorktreeBranchNameGenerator(
    manager: manager,
    providerCatalog: paseoProviderCatalog,
    configuredProviders: () => configStore.config.metadataGenerationProviders,
  );
  final workspaceAutoName = WorkspaceAutoName(
    workspaces: workspaceRegistries.workspaces,
    git: gitService,
    generate: branchNameGenerator.call,
    notifyGitMutation: (cwd, mutation) async {
      if (mutation == 'rename-branch') {
        await workspaceGitObserverBackend.refreshNow(cwd);
      }
    },
  );
  Future<List<String>> archiveWorkspaceOwnedContent(String workspaceId) async {
    final archivedAgentIds = await manager.archiveWorkspaceAgents(workspaceId);
    final terminalIds = [
      for (final terminal in terminals.listV2(workspaceId: workspaceId))
        terminal['id']! as String,
    ];
    for (final terminalId in terminalIds) {
      try {
        await terminals.killAndWait(terminalId);
      } on Object {
        // Owned-content teardown is best effort before durable archival.
      }
    }
    return archivedAgentIds;
  }

  workspaceV2 = WorkspaceV2Service(
    registries: workspaceRegistries,
    git: gitService,
    gitSnapshots: workspaceGitObserverBackend,
    workspaceSetup: workspaceSetup,
    terminalBootstrap: terminalBootstrap,
    workspaceAutoName: workspaceAutoName,
    appendAgentTimeline: manager.upsertTimelineItem,
    archiveOwnedContent: archiveWorkspaceOwnedContent,
    listAgents: manager.list,
    listTerminalContributions: terminals.listActivityContributions,
    broadcast: (message, connectionIds) =>
        server.broadcastV2(message, connectionIds: connectionIds),
  );
  createAgentLifecycle = CreateAgentLifecycleDispatch(
    manager: manager,
    workspaces: workspaceV2,
    git: gitService,
    archiveWorkspace: (workspaceId) async {
      await archiveWorkspaceOwnedContent(workspaceId);
      await workspaceV2.archiveAutomationWorkspace(workspaceId);
    },
    log: log,
  );
  final terminalV2 = TerminalV2Service(
    terminals: terminals,
    resolveWorkspaceId: (cwd) async {
      final normalized = p.normalize(p.absolute(cwd));
      PersistedWorkspaceRecord? owner;
      for (final workspace in await workspaceRegistries.workspaces.list()) {
        if (workspace.archivedAt != null) continue;
        final root = p.normalize(p.absolute(workspace.cwd));
        if (p.equals(root, normalized) || p.isWithin(root, normalized)) {
          if (owner == null || root.length > owner.cwd.length) {
            owner = workspace;
          }
        }
      }
      return owner?.workspaceId;
    },
  );
  final loopRuntime = LoopAgentRuntime(
    manager,
    workspaceV2,
    resolveCreateMode: paseoProviderCatalog.resolveCreateAgentMode,
  );
  loops = LoopService(
    home: paths.dataDir,
    createAgentSession: loopRuntime.createSession,
    resolveWorkspace: loopRuntime.resolveWorkspace,
    onError: (error, stack) => log!('loop service error: $error\n$stack'),
  );
  final scheduleRunner = ScheduleAgentRunner(
    manager,
    workspaceV2,
    resolveCreateMode: paseoProviderCatalog.resolveCreateAgentMode,
    recordWorkspace:
        ({
          required scheduleId,
          required runId,
          required workspaceId,
          required agentId,
        }) => schedules.recordRunWorkspace(
          scheduleId: scheduleId,
          runId: runId,
          workspaceId: workspaceId,
          agentId: agentId,
        ),
  );
  schedules = ScheduleService(
    home: paths.dataDir,
    runner: scheduleRunner.call,
    archiveWorkspace: workspaceV2.archiveScheduleRunWorkspace,
    targetAgentExists: (agentId) =>
        manager.list().any((agent) => agent.agentId == agentId),
  );
  chat = FileBackedChatService(
    home: paths.dataDir,
    prepareMentions:
        ({
          required room,
          required authorAgentId,
          required body,
          required mentionAgentIds,
          required roomPosterAgentIds,
        }) async {
          final candidates = <String>{
            for (final mention in mentionAgentIds)
              if (mention != 'everyone') mention,
            if (mentionAgentIds.contains('everyone')) ...roomPosterAgentIds,
          }..remove(authorAgentId);
          final active = {
            for (final agent in manager.list())
              if (agent.runState != AgentRunState.error) agent.agentId: agent,
          };
          final targets = <String>{};
          for (final candidate in candidates) {
            try {
              final resolved = manager.resolveIdentifier(candidate);
              if (active.containsKey(resolved.agentId)) {
                targets.add(resolved.agentId);
              }
            } on Object catch (error) {
              log!('failed to resolve chat mention $candidate: $error');
            }
          }
          if (mentionAgentIds.contains('everyone') &&
              targets.length > chatMentionFanoutLimit) {
            throw ChatServiceException(
              'chat_mention_fanout_limit_exceeded',
              '@everyone would notify ${targets.length} agents, which exceeds '
                  'the limit of $chatMentionFanoutLimit. Narrow the room or '
                  'mention specific agents.',
            );
          }
          return targets.toList(growable: false);
        },
    notifyMentions:
        ({
          required room,
          required authorAgentId,
          required body,
          required mentionAgentIds,
          required roomPosterAgentIds,
        }) async {
          if (mentionAgentIds.isEmpty) return;
          final notification = buildChatMentionNotification(
            room: room,
            authorAgentId: authorAgentId,
            body: body,
            mentionAgentIds: mentionAgentIds,
          );
          await Future.wait([
            for (final target in mentionAgentIds)
              manager
                  .prompt(target, notification)
                  .catchError(
                    (Object error) =>
                        log!('failed to notify chat mention $target: $error'),
                  ),
          ]);
        },
    onError: (error, stack) => log!('chat service error: $error\n$stack'),
  );
  await chat.initialize();
  final agentCommands = AgentCommandsService(manager);
  final providerCatalogV2 = ProviderCatalogV2Service(
    registry: paseoProviderCatalog,
    featureResolver: manager.listFeatures,
    onSnapshotChanged: (update) => server.broadcastV2(update.toJson()),
  );
  final voiceSessions = VoiceSessionV2Service(
    createHost: (connection) =>
        _DaemonVoiceSessionHost(manager: manager, connection: connection),
    resolveTts: speechService?.resolveTts ?? resolveVoiceTts ?? () => null,
    resolveStt: speechService?.resolveStt ?? resolveVoiceStt ?? () => null,
    resolveDictationStt:
        speechService?.resolveDictationStt ?? resolveDictationStt,
    resolveTurnDetection:
        speechService?.resolveTurnDetection ??
        resolveVoiceTurnDetection ??
        () => null,
    voiceBridge: voiceBridge,
    getSpeechReadiness: speechService?.getReadiness ?? getSpeechReadiness,
    logger: speechLogger ?? const NullSpeechLogger(),
    sttLanguage: speechService?.resolveSttLanguage() ?? sttLanguage,
    dictationLanguage:
        speechService?.resolveDictationSttLanguage() ?? dictationLanguage,
    environment: Platform.environment,
    cwd: paths.dataDir,
  );
  final stopSpeechReadiness =
      speechService?.onReadinessChange(
        (snapshot) => server.updateServerCapabilities(
          buildSpeechServerCapabilities(snapshot),
        ),
      ) ??
      () {};
  final hubRelationships = HubRelationshipController(
    home: paths.dataDir,
    serverId: serverId,
    daemonPublicKey: daemonKeyPair.publicKeyB64,
    remote: hubRelationshipRemote ?? DirectHubRelationshipRemote(),
    clock: hubRelationshipClock,
    retryPolicy: hubRelationshipRetryPolicy,
    log: log,
    attachSocket: (socket, {required daemonId, required scopes}) {
      server.attachHubSocket(
        frames: socket.frames,
        send: socket.send,
        close: socket.close,
        daemonId: daemonId,
        scopes: scopes,
      );
    },
  );
  String? agentMcpBaseUrl;
  final stopConfigBroadcast = configStore.onChange((config) {
    manager.configureRuntimeMcp(
      baseUrl: agentMcpBaseUrl,
      injectIntoAgents: injectMcpIntoAgents ?? config.injectMcpIntoAgents,
    );
    manager.setAppendSystemPrompt(config.appendSystemPrompt);
    server.broadcastV2({
      'type': 'status',
      'message': DaemonConfigChangedStatus(config: config).toJson(),
    });
  });
  server.onV2SessionMessage = (connection, message) async {
    if (await voiceSessions.handle(connection, message)) {
      return v2HandledNoResponse;
    }
    if (message['type'] == 'client_heartbeat') {
      _recordClientHeartbeat(connection, message);
      final presence = connection.clientPresence;
      final focusedTerminalId = presence.focusedTerminalId;
      if (presence.appVisible && focusedTerminalId != null) {
        try {
          terminals.clearAttention(focusedTerminalId);
        } on StateError {
          // A stale heartbeat may race terminal exit/removal.
        }
      }
      return null;
    }
    if (message['type'] == CreateAgentRequest.type) {
      final requestId = message['requestId'] as String? ?? '';
      try {
        final request = CreateAgentRequest.fromJson(message);
        final config = request.config;
        final legacy = await router.dispatch(
          connection,
          RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: request.requestId,
            payload: {
              'cwd': config.cwd,
              if (request.workspaceId != null)
                'workspaceId': request.workspaceId,
              if (request.callerAgentId != null)
                'callerAgentId': request.callerAgentId,
              if (request.worktreeName != null)
                'worktreeName': request.worktreeName,
              'provider': config.provider,
              if (config.model != null) 'model': config.model,
              if (config.modeId != null) 'modeId': config.modeId,
              if (config.thinkingOptionId != null)
                'thinkingOptionId': config.thinkingOptionId,
              if (config.featureValues != null)
                'features': config.featureValues,
              if (config.hasTitle) 'title': config.title,
              if (config.systemPrompt != null)
                'systemPrompt': config.systemPrompt,
              if (config.mcpServers != null) 'mcpServers': config.mcpServers,
              if (request.initialPrompt != null)
                'initialPrompt': request.initialPrompt,
              if (request.clientMessageId != null)
                'clientMessageId': request.clientMessageId,
              if (request.images.isNotEmpty)
                'images': [for (final image in request.images) image.toJson()],
              if (request.attachments.isNotEmpty)
                'attachments': [
                  for (final attachment in request.attachments)
                    attachment.toJson(),
                ],
              if (request.env != null) 'env': request.env,
              if (request.outputSchema != null)
                'outputSchema': request.outputSchema,
              if (request.git != null) 'git': request.git!.toJson(),
              if (request.worktree != null)
                'worktree': request.worktree!.toJson(),
              if (request.autoArchive != null)
                'autoArchive': request.autoArchive,
              'labels': request.labels,
            },
          ),
        );
        if (legacy.error case final error?) {
          return AgentCreateFailedStatus(
            requestId: request.requestId,
            error: error.message,
            errorCode: error.code,
          ).toJson();
        }
        final rawAgent = legacy.payload['agent'];
        if (rawAgent is! Map) {
          throw StateError('Agent creation returned no agent');
        }
        final agentId = rawAgent['agentId'];
        if (agentId is! String || agentId.isEmpty) {
          throw StateError('Agent creation returned no agent id');
        }
        return AgentCreatedStatus(
          requestId: request.requestId,
          agentId: agentId,
          agent: _paseoAgentSnapshot(manager, paseoProviderCatalog, agentId),
        ).toJson();
      } on Object catch (error) {
        return AgentCreateFailedStatus(
          requestId: requestId,
          error: _cancelAgentError(error),
        ).toJson();
      }
    }
    if (message['type'] == 'clear_agent_attention') {
      final rawAgentIds = message['agentId'];
      final agentIds = switch (rawAgentIds) {
        String value when value.trim().isNotEmpty => [value.trim()],
        List values => [
          for (final value in values)
            if (value is String && value.trim().isNotEmpty) value.trim(),
        ],
        _ => const <String>[],
      };
      if (agentIds.isEmpty) {
        throw const FormatException('agentId is required');
      }
      final agents = <AgentSummary>[];
      for (final agentId in agentIds) {
        agents.add(await manager.clearAttention(agentId));
      }
      return {
        'type': 'clear_agent_attention_response',
        'payload': {
          'requestId': message['requestId'] as String? ?? '',
          'agentId': rawAgentIds,
          'agents': agents.map((agent) => agent.toJson()).toList(),
        },
      };
    }
    if (message['type'] == CancelAgentRequest.type) {
      return await _handlePaseoCancelAgent(
            manager,
            paseoProviderCatalog,
            message,
          ) ??
          v2HandledNoResponse;
    }
    if (message['type'] == ArchiveAgentRequest.type) {
      final request = ArchiveAgentRequest.fromJson(message);
      final agent = await manager.archive(request.agentId);
      return AgentArchivedResponse(
        requestId: request.requestId,
        agentId: request.agentId,
        archivedAt: agent.archivedAt!,
      ).toJson();
    }
    if (message['type'] == DeleteAgentRequest.type) {
      final request = DeleteAgentRequest.fromJson(message);
      await manager.delete(request.agentId);
      return AgentDeletedResponse(
        requestId: request.requestId,
        agentId: request.agentId,
      ).toJson();
    }
    if (message['type'] == AgentDetachRequest.type) {
      final request = AgentDetachRequest.fromJson(message);
      try {
        final before = manager.get(request.agentId);
        final previousParent =
            before?.parentAgentId ?? parentAgentIdFromLabels(before?.labels);
        final agent = await manager.detach(request.agentId);
        final parentWorkspaceId = previousParent == null
            ? null
            : manager.get(previousParent)?.workspaceId;
        if (parentWorkspaceId != null &&
            parentWorkspaceId != agent.workspaceId) {
          await workspaceV2.onAgentStateChanged(parentWorkspaceId);
        }
        return AgentDetachResponse(
          requestId: request.requestId,
          agentId: request.agentId,
          accepted: true,
          error: null,
        ).toJson();
      } on Object catch (error) {
        return AgentDetachResponse(
          requestId: request.requestId,
          agentId: request.agentId,
          accepted: false,
          error: '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), ''),
        ).toJson();
      }
    }
    if (message['type'] == RefreshAgentRequest.type) {
      final request = RefreshAgentRequest.fromJson(message);
      try {
        final before = manager.get(request.agentId);
        if (before == null) {
          throw StateError('Agent not found: ${request.agentId}');
        }
        await manager.reloadAgentSession(
          request.agentId,
          systemPrompt: before.systemPrompt,
          rehydrateFromProvider: true,
          unarchive: true,
        );
        return AgentRefreshedStatus(
          requestId: request.requestId,
          agentId: request.agentId,
          timelineSize: manager.fetchTimeline(request.agentId).items.length,
        ).toJson();
      } on Object catch (error) {
        return {
          'type': 'rpc_error',
          'payload': {
            'requestId': request.requestId,
            'requestType': RefreshAgentRequest.type,
            'error': '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), ''),
            'code': 'agent_refresh_failed',
          },
        };
      }
    }
    if (message['type'] == UpdateAgentRequest.type) {
      final request = UpdateAgentRequest.fromJson(message);
      final title = request.name?.trim();
      final labels = request.labels?.isNotEmpty == true ? request.labels : null;
      if ((title == null || title.isEmpty) && labels == null) {
        return UpdateAgentResponse(
          requestId: request.requestId,
          agentId: request.agentId,
          accepted: false,
          error: 'Nothing to update (provide name and/or labels)',
        ).toJson();
      }
      try {
        await manager.updateMetadata(
          request.agentId,
          name: title,
          labels: labels,
        );
        return UpdateAgentResponse(
          requestId: request.requestId,
          agentId: request.agentId,
          accepted: true,
          error: null,
        ).toJson();
      } on Object catch (error) {
        return UpdateAgentResponse(
          requestId: request.requestId,
          agentId: request.agentId,
          accepted: false,
          error: '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), ''),
        ).toJson();
      }
    }
    if (message['type'] == SendAgentMessageRequest.type) {
      return _handlePaseoSendAgentMessage(
        manager,
        paseoProviderCatalog,
        connection,
        message,
      );
    }
    if (message['type'] == WaitForFinishRequest.type) {
      return _handlePaseoWaitForFinish(
        manager,
        paseoProviderCatalog,
        connection,
        message,
      );
    }
    final agentTimelineResponse = _handlePaseoTimelineFetch(
      manager,
      paseoProviderCatalog,
      message,
    );
    if (agentTimelineResponse != null) return agentTimelineResponse;
    final agentResponse = await _handlePaseoFetchAgent(
      manager,
      paseoProviderCatalog,
      workspaceRegistries,
      connection,
      message,
    );
    if (agentResponse != null) return agentResponse;
    if (message['type'] == ImportAgentRequest.type) {
      final requestId = message['requestId'] as String? ?? '';
      try {
        final request = ImportAgentRequest.fromJson(message);
        final provider = request.normalizedProvider;
        final providerHandleId = request.normalizedProviderHandleId;
        if (provider == null || providerHandleId == null) {
          return _importAgentFailedStatus(
            request.requestId,
            'Import requires providerId and providerHandleId',
          );
        }
        final cwd = request.cwd;
        if (cwd == null) {
          return _importAgentFailedStatus(
            request.requestId,
            'Import requires cwd from the selected provider session',
          );
        }
        final placement = await workspaceV2.runInImportWorkspace(
          cwd: cwd,
          requestedWorkspaceId: request.workspaceId,
          operation: (workspace) => manager.importProviderSession(
            provider: provider,
            providerHandleId: providerHandleId,
            cwd: cwd,
            workspaceId: workspace.workspaceId,
            labels: request.labels ?? const {},
          ),
        );
        final imported = placement.value;
        return {
          'type': 'status',
          'payload': {
            'status': 'agent_resumed',
            'agentId': imported.summary.agentId,
            'requestId': request.requestId,
            'timelineSize': imported.timelineSize,
            'agent': PaseoAgentSnapshotCodec.encode(imported.summary),
          },
        };
      } catch (error) {
        final message = _importAgentErrorMessage(error);
        server.broadcastV2({
          'type': 'activity_log',
          'payload': {
            'id': const Uuid().v4(),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'type': 'error',
            'content': 'Failed to import agent: $message',
          },
        });
        return _importAgentFailedStatus(requestId, message);
      }
    }
    if (message['type'] == FetchRecentProviderSessionsRequest.type) {
      final requestId = message['requestId'] as String? ?? '';
      try {
        final request = FetchRecentProviderSessionsRequest.fromJson(message);
        final result = await listImportableProviderSessions(
          request: request,
          manager: manager,
          providerLabel: (provider) =>
              paseoProviderCatalog.definition(provider)?.label ?? provider,
        );
        return FetchRecentProviderSessionsResponse(
          requestId: request.requestId,
          entries: result.entries,
          filteredAlreadyImportedCount: result.filteredAlreadyImportedCount > 0
              ? result.filteredAlreadyImportedCount
              : null,
        ).toJson();
      } on ImportSessionsRequestException catch (error) {
        return {
          'type': 'rpc_error',
          'payload': {
            'requestId': requestId,
            'requestType': message['type'],
            'error': error.message,
            'code': error.code,
          },
        };
      }
    }
    if (message['type'] == AgentPermissionResponseMessage.type) {
      final request = AgentPermissionResponseMessage.fromJson(message);
      final response = request.response;
      await manager.respondPermissionDetailed(
        agentId: request.agentId,
        permissionId: request.requestId,
        behavior: response.behavior.name,
        selectedActionId: response.selectedActionId,
        updatedInput: response.updatedInput,
        updatedPermissions: response.updatedPermissions,
        message: response.message,
        interrupt: response.interrupt,
      );
      return v2HandledNoResponse;
    }
    final projectGithubCloneResponse = await projectGithubClone.handle(message);
    if (projectGithubCloneResponse != null) return projectGithubCloneResponse;
    final githubRepositorySearchResponse = await githubRepositorySearch.handle(
      message,
    );
    if (githubRepositorySearchResponse != null) {
      return githubRepositorySearchResponse;
    }
    final agentDirectoryResponse = await _handlePaseoFetchAgents(
      manager,
      workspaceRegistries,
      connection,
      message,
      agentDirectorySubscriptions,
      server,
    );
    if (agentDirectoryResponse != null) return agentDirectoryResponse;
    final agentConfigResponse = await agentConfig.handle(connection, message);
    if (agentConfigResponse != null) return agentConfigResponse;
    final agentCommandsResponse = await agentCommands.handle(message);
    if (agentCommandsResponse != null) return agentCommandsResponse;
    final chatResponse = await chat.handle(
      message,
      defaultAuthorAgentId: connection.clientName,
    );
    if (chatResponse != null) return chatResponse;
    final scheduleResponse = await schedules.handle(message);
    if (scheduleResponse != null) return scheduleResponse;
    final loopResponse = await loops.handle(message);
    if (loopResponse != null) return loopResponse;
    final terminalResponse = await terminalV2.handle(connection, message);
    if (terminalResponse != null) return terminalResponse;
    final workspaceScriptResponse = await workspaceScripts.handle(
      connection,
      message,
    );
    if (workspaceScriptResponse != null) return workspaceScriptResponse;
    final fileExplorerResponse = await fileExplorer.handle(connection, message);
    if (fileExplorerResponse != null) return fileExplorerResponse;
    final projectConfigResponse = await projectConfig.handle(
      connection,
      message,
    );
    if (projectConfigResponse != null) return projectConfigResponse;
    final fileTransferResponse = await fileTransfers.handle(
      connection,
      message,
    );
    if (fileTransferResponse != null) return fileTransferResponse;
    if (message['type'] == DaemonGetPairingOfferRequest.type) {
      final request = DaemonGetPairingOfferRequest.fromJson(message);
      final pairing = await generateLocalPairingOffer(
        tinyrackHome: paths.dataDir,
        relayEnabled: effectiveRelay?.enabled ?? false,
        relayEndpoint: effectiveRelay?.endpoint ?? defaultTinyrackRelayEndpoint,
        relayPublicEndpoint: effectiveRelay?.publicEndpoint,
        relayUseTls: effectiveRelay?.useTls,
        relayPublicUseTls: effectiveRelay?.publicUseTls,
        appBaseUrl: appBaseUrl,
        includeQr: true,
        log: log,
      );
      return DaemonGetPairingOfferResponse(
        requestId: request.requestId,
        url: pairing.url ?? '',
        qr: pairing.qr,
        relayEnabled: pairing.relayEnabled,
      ).toJson();
    }
    if (message['type'] == DiagnosticsRequest.type) {
      final request = DiagnosticsRequest.fromJson(message);
      try {
        final diagnostic = await collectDaemonDiagnostics(
          DaemonDiagnosticsOptions(
            home: paths.dataDir,
            serverId: serverId,
            daemonVersion: daemonVersion,
            listen: '$host:${server.port}',
            relayEnabled: effectiveRelay?.enabled ?? false,
            relayEndpoint: effectiveRelay?.endpoint,
            relayPublicEndpoint: effectiveRelay?.publicEndpoint,
            relayUseTls: effectiveRelay?.useTls ?? false,
            relayPublicUseTls: effectiveRelay?.publicUseTls ?? false,
            startedAt: startedAt,
            listAgents: manager.list,
            listProjects: workspaceRegistries.projects.list,
            listWorkspaces: workspaceRegistries.workspaces.list,
            listProviders: paseoProviderCatalog.listAvailability,
            webSocketRuntime: server.diagnosticSnapshot,
            log: log,
          ),
        );
        return DiagnosticsResponse(
          requestId: request.requestId,
          diagnostic: diagnostic,
        ).toJson();
      } catch (error) {
        return DiagnosticsResponse(
          requestId: request.requestId,
          diagnostic: 'Tinyrack diagnostics\n  Error: $error',
        ).toJson();
      }
    }
    if (message['type']
        case HubManagementDaemonConnectRequest.type ||
            HubManagementDaemonGetStatusRequest.type ||
            HubManagementDaemonDisconnectRequest.type) {
      final requestId = message['requestId'] as String? ?? '';
      try {
        final request = HubManagementDaemonRequest.fromJson(message);
        return switch (request) {
          HubManagementDaemonConnectRequest request =>
            HubManagementDaemonConnectResponse(
              requestId: request.requestId,
              status: await hubRelationships.connect(
                hubUrl: request.hubUrl,
                token: request.token,
              ),
            ).toJson(),
          HubManagementDaemonGetStatusRequest request =>
            HubManagementDaemonGetStatusResponse(
              requestId: request.requestId,
              status: hubRelationships.status,
            ).toJson(),
          HubManagementDaemonDisconnectRequest request => await _disconnectHub(
            hubRelationships,
            request,
          ),
        };
      } catch (error) {
        return {
          'type': 'rpc_error',
          'payload': {
            'requestId': requestId,
            'requestType': message['type'],
            'error': '$error',
            'code': 'handler_error',
          },
        };
      }
    }
    if (message['type'] == 'get_daemon_config_request') {
      final request = GetDaemonConfigRequest.fromJson(message);
      return DaemonConfigResponse(
        type: 'get_daemon_config_response',
        requestId: request.requestId,
        config: configStore.config,
      ).toJson();
    }
    if (message['type'] == 'set_daemon_config_request') {
      final request = SetDaemonConfigRequest.fromJson(message);
      configStore.patch(request.config);
      return DaemonConfigResponse(
        type: 'set_daemon_config_response',
        requestId: request.requestId,
        config: configStore.config,
      ).toJson();
    }
    final providerResponse = await providerCatalogV2.handle(message);
    if (providerResponse != null) return providerResponse;
    final forgeActionResponse = await forgeActions.handle(message);
    if (forgeActionResponse != null) return forgeActionResponse;
    final checkoutStatusResponse = await checkoutStatus.handle(message);
    if (checkoutStatusResponse != null) return checkoutStatusResponse;
    if (message['type'] == SubscribeCheckoutDiffRequest.type) {
      return checkoutDiff.subscribe(connection, message);
    }
    if (message['type'] == UnsubscribeCheckoutDiffRequest.type) {
      checkoutDiff.unsubscribe(connection.id, message);
      return v2HandledNoResponse;
    }
    final prStatusResponse = await checkoutPrStatus.handle(message);
    if (prStatusResponse != null) return prStatusResponse;
    final checkoutRefreshResponse = await checkoutRefresh.handle(message);
    if (checkoutRefreshResponse != null) return checkoutRefreshResponse;
    final checkDetailsResponse = await forgeCheckDetails.handle(message);
    if (checkDetailsResponse != null) return checkDetailsResponse;
    final forgeResponse = await forgeSearch.handle(message);
    if (forgeResponse != null) return forgeResponse;
    final timelineResponse = await pullRequestTimeline.handle(message);
    return timelineResponse ??
        workspaceSetup.handle(message) ??
        workspaceV2.handle(connection, message);
  };
  server.onBinaryFrame = (connection, frame) =>
      terminals.handleFrame(connection.id, frame);
  server.onFileTransferFrame = fileTransfers.handleFrame;
  server.onConnectionClosed = (connection) {
    unawaited(voiceSessions.onConnectionClosed(connection));
    agentDirectorySubscriptions.remove(connection.id);
    terminals.onConnectionClosed(connection.id);
    terminalV2.onConnectionClosed(connection.id);
    workspaceV2.onConnectionClosed(connection.id);
    checkoutDiff.onConnectionClosed(connection.id);
    fileExplorer.onConnectionClosed(connection.id);
    fileTransfers.onConnectionClosed(connection.id);
  };

  RelayTransportController? relayTransport;
  var shuttingDown = false;
  Future<void> shutdown(String reason) async {
    if (shuttingDown) return;
    shuttingDown = true;
    log!('shutting down ($reason)');
    stopTerminalAgentHookSetting();
    stopConfigBroadcast();
    scriptHealth.stop();
    schedules.stop();
    chat.dispose();
    await loops.prepareForDaemonShutdown();
    stopSpeechReadiness();
    await voiceSessions.dispose();
    speechService?.stop();
    voiceBridge.clear();
    workspaceScripts.dispose();
    checkoutDiff.dispose();
    await workspaceGitObserverBackend.disposeAndWait();
    await manager.dispose();
    fileExplorer.close();
    await terminals.dispose();
    await hubRelationships.stop();
    await relayTransport?.stop();
    await serviceProxyStandalone?.stop();
    await server.stop();
    await lock.release();
    if (onShutdownRequested != null) {
      onShutdownRequested();
    }
  }

  router
    ..on(MessageTypes.daemonStatusRequest, (_, __) {
      return {
        'pid': pid,
        'version': daemonVersion,
        'uptimeMs': DateTime.now().difference(startedAt).inMilliseconds,
        'desktopManaged': desktopManaged,
      };
    })
    ..on(MessageTypes.daemonShutdownRequest, (connection, __) {
      if (!connection.isLoopback) {
        throw RpcException(
          RpcErrorCodes.unauthorized,
          'shutdown is only allowed from loopback connections',
        );
      }
      Timer(const Duration(milliseconds: 200), () {
        unawaited(shutdown('shutdown request'));
      });
      return const <String, Object?>{};
    });

  try {
    await server.start(host: host, port: port);
    final mcpHost = switch (host) {
      '0.0.0.0' || '::' => '127.0.0.1',
      _ => host,
    };
    agentMcpBaseUrl = agentMcpEnabled
        ? Uri(
            scheme: 'http',
            host: mcpHost,
            port: server.port,
            path: agentMcpPath,
          ).toString()
        : null;
    manager.configureRuntimeMcp(
      baseUrl: agentMcpBaseUrl,
      injectIntoAgents:
          injectMcpIntoAgents ?? configStore.config.injectMcpIntoAgents,
    );
    if (serviceProxyStandalone != null) {
      await serviceProxyStandalone.start(
        parseServiceProxyListenTarget(serviceProxyListen!),
      );
    }
  } catch (e) {
    log('failed to bind ws://$host:$port: $e');
    await serviceProxyStandalone?.stop();
    await server.stop();
    await lock.release();
    rethrow;
  }

  await lock.update(
    PidLockData(
      pid: pid,
      startedAtMs: startedAt.millisecondsSinceEpoch,
      host: host,
      port: server.port,
      version: daemonVersion,
      desktopManaged: desktopManaged,
    ),
  );
  lock.startHeartbeat();

  log('daemon listening on ws://$host:${server.port}');
  speechService?.start();
  scriptHealth.start();
  await schedules.start();
  await loops.initialize();
  await hubRelationships.start();

  if (effectiveRelay?.enabled ?? false) {
    relayTransport = RelayTransportController(
      server: server,
      relayEndpoint: effectiveRelay!.endpoint,
      relayUseTls: effectiveRelay.useTls,
      serverId: serverId,
      daemonKeyPair: daemonKeyPair.keyPair,
      log: log,
    );
    log('relay transport connecting to ${effectiveRelay.endpoint}');
  }

  return DaemonServerHandle(
    server: server,
    lock: lock,
    manager: manager,
    terminals: terminals,
    configStore: configStore,
    pairingOffer: pairingOffer,
    relayTransport: relayTransport,
    hubRelationships: hubRelationships,
    loops: loops,
    schedules: schedules,
    voiceBridge: voiceBridge,
    serviceProxyStandalone: serviceProxyStandalone,
    stop: () => shutdown('manual stop'),
  );
}

Map<String, Object?> _importAgentFailedStatus(String requestId, String error) =>
    {
      'type': 'status',
      'payload': {
        'status': 'agent_create_failed',
        'requestId': requestId,
        'error': error,
      },
    };

String _importAgentErrorMessage(Object error) => switch (error) {
  StateError(:final message) => '$message',
  FormatException(:final message) => '$message',
  _ => '$error',
};

Map<String, Object?>? _handlePaseoTimelineFetch(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  Map<String, Object?> message,
) {
  if (message['type'] != 'fetch_agent_timeline_request') return null;
  final requestId = _requireString(message, 'requestId');
  final agentId = _requireString(message, 'agentId');
  final rawCursor = message['cursor'];
  if (rawCursor != null && rawCursor is! Map) {
    throw const FormatException('cursor must be an object');
  }
  final cursor = rawCursor == null
      ? null
      : Map<String, Object?>.from(rawCursor as Map);
  final direction =
      (message['direction'] as String?) ?? (cursor == null ? 'tail' : 'after');
  if (!const {'tail', 'before', 'after'}.contains(direction)) {
    throw FormatException('Unknown timeline direction: $direction');
  }
  final projection = (message['projection'] as String?) ?? 'projected';
  if (!const {'projected', 'canonical'}.contains(projection)) {
    throw FormatException('Unknown timeline projection: $projection');
  }
  final rawLimit = message['limit'];
  if (rawLimit != null &&
      (rawLimit is! num ||
          rawLimit.toInt() != rawLimit ||
          rawLimit.toInt() < 0)) {
    throw const FormatException('limit must be a nonnegative integer');
  }
  final limit = (rawLimit as num?)?.toInt() ?? (direction == 'after' ? 0 : 200);

  try {
    final snapshot = manager.fetchCanonicalTimeline(agentId);
    final epoch = snapshot.epoch.toString();
    final rows = snapshot.rows
        .where((row) => row.item is! TurnItem && row.item is! PermissionItem)
        .toList(growable: false);
    final minSeq = rows.isEmpty ? 0 : rows.first.seq;
    final maxSeq = rows.isEmpty ? 0 : rows.last.seq;
    final cursorEpoch = cursor?['epoch'];
    final cursorSeqValue = cursor?['seq'];
    if (cursorEpoch != null && cursorEpoch is! String) {
      throw const FormatException('cursor.epoch must be a string');
    }
    if (cursorSeqValue != null &&
        (cursorSeqValue is! num ||
            cursorSeqValue.toInt() != cursorSeqValue ||
            cursorSeqValue.toInt() < 0)) {
      throw const FormatException('cursor.seq must be a nonnegative integer');
    }
    final cursorSeq = (cursorSeqValue as num?)?.toInt();
    final staleCursor = cursor != null && cursorEpoch != epoch;
    final gap =
        !staleCursor &&
        direction == 'after' &&
        cursorSeq != null &&
        rows.isNotEmpty &&
        cursorSeq < minSeq - 1;
    final providerDefinition = providerCatalog.definition(
      snapshot.agent.provider,
    );

    final reset = staleCursor || gap;
    late final List<TimelineProjectionEntry> selected;
    late final int? firstSeq;
    late final int? lastSeq;
    late final bool hasOlder;
    late final bool hasNewer;
    if (projection == 'projected') {
      final page = selectProjectedTimelinePage(
        rows: rows,
        direction: reset ? 'tail' : direction,
        cursorSeq: reset ? null : cursorSeq,
        limit: limit,
        boundMinSeq: rows.isEmpty ? null : minSeq,
        boundMaxSeq: rows.isEmpty ? null : maxSeq,
      );
      selected = page.entries;
      firstSeq = page.startSeq;
      lastSeq = page.endSeq;
      hasOlder = page.hasOlder;
      hasNewer = page.hasNewer;
    } else {
      final selectedRows = reset
          ? _tailTimelineRows(rows, limit)
          : _selectCanonicalTimelineRows(
              rows,
              direction: direction,
              cursorSeq: cursorSeq,
              lastSeq: snapshot.lastSeq,
              limit: limit,
            );
      selected = projectTimelineRows(selectedRows, projected: false);
      firstSeq = selectedRows.firstOrNull?.seq;
      lastSeq = selectedRows.lastOrNull?.seq;
      hasOlder = switch (direction) {
        'after' =>
          firstSeq != null ? firstSeq > minSeq : (cursorSeq ?? 0) >= minSeq,
        _ => firstSeq != null && firstSeq > minSeq,
      };
      hasNewer = switch (direction) {
        'tail' => false,
        'before' => rows.any(
          (row) => row.seq >= (cursorSeq ?? snapshot.lastSeq + 1),
        ),
        _ => lastSeq != null && lastSeq < maxSeq,
      };
    }

    return {
      'type': 'fetch_agent_timeline_response',
      'payload': {
        'requestId': requestId,
        'agentId': agentId,
        'agent': PaseoAgentSnapshotCodec.encode(
          snapshot.agent,
          pendingPermissions: snapshot.rows
              .map((row) => row.item)
              .whereType<PermissionItem>(),
          capabilities: providerDefinition?.capabilities,
          features: paseoProviderFeaturesFor(snapshot.agent),
          availableModes: providerDefinition == null
              ? null
              : [
                  for (final mode in providerDefinition.modes)
                    mode.mode.toJson(),
                ],
          currentModeId: providerDefinition == null
              ? snapshot.agent.currentModeId
              : _snapshotCurrentModeId(snapshot.agent, providerDefinition),
          providerUnavailable: providerDefinition == null,
        ),
        'direction': direction,
        'projection': projection,
        'epoch': epoch,
        'reset': reset,
        'staleCursor': staleCursor,
        'gap': gap,
        'window': {
          'minSeq': minSeq,
          'maxSeq': maxSeq,
          'nextSeq': snapshot.lastSeq + 1,
        },
        'startCursor': firstSeq == null
            ? null
            : {'epoch': epoch, 'seq': firstSeq},
        'endCursor': lastSeq == null ? null : {'epoch': epoch, 'seq': lastSeq},
        'hasOlder': hasOlder,
        'hasNewer': hasNewer,
        'entries': [
          for (final entry in selected)
            {
              'provider': snapshot.agent.provider,
              'item': PaseoTimelineCodec.encode(entry.item),
              'timestamp': entry.timestamp,
              'seqStart': entry.seqStart,
              'seqEnd': entry.seqEnd,
              'sourceSeqRanges': [
                for (final range in entry.sourceSeqRanges) range.toJson(),
              ],
              'collapsed': [for (final kind in entry.collapsed) kind.wire],
            },
        ],
        'error': null,
      },
    };
  } catch (error) {
    return {
      'type': 'fetch_agent_timeline_response',
      'payload': {
        'requestId': requestId,
        'agentId': agentId,
        'agent': null,
        'direction': direction,
        'projection': projection,
        'epoch': '',
        'reset': false,
        'staleCursor': false,
        'gap': false,
        'window': const {'minSeq': 0, 'maxSeq': 0, 'nextSeq': 0},
        'startCursor': null,
        'endCursor': null,
        'hasOlder': false,
        'hasNewer': false,
        'entries': const <Object?>[],
        'error': error.toString(),
      },
    };
  }
}

Future<Map<String, Object?>?> _handlePaseoFetchAgent(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  WorkspaceRegistries registries,
  Connection connection,
  Map<String, Object?> message,
) async {
  if (message['type'] != FetchAgentRequest.type) return null;
  final request = FetchAgentRequest.fromJson(message);
  try {
    final agent = manager.resolveIdentifier(request.agentId);
    if (!isProviderVisibleToClient(agent.provider, connection.appVersion)) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent not found: ${agent.agentId}',
      );
    }
    final timeline = manager.fetchCanonicalTimeline(agent.agentId);
    final snapshot = timeline.agent.copyWith(
      providerUnavailable: !manager.isProviderAvailable(agent.provider),
    );
    final providerDefinition = providerCatalog.definition(agent.provider);
    return {
      'type': FetchAgentResponse.type,
      'payload': {
        'requestId': request.requestId,
        'agent': PaseoAgentSnapshotCodec.encode(
          snapshot,
          pendingPermissions: timeline.rows
              .map((row) => row.item)
              .whereType<PermissionItem>(),
          capabilities: providerDefinition?.capabilities,
          features: paseoProviderFeaturesFor(snapshot),
          availableModes: providerDefinition == null
              ? null
              : [
                  for (final mode in providerDefinition.modes)
                    mode.mode.toJson(),
                ],
          currentModeId: providerDefinition == null
              ? snapshot.currentModeId
              : _snapshotCurrentModeId(snapshot, providerDefinition),
          providerUnavailable: providerDefinition == null,
        ),
        'project': await buildAgentProjectPlacement(snapshot, registries),
        'error': null,
      },
    };
  } on RpcException catch (error) {
    return FetchAgentResponse(
      requestId: request.requestId,
      agent: null,
      project: null,
      error: error.error.message,
    ).toJson();
  }
}

Future<Map<String, Object?>?> _handlePaseoCancelAgent(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  Map<String, Object?> message,
) async {
  final request = CancelAgentRequest.fromJson(message);
  try {
    await manager.cancelAgentRun(request.agentId);
    if (request.requestId == null) return null;
    return CancelAgentResponse(
      requestId: request.requestId!,
      agentId: request.agentId,
      agent: _paseoAgentSnapshot(manager, providerCatalog, request.agentId),
      error: null,
    ).toJson();
  } on Object catch (error) {
    if (request.requestId == null) return null;
    return CancelAgentResponse(
      requestId: request.requestId!,
      agentId: request.agentId,
      agent: _paseoAgentSnapshotOrNull(
        manager,
        providerCatalog,
        request.agentId,
      ),
      error: _cancelAgentError(error),
    ).toJson();
  }
}

Map<String, Object?> _paseoAgentSnapshot(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  String agentId,
) {
  final timeline = manager.fetchCanonicalTimeline(agentId);
  final agent = timeline.agent.copyWith(
    providerUnavailable: !manager.isProviderAvailable(timeline.agent.provider),
  );
  final providerDefinition = providerCatalog.definition(agent.provider);
  return PaseoAgentSnapshotCodec.encode(
    agent,
    pendingPermissions: timeline.rows
        .map((row) => row.item)
        .whereType<PermissionItem>(),
    capabilities: providerDefinition?.capabilities,
    features: paseoProviderFeaturesFor(agent),
    availableModes: providerDefinition == null
        ? null
        : [for (final mode in providerDefinition.modes) mode.mode.toJson()],
    currentModeId: providerDefinition == null
        ? agent.currentModeId
        : _snapshotCurrentModeId(agent, providerDefinition),
    providerUnavailable: providerDefinition == null,
  );
}

Map<String, Object?>? _paseoAgentSnapshotOrNull(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  String agentId,
) {
  try {
    return _paseoAgentSnapshot(manager, providerCatalog, agentId);
  } on Object {
    return null;
  }
}

String _cancelAgentError(Object error) => switch (error) {
  RpcException(:final error) => error.message,
  ArgumentError(message: final message) => '$message',
  UnsupportedError(message: final message) => message ?? '',
  _ => '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), ''),
};

Future<Map<String, Object?>> _handlePaseoSendAgentMessage(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  Connection connection,
  Map<String, Object?> message,
) async {
  final request = SendAgentMessageRequest.fromJson(message);
  String responseAgentId = request.agentId;
  try {
    final resolved = manager.resolveIdentifier(request.agentId);
    if (!isProviderVisibleToClient(resolved.provider, connection.appVersion)) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent not found: ${request.agentId}',
      );
    }
    responseAgentId = resolved.agentId;
    if (resolved.archivedAt != null) {
      await manager.unarchive(resolved.agentId);
    }
    if (!manager.hasClientMessageId(resolved.agentId, request.messageId)) {
      if (manager.hasActiveAgentRun(resolved.agentId)) {
        await manager.cancelAgentRun(resolved.agentId);
      }
      await manager.prompt(
        resolved.agentId,
        request.text,
        images: request.images,
        attachments: request.attachments,
        clientMessageId: request.messageId,
      );
    }
    final current = manager.get(resolved.agentId, includeArchived: false);
    final rejected = current == null || current.runState == AgentRunState.error;
    return SendAgentMessageResponse(
      requestId: request.requestId,
      agentId: resolved.agentId,
      accepted: !rejected,
      error: rejected
          ? (current?.lastError?.trim().isNotEmpty == true
                ? current!.lastError
                : 'Agent failed to start')
          : null,
    ).toJson();
  } on Object catch (error) {
    return SendAgentMessageResponse(
      requestId: request.requestId,
      agentId: responseAgentId,
      accepted: false,
      error: _cancelAgentError(error),
    ).toJson();
  }
}

Future<Map<String, Object?>> _handlePaseoWaitForFinish(
  AgentManager manager,
  PaseoProviderCatalogRegistry providerCatalog,
  Connection connection,
  Map<String, Object?> message,
) async {
  final request = WaitForFinishRequest.fromJson(message);
  String? agentId;
  try {
    final resolved = manager.resolveIdentifier(request.agentId);
    if (!isProviderVisibleToClient(resolved.provider, connection.appVersion)) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent not found: ${request.agentId}',
      );
    }
    agentId = resolved.agentId;
    final result = await manager.waitForAgentEvent(
      resolved.agentId,
      waitForActive: true,
      timeout: request.timeoutMs == null
          ? null
          : Duration(milliseconds: request.timeoutMs!),
    );
    final status = result.permission != null
        ? WaitForFinishStatus.permission
        : result.summary.runState == AgentRunState.error
        ? WaitForFinishStatus.error
        : WaitForFinishStatus.idle;
    return WaitForFinishResponse(
      requestId: request.requestId,
      status: status,
      finalAgent: _paseoAgentSnapshot(
        manager,
        providerCatalog,
        resolved.agentId,
      ),
      error: status == WaitForFinishStatus.error
          ? _waitForFinishError(result.summary)
          : null,
      lastMessage: result.lastMessage,
    ).toJson();
  } on TimeoutException {
    return WaitForFinishResponse(
      requestId: request.requestId,
      status: WaitForFinishStatus.timeout,
      finalAgent: agentId == null
          ? null
          : _paseoAgentSnapshotOrNull(manager, providerCatalog, agentId),
      error: null,
      lastMessage: null,
    ).toJson();
  } on Object catch (error) {
    return WaitForFinishResponse(
      requestId: request.requestId,
      status: WaitForFinishStatus.error,
      finalAgent: agentId == null
          ? null
          : _paseoAgentSnapshotOrNull(manager, providerCatalog, agentId),
      error: _cancelAgentError(error),
      lastMessage: null,
    ).toJson();
  }
}

String _waitForFinishError(AgentSummary summary) {
  final message = summary.lastError?.trim();
  return message == null || message.isEmpty ? 'Agent failed' : message;
}

Future<Object?> _handlePaseoFetchAgents(
  AgentManager manager,
  WorkspaceRegistries registries,
  Connection connection,
  Map<String, Object?> message,
  Map<String, AgentDirectorySubscription> subscriptions,
  WsServer server,
) async {
  final isHistory = message['type'] == FetchAgentHistoryRequest.type;
  if (!isHistory && message['type'] != FetchAgentsRequest.type) return null;
  final activeRequest = isHistory ? null : FetchAgentsRequest.fromJson(message);
  final historyRequest = isHistory
      ? FetchAgentHistoryRequest.fromJson(message)
      : null;
  final requestId = activeRequest?.requestId ?? historyRequest!.requestId;
  final requestedFilter = activeRequest?.filter ?? historyRequest?.filter;
  final filter = isHistory && requestedFilter?.includeArchived == null
      ? _copyAgentDirectoryFilter(requestedFilter, includeArchived: true)
      : requestedFilter;
  final requestedSort = activeRequest?.sort ?? historyRequest!.sort;
  final sort = normalizeAgentDirectorySort(requestedSort);
  final limit = activeRequest?.limit ?? historyRequest?.limit ?? 200;
  final cursor = activeRequest?.cursor ?? historyRequest?.cursor;
  final hasSubscription = activeRequest?.hasSubscription ?? false;
  final requestedSubscriptionId = activeRequest?.subscriptionId;
  final subscriptionId = hasSubscription
      ? (requestedSubscriptionId?.trim().isNotEmpty == true
            ? requestedSubscriptionId!.trim()
            : const Uuid().v4())
      : null;
  if (subscriptionId != null) {
    subscriptions[connection.id] = AgentDirectorySubscription(
      subscriptionId: subscriptionId,
      filter: filter,
    );
  }

  final entries = <AgentDirectoryEntry>[];
  for (final agent in manager.list(
    includeArchived:
        isHistory ||
        (!activeRequest!.activeScope && filter?.includeArchived == true),
  )) {
    if (!isProviderVisibleToClient(agent.provider, connection.appVersion)) {
      continue;
    }
    final snapshot = agent.copyWith(
      providerUnavailable: !manager.isProviderAvailable(agent.provider),
    );
    final project = await buildAgentProjectPlacement(
      snapshot,
      registries,
      activeOnly: activeRequest?.activeScope ?? false,
    );
    if (project != null) {
      entries.add(
        AgentDirectoryEntry(
          agent: snapshot,
          project: project,
          pendingPermissions: _pendingPermissionPayloads(manager, snapshot),
        ),
      );
    }
  }
  entries.removeWhere((entry) => !_matchesAgentDirectoryFilter(entry, filter));
  entries.sort(
    (left, right) =>
        compareAgentDirectoryEntries(left.agent, right.agent, sort),
  );

  if (cursor != null) {
    try {
      final decoded = decodeAgentDirectoryCursor(cursor, sort);
      entries.removeWhere(
        (entry) =>
            compareAgentDirectoryEntryWithCursor(entry.agent, decoded, sort) <=
            0,
      );
    } on AgentDirectoryCursorException catch (error) {
      if (subscriptionId != null &&
          subscriptions[connection.id]?.subscriptionId == subscriptionId) {
        subscriptions.remove(connection.id);
      }
      return {
        'type': 'rpc_error',
        'payload': {
          'requestId': requestId,
          'requestType': message['type'],
          'error': error.message,
          'code': 'invalid_cursor',
        },
      };
    }
  }

  final hasMore = entries.length > limit;
  final pageEntries = entries.take(limit).toList(growable: false);
  final pageInfo = AgentDirectoryPageInfo(
    nextCursor: hasMore && pageEntries.isNotEmpty
        ? encodeAgentDirectoryCursor(pageEntries.last.agent, sort)
        : null,
    prevCursor: cursor,
    hasMore: hasMore,
  );
  if (isHistory) {
    return FetchAgentHistoryResponse(
      requestId: requestId,
      entries: pageEntries,
      pageInfo: pageInfo,
    ).toJson();
  }

  final response = FetchAgentsResponse(
    requestId: requestId,
    subscriptionId: subscriptionId,
    entries: pageEntries,
    pageInfo: pageInfo,
  ).toJson();
  if (subscriptionId == null) return response;

  final snapshotUpdatedAtByAgentId = <String, int>{
    for (final entry in pageEntries)
      if (DateTime.tryParse(entry.agent.updatedAt ?? '') case final updatedAt?)
        entry.agent.agentId: updatedAt.millisecondsSinceEpoch,
  };
  return V2SessionResponse(
    message: response,
    afterSend: () {
      final subscription = subscriptions[connection.id];
      if (subscription?.subscriptionId != subscriptionId) return;
      subscription!.flush(
        snapshotUpdatedAtByAgentId: snapshotUpdatedAtByAgentId,
        emit: (update) =>
            _emitAgentDirectoryUpdate(server, connection.id, update),
      );
    },
  );
}

List<Map<String, Object?>> _pendingPermissionPayloads(
  AgentManager manager,
  AgentSummary agent,
) {
  final timeline = manager.fetchCanonicalTimeline(agent.agentId);
  return PaseoAgentSnapshotCodec.encodePendingPermissions(
    agent,
    timeline.rows.map((row) => row.item).whereType<PermissionItem>(),
  );
}

AgentDirectoryFilter _copyAgentDirectoryFilter(
  AgentDirectoryFilter? filter, {
  required bool includeArchived,
}) => AgentDirectoryFilter(
  labels: filter?.labels ?? const {},
  projectKeys: filter?.projectKeys ?? const [],
  statuses: filter?.statuses ?? const [],
  includeArchived: includeArchived,
  requiresAttention: filter?.requiresAttention,
  thinkingOptionId: filter?.thinkingOptionId,
  hasThinkingOptionId: filter?.hasThinkingOptionId ?? false,
);

bool _matchesAgentDirectoryFilter(
  AgentDirectoryEntry entry,
  AgentDirectoryFilter? filter,
) {
  if (filter == null) return true;
  final agent = entry.agent;
  for (final label in filter.labels.entries) {
    if (agent.labels[label.key] != label.value) return false;
  }
  final projectKeys = {
    for (final key in filter.projectKeys)
      if (key.trim().isNotEmpty) key,
  };
  if (projectKeys.isNotEmpty &&
      !projectKeys.contains(entry.project['projectKey'])) {
    return false;
  }
  if (filter.includeArchived != true && agent.archivedAt != null) return false;
  if (filter.statuses.isNotEmpty) {
    final status = PaseoAgentSnapshotCodec.encode(agent)['status'];
    if (!filter.statuses.contains(status)) return false;
  }
  if (filter.requiresAttention != null &&
      agent.requiresAttention != filter.requiresAttention) {
    return false;
  }
  if (filter.hasThinkingOptionId &&
      agent.thinkingOptionId != filter.thinkingOptionId) {
    return false;
  }
  return true;
}

void _emitAgentDirectoryUpdate(
  WsServer server,
  String connectionId,
  AgentDirectoryUpdate update,
) {
  server.broadcastV2(
    {
      'type': 'agent_update',
      'payload': switch (update) {
        AgentDirectoryUpsert(:final agent, :final project) => {
          'kind': 'upsert',
          'agent': PaseoAgentSnapshotCodec.encode(agent),
          'project': project,
        },
        AgentDirectoryRemove(:final agentId) => {
          'kind': 'remove',
          'agentId': agentId,
        },
      },
    },
    connectionIds: {connectionId},
  );
}

String? _snapshotCurrentModeId(
  AgentSummary agent,
  PaseoProviderDefinition provider,
) {
  if (agent.currentModeId != null) return agent.currentModeId;
  final preferred = switch (agent.mode) {
    AgentMode.plan => const [
      'plan',
      'https://agentclientprotocol.com/protocol/session-modes#plan',
    ],
    AgentMode.fullAccess => const [
      'full-access',
      'bypassPermissions',
      'allow-all',
      'full',
    ],
    AgentMode.normal => [
      if (provider.defaultModeId != null) provider.defaultModeId!,
      'default',
      'auto',
      'build',
      'write',
      'ask',
    ],
  };
  final available = {for (final mode in provider.modes) mode.mode.id};
  for (final modeId in preferred) {
    if (available.contains(modeId)) return modeId;
  }
  return provider.defaultModeId;
}

List<TimelineRow> _tailTimelineRows(List<TimelineRow> rows, int limit) {
  if (limit == 0 || limit >= rows.length) return List.of(rows);
  return rows.skip(rows.length - limit).toList();
}

List<TimelineRow> _selectCanonicalTimelineRows(
  List<TimelineRow> rows, {
  required String direction,
  required int? cursorSeq,
  required int lastSeq,
  required int limit,
}) {
  var selected = switch (direction) {
    'after' => rows.where((row) => row.seq > (cursorSeq ?? 0)).toList(),
    'before' =>
      rows.where((row) => row.seq < (cursorSeq ?? lastSeq + 1)).toList(),
    _ => List.of(rows),
  };
  if (limit > 0 && selected.length > limit) {
    selected = direction == 'after'
        ? selected.take(limit).toList()
        : selected.skip(selected.length - limit).toList();
  }
  return selected;
}

/// Sends the attention event to every v2 client while selecting at most one
/// in-app notification recipient. Returns whether the later Hub layer should
/// send push because no client is present.
bool broadcastAgentAttention({
  required WsServer server,
  required String agentId,
  required AgentAttentionReason reason,
  required String timestamp,
  int? nowMs,
}) {
  final connections = server.authenticatedV2Connections;
  final plan = computeNotificationPlan(
    allStates: [
      for (final connection in connections) connection.clientPresence,
    ],
    focusTarget: AttentionFocusTarget.agent(agentId),
    pushEligible: isPushEligibleAttentionReason(reason),
    nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  for (var index = 0; index < connections.length; index++) {
    server.broadcastV2(
      {
        'type': 'agent_attention_required',
        'payload': {
          'agentId': agentId,
          'reason': reason.name,
          'timestamp': timestamp,
          'shouldNotify': index == plan.inAppRecipientIndex,
        },
      },
      connectionIds: {connections[index].id},
    );
  }
  return plan.shouldPush;
}

/// Broadcasts the normalized terminal attention edge and returns whether the
/// later Hub layer should send push because no connected client is present.
bool broadcastTerminalAttention({
  required WsServer server,
  required TerminalActivityTransition transition,
  int? nowMs,
}) {
  final reason = transition.activity?.attentionReason;
  if (reason == null) return false;
  final connections = server.authenticatedV2Connections;
  final plan = computeNotificationPlan(
    allStates: [
      for (final connection in connections) connection.clientPresence,
    ],
    focusTarget: AttentionFocusTarget.terminal(transition.terminalId),
    pushEligible: true,
    nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  final title = reason == TerminalActivityAttentionReason.needsInput
      ? 'Terminal needs input'
      : 'Terminal finished';
  for (var index = 0; index < connections.length; index++) {
    server.broadcastV2(
      TerminalAttentionRequired(
        serverId: server.serverId,
        terminalId: transition.terminalId,
        cwd: transition.cwd,
        workspaceId: transition.workspaceId,
        reason: reason,
        title: title,
        body: transition.terminalName,
        shouldNotify: index == plan.inAppRecipientIndex,
      ).toJson(),
      connectionIds: {connections[index].id},
    );
  }
  return plan.shouldPush;
}

final class _DaemonVoiceSessionHost implements VoiceSessionHost {
  const _DaemonVoiceSessionHost({
    required this.manager,
    required this.connection,
  });

  final AgentManager manager;
  final Connection connection;

  @override
  void emit(Map<String, Object?> message) {
    connection.sendJson({'type': 'session', 'message': message});
  }

  @override
  Future<VoiceSessionAgent> loadAgent(String agentId) async {
    await manager.ensureLoaded(agentId);
    final agent = manager.get(agentId, includeArchived: false);
    if (agent == null) throw StateError('Agent not found: $agentId');
    return VoiceSessionAgent(
      id: agent.agentId,
      systemPrompt: agent.systemPrompt,
    );
  }

  @override
  Future<VoiceSessionAgent> reloadAgentSession(
    String agentId,
    VoiceSessionAgentOverrides overrides,
  ) async {
    final agent = await manager.reloadAgentSession(
      agentId,
      systemPrompt: overrides.systemPrompt,
    );
    return VoiceSessionAgent(
      id: agent.agentId,
      systemPrompt: agent.systemPrompt,
    );
  }

  @override
  Future<void> sendSpokenInput(String agentId, String text) =>
      manager.prompt(agentId, text);

  @override
  Future<void> interruptAgentIfRunning(String agentId) async {
    if (manager.hasActiveAgentRun(agentId)) {
      await manager.interrupt(agentId);
    }
  }

  @override
  bool hasActiveAgentRun(String? agentId) => manager.hasActiveAgentRun(agentId);
}

AgentMode _parseMode(Object? raw) {
  final name = (raw as String?) ?? 'normal';
  try {
    return AgentMode.values.byName(name);
  } catch (_) {
    throw RpcException(RpcErrorCodes.invalidPayload, 'unknown mode "$name"');
  }
}

void _recordClientHeartbeat(
  Connection connection,
  Map<String, Object?> message,
) {
  final deviceType = message['deviceType'];
  if (deviceType != 'web' && deviceType != 'mobile') {
    throw const FormatException('deviceType must be web or mobile');
  }
  if (!message.containsKey('focusedAgentId') ||
      (message['focusedAgentId'] != null &&
          message['focusedAgentId'] is! String)) {
    throw const FormatException('focusedAgentId must be a string or null');
  }
  final focusedTerminalId = message['focusedTerminalId'];
  if (focusedTerminalId != null && focusedTerminalId is! String) {
    throw const FormatException('focusedTerminalId must be a string or null');
  }
  final lastActivityAt = message['lastActivityAt'];
  final parsedActivity = lastActivityAt is String
      ? DateTime.tryParse(lastActivityAt)
      : null;
  if (parsedActivity == null) {
    throw const FormatException('lastActivityAt must be an ISO timestamp');
  }
  final appVisible = message['appVisible'];
  if (appVisible is! bool) {
    throw const FormatException('appVisible must be a boolean');
  }
  final visibilityChangedAt = message['appVisibilityChangedAt'];
  if (visibilityChangedAt != null &&
      (visibilityChangedAt is! String ||
          DateTime.tryParse(visibilityChangedAt) == null)) {
    throw const FormatException(
      'appVisibilityChangedAt must be an ISO timestamp',
    );
  }
  final terminalId = (focusedTerminalId as String?)?.trim();
  connection.clientPresence = ClientPresenceState(
    appVisible: appVisible,
    lastActivityAtMs: parsedActivity.millisecondsSinceEpoch,
    focusedAgentId: message['focusedAgentId'] as String?,
    focusedTerminalId: terminalId?.isEmpty == true ? null : terminalId,
  );
}

ProviderId _parseProviderId(Object? raw) {
  final name = raw as String?;
  if (name == null || name.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, 'providerId is required');
  }
  try {
    return ProviderId.fromWire(name);
  } catch (_) {
    throw RpcException(
      RpcErrorCodes.invalidPayload,
      'unknown providerId "$name"',
    );
  }
}

Future<Map<String, Object?>> _disconnectHub(
  HubRelationshipController relationships,
  HubManagementDaemonDisconnectRequest request,
) async {
  final result = await relationships.disconnect(force: request.force);
  return HubManagementDaemonDisconnectResponse(
    requestId: request.requestId,
    status: result.status,
    warning: result.warning,
  ).toJson();
}

String _requireString(Map<String, Object?> payload, String key) {
  final value = payload[key] as String?;
  if (value == null || value.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, '$key is required');
  }
  return value;
}
