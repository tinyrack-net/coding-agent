import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../agent/prompt_attachments.dart';
import '../agent_client.dart';
import '../agent_session.dart';
import '../provider_event.dart';
import 'acp_catalog.dart';
import 'acp_client_runtime.dart';
import 'acp_history.dart';
import 'acp_rpc_process.dart';
import 'omp_system_notice.dart';
import 'provider_launch_config.dart';

typedef AcpCommandResolver = Future<String?> Function();

final class GenericAcpAgentClient
    implements
        AgentClient,
        McpAgentClient,
        EnvironmentAgentClient,
        EnvironmentMcpAgentClient,
        ImportableAgentClient {
  const GenericAcpAgentClient({
    required this.provider,
    required this.command,
    required this.commandArgs,
    required AcpCommandResolver resolveCommand,
    this.environment = const {},
    this.providerParams = const {},
    this.fallbackModes = const [],
    this.processStarter,
  }) : _resolveCommand = resolveCommand;

  final String provider;
  final String command;
  final List<String> commandArgs;
  final Map<String, String> environment;
  final Map<String, Object?> providerParams;
  final List<ProviderMode> fallbackModes;
  final AcpRpcProcessStarter? processStarter;
  final AcpCommandResolver _resolveCommand;

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
  }) => createSessionWithMcp(
    cwd: cwd,
    model: model,
    mode: mode,
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    featureValues: featureValues,
    systemPrompt: systemPrompt,
    sessionId: sessionId,
    initialHistory: initialHistory,
  );

  @override
  Future<AgentSession> createSessionWithMcp({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  }) => createSessionWithMcpAndEnvironment(
    cwd: cwd,
    model: model,
    mode: mode,
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    featureValues: featureValues,
    systemPrompt: systemPrompt,
    sessionId: sessionId,
    initialHistory: initialHistory,
    mcpServers: mcpServers,
  );

  @override
  Future<AgentSession> createSessionWithEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, String> environment = const {},
  }) => createSessionWithMcpAndEnvironment(
    cwd: cwd,
    model: model,
    mode: mode,
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    featureValues: featureValues,
    systemPrompt: systemPrompt,
    sessionId: sessionId,
    initialHistory: initialHistory,
    environment: environment,
  );

  @override
  Future<AgentSession> createSessionWithMcpAndEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
    Map<String, String> environment = const {},
  }) async {
    if (systemPrompt?.trim().isNotEmpty == true) {
      throw UnsupportedError(
        "ACP provider '$provider' does not advertise system-prompt support",
      );
    }
    final executable = await _resolveCommand();
    if (executable == null) {
      throw StateError(
        "ACP provider '$provider' command is unavailable: $command",
      );
    }
    final session = GenericAcpAgentSession(
      provider: provider,
      executable: executable,
      commandArgs: commandArgs,
      cwd: cwd,
      environment: _providerEnvironment(environment),
      model: model,
      modeId: modeId,
      thinkingOptionId: thinkingOptionId,
      featureValues: featureValues,
      resumeSessionId: sessionId,
      fallbackModes: fallbackModes,
      mcpServers: acpSupportsMcpServers(providerParams)
          ? normalizeAcpMcpServers(mcpServers)
          : const [],
      clientCapabilities: buildAcpClientCapabilities(providerParams),
      processStarter: processStarter,
    );
    await session.initialize();
    return session;
  }

  Future<AcpProviderCatalog> fetchCatalog({required String cwd}) async {
    final executable = await _resolveCommand();
    if (executable == null) {
      throw StateError(
        "ACP provider '$provider' command is unavailable: $command",
      );
    }
    final session = GenericAcpAgentSession(
      provider: provider,
      executable: executable,
      commandArgs: commandArgs,
      cwd: cwd,
      environment: _providerEnvironment(const {'NO_BROWSER': 'true'}),
      model: '',
      modeId: null,
      thinkingOptionId: null,
      featureValues: const {},
      resumeSessionId: null,
      fallbackModes: fallbackModes,
      mcpServers: const [],
      clientCapabilities: buildAcpClientCapabilities(providerParams),
      processStarter: processStarter,
    );
    try {
      await session.initialize();
      return session.catalog;
    } finally {
      await session.dispose();
    }
  }

  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async {
    final executable = await _requireExecutable();
    final rpc = await AcpRpcProcess.start(
      launch: AcpRpcProcessLaunch(
        command: executable,
        args: commandArgs,
        cwd: options?.cwd ?? '.',
        environment: _providerEnvironment(const {'NO_BROWSER': 'true'}),
        includeParentEnvironment: false,
      ),
      diagnosticName: '$provider ACP session list',
      onIncoming: (method, _) {
        throw UnsupportedError(
          'Unsupported ACP client method during session listing: $method',
        );
      },
      spawn: processStarter,
    );
    try {
      final initialized = await _initializeAcp(
        rpc,
        buildAcpClientCapabilities(providerParams),
      );
      final capabilities =
          _map(initialized['agentCapabilities']) ?? const <String, Object?>{};
      final sessionCapabilities =
          _map(capabilities['sessionCapabilities']) ??
          const <String, Object?>{};
      if (!_capabilityEnabled(sessionCapabilities, 'list')) return const [];

      final sessions = <ImportableProviderSession>[];
      String? cursor;
      for (;;) {
        final page = _requiredMap(
          await rpc.request('session/list', {
            if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
            if (options?.cwd case final cwd? when cwd.isNotEmpty) 'cwd': cwd,
          }),
          'ACP session/list result',
        );
        final rows = page['sessions'];
        if (rows is! List) {
          throw const FormatException(
            'ACP session/list result requires sessions',
          );
        }
        for (final row in rows) {
          sessions.add(_importableSession(_requiredMap(row, 'ACP session')));
        }
        final nextCursor = page['nextCursor'];
        if (nextCursor != null && nextCursor is! String) {
          throw const FormatException(
            'ACP session/list nextCursor must be a string',
          );
        }
        cursor = nextCursor as String?;
        if (cursor == null || cursor.isEmpty) break;
        final limit = options?.limit;
        if (limit != null && sessions.length >= limit) break;
      }
      final limit = options?.limit;
      if (limit == null || sessions.length <= limit) {
        return List.unmodifiable(sessions);
      }
      return List.unmodifiable(sessions.take(limit));
    } finally {
      await rpc.close();
    }
  }

  Future<String> _requireExecutable() async {
    final executable = await _resolveCommand();
    if (executable == null) {
      throw StateError(
        "ACP provider '$provider' command is unavailable: $command",
      );
    }
    return executable;
  }

  Map<String, String> _providerEnvironment([Map<String, String?>? overlay]) =>
      createProviderEnvironment(
        baseEnvironment: Platform.environment,
        overlays: [environment, overlay],
      );
}

final class _PendingAcpPermission {
  _PendingAcpPermission({required this.options, required this.completer});

  final List<Map<String, Object?>> options;
  final Completer<Object?> completer;
}

final class _AcpToolSnapshot {
  const _AcpToolSnapshot({
    required this.id,
    required this.title,
    required this.status,
    required this.rawInput,
    required this.rawOutput,
  });

  final String id;
  final String title;
  final ToolCallStatus status;
  final Map<String, Object?> rawInput;
  final Object? rawOutput;
}

final class GenericAcpAgentSession
    implements
        ImagePromptAgentSession,
        ConfigurableAgentSession,
        CommandListingAgentSession,
        HistoryRestoringAgentSession {
  GenericAcpAgentSession({
    required this.provider,
    required this.executable,
    required this.commandArgs,
    required this.cwd,
    required this.environment,
    required this.model,
    required this.modeId,
    required this.thinkingOptionId,
    required this.featureValues,
    required this.resumeSessionId,
    required this.fallbackModes,
    required this.mcpServers,
    required this.clientCapabilities,
    this.processStarter,
  }) {
    _events = StreamController<ProviderEvent>.broadcast(sync: true);
  }

  static const _uuid = Uuid();

  final String provider;
  final String executable;
  final List<String> commandArgs;
  final String cwd;
  final Map<String, String> environment;
  final String model;
  final String? modeId;
  final String? thinkingOptionId;
  final Map<String, Object?> featureValues;
  final String? resumeSessionId;
  final List<ProviderMode> fallbackModes;
  final List<Map<String, Object?>> mcpServers;
  final Map<String, Object?> clientCapabilities;
  final AcpRpcProcessStarter? processStarter;

  late final StreamController<ProviderEvent> _events;
  final Map<String, _PendingAcpPermission> _pendingPermissions = {};
  final Map<String, _AcpToolSnapshot> _toolCalls = {};
  final List<AgentSlashCommand> _commands = [];
  final Map<String, Object?> _sessionState = {};

  AcpRpcProcess? _rpc;
  late final AcpClientRuntime _clientRuntime = AcpClientRuntime(
    cwd: cwd,
    environment: environment,
  );
  AcpHistoryProjector? _historyProjector;
  late AcpProviderCatalog _catalog;
  List<TimelineItem>? _restoredHistory;
  String? _sessionId;
  String? _fallbackAssistantMessageId;
  String? _fallbackReasoningId;
  final Map<String, StringBuffer> _ompAssistantBuffers = {};
  bool _turnActive = false;
  bool _disposed = false;
  bool _intentionalClose = false;

  AcpProviderCatalog get catalog => _catalog;

  @override
  List<TimelineItem>? get restoredHistory => _restoredHistory;

  @override
  Stream<ProviderEvent> get events async* {
    final sessionId = _sessionId;
    if (sessionId != null) yield SessionStarted(sessionId: sessionId);
    yield* _events.stream;
  }

  Future<void> initialize() async {
    _catalog = deriveAcpProviderCatalog(
      provider: provider,
      sessionState: const {},
      fallbackModes: fallbackModes,
    );
    try {
      final rpc = await AcpRpcProcess.start(
        launch: AcpRpcProcessLaunch(
          command: executable,
          args: commandArgs,
          cwd: cwd,
          environment: environment,
          includeParentEnvironment: false,
        ),
        diagnosticName: '$provider ACP',
        onIncoming: _handleIncoming,
        spawn: processStarter,
      );
      _rpc = rpc;
      rpc.onExit((exit) {
        if (!_intentionalClose && !_events.isClosed) {
          _events.add(SessionExited(exitCode: exit.code));
        }
      });

      final initialized = await _initializeAcp(rpc, clientCapabilities);
      final capabilities =
          _map(initialized['agentCapabilities']) ?? const <String, Object?>{};
      final sessionCapabilities =
          _map(capabilities['sessionCapabilities']) ??
          const <String, Object?>{};

      final requestedSessionId = resumeSessionId;
      Object? response;
      if (requestedSessionId == null) {
        response = await rpc.request('session/new', {
          'cwd': cwd,
          'mcpServers': mcpServers,
        });
      } else {
        _sessionId = requestedSessionId;
        final supportsLoad = _capabilityEnabled(capabilities, 'loadSession');
        if (supportsLoad) _historyProjector = AcpHistoryProjector();
        response = await _resume(
          rpc,
          requestedSessionId,
          loadSession: supportsLoad,
          resumeSession: _capabilityEnabled(sessionCapabilities, 'resume'),
        );
        final projector = _historyProjector;
        if (projector != null) {
          _restoredHistory = projector.finish();
          _historyProjector = null;
        }
      }
      final sessionState = _requiredMap(response, 'ACP session result');
      _sessionId =
          sessionState['sessionId'] as String? ??
          requestedSessionId ??
          (throw const FormatException(
            'ACP session result requires sessionId',
          ));
      _applySessionState(sessionState);
      await _applyConfiguredOverrides();
    } on Object {
      await _closeAfterInitializationFailure();
      rethrow;
    }
  }

  Future<Object?> _resume(
    AcpRpcProcess rpc,
    String sessionId, {
    required bool loadSession,
    required bool resumeSession,
  }) {
    final params = {
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
    };
    if (loadSession) return rpc.request('session/load', params);
    if (resumeSession) return rpc.request('session/resume', params);
    throw StateError('$provider does not support ACP session resume');
  }

  @override
  Future<void> prompt(String text) => _promptBlocks([
    {'type': 'text', 'text': text},
  ]);

  @override
  Future<void> promptWithAttachments(
    String text,
    List<AgentAttachment> attachments,
  ) => promptWithImagesAndAttachments(text, const [], attachments);

  @override
  Future<void> promptWithImagesAndAttachments(
    String text,
    List<AgentPromptImage> images,
    List<AgentAttachment> attachments,
  ) {
    final history = attachments.where(isChatHistoryAttachment);
    final context = attachments.where(
      (attachment) => !isChatHistoryAttachment(attachment),
    );
    return _promptBlocks([
      for (final attachment in history)
        {'type': 'text', 'text': renderPromptAttachmentAsText(attachment)},
      if (text.trim().isNotEmpty) {'type': 'text', 'text': text.trim()},
      for (final image in images)
        {'type': 'image', 'data': image.data, 'mimeType': image.mimeType},
      for (final attachment in context)
        {'type': 'text', 'text': renderPromptAttachmentAsText(attachment)},
    ]);
  }

  Future<void> _promptBlocks(List<Map<String, Object?>> prompt) async {
    final rpc = _requireRpc();
    final sessionId = _requireSessionId();
    if (_turnActive) {
      throw StateError('A foreground ACP turn is already active');
    }
    _turnActive = true;
    _fallbackAssistantMessageId = null;
    _fallbackReasoningId = null;
    _ompAssistantBuffers.clear();
    final messageId = _uuid.v4();
    unawaited(
      rpc
          .request('session/prompt', {
            'sessionId': sessionId,
            'messageId': messageId,
            'prompt': prompt,
          }, timeout: acpRpcNoTimeout)
          .then(_handlePromptResponse)
          .catchError((Object error) {
            _finishTurn(TurnFailed(error: _requestErrorMessage(error)));
            return null;
          }),
    );
  }

  @override
  Future<void> interrupt() async {
    final rpc = _rpc;
    final sessionId = _sessionId;
    _cancelPendingPermissions();
    if (rpc != null && sessionId != null && _turnActive) {
      rpc.notify('session/cancel', {'sessionId': sessionId});
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _intentionalClose = true;
    await interrupt();
    await _clientRuntime.dispose();
    final rpc = _rpc;
    _rpc = null;
    if (rpc != null) await rpc.close();
    if (!_events.isClosed) await _events.close();
  }

  @override
  Future<AgentProviderNotice?> setMode(String modeId) async {
    if (modeId == _catalog.currentModeId) return null;
    final option = _catalog.selectConfigOption('mode');
    final useConfigOption =
        !_catalog.hasExplicitModes &&
        option != null &&
        _catalog.configOptionContains(option, modeId);
    final result = useConfigOption
        ? await _setConfigOptionRequest(option['id'] as String, modeId)
        : await _requireRpc().request('session/set_mode', {
            'sessionId': _requireSessionId(),
            'modeId': modeId,
          });
    final state = _map(result);
    if (state != null) _applySessionState(state);
    return null;
  }

  @override
  Future<void> setModel(String? modelId) async {
    if (modelId == null || modelId.isEmpty) return;
    if (modelId == _catalog.currentModelId) return;
    final option = _catalog.selectConfigOption('model');
    final useConfigOption =
        !_catalog.hasExplicitModels &&
        option != null &&
        _catalog.configOptionContains(option, modelId);
    final result = useConfigOption
        ? await _setConfigOptionRequest(option['id'] as String, modelId)
        : await _requireRpc().request('session/set_model', {
            'sessionId': _requireSessionId(),
            'modelId': modelId,
          });
    final state = _map(result);
    if (state != null) _applySessionState(state);
  }

  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async {
    if (thinkingOptionId == null || thinkingOptionId.isEmpty) return null;
    if (thinkingOptionId == _catalog.currentThinkingOptionId) return null;
    final option = _catalog.selectConfigOption('thought_level');
    await _setConfigOption(
      option?['id'] as String? ?? 'thought_level',
      thinkingOptionId,
    );
    return null;
  }

  @override
  Future<void> setFeature(String featureId, Object? value) =>
      _setConfigOption(featureId, value);

  Future<void> _setConfigOption(String configId, Object? value) async {
    if (value is! String && value is! bool) {
      throw ArgumentError.value(value, configId, 'must be a string or boolean');
    }
    final result = await _setConfigOptionRequest(configId, value);
    final state = _map(result);
    if (state != null) _applySessionState(state);
  }

  Future<Object?> _setConfigOptionRequest(String configId, Object? value) =>
      _requireRpc().request('session/set_config_option', {
        'sessionId': _requireSessionId(),
        'configId': configId,
        if (value is bool) 'type': 'boolean',
        'value': value,
      });

  @override
  Future<List<AgentSlashCommand>> listCommands() async =>
      List.unmodifiable(_commands);

  Future<Object?> _handleIncoming(
    String method,
    Map<String, Object?> params,
  ) async {
    if (_clientRuntime.supports(method)) {
      return _clientRuntime.handle(method, params);
    }
    switch (method) {
      case 'session/update':
        _handleSessionUpdate(params);
        return const {};
      case 'session/request_permission':
        return _handlePermissionRequest(params);
      default:
        throw UnsupportedError('Unsupported ACP client method: $method');
    }
  }

  void _handleSessionUpdate(Map<String, Object?> params) {
    if (params['sessionId'] != _sessionId) return;
    final update = _map(params['update']);
    if (update == null) return;
    _historyProjector?.addUpdate(update);
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
        final text = _contentText(update['content']);
        if (text != null) {
          final itemId =
              update['messageId'] as String? ??
              (_fallbackAssistantMessageId ??= _uuid.v4());
          if (provider == 'omp') {
            _handleOmpAssistantChunk(itemId, text);
          } else {
            _events.add(AssistantTextDelta(itemId: itemId, text: text));
          }
        }
      case 'agent_thought_chunk':
        final text = _contentText(update['content']);
        if (text != null) {
          final itemId =
              update['messageId'] as String? ??
              (_fallbackReasoningId ??= _uuid.v4());
          _events.add(ReasoningDelta(itemId: itemId, text: text));
        }
      case 'tool_call':
      case 'tool_call_update':
        _handleToolCall(update);
      case 'available_commands_update':
        _commands
          ..clear()
          ..addAll(
            _listOfMaps(update['availableCommands']).map(
              (command) => AgentSlashCommand(
                name: command['name'] as String? ?? '',
                description: command['description'] as String? ?? '',
                argumentHint: _map(command['input'])?['hint'] as String? ?? '',
              ),
            ),
          );
      case 'current_mode_update':
        _applySessionState({
          'modes': {
            ...?_map(_sessionState['modes']),
            'currentModeId': update['currentModeId'],
          },
        });
      case 'config_option_update':
        _applySessionState({'configOptions': update['configOptions']});
      case 'usage_update':
        final usage = _usage(update);
        if (usage != null) _events.add(UsageUpdated(usage: usage));
    }
  }

  Future<Object?> _handlePermissionRequest(Map<String, Object?> params) {
    final toolCall = _map(params['toolCall']) ?? const <String, Object?>{};
    final toolCallId = toolCall['toolCallId'] as String? ?? _uuid.v4();
    final snapshot = _mergeToolSnapshot(toolCallId, toolCall);
    final permissionId = _uuid.v4();
    final completer = Completer<Object?>();
    final options = _listOfMaps(params['options']);
    _pendingPermissions[permissionId] = _PendingAcpPermission(
      options: options,
      completer: completer,
    );
    _events.add(
      PermissionRequested(
        permissionId: permissionId,
        toolName: snapshot.title,
        detail: _toolDetail(snapshot),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) => _resolvePermission(
              permissionId,
              decision,
              selectedActionId: selectedActionId,
            ),
      ),
    );
    return completer.future;
  }

  Future<void> _resolvePermission(
    String permissionId,
    PermissionDecision decision, {
    String? selectedActionId,
  }) async {
    final pending = _pendingPermissions.remove(permissionId);
    if (pending == null || pending.completer.isCompleted) return;
    final preferred = decision == PermissionDecision.allow
        ? const ['allow_once', 'allow_always']
        : const ['reject_once', 'reject_always'];
    Map<String, Object?>? selected = selectedActionId == null
        ? null
        : pending.options.cast<Map<String, Object?>?>().firstWhere(
            (option) => option?['optionId'] == selectedActionId,
            orElse: () => null,
          );
    for (final kind in preferred) {
      if (selected != null) break;
      selected = pending.options.cast<Map<String, Object?>?>().firstWhere(
        (option) => option?['kind'] == kind,
        orElse: () => null,
      );
      if (selected != null) break;
    }
    pending.completer.complete(
      selected == null
          ? {
              'outcome': {'outcome': 'cancelled'},
            }
          : {
              'outcome': {
                'outcome': 'selected',
                'optionId': selected['optionId'],
              },
            },
    );
  }

  void _cancelPendingPermissions() {
    for (final pending in _pendingPermissions.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete({
          'outcome': {'outcome': 'cancelled'},
        });
      }
    }
    _pendingPermissions.clear();
  }

  void _handleToolCall(Map<String, Object?> update) {
    final id = update['toolCallId'];
    if (id is! String || id.isEmpty) return;
    final previous = _toolCalls[id];
    final snapshot = _mergeToolSnapshot(id, update, previous);
    final isNew = previous == null;
    _events.add(
      isNew
          ? ToolCallStarted(
              itemId: id,
              toolName: snapshot.title,
              status: snapshot.status,
              detail: _toolDetail(snapshot),
            )
          : ToolCallUpdated(
              itemId: id,
              toolName: snapshot.title,
              status: snapshot.status,
              detail: _toolDetail(snapshot),
            ),
    );
  }

  _AcpToolSnapshot _mergeToolSnapshot(
    String id,
    Map<String, Object?> update, [
    _AcpToolSnapshot? previous,
  ]) {
    final rawInput = update.containsKey('rawInput')
        ? (_map(update['rawInput']) ?? const <String, Object?>{})
        : previous?.rawInput ?? const <String, Object?>{};
    final snapshot = _AcpToolSnapshot(
      id: id,
      title: update['title'] as String? ?? previous?.title ?? 'Tool',
      status:
          _toolStatus(update['status']) ??
          previous?.status ??
          ToolCallStatus.pending,
      rawInput: rawInput,
      rawOutput: update.containsKey('rawOutput')
          ? update['rawOutput']
          : previous?.rawOutput,
    );
    _toolCalls[id] = snapshot;
    return snapshot;
  }

  ToolCallDetail _toolDetail(_AcpToolSnapshot snapshot) => GenericDetail(
    input: snapshot.rawInput,
    output: snapshot.rawOutput,
    errorMessage: snapshot.status == ToolCallStatus.error
        ? _requestErrorMessage(snapshot.rawOutput)
        : null,
  );

  void _handlePromptResponse(Object? result) {
    final response = _requiredMap(result, 'session/prompt result');
    final usage = _usage(_map(response['usage']) ?? response);
    if (usage != null) _events.add(UsageUpdated(usage: usage));
    final stopReason = response['stopReason'];
    if (stopReason == 'cancelled') {
      _finishTurn(const TurnFailed(error: 'Interrupted'));
    } else {
      _finishTurn(const TurnCompleted());
    }
  }

  void _finishTurn(ProviderEvent event) {
    if (!_turnActive || _events.isClosed) return;
    _turnActive = false;
    _flushOmpAssistantBuffers();
    _fallbackAssistantMessageId = null;
    _fallbackReasoningId = null;
    _events.add(event);
  }

  void _handleOmpAssistantChunk(String itemId, String text) {
    final pending = _ompAssistantBuffers[itemId];
    if (pending == null) {
      final candidate = text.trimLeft();
      if (!ompSystemNoticeOpenTag.startsWith(candidate) &&
          !candidate.startsWith(ompSystemNoticeOpenTag)) {
        _events.add(AssistantTextDelta(itemId: itemId, text: text));
        return;
      }
    }

    final buffer = _ompAssistantBuffers.putIfAbsent(itemId, StringBuffer.new)
      ..write(text);
    final combined = buffer.toString();
    final candidate = combined.trimLeft();
    if (ompSystemNoticeOpenTag.startsWith(candidate)) return;
    if (!candidate.startsWith(ompSystemNoticeOpenTag)) {
      _ompAssistantBuffers.remove(itemId);
      _events.add(AssistantTextDelta(itemId: itemId, text: combined));
      return;
    }

    final closeIndex = combined.indexOf(ompSystemNoticeCloseTag);
    if (closeIndex == -1) return;
    final noticeEnd = closeIndex + ompSystemNoticeCloseTag.length;
    final noticeText = combined.substring(0, noticeEnd);
    final notice = parseOmpSystemNotice(noticeText);
    _ompAssistantBuffers.remove(itemId);
    if (notice != null) {
      _events.add(
        ToolCallStarted(
          itemId: notice.callId,
          toolName: 'task_notification',
          status: notice.status,
          detail: PlainTextDetail(
            label: notice.label,
            text: notice.text,
            icon: 'wrench',
          ),
          errorMessage: notice.errorMessage,
          metadata: notice.metadata,
        ),
      );
    }
    final trailing = combined.substring(noticeEnd);
    if (trailing.trim().isNotEmpty) {
      _events.add(AssistantTextDelta(itemId: itemId, text: trailing));
    }
  }

  void _flushOmpAssistantBuffers() {
    for (final entry in _ompAssistantBuffers.entries) {
      final text = entry.value.toString();
      final candidate = text.trimLeft();
      final isNotice =
          ompSystemNoticeOpenTag.startsWith(candidate) ||
          candidate.startsWith(ompSystemNoticeOpenTag);
      if (!isNotice) {
        _events.add(AssistantTextDelta(itemId: entry.key, text: text));
      }
    }
    _ompAssistantBuffers.clear();
  }

  void _applySessionState(Map<String, Object?> state) {
    for (final key in const ['models', 'modes', 'configOptions']) {
      if (state.containsKey(key)) _sessionState[key] = state[key];
    }
    _catalog = deriveAcpProviderCatalog(
      provider: provider,
      sessionState: _sessionState,
      fallbackModes: fallbackModes,
    );
    final commands = state['availableCommands'];
    if (commands is List) {
      _commands
        ..clear()
        ..addAll(
          _listOfMaps(commands).map(
            (command) => AgentSlashCommand(
              name: command['name'] as String? ?? '',
              description: command['description'] as String? ?? '',
              argumentHint: _map(command['input'])?['hint'] as String? ?? '',
            ),
          ),
        );
    }
  }

  Future<void> _applyConfiguredOverrides() async {
    if (modeId?.isNotEmpty == true) await setMode(modeId!);
    if (model.isNotEmpty) await setModel(model);
    if (thinkingOptionId?.isNotEmpty == true) {
      await setThinkingOption(thinkingOptionId);
    }
    for (final entry in featureValues.entries) {
      await setFeature(entry.key, entry.value);
    }
  }

  AcpRpcProcess _requireRpc() =>
      _rpc ?? (throw StateError('$provider ACP session is not initialized'));

  String _requireSessionId() =>
      _sessionId ??
      (throw StateError('$provider ACP session did not expose a session id'));

  Future<void> _closeAfterInitializationFailure() async {
    _intentionalClose = true;
    try {
      await _clientRuntime.dispose();
    } on Object {
      // The ACP initialization failure is authoritative. Continue to the
      // provider process cleanup even if a client-owned terminal fails to
      // release.
    }
    final rpc = _rpc;
    _rpc = null;
    if (rpc != null) {
      try {
        await rpc.close();
      } on Object {
        // Preserve the original session/new, session/load, or handshake error.
      }
    }
  }
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, Object?> _requiredMap(Object? value, String label) =>
    _map(value) ?? (throw FormatException('$label must be an object'));

List<Map<String, Object?>> _listOfMaps(Object? value) => value is List
    ? value.map(_map).whereType<Map<String, Object?>>().toList()
    : const [];

String? _contentText(Object? value) {
  final content = _map(value);
  if (content?['type'] == 'text') return content?['text'] as String?;
  if (content?['type'] == 'resource') {
    final resource = _map(content?['resource']);
    return resource?['text'] as String?;
  }
  return null;
}

ToolCallStatus? _toolStatus(Object? value) => switch (value) {
  'pending' => ToolCallStatus.pending,
  'in_progress' => ToolCallStatus.running,
  'completed' => ToolCallStatus.success,
  'failed' => ToolCallStatus.error,
  _ => null,
};

AgentUsage? _usage(Map<String, Object?> value) {
  final input = (value['inputTokens'] as num?)?.toInt();
  final output = (value['outputTokens'] as num?)?.toInt();
  final cached = (value['cachedReadTokens'] as num?)?.toInt();
  if (input == null && output == null && cached == null) return null;
  return AgentUsage(
    inputTokens: input,
    outputTokens: output,
    cachedInputTokens: cached,
  );
}

String _requestErrorMessage(Object? error) {
  if (error is AcpRpcError) return error.message;
  if (error is Error) return error.toString();
  final record = _map(error);
  return record?['message'] as String? ?? error.toString();
}

Future<Map<String, Object?>> _initializeAcp(
  AcpRpcProcess rpc,
  Map<String, Object?> clientCapabilities,
) async => _requiredMap(
  await rpc.request('initialize', {
    'protocolVersion': 1,
    'clientCapabilities': clientCapabilities,
    'clientInfo': {'name': 'Tinyrack', 'version': '0.2.0'},
  }),
  'initialize result',
);

bool _capabilityEnabled(Map<String, Object?> capabilities, String key) =>
    capabilities.containsKey(key) &&
    capabilities[key] != null &&
    capabilities[key] != false;

ImportableProviderSession _importableSession(Map<String, Object?> row) {
  final sessionId = row['sessionId'];
  final cwd = row['cwd'];
  final title = row['title'];
  final updatedAt = row['updatedAt'];
  if (sessionId is! String || sessionId.isEmpty) {
    throw const FormatException('ACP session requires sessionId');
  }
  if (cwd is! String || cwd.isEmpty) {
    throw const FormatException('ACP session requires cwd');
  }
  if (title != null && title is! String) {
    throw const FormatException('ACP session title must be a string');
  }
  if (updatedAt != null && updatedAt is! String) {
    throw const FormatException('ACP session updatedAt must be a string');
  }
  return ImportableProviderSession(
    providerHandleId: sessionId,
    cwd: cwd,
    title: title as String?,
    firstPromptPreview: null,
    lastPromptPreview: null,
    lastActivityAt: updatedAt == null
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : DateTime.parse(updatedAt as String).toUtc(),
  );
}
