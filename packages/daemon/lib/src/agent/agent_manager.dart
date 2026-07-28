/// Owns all agent runtimes: lifecycle, provider sessions, timeline updates,
/// run-state transitions, persistence, and broadcast fan-out.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../permission/permission_broker.dart';
import '../providers/agent_client.dart';
import '../providers/agent_session.dart';
import '../providers/provider_event.dart';
import '../server/rpc_router.dart';
import '../utils/path_identity.dart';
import 'agent_store.dart';
import 'create_agent_title.dart';
import 'provider_subagent_store.dart';
import 'runtime_mcp_config.dart';
import 'system_prompt.dart';
import 'timeline_store.dart';

typedef PermissionRequestedBroadcast =
    void Function(
      String agentId,
      String permissionId,
      String toolName,
      ToolCallDetail detail,
    );
typedef PermissionResolvedBroadcast =
    void Function(String permissionId, PermissionDecision decision);
typedef AgentAttentionBroadcast =
    void Function(
      String agentId,
      AgentAttentionReason reason,
      String timestamp,
    );
typedef AgentStreamSubscriber = void Function(AgentStreamPayload payload);
typedef AgentClientResolver = AgentClient? Function(String provider);
typedef AgentProviderIdsResolver = Iterable<String> Function();

final class _AgentStreamSubscription {
  const _AgentStreamSubscription({required this.subscriber, this.agentId});

  final AgentStreamSubscriber subscriber;
  final String? agentId;
}

final class AgentRuntime {
  AgentRuntime({
    required this.summary,
    required this.timeline,
    this.archived = false,
    this.internal = false,
    this.mcpServers = const {},
  });

  AgentSummary summary;
  TimelineStore timeline;
  bool archived;
  final bool internal;
  final Map<String, Object?> mcpServers;

  AgentSession? session;
  StreamSubscription<ProviderEvent>? sessionSub;

  /// id of the open TurnItem, if a turn is in flight.
  String? currentTurnId;
  bool interruptRequested = false;

  /// Accumulated streaming text per timeline item id.
  final Map<String, StringBuffer> textBuffers = {};
}

final class AgentRunOutcome {
  const AgentRunOutcome({
    required this.summary,
    required this.output,
    required this.timeline,
  });

  final AgentSummary summary;
  final String? output;
  final List<TimelineItem> timeline;
}

final class AgentWaitResult {
  const AgentWaitResult({
    required this.summary,
    this.lastMessage,
    this.permission,
  });

  final AgentSummary summary;
  final String? lastMessage;
  final PermissionItem? permission;
}

final class ManagedImportableProviderSession {
  const ManagedImportableProviderSession({
    required this.provider,
    required this.session,
  });

  final String provider;
  final ImportableProviderSession session;
}

final class ImportedProviderSession {
  const ImportedProviderSession({
    required this.summary,
    required this.timelineSize,
    required this.reactivated,
  });

  final AgentSummary summary;
  final int timelineSize;
  final bool reactivated;
}

class AgentManager {
  AgentManager({
    required Map<String, AgentClient> clients,
    required AgentStore store,
    AgentClientResolver? clientResolver,
    AgentProviderIdsResolver? providerIdsResolver,
    PermissionBroker? broker,
    this.onStream,
    this.onState,
    this.onPermissionRequested,
    this.onPermissionResolved,
    this.onAttention,
    String? mcpBaseUrl,
    String? mcpAuthToken,
    bool injectMcpIntoAgents = false,
    String? appendSystemPrompt,
    void Function(ProviderSubagentUpdate update)? onProviderSubagentUpdate,
  }) : _clients = clients,
       _clientResolver = clientResolver,
       _providerIdsResolver = providerIdsResolver,
       _store = store,
       _mcpBaseUrl = mcpBaseUrl,
       _mcpAuthToken = mcpAuthToken,
       _injectMcpIntoAgents = injectMcpIntoAgents,
       _appendSystemPrompt = appendSystemPrompt ?? '',
       broker = broker ?? PermissionBroker(),
       providerSubagents = ProviderSubagentStore(
         onUpdate: onProviderSubagentUpdate,
       );

  final Map<String, AgentClient> _clients;
  final AgentClientResolver? _clientResolver;
  final AgentProviderIdsResolver? _providerIdsResolver;
  final AgentStore _store;
  final PermissionBroker broker;
  final ProviderSubagentStore providerSubagents;
  final _uuid = const Uuid();

  void Function(AgentStreamPayload payload)? onStream;
  void Function(AgentStatePayload payload)? onState;
  PermissionRequestedBroadcast? onPermissionRequested;
  PermissionResolvedBroadcast? onPermissionResolved;
  AgentAttentionBroadcast? onAttention;

  final Map<String, AgentRuntime> _runtimes = {};
  final Set<_AgentStreamSubscription> _streamSubscribers = {};
  final Map<String, List<Completer<void>>> _stateWaiters = {};
  final Map<String, Future<void>> _providerSessionImportMutations = {};
  String? _mcpBaseUrl;
  final String? _mcpAuthToken;
  bool _injectMcpIntoAgents;
  String _appendSystemPrompt;

  void configureRuntimeMcp({
    required String? baseUrl,
    required bool injectIntoAgents,
  }) {
    _mcpBaseUrl = baseUrl;
    _injectMcpIntoAgents = injectIntoAgents;
  }

  void setAppendSystemPrompt(String? prompt) {
    _appendSystemPrompt = prompt ?? '';
  }

  void Function() subscribeStream(
    AgentStreamSubscriber subscriber, {
    String? agentId,
  }) {
    final subscription = _AgentStreamSubscription(
      subscriber: subscriber,
      agentId: agentId,
    );
    _streamSubscribers.add(subscription);
    return () => _streamSubscribers.remove(subscription);
  }

  String? get mcpAuthToken => _mcpAuthToken;

  /// Restore persisted agents (sessions are recreated lazily on next prompt).
  Future<void> load() async {
    for (final record in await _store.loadAll()) {
      final runtime = AgentRuntime(
        // A restored agent has no live session; coerce transient states.
        summary: record.summary.copyWith(
          runState: record.archived ? AgentRunState.closed : AgentRunState.idle,
        ),
        timeline: TimelineStore(
          agentId: record.summary.agentId,
          epoch: record.epoch,
          items: record.items,
          rows: record.rows,
          lastSeq: record.lastSeq,
        ),
        archived: record.archived,
        internal: record.internal,
        mcpServers: stripInternalAgentMcpServers(record.mcpServers),
      );
      runtime.timeline.onItem = _onTimelineItem;
      _runtimes[record.summary.agentId] = runtime;
    }
  }

  List<AgentSummary> list({bool includeArchived = false}) => [
    for (final r in _runtimes.values)
      if (!r.internal && (!r.archived || includeArchived)) r.summary,
  ];

  bool isProviderAvailable(String provider) => _clientFor(provider) != null;

  Future<List<AgentSlashCommand>> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
  }) async {
    final runtime = _runtimes[agentId];
    if (runtime != null && !runtime.archived) {
      if (runtime.session == null) await _startSession(runtime);
      final session = runtime.session;
      if (session is CommandListingAgentSession) {
        return session.listCommands();
      }
      throw UnsupportedError('Agent does not support listing commands');
    }

    if (draftConfig == null) {
      throw StateError('Agent not found: $agentId');
    }
    final model = draftConfig.model?.trim();
    if (model == null || model.isEmpty) return const [];
    final client = _clientFor(draftConfig.provider);
    if (client == null) {
      throw StateError(
        "Provider '${draftConfig.provider}' is not available. "
        'Please ensure the CLI is installed.',
      );
    }
    if (client is DraftCommandListingAgentClient) {
      return client.listCommands(draftConfig);
    }

    final session = await client.createSession(
      cwd: draftConfig.cwd,
      model: model,
      mode: AgentMode.normal,
      modeId: draftConfig.modeId,
      thinkingOptionId: draftConfig.thinkingOptionId,
      featureValues: draftConfig.featureValues ?? const {},
    );
    try {
      if (session is! CommandListingAgentSession) {
        throw UnsupportedError(
          "Provider '${draftConfig.provider}' does not support listing commands",
        );
      }
      return session.listCommands();
    } finally {
      await session.dispose();
    }
  }

  Future<List<AgentFeature>> listFeatures(
    ListCommandsDraftConfig draftConfig,
  ) async {
    final model = draftConfig.model?.trim();
    if (model == null || model.isEmpty) return const [];
    final client = _clientFor(draftConfig.provider);
    if (client == null) {
      throw StateError(
        "Provider '${draftConfig.provider}' is not available. "
        'Please ensure the CLI is installed.',
      );
    }
    if (client is DraftFeatureListingAgentClient) {
      return client.listFeatures(draftConfig);
    }

    final session = await client.createSession(
      cwd: draftConfig.cwd,
      model: model,
      mode: AgentMode.normal,
      modeId: draftConfig.modeId,
      thinkingOptionId: draftConfig.thinkingOptionId,
      featureValues: draftConfig.featureValues ?? const {},
    );
    try {
      return session is FeatureListingAgentSession
          ? session.features
          : const [];
    } finally {
      await session.dispose();
    }
  }

  Future<List<ManagedImportableProviderSession>> listImportableSessions({
    int? limit,
    Set<String>? providerFilter,
    String? cwd,
  }) async {
    final results = <ManagedImportableProviderSession>[];
    for (final provider in _providerIds) {
      if (providerFilter != null && !providerFilter.contains(provider)) {
        continue;
      }
      final client = _clientFor(provider);
      if (client is! ImportableAgentClient) continue;
      final importableClient = client as ImportableAgentClient;
      try {
        final sessions = await importableClient.listImportableSessions(
          ListImportableSessionsOptions(limit: limit, cwd: cwd),
        );
        results.addAll(
          sessions.map(
            (session) => ManagedImportableProviderSession(
              provider: provider,
              session: session,
            ),
          ),
        );
      } on Object {
        // Paseo isolates provider discovery failures so one missing/broken
        // executable does not make the aggregate recent-sessions RPC fail.
      }
    }
    return results;
  }

  /// Imports or reactivates one provider-native session using the frozen
  /// Paseo 0.2.0 identity and duplicate rules.
  Future<ImportedProviderSession> importProviderSession({
    required String provider,
    required String providerHandleId,
    required String cwd,
    required String workspaceId,
    Map<String, String> labels = const {},
  }) {
    final key = '$provider\u0000$providerHandleId';
    return _serializeProviderSessionImport(
      key,
      () => _importProviderSessionNow(
        provider: provider,
        providerHandleId: providerHandleId,
        cwd: cwd,
        workspaceId: workspaceId,
        labels: labels,
      ),
    );
  }

  Future<T> _serializeProviderSessionImport<T>(
    String key,
    Future<T> Function() operation,
  ) async {
    final previous = _providerSessionImportMutations[key];
    final gate = Completer<void>();
    final current = gate.future;
    _providerSessionImportMutations[key] = current;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // A failed predecessor must not poison the serialized mutation lane.
      }
    }
    try {
      return await operation();
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_providerSessionImportMutations[key], current)) {
        _providerSessionImportMutations.remove(key);
      }
    }
  }

  Future<ImportedProviderSession> _importProviderSessionNow({
    required String provider,
    required String providerHandleId,
    required String cwd,
    required String workspaceId,
    required Map<String, String> labels,
  }) async {
    if (_clientFor(provider) == null) {
      throw StateError('unsupported provider "$provider"');
    }
    final matches = [
      for (final runtime in _runtimes.values)
        if (!runtime.internal &&
            runtime.summary.provider == provider &&
            runtime.summary.sessionId == providerHandleId)
          runtime,
    ];
    final active = matches.where((runtime) => !runtime.archived).firstOrNull;
    if (active != null) {
      throw StateError(
        'Provider session is already imported: $providerHandleId',
      );
    }
    final archived = matches.where((runtime) => runtime.archived).firstOrNull;
    if (archived != null) {
      if (!realpathAwarePathMatcher(cwd)(archived.summary.cwd)) {
        throw StateError(
          'Provider session cwd does not match import cwd: $providerHandleId',
        );
      }
      return _reactivateImportedProviderSession(
        archived,
        workspaceId: workspaceId,
        labels: labels,
      );
    }

    final agentId = _uuid.v4();
    final createdAt = DateTime.now().toUtc();
    final runtime = AgentRuntime(
      summary: AgentSummary(
        agentId: agentId,
        title: 'Agent',
        cwd: cwd,
        provider: provider,
        model: '',
        mode: AgentMode.normal,
        runState: AgentRunState.initializing,
        createdAtMs: createdAt.millisecondsSinceEpoch,
        updatedAt: createdAt.toIso8601String(),
        sessionId: providerHandleId,
        workspaceId: workspaceId,
        parentAgentId: parentAgentIdFromLabels(labels),
        labels: Map.unmodifiable(labels),
      ),
      timeline: TimelineStore(agentId: agentId),
    );
    runtime.timeline.onItem = _onTimelineItem;
    _runtimes[agentId] = runtime;
    try {
      await _startSession(runtime);
      final importedTitle = resolveCreateAgentTitles(
        initialPrompt: _firstUserMessageText(runtime.timeline.snapshot()),
      ).provisionalTitle;
      if (importedTitle != null) {
        runtime.summary = runtime.summary.copyWith(title: importedTitle);
      }
      if (runtime.summary.runState == AgentRunState.initializing) {
        runtime.summary = runtime.summary.copyWith(
          runState: AgentRunState.idle,
          updatedAt: DateTime.now().toUtc().toIso8601String(),
        );
      }
      _persist(runtime);
      await _store.flush();
      _broadcastState(runtime);
      return ImportedProviderSession(
        summary: runtime.summary,
        timelineSize: runtime.timeline.snapshot().length,
        reactivated: false,
      );
    } catch (_) {
      await runtime.sessionSub?.cancel();
      await runtime.session?.dispose();
      runtime.timeline.dispose();
      _runtimes.remove(agentId);
      rethrow;
    }
  }

  Future<ImportedProviderSession> _reactivateImportedProviderSession(
    AgentRuntime runtime, {
    required String workspaceId,
    required Map<String, String> labels,
  }) async {
    final previousSummary = runtime.summary;
    final previousArchived = runtime.archived;
    final previousEpoch = runtime.timeline.epoch;
    final previousLastSeq = runtime.timeline.lastSeq;
    final previousItems = runtime.timeline.snapshot();
    final previousRows = runtime.timeline.snapshotRows();
    runtime.archived = false;
    final mergedLabels = <String, String>{...runtime.summary.labels, ...labels};
    if (runtime.summary.labels.containsKey(paseoParentAgentIdLabel) ||
        labels.containsKey(paseoParentAgentIdLabel)) {
      final requestedParentAgentId = parentAgentIdFromLabels(labels);
      if (requestedParentAgentId == null) {
        mergedLabels.remove(paseoParentAgentIdLabel);
      } else {
        mergedLabels[paseoParentAgentIdLabel] = requestedParentAgentId;
      }
    }
    final parentAgentId = parentAgentIdFromLabels(mergedLabels);
    runtime.summary = runtime.summary.copyWith(
      workspaceId: workspaceId,
      runState: AgentRunState.initializing,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      archivedAt: null,
      requiresAttention: false,
      clearAttention: true,
      parentAgentId: parentAgentId,
      clearParentAgentId: parentAgentId == null,
      labels: mergedLabels,
    );
    try {
      await _startSession(runtime);
      if (runtime.summary.runState == AgentRunState.initializing) {
        runtime.summary = runtime.summary.copyWith(
          runState: AgentRunState.idle,
          updatedAt: DateTime.now().toUtc().toIso8601String(),
        );
      }
      _persist(runtime);
      await _store.flush();
      _broadcastState(runtime);
      return ImportedProviderSession(
        summary: runtime.summary,
        timelineSize: runtime.timeline.snapshot().length,
        reactivated: true,
      );
    } catch (_) {
      await runtime.sessionSub?.cancel();
      await runtime.session?.dispose();
      runtime.sessionSub = null;
      runtime.session = null;
      runtime.timeline.dispose();
      runtime.timeline = TimelineStore(
        agentId: previousSummary.agentId,
        epoch: previousEpoch,
        lastSeq: previousLastSeq,
        items: previousItems,
        rows: previousRows,
      )..onItem = _onTimelineItem;
      runtime.summary = previousSummary;
      runtime.archived = previousArchived;
      _persist(runtime);
      await _store.flush();
      rethrow;
    }
  }

  AgentSummary? get(String agentId, {bool includeArchived = true}) {
    final runtime = _runtimes[agentId];
    if (runtime == null || (!includeArchived && runtime.archived)) return null;
    return runtime.summary;
  }

  Map<String, Object?> mcpServersFor(String agentId) =>
      Map.unmodifiable(_runtime(agentId).mcpServers);

  /// Resolves the frozen Paseo identifier contract: exact id, unique id
  /// prefix, then exact full title. Archived agents remain addressable.
  AgentSummary resolveIdentifier(String identifier) {
    final trimmed = identifier.trim();
    if (trimmed.isEmpty) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent identifier cannot be empty',
      );
    }
    final agents = list(includeArchived: true);
    final exact = agents.where((agent) => agent.agentId == trimmed).firstOrNull;
    if (exact != null) return exact;

    final prefixMatches = [
      for (final agent in agents)
        if (agent.agentId.startsWith(trimmed)) agent,
    ];
    if (prefixMatches.length == 1) return prefixMatches.single;
    if (prefixMatches.length > 1) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent identifier "$trimmed" is ambiguous '
        '(${_identifierSamples(prefixMatches)})',
      );
    }

    final titleMatches = [
      for (final agent in agents)
        if (agent.title == trimmed) agent,
    ];
    if (titleMatches.length == 1) return titleMatches.single;
    if (titleMatches.length > 1) {
      throw RpcException(
        RpcErrorCodes.notFound,
        'Agent title "$trimmed" is ambiguous '
        '(${_identifierSamples(titleMatches)})',
      );
    }
    throw RpcException(RpcErrorCodes.notFound, 'Agent not found: $trimmed');
  }

  String _identifierSamples(List<AgentSummary> agents) {
    final samples = agents
        .take(5)
        .map(
          (agent) =>
              agent.agentId.substring(0, agent.agentId.length.clamp(0, 8)),
        )
        .join(', ');
    return agents.length > 5 ? '$samples, …' : samples;
  }

  AgentRuntime _runtime(String agentId) {
    final runtime = _runtimes[agentId];
    if (runtime == null || runtime.archived) {
      throw RpcException(RpcErrorCodes.notFound, 'no agent $agentId');
    }
    return runtime;
  }

  Future<AgentSummary> createAgent({
    required String cwd,
    required String provider,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    Map<String, Object?> mcpServers = const {},
    String? title,
    String? workspaceId,
    String? projectPath,
    String? branch,
    bool isWorktree = false,
    String? parentAgentId,
    Map<String, String> labels = const {},
    String? initialPrompt,
    String? clientMessageId,
    List<AgentPromptImage> images = const [],
    List<AgentAttachment> attachments = const [],
    bool internal = false,
  }) async {
    final client = _clientFor(provider);
    if (client == null) {
      throw RpcException(
        RpcErrorCodes.invalidPayload,
        'unsupported provider "$provider" '
        '(supported: ${_providerIds.join(', ')})',
      );
    }
    if (parentAgentId != null) {
      _runtime(parentAgentId);
    }
    final agentId = _uuid.v4();
    final createdAt = DateTime.now().toUtc();
    final resolvedTitles = resolveCreateAgentTitles(
      configTitle: title,
      initialPrompt: initialPrompt,
    );
    if ((resolvedTitles.explicitTitle?.length ?? 0) >
        maxExplicitAgentTitleChars) {
      throw RpcException(
        RpcErrorCodes.invalidPayload,
        'Agent title must be at most $maxExplicitAgentTitleChars characters',
      );
    }
    final runtime = AgentRuntime(
      summary: AgentSummary(
        agentId: agentId,
        title: resolvedTitles.provisionalTitle ?? 'Agent',
        cwd: cwd,
        provider: provider,
        model: model,
        mode: mode,
        runState: AgentRunState.initializing,
        createdAtMs: createdAt.millisecondsSinceEpoch,
        updatedAt: createdAt.toIso8601String(),
        workspaceId: workspaceId,
        projectPath: projectPath,
        branch: branch,
        isWorktree: isWorktree,
        parentAgentId: parentAgentId,
        labels: Map.unmodifiable({
          ...labels,
          if (parentAgentId != null) paseoParentAgentIdLabel: parentAgentId,
        }),
        thinkingOptionId: thinkingOptionId,
        currentModeId: modeId,
        featureValues: featureValues,
        systemPrompt: _normalizeOptionalText(systemPrompt),
      ),
      timeline: TimelineStore(agentId: agentId),
      internal: internal,
      mcpServers: Map.unmodifiable(stripInternalAgentMcpServers(mcpServers)),
    );
    runtime.timeline.onItem = _onTimelineItem;
    _runtimes[agentId] = runtime;
    try {
      await _startSession(runtime);
    } catch (e) {
      _runtimes.remove(agentId);
      throw RpcException(RpcErrorCodes.internal, 'failed to start session: $e');
    }
    _persist(runtime);
    _broadcastState(runtime);
    if ((initialPrompt?.isNotEmpty ?? false) ||
        images.isNotEmpty ||
        attachments.isNotEmpty) {
      unawaited(
        prompt(
          agentId,
          initialPrompt ?? '',
          images: images,
          attachments: attachments,
          clientMessageId: clientMessageId,
        ),
      );
    }
    return runtime.summary;
  }

  Future<void> _startSession(AgentRuntime runtime) async {
    final session = await _createProviderSession(
      runtime,
      systemPrompt: runtime.summary.systemPrompt,
    );
    _attachSession(runtime, session, restoreHistory: true);
  }

  Future<AgentSession> _createProviderSession(
    AgentRuntime runtime, {
    required String? systemPrompt,
  }) async {
    final client = _clientFor(runtime.summary.provider);
    if (client == null) {
      throw StateError(
        "Provider '${runtime.summary.provider}' is no longer configured",
      );
    }
    final launchMcpServers = _injectMcpIntoAgents
        ? withRuntimeTinyrackMcpServer(
            storedMcpServers: runtime.mcpServers,
            agentId: runtime.summary.agentId,
            mcpBaseUrl: _mcpBaseUrl,
            mcpAuthToken: _mcpAuthToken,
          )
        : stripInternalAgentMcpServers(runtime.mcpServers);
    final launchSystemPrompt = composeSystemPromptParts([
      systemPrompt,
      _appendSystemPrompt,
    ]);
    final session = client is McpAgentClient
        ? await client.createSessionWithMcp(
            cwd: runtime.summary.cwd,
            model: runtime.summary.model,
            mode: runtime.summary.mode,
            modeId: runtime.summary.currentModeId,
            thinkingOptionId: runtime.summary.thinkingOptionId,
            featureValues: runtime.summary.featureValues,
            systemPrompt: launchSystemPrompt,
            sessionId: runtime.summary.sessionId,
            initialHistory: runtime.timeline.snapshot(),
            mcpServers: launchMcpServers,
          )
        : await client.createSession(
            cwd: runtime.summary.cwd,
            model: runtime.summary.model,
            mode: runtime.summary.mode,
            modeId: runtime.summary.currentModeId,
            thinkingOptionId: runtime.summary.thinkingOptionId,
            featureValues: runtime.summary.featureValues,
            systemPrompt: launchSystemPrompt,
            sessionId: runtime.summary.sessionId,
            initialHistory: runtime.timeline.snapshot(),
          );
    return session;
  }

  void _attachSession(
    AgentRuntime runtime,
    AgentSession session, {
    required bool restoreHistory,
  }) {
    runtime.session = session;
    runtime.sessionSub = session.events.listen(
      (event) => _onProviderEvent(runtime, event),
    );
    if (restoreHistory && session is HistoryRestoringAgentSession) {
      final history = session.restoredHistory;
      if (history != null) {
        runtime.timeline.rebuild(history);
        runtime.textBuffers.clear();
        runtime.currentTurnId = null;
        runtime.interruptRequested = false;
        _persist(runtime);
      }
    }
    if (session is ProviderSubagentRestoringAgentSession) {
      providerSubagents.replace(
        runtime.summary.agentId,
        runtime.summary.provider,
        session.restoredProviderSubagents,
      );
    }
  }

  Future<AgentSummary> reloadAgentSession(
    String agentId, {
    required String? systemPrompt,
  }) async {
    final runtime = _runtime(agentId);
    if (runtime.currentTurnId != null ||
        runtime.summary.runState == AgentRunState.running ||
        runtime.summary.runState == AgentRunState.awaitingPermission) {
      await interrupt(agentId);
      if (runtime.currentTurnId != null) {
        _closeTurn(runtime, TurnPhase.canceled);
      }
      _setRunState(runtime, AgentRunState.idle);
    }

    final normalizedSystemPrompt = _normalizeOptionalText(systemPrompt);
    final replacement = await _createProviderSession(
      runtime,
      systemPrompt: normalizedSystemPrompt,
    );
    final previousSession = runtime.session;
    final previousSubscription = runtime.sessionSub;
    runtime.session = null;
    runtime.sessionSub = null;
    await previousSubscription?.cancel();
    try {
      await previousSession?.dispose();
    } catch (_) {
      // The replacement is already live. A stale provider process failing to
      // close must not roll the agent back to a canceled subscription.
    }
    runtime.summary = runtime.summary.copyWith(
      systemPrompt: normalizedSystemPrompt,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    _attachSession(runtime, replacement, restoreHistory: false);
    _persist(runtime);
    await _store.flush();
    _broadcastState(runtime);
    return runtime.summary;
  }

  bool hasActiveAgentRun(String? agentId) {
    if (agentId == null) return false;
    final runtime = _runtimes[agentId];
    if (runtime == null || runtime.archived) return false;
    return runtime.currentTurnId != null ||
        runtime.summary.runState == AgentRunState.running ||
        runtime.summary.runState == AgentRunState.awaitingPermission;
  }

  AgentClient? _clientFor(String provider) =>
      _clients[provider] ?? _clientResolver?.call(provider);

  List<String> get _providerIds => {
    ..._clients.keys,
    ...?_providerIdsResolver?.call(),
  }.toList(growable: false);

  Future<void> prompt(
    String agentId,
    String text, {
    List<AgentPromptImage> images = const [],
    List<AgentAttachment> attachments = const [],
    String? clientMessageId,
  }) async {
    final runtime = _runtime(agentId);
    runtime.summary = runtime.summary.copyWith(lastError: null);
    if (runtime.session == null) {
      // Session died earlier: recreate, resuming the provider conversation.
      try {
        await _startSession(runtime);
      } catch (e) {
        runtime.timeline.upsert(
          ErrorItem(id: _uuid.v4(), message: 'failed to restart session: $e'),
        );
        _setRunState(runtime, AgentRunState.error);
        return;
      }
    }
    runtime.interruptRequested = false;
    runtime.summary = runtime.summary.copyWith(
      lastUserMessageAt: DateTime.now().toUtc().toIso8601String(),
    );
    runtime.timeline.upsert(
      UserMessageItem(
        id: clientMessageId?.trim().isNotEmpty == true
            ? clientMessageId!.trim()
            : _uuid.v4(),
        text: text,
        clientMessageId: clientMessageId?.trim().isNotEmpty == true
            ? clientMessageId!.trim()
            : null,
        attachments: attachments,
      ),
    );
    final turnId = 'turn_${_uuid.v4()}';
    runtime.currentTurnId = turnId;
    runtime.timeline.upsert(TurnItem(id: turnId, phase: TurnPhase.started));
    _setRunState(runtime, AgentRunState.running);
    try {
      final session = runtime.session!;
      if (session is ImagePromptAgentSession) {
        await session.promptWithImagesAndAttachments(text, images, attachments);
      } else if (session is StructuredPromptAgentSession) {
        await session.promptWithAttachments(text, attachments);
      } else {
        await session.prompt(_renderPrompt(text, attachments));
      }
    } catch (e) {
      runtime.timeline.upsert(
        ErrorItem(id: _uuid.v4(), message: 'prompt failed: $e'),
      );
      _closeTurn(runtime, TurnPhase.failed, errorMessage: '$e');
      _setRunState(runtime, AgentRunState.error);
    }
  }

  Future<AgentRunOutcome> runAndWait(
    String agentId,
    String text, {
    Duration timeout = const Duration(hours: 24),
  }) async {
    final runtime = _runtime(agentId);
    if (runtime.currentTurnId != null ||
        runtime.summary.runState == AgentRunState.running ||
        runtime.summary.runState == AgentRunState.awaitingPermission) {
      throw StateError('Agent $agentId already has an active run');
    }
    final beforeSeq = runtime.timeline.lastSeq;
    await prompt(agentId, text);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final current = _runtime(agentId);
      final state = current.summary.runState;
      if (state == AgentRunState.awaitingPermission) {
        throw StateError('Agent $agentId is waiting for permission');
      }
      if (state == AgentRunState.error) {
        throw StateError(_lastError(current) ?? 'Agent $agentId failed');
      }
      if (current.currentTurnId == null && state == AgentRunState.idle) {
        final timeline = current.timeline.fetch(afterSeq: beforeSeq).items;
        final output = timeline
            .whereType<AssistantMessageItem>()
            .where((item) => item.complete)
            .lastOrNull
            ?.text
            .trim();
        return AgentRunOutcome(
          summary: current.summary,
          output: output == null || output.isEmpty ? null : output,
          timeline: timeline,
        );
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('Agent $agentId run timed out', timeout);
      }
      final waiter = Completer<void>();
      _stateWaiters.putIfAbsent(agentId, () => []).add(waiter);
      try {
        await waiter.future.timeout(remaining);
      } finally {
        _stateWaiters[agentId]?.remove(waiter);
        if (_stateWaiters[agentId]?.isEmpty ?? false) {
          _stateWaiters.remove(agentId);
        }
      }
    }
  }

  Future<AgentWaitResult> waitForAgentEvent(
    String agentId, {
    bool waitForActive = false,
    Duration? timeout,
  }) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    var hasSeenActive = false;
    while (true) {
      final runtime = _runtime(agentId);
      final state = runtime.summary.runState;
      if (state == AgentRunState.running ||
          state == AgentRunState.awaitingPermission) {
        hasSeenActive = true;
      }
      final permission = _latestPendingPermission(runtime);
      if (permission != null) {
        return AgentWaitResult(
          summary: runtime.summary,
          lastMessage: _lastAssistantMessage(runtime),
          permission: permission,
        );
      }
      if (state == AgentRunState.error ||
          state == AgentRunState.closed ||
          (state == AgentRunState.idle &&
              (!waitForActive ||
                  hasSeenActive ||
                  _latestTurnIsFinal(runtime)))) {
        return AgentWaitResult(
          summary: runtime.summary,
          lastMessage: _lastAssistantMessage(runtime),
        );
      }

      final remaining = deadline?.difference(DateTime.now());
      if (remaining != null && remaining <= Duration.zero) {
        throw TimeoutException('Agent $agentId wait timed out', timeout);
      }
      final waiter = Completer<void>();
      _stateWaiters.putIfAbsent(agentId, () => []).add(waiter);
      try {
        if (remaining == null) {
          await waiter.future;
        } else {
          await waiter.future.timeout(remaining);
        }
      } finally {
        _stateWaiters[agentId]?.remove(waiter);
        if (_stateWaiters[agentId]?.isEmpty ?? false) {
          _stateWaiters.remove(agentId);
        }
      }
    }
  }

  PermissionItem? _latestPendingPermission(AgentRuntime runtime) => runtime
      .timeline
      .snapshot()
      .whereType<PermissionItem>()
      .where((item) => item.status == PermissionStatus.pending)
      .lastOrNull;

  String? _lastAssistantMessage(AgentRuntime runtime) {
    final text = runtime.timeline
        .snapshot()
        .whereType<AssistantMessageItem>()
        .where((item) => item.complete)
        .lastOrNull
        ?.text
        .trim();
    return text == null || text.isEmpty ? null : text;
  }

  bool _latestTurnIsFinal(AgentRuntime runtime) {
    final turn = runtime.timeline.snapshot().whereType<TurnItem>().lastOrNull;
    return turn != null && turn.phase != TurnPhase.started;
  }

  String? _lastError(AgentRuntime runtime) {
    for (final item in runtime.timeline.snapshot().reversed) {
      switch (item) {
        case ErrorItem(:final message):
          return message;
        case TurnItem(:final errorMessage) when errorMessage != null:
          return errorMessage;
        default:
          continue;
      }
    }
    return null;
  }

  String _renderPrompt(String text, List<AgentAttachment> attachments) {
    if (attachments.isEmpty) return text;
    final parts = <String>[
      if (text.trim().isNotEmpty) text.trim(),
      for (final attachment in attachments)
        if (attachment case TextAgentAttachment(text: final value))
          value.trim(),
    ]..removeWhere((part) => part.isEmpty);
    return parts.join('\n\n');
  }

  Future<void> interrupt(String agentId) async {
    final runtime = _runtime(agentId);
    runtime.interruptRequested = true;
    await runtime.session?.interrupt();
  }

  Future<void> close(String agentId) async {
    final runtime = _runtime(agentId);
    runtime.interruptRequested = true;
    final session = runtime.session;
    runtime.session = null;
    await runtime.sessionSub?.cancel();
    runtime.sessionSub = null;
    await broker.autoDenyForAgent(agentId);
    if (runtime.currentTurnId != null) {
      _closeTurn(runtime, TurnPhase.canceled);
    }
    runtime.timeline.flushAll();
    runtime.textBuffers.clear();
    runtime.summary = runtime.summary.copyWith(
      runState: AgentRunState.closed,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      requiresAttention: false,
      clearAttention: true,
    );
    _persist(runtime);
    _broadcastState(runtime);
    await session?.dispose();
    await _store.flush();
  }

  /// Removes a transient metadata-generation agent after its provider session
  /// has been closed. Internal agents are never persisted or broadcast.
  Future<void> discardInternalAgent(String agentId) async {
    final runtime = _runtime(agentId);
    if (!runtime.internal) {
      throw StateError('Only internal agents can be discarded');
    }
    if (runtime.session != null ||
        runtime.summary.runState != AgentRunState.closed) {
      await close(agentId);
    }
    _runtimes.remove(agentId);
    _stateWaiters.remove(agentId);
    providerSubagents.clear(agentId);
    runtime.timeline.dispose();
  }

  Future<void> ensureLoaded(String agentId) async {
    final runtime = _runtime(agentId);
    if (runtime.session != null) return;
    await _startSession(runtime);
  }

  Future<AgentProviderNotice?> setModeId(String agentId, String modeId) async {
    final mode = _modeFromId(modeId);
    await ensureLoaded(agentId);
    final runtime = _runtime(agentId);
    final session = runtime.session;
    if (session is! ConfigurableAgentSession) {
      throw UnsupportedError('Agent session does not support setting modes');
    }
    final notice = await session.setMode(modeId);
    runtime.summary = runtime.summary.copyWith(
      mode: mode,
      currentModeId: modeId,
    );
    _persist(runtime);
    _broadcastState(runtime);
    return notice;
  }

  Future<void> setModelId(String agentId, String? modelId) async {
    await ensureLoaded(agentId);
    final runtime = _runtime(agentId);
    final session = runtime.session;
    if (session is! ConfigurableAgentSession) {
      throw UnsupportedError('Agent session does not support setting models');
    }
    final normalized = modelId?.trim();
    await session.setModel(
      normalized == null || normalized.isEmpty ? null : normalized,
    );
    runtime.summary = runtime.summary.copyWith(
      model: normalized == null || normalized.isEmpty ? null : normalized,
    );
    _persist(runtime);
    _broadcastState(runtime);
  }

  Future<AgentProviderNotice?> setThinkingOption(
    String agentId,
    String? thinkingOptionId,
  ) async {
    await ensureLoaded(agentId);
    final runtime = _runtime(agentId);
    final session = runtime.session;
    if (session is! ConfigurableAgentSession) {
      throw UnsupportedError(
        'Agent session does not support setting thinking options',
      );
    }
    final normalized = thinkingOptionId?.trim();
    final value = normalized == null || normalized.isEmpty ? null : normalized;
    final notice = await session.setThinkingOption(value);
    runtime.summary = runtime.summary.copyWith(thinkingOptionId: value);
    _persist(runtime);
    _broadcastState(runtime);
    return notice;
  }

  Future<void> setFeature(
    String agentId,
    String featureId,
    Object? value,
  ) async {
    await ensureLoaded(agentId);
    final runtime = _runtime(agentId);
    final session = runtime.session;
    if (session is! ConfigurableAgentSession) {
      throw UnsupportedError('Agent session does not support setting features');
    }
    await session.setFeature(featureId, value);
    runtime.summary = runtime.summary.copyWith(
      featureValues: {...runtime.summary.featureValues, featureId: value},
    );
    _persist(runtime);
    _broadcastState(runtime);
  }

  Future<AgentSummary> setMode(String agentId, AgentMode mode) async {
    final runtime = _runtime(agentId);
    // M1: stored only; the flag applies when the next session is spawned.
    runtime.summary = runtime.summary.copyWith(
      mode: mode,
      currentModeId: switch (mode) {
        AgentMode.plan => 'plan',
        AgentMode.normal => 'normal',
        AgentMode.fullAccess => 'full-access',
      },
    );
    _persist(runtime);
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<AgentSummary> rename(String agentId, String title) async {
    final runtime = _runtime(agentId);
    runtime.summary = runtime.summary.copyWith(title: title);
    _persist(runtime);
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<AgentSummary> setLabels(
    String agentId,
    Map<String, String> labels,
  ) async {
    final runtime = _runtime(agentId);
    runtime.summary = runtime.summary.copyWith(
      labels: {...runtime.summary.labels, ...labels},
    );
    _persist(runtime);
    await _store.flush();
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<void> archive(String agentId) async {
    final runtime = _runtime(agentId);
    await _archiveTree(runtime);
    await _store.flush();
  }

  /// Archives agents owned by one workspace without crossing workspace
  /// boundaries through parent/subagent relationships.
  Future<List<String>> archiveWorkspaceAgents(String workspaceId) async {
    final matches = [
      for (final runtime in _runtimes.values)
        if (!runtime.archived && runtime.summary.workspaceId == workspaceId)
          runtime,
    ];
    for (final runtime in matches) {
      await _archiveOne(runtime);
    }
    await _store.flush();
    return [for (final runtime in matches) runtime.summary.agentId];
  }

  Future<void> _archiveTree(AgentRuntime runtime) async {
    final children = [
      for (final candidate in _runtimes.values)
        if (!candidate.archived &&
            candidate.summary.parentAgentId == runtime.summary.agentId)
          candidate,
    ];
    for (final child in children) {
      await _archiveTree(child);
    }

    await _archiveOne(runtime);
  }

  Future<void> _archiveOne(AgentRuntime runtime) async {
    if (runtime.archived) return;
    runtime.archived = true;
    runtime.summary = runtime.summary.copyWith(
      runState: AgentRunState.closed,
      archivedAt: DateTime.now().toUtc().toIso8601String(),
      requiresAttention: false,
      clearAttention: true,
    );
    final session = runtime.session;
    runtime.session = null;
    await runtime.sessionSub?.cancel();
    runtime.sessionSub = null;
    await broker.autoDenyForAgent(runtime.summary.agentId);
    await session?.dispose();
    runtime.timeline.flushAll();
    providerSubagents.clear(runtime.summary.agentId);
    _persist(runtime);
    _broadcastState(runtime);
  }

  Future<AgentSummary> detach(String agentId) async {
    final runtime = _runtime(agentId);
    if (runtime.summary.parentAgentId == null) {
      return runtime.summary;
    }
    runtime.summary = runtime.summary.copyWith(clearParentAgentId: true);
    _persist(runtime);
    await _store.flush();
    _broadcastState(runtime);
    return runtime.summary;
  }

  Future<AgentSummary> clearAttention(String agentId) async {
    final runtime = _runtime(agentId);
    if (!runtime.summary.requiresAttention) return runtime.summary;
    runtime.summary = runtime.summary.copyWith(
      requiresAttention: false,
      clearAttention: true,
    );
    _persist(runtime);
    await _store.flush();
    _broadcastState(runtime);
    return runtime.summary;
  }

  TimelineFetchResponse fetchTimeline(
    String agentId, {
    int? epoch,
    int? afterSeq,
  }) {
    final runtime = _runtime(agentId);
    final timeline = runtime.timeline;
    // Stale-epoch (or no-epoch) clients get the full snapshot.
    if (epoch == null || epoch != timeline.epoch) {
      return timeline.fetch();
    }
    return timeline.fetch(afterSeq: afterSeq ?? 0);
  }

  ({AgentSummary agent, int epoch, int lastSeq, List<TimelineRow> rows})
  fetchCanonicalTimeline(String agentId) {
    final runtime = _runtime(agentId);
    return (
      agent: runtime.summary,
      epoch: runtime.timeline.epoch,
      lastSeq: runtime.timeline.lastSeq,
      rows: runtime.timeline.snapshotRows(),
    );
  }

  /// Appends or replaces a daemon-owned lifecycle item on an active agent.
  ///
  /// Paseo uses this for setup/terminal bootstrap work that is initiated by
  /// the daemon rather than emitted by the provider process.
  bool upsertTimelineItem(String agentId, TimelineItem item) {
    final runtime = _runtimes[agentId];
    if (runtime == null || runtime.archived) return false;
    runtime.timeline.upsert(item);
    return true;
  }

  Future<void> respondPermission(String permissionId, String decision) =>
      broker.respond(permissionId, decision);

  Future<void> respondPermissionDetailed({
    required String agentId,
    required String permissionId,
    required String behavior,
    String? message,
    String? selectedActionId,
    Map<String, Object?>? updatedInput,
    List<Map<String, Object?>>? updatedPermissions,
    bool? interrupt,
  }) => broker.respondDetailed(
    permissionId: permissionId,
    behavior: behavior,
    agentId: agentId,
    message: message,
    selectedActionId: selectedActionId,
    updatedInput: updatedInput,
    updatedPermissions: updatedPermissions,
    interrupt: interrupt,
  );

  /// Wipe the in-memory and persisted conversation state for one or every
  /// agent. Returns the number of agents actually affected.
  ///
  /// For each affected agent this: tears down its live session, cancels any
  /// pending permission prompts, drops the timeline (bumping the epoch so
  /// stale clients refetch an empty list), nulls the provider session id so
  /// the next prompt starts a fresh provider-side conversation, and writes
  /// the wiped state to disk.
  Future<int> clearConversations({String? agentId}) async {
    final targets = <AgentRuntime>[];
    for (final r in _runtimes.values) {
      if (agentId == null || r.summary.agentId == agentId) {
        targets.add(r);
      }
    }
    for (final runtime in targets) {
      // Tear down the live session, if any.
      await runtime.sessionSub?.cancel();
      runtime.sessionSub = null;
      final session = runtime.session;
      runtime.session = null;
      // Drop any pending permission prompts for this agent.
      await broker.autoDenyForAgent(runtime.summary.agentId);
      await session?.dispose();

      // Drop accumulated streaming text and turn state.
      runtime.textBuffers.clear();
      runtime.currentTurnId = null;
      runtime.interruptRequested = false;

      // Wipe the timeline (bumps epoch, clears items).
      runtime.timeline.clear();
      providerSubagents.clear(runtime.summary.agentId);

      // Null the session id so the next prompt starts a fresh provider
      // session, and force run state back to idle. We can't go through
      // `copyWith` here because its `String? sessionId ?? this.sessionId`
      // pattern can't represent "clear the field" — build the summary
      // directly with all the original fields swapped.
      final s = runtime.summary;
      runtime.summary = AgentSummary(
        agentId: s.agentId,
        title: s.title,
        cwd: s.cwd,
        provider: s.provider,
        model: s.model,
        mode: s.mode,
        runState: AgentRunState.idle,
        createdAtMs: s.createdAtMs,
        sessionId: null,
        workspaceId: s.workspaceId,
        projectPath: s.projectPath,
        branch: s.branch,
        isWorktree: s.isWorktree,
        lastUsage: s.lastUsage,
        parentAgentId: s.parentAgentId,
        requiresAttention: false,
        archivedAt: s.archivedAt,
      );

      _persist(runtime);
      _broadcastState(runtime);
    }
    // Flush debounced writes immediately so a quit right after the reset
    // doesn't lose the wiped state to disk.
    await _store.flush();
    return targets.length;
  }

  Future<void> dispose() async {
    for (final waiters in _stateWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('Agent manager disposed'));
        }
      }
    }
    _stateWaiters.clear();
    _streamSubscribers.clear();
    for (final runtime in _runtimes.values) {
      await runtime.sessionSub?.cancel();
      await runtime.session?.dispose();
      runtime.timeline.dispose();
      _persist(runtime);
    }
    await _store.flush();
  }

  // -- provider event handling ----------------------------------------------

  void _onProviderEvent(AgentRuntime runtime, ProviderEvent event) {
    switch (event) {
      case SessionStarted(:final sessionId):
        runtime.summary = runtime.summary.copyWith(sessionId: sessionId);
        if (runtime.summary.runState == AgentRunState.initializing) {
          _setRunState(runtime, AgentRunState.idle);
        } else {
          _persist(runtime);
          _broadcastState(runtime);
        }

      case AssistantTextDelta(:final itemId, :final text):
        final buffer = runtime.textBuffers.putIfAbsent(itemId, StringBuffer.new)
          ..write(text);
        runtime.timeline.upsertCoalesced(
          AssistantMessageItem(
            id: itemId,
            text: buffer.toString(),
            complete: false,
          ),
        );

      case ReasoningDelta(:final itemId, :final text):
        final buffer = runtime.textBuffers.putIfAbsent(itemId, StringBuffer.new)
          ..write(text);
        runtime.timeline.upsertCoalesced(
          ReasoningItem(id: itemId, text: buffer.toString(), complete: false),
        );

      case AssistantMessageComplete(:final itemId, :final fullText):
        runtime.textBuffers.remove(itemId);
        runtime.timeline.upsert(
          AssistantMessageItem(id: itemId, text: fullText, complete: true),
        );

      case ReasoningComplete(:final itemId, :final fullText):
        runtime.textBuffers.remove(itemId);
        runtime.timeline.upsert(
          ReasoningItem(id: itemId, text: fullText, complete: true),
        );

      case ToolCallStarted(
        :final itemId,
        :final toolName,
        :final status,
        :final detail,
      ):
      case ToolCallUpdated(
        :final itemId,
        :final toolName,
        :final status,
        :final detail,
      ):
        runtime.timeline.upsert(
          ToolCallItem(
            id: itemId,
            toolName: toolName,
            status: status,
            detail: detail,
          ),
        );

      case PermissionRequested(
        :final permissionId,
        :final toolName,
        :final detail,
        :final respond,
      ):
        _onPermissionRequested(
          runtime,
          permissionId,
          toolName,
          detail,
          respond,
        );

      case UsageUpdated(:final usage):
        runtime.summary = runtime.summary.copyWith(lastUsage: usage);
        _persist(runtime);
        _broadcastState(runtime);

      case CompactionUpdated(
        :final itemId,
        :final status,
        :final trigger,
        :final preTokens,
      ):
        runtime.timeline.upsert(
          CompactionItem(
            id: itemId,
            status: status,
            trigger: trigger,
            preTokens: preTokens,
          ),
        );

      case ProviderSubagentUpserted(
        :final subagentId,
        :final title,
        :final description,
        :final status,
        :final toolCallId,
        :final cwd,
      ):
        if (!runtime.internal) {
          providerSubagents.upsert(
            parentAgentId: runtime.summary.agentId,
            provider: runtime.summary.provider,
            subagentId: subagentId,
            title: title,
            description: description,
            status: status,
            toolCallId: toolCallId,
            cwd: cwd,
          );
        }

      case ProviderSubagentTimelineChanged(
        :final subagentId,
        :final item,
        :final timestamp,
      ):
        if (!runtime.internal) {
          providerSubagents.appendTimeline(
            parentAgentId: runtime.summary.agentId,
            provider: runtime.summary.provider,
            subagentId: subagentId,
            item: item,
            timestamp: timestamp,
          );
        }

      case ProviderSubagentRemoved(:final subagentId):
        assert(subagentId.isNotEmpty);

      case TurnCompleted():
        runtime.timeline.flushAll();
        _closeTurn(runtime, TurnPhase.completed);
        _setRunState(runtime, AgentRunState.idle);

      case TurnFailed(:final error):
        runtime.timeline.flushAll();
        if (runtime.interruptRequested) {
          _closeTurn(runtime, TurnPhase.canceled);
          _setRunState(runtime, AgentRunState.idle);
        } else {
          _closeTurn(runtime, TurnPhase.failed, errorMessage: error);
          _setRunState(runtime, AgentRunState.error);
        }

      case SessionExited():
        _onSessionExited(runtime);
    }
  }

  void _onPermissionRequested(
    AgentRuntime runtime,
    String permissionId,
    String toolName,
    ToolCallDetail detail,
    PermissionRespond respond,
  ) {
    final itemId = 'perm_$permissionId';
    runtime.timeline.upsert(
      PermissionItem(
        id: itemId,
        permissionId: permissionId,
        toolName: toolName,
        status: PermissionStatus.pending,
        detail: detail,
      ),
    );
    broker.register(
      permissionId: permissionId,
      agentId: runtime.summary.agentId,
      respond: respond,
      onResolved: (decision) {
        runtime.timeline.upsert(
          PermissionItem(
            id: itemId,
            permissionId: permissionId,
            toolName: toolName,
            status: decision == PermissionDecision.allow
                ? PermissionStatus.allowed
                : PermissionStatus.denied,
            detail: detail,
          ),
        );
        if (runtime.summary.runState == AgentRunState.awaitingPermission) {
          _setRunState(runtime, AgentRunState.running);
        }
        onPermissionResolved?.call(permissionId, decision);
      },
    );
    _setRunState(runtime, AgentRunState.awaitingPermission);
    onAttention?.call(
      runtime.summary.agentId,
      AgentAttentionReason.permission,
      DateTime.now().toUtc().toIso8601String(),
    );
    onPermissionRequested?.call(
      runtime.summary.agentId,
      permissionId,
      toolName,
      detail,
    );
  }

  void _onSessionExited(AgentRuntime runtime) {
    runtime.session = null;
    runtime.sessionSub?.cancel();
    runtime.sessionSub = null;
    runtime.timeline.flushAll();
    unawaited(broker.autoDenyForAgent(runtime.summary.agentId));
    if (runtime.currentTurnId != null) {
      // Turn still open: the process died mid-turn.
      if (runtime.interruptRequested) {
        _closeTurn(runtime, TurnPhase.canceled);
        _setRunState(runtime, AgentRunState.idle);
      } else {
        _closeTurn(runtime, TurnPhase.failed, errorMessage: 'session exited');
        _setRunState(runtime, AgentRunState.error);
      }
    } else if (runtime.summary.runState != AgentRunState.error) {
      _setRunState(runtime, AgentRunState.idle);
    }
  }

  void _closeTurn(
    AgentRuntime runtime,
    TurnPhase phase, {
    String? errorMessage,
  }) {
    final turnId = runtime.currentTurnId;
    runtime.currentTurnId = null;
    if (turnId == null) return;
    runtime.timeline.upsert(
      TurnItem(id: turnId, phase: phase, errorMessage: errorMessage),
    );
  }

  void _setRunState(AgentRuntime runtime, AgentRunState state) {
    final previous = runtime.summary.runState;
    if (previous == state) return;
    final timestamp = DateTime.now().toUtc().toIso8601String();
    var summary = runtime.summary.copyWith(
      runState: state,
      updatedAt: timestamp,
    );
    if (state == AgentRunState.error) {
      summary = summary.copyWith(lastError: _lastError(runtime));
    } else if (state == AgentRunState.idle) {
      summary = summary.copyWith(lastError: null);
    }
    if (!runtime.internal && !summary.requiresAttention) {
      final reason = switch ((previous, state)) {
        (AgentRunState.running, AgentRunState.idle) =>
          AgentAttentionReason.finished,
        (_, AgentRunState.error) when previous != AgentRunState.error =>
          AgentAttentionReason.error,
        _ => null,
      };
      if (reason != null) {
        summary = summary.copyWith(
          requiresAttention: true,
          attentionReason: reason,
          attentionTimestamp: timestamp,
        );
        onAttention?.call(summary.agentId, reason, timestamp);
      }
    }
    runtime.summary = summary;
    _persist(runtime);
    _broadcastState(runtime);
  }

  void _broadcastState(AgentRuntime runtime) {
    if (!runtime.internal) {
      onState?.call(AgentStatePayload(agent: runtime.summary));
    }
    for (final waiter
        in _stateWaiters.remove(runtime.summary.agentId) ?? const []) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _onTimelineItem(String agentId, int epoch, int seq, TimelineItem item) {
    final runtime = _runtimes[agentId];
    if (runtime?.internal != true) {
      final payload = AgentStreamPayload(
        agentId: agentId,
        epoch: epoch,
        seq: seq,
        item: item,
        provider: runtime?.summary.provider ?? 'codex',
        timestamp: DateTime.now().toUtc().toIso8601String(),
      );
      onStream?.call(payload);
      for (final subscription in _streamSubscribers.toList(growable: false)) {
        if (subscription.agentId == null || subscription.agentId == agentId) {
          subscription.subscriber(payload);
        }
      }
    }
    if (runtime != null) _persist(runtime);
  }

  void _persist(AgentRuntime runtime) {
    if (runtime.internal) return;
    _store.scheduleSave(
      PersistedAgent(
        summary: runtime.summary,
        archived: runtime.archived,
        epoch: runtime.timeline.epoch,
        lastSeq: runtime.timeline.lastSeq,
        items: runtime.timeline.snapshot(),
        rows: runtime.timeline.snapshotRows(),
        mcpServers: runtime.mcpServers,
      ),
    );
  }
}

String? _normalizeOptionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _firstUserMessageText(Iterable<TimelineItem> timeline) {
  for (final item in timeline) {
    if (item is! UserMessageItem) continue;
    final text = item.text.trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

AgentMode _modeFromId(String modeId) => switch (modeId) {
  'read-only' ||
  'plan' ||
  'https://agentclientprotocol.com/protocol/session-modes#plan' =>
    AgentMode.plan,
  'full-access' ||
  'fullAccess' ||
  'bypassPermissions' ||
  'allow-all' ||
  'full' => AgentMode.fullAccess,
  _ => AgentMode.normal,
};
