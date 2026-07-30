import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_session.dart';
import 'codex_app_server_client.dart';
import 'codex_command_catalog.dart';
import 'codex_history.dart';
import 'jsonl_rpc_process.dart';

const codexTurnStartTimeout = Duration(seconds: 90);
const codexInterruptTimeout = Duration(seconds: 2);

Map<String, Object?> normalizeCodexOutputSchema(Map<String, Object?> schema) {
  final normalized = _normalizeCodexOutputSchemaNode(schema, r'$');
  if (normalized is! Map<String, Object?> ||
      !_isCodexObjectSchema(normalized)) {
    throw StateError('Codex structured outputs require a root object schema.');
  }
  return normalized;
}

Object? _normalizeCodexOutputSchemaNode(Object? schema, String schemaPath) {
  if (schema is List) {
    return [
      for (var index = 0; index < schema.length; index++)
        _normalizeCodexOutputSchemaNode(schema[index], '$schemaPath[$index]'),
    ];
  }
  if (schema is! Map) return schema;
  final normalized = <String, Object?>{
    for (final entry in schema.entries)
      entry.key as String: _normalizeCodexOutputSchemaNode(
        entry.value,
        '$schemaPath.${entry.key}',
      ),
  };
  if (!_isCodexObjectSchema(normalized)) return normalized;
  if (!normalized.containsKey('additionalProperties')) {
    normalized['additionalProperties'] = false;
  } else if (normalized['additionalProperties'] != false) {
    throw StateError(
      'Codex structured outputs require $schemaPath to set '
      'additionalProperties to false for object schemas.',
    );
  }
  final properties = normalized['properties'];
  if (properties is! Map) return normalized;
  final required = <String>{
    ...?((normalized['required'] as List?)?.whereType<String>()),
    ...properties.keys.cast<String>(),
  };
  normalized['required'] = required.toList(growable: false);
  return normalized;
}

bool _isCodexObjectSchema(Map<String, Object?> schema) {
  final type = schema['type'];
  return schema['properties'] is Map ||
      type == 'object' ||
      (type is List && type.contains('object'));
}

ProviderSubagentStatus _providerSubagentStatus(ToolCallStatus status) =>
    switch (status) {
      ToolCallStatus.success => ProviderSubagentStatus.completed,
      ToolCallStatus.error => ProviderSubagentStatus.failed,
      ToolCallStatus.canceled => ProviderSubagentStatus.canceled,
      ToolCallStatus.pending ||
      ToolCallStatus.running => ProviderSubagentStatus.running,
    };

final class CodexRuntimeConfig {
  const CodexRuntimeConfig({
    required this.cwd,
    required this.modeId,
    this.model,
    this.thinkingOptionId,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.systemPrompt,
    this.daemonAppendSystemPrompt,
    this.innerConfig,
    this.serviceTier,
    this.ephemeral = false,
  });

  final String cwd;
  final String modeId;
  final String? model;
  final String? thinkingOptionId;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final String? systemPrompt;
  final String? daemonAppendSystemPrompt;
  final Map<String, Object?>? innerConfig;
  final String? serviceTier;
  final bool ephemeral;
}

final class CodexModePreset {
  const CodexModePreset({
    required this.approvalPolicy,
    required this.sandbox,
    this.networkAccess,
    this.approvalsReviewer,
  });

  final String approvalPolicy;
  final String sandbox;
  final bool? networkAccess;
  final String? approvalsReviewer;
}

const codexModePresets = <String, CodexModePreset>{
  'read-only': CodexModePreset(
    approvalPolicy: 'on-request',
    sandbox: 'read-only',
  ),
  'auto': CodexModePreset(
    approvalPolicy: 'on-request',
    sandbox: 'workspace-write',
  ),
  'auto-review': CodexModePreset(
    approvalPolicy: 'on-request',
    sandbox: 'workspace-write',
    approvalsReviewer: 'auto_review',
  ),
  'full-access': CodexModePreset(
    approvalPolicy: 'never',
    sandbox: 'danger-full-access',
    networkAccess: true,
  ),
};

final class CodexSessionRuntime {
  CodexSessionRuntime({
    required CodexAppServerConnection client,
    required CodexRuntimeConfig config,
    String? resumeThreadId,
  }) : _client = client,
       _config = config,
       _currentThreadId = resumeThreadId,
       _modeId = config.modeId,
       _model = _normalizeValue(config.model),
       _thinkingOptionId = _normalizeThinking(config.thinkingOptionId) {
    if (!codexModePresets.containsKey(config.modeId)) {
      throw ArgumentError.value(
        config.modeId,
        'modeId',
        'Valid Codex modes are: ${codexModePresets.keys.join(', ')}',
      );
    }
    _client.setNotificationHandler(_handleNotification);
  }

  final CodexAppServerConnection _client;
  final CodexRuntimeConfig _config;
  final Set<CodexAppServerNotificationHandler> _notificationSubscribers = {};

  String? _currentThreadId;
  String? _currentTurnId;
  var _foregroundTurnActive = false;
  String _modeId;
  String? _model;
  String? _thinkingOptionId;
  var _connected = false;
  List<TimelineItem>? _restoredHistory;
  final List<RestoredProviderSubagent> _restoredProviderSubagents = [];

  String? get threadId => _currentThreadId;
  String? get turnId => _currentTurnId;
  String? get model => _model;
  String? get thinkingOptionId => _thinkingOptionId;
  String get modeId => _modeId;
  bool get isConnected => _connected;
  bool get isTurnActive => _foregroundTurnActive;
  List<TimelineItem>? get restoredHistory => _restoredHistory == null
      ? null
      : List<TimelineItem>.unmodifiable(_restoredHistory!);
  List<RestoredProviderSubagent> get restoredProviderSubagents =>
      List.unmodifiable(_restoredProviderSubagents);

  void Function() onNotification(CodexAppServerNotificationHandler callback) {
    _notificationSubscribers.add(callback);
    return () => _notificationSubscribers.remove(callback);
  }

  void setMode(String modeId) {
    if (!codexModePresets.containsKey(modeId)) {
      throw ArgumentError.value(modeId, 'modeId', 'Unknown Codex mode');
    }
    _modeId = modeId;
  }

  void setModel(String? modelId) {
    _model = _normalizeValue(modelId);
  }

  void setThinkingOption(String? thinkingOptionId) {
    _thinkingOptionId = _normalizeThinking(thinkingOptionId);
  }

  void setRequestHandler(String method, CodexAppServerRequestHandler handler) {
    _client.setRequestHandler(method, handler);
  }

  void Function() onExit(void Function(JsonlRpcExit exit) callback) {
    return _client.onExit(callback);
  }

  Future<void> connect() async {
    if (_connected) {
      return;
    }
    try {
      await _client.request('initialize', codexInitializeParams);
      _client.notify('initialized', <String, Object?>{});
      if (_currentThreadId != null) {
        await ensureThreadLoaded();
        final projection = projectCodexThreadHistoryWithSubagents(
          await _readThread(_currentThreadId!),
          cwd: _config.cwd,
        );
        _restoredHistory = projection.timeline;
        await _loadRestoredProviderSubagents(projection.subagentRoutes);
      }
      _connected = true;
    } on Object {
      try {
        await close();
      } on Object {
        // The connection failure is authoritative. Cleanup is best effort and
        // must not replace the provider error that explains why startup failed.
      }
      rethrow;
    }
  }

  Future<List<AgentSlashCommand>> listCommands() async {
    if (!_connected) await connect();
    return listCodexCommands(
      cwd: _config.cwd,
      request: (method, params) => _client.request(method, params),
    );
  }

  Future<Object?> _readThread(String threadId) => _client.request(
    'thread/read',
    {'threadId': threadId, 'includeTurns': true},
  );

  Future<void> _loadRestoredProviderSubagents(
    List<CodexPersistedSubagentRoute> rootRoutes,
  ) async {
    _restoredProviderSubagents.clear();
    final queue = List<CodexPersistedSubagentRoute>.of(rootRoutes);
    final visited = <String>{if (_currentThreadId case final id?) id};
    while (queue.isNotEmpty && visited.length < 100) {
      final route = queue.removeAt(0);
      if (!visited.add(route.childThreadId)) {
        continue;
      }
      try {
        final child = projectCodexThreadHistoryWithSubagents(
          await _readThread(route.childThreadId),
          cwd: _config.cwd,
        );
        final detail = route.toolCall.detail as SubAgentDetail;
        _restoredProviderSubagents.add(
          RestoredProviderSubagent(
            id: route.childThreadId,
            title: detail.subAgentType,
            description: detail.description,
            status: _providerSubagentStatus(route.toolCall.status),
            toolCallId: route.toolCall.id,
            cwd: _config.cwd,
            timeline: List.unmodifiable(child.timeline),
          ),
        );
        queue.addAll(child.subagentRoutes);
      } on Object {
        // A single unreadable child must not prevent the parent conversation
        // from resuming; live notifications can still repopulate it later.
      }
    }
  }

  Future<void> ensureThreadLoaded() async {
    final threadId = _currentThreadId;
    if (threadId == null) {
      return;
    }
    final loaded = _asRecord(
      await _client.request('thread/loaded/list', <String, Object?>{}),
    );
    final ids = loaded?['data'];
    if (ids is List && ids.contains(threadId)) {
      return;
    }

    final params = <String, Object?>{'threadId': threadId};
    final instructions = _composeInstructions();
    if (instructions != null) {
      params['developerInstructions'] = instructions;
    }
    if (_config.innerConfig case final innerConfig?) {
      params['config'] = innerConfig;
    }
    try {
      await _client.request('thread/resume', params);
    } on Object catch (error) {
      throw StateError('Failed to resume Codex thread $threadId: $error');
    }
  }

  Future<String> ensureThread() async {
    final existing = _currentThreadId;
    if (existing != null) {
      return existing;
    }
    await _resolveModelAndThinking();
    final selectedModel = _model;
    if (selectedModel == null) {
      throw StateError('Unable to resolve Codex model');
    }

    final preset = codexModePresets[_modeId]!;
    final params = <String, Object?>{
      'model': selectedModel,
      'cwd': _config.cwd,
      'approvalPolicy': _config.approvalPolicy ?? preset.approvalPolicy,
      'sandbox': _config.sandboxMode ?? preset.sandbox,
    };
    final instructions = _composeInstructions();
    if (instructions != null) {
      params['developerInstructions'] = instructions;
    }
    if (_config.innerConfig case final innerConfig?) {
      params['config'] = innerConfig;
    }
    if (_config.ephemeral) {
      params['ephemeral'] = true;
    }
    if (preset.approvalsReviewer case final approvalsReviewer?) {
      params['approvalsReviewer'] = approvalsReviewer;
    }

    final response = _asRecord(await _client.request('thread/start', params));
    final thread = _asRecord(response?['thread']);
    final threadId = thread?['id'];
    if (threadId is! String) {
      throw StateError('Codex app-server did not return thread id');
    }
    _currentThreadId = threadId;
    return threadId;
  }

  Future<void> startTurn(String prompt) async {
    return startTurnInput([
      {'type': 'text', 'text': prompt, 'text_elements': <Object?>[]},
    ]);
  }

  Future<void> startTurnInput(
    List<Map<String, Object?>> input, {
    Map<String, Object?>? outputSchema,
  }) async {
    if (_foregroundTurnActive) {
      throw StateError('A Codex foreground turn is already active');
    }
    await connect();
    final threadId = _currentThreadId == null
        ? await ensureThread()
        : _currentThreadId!;
    final preset = codexModePresets[_modeId]!;
    final sandbox = _config.sandboxMode ?? preset.sandbox;
    final params = <String, Object?>{
      'threadId': threadId,
      'input': input,
      'approvalPolicy': _config.approvalPolicy ?? preset.approvalPolicy,
      'sandboxPolicy': _sandboxPolicy(
        sandbox,
        _config.networkAccess ?? preset.networkAccess,
      ),
      if (_model != null) 'model': _model,
      if (_thinkingOptionId != null) 'effort': _thinkingOptionId,
      if (_config.serviceTier != null) 'serviceTier': _config.serviceTier,
      if (_config.cwd.isNotEmpty) 'cwd': _config.cwd,
      if (_composeInstructions() case final instructions?)
        'developerInstructions': instructions,
      if (_config.innerConfig case final innerConfig?) 'config': innerConfig,
      if (preset.approvalsReviewer case final approvalsReviewer?)
        'approvalsReviewer': approvalsReviewer,
      if (outputSchema != null)
        'outputSchema': normalizeCodexOutputSchema(outputSchema),
    };
    _currentTurnId = null;
    _foregroundTurnActive = true;
    try {
      await _client.request('turn/start', params, codexTurnStartTimeout);
    } on Object {
      _foregroundTurnActive = false;
      rethrow;
    }
  }

  Future<void> interrupt() async {
    final threadId = _currentThreadId;
    if (threadId == null) {
      throw StateError(
        'Cannot interrupt Codex before the active thread is initialized',
      );
    }
    final turnId = _currentTurnId;
    if (turnId == null) {
      throw StateError(
        'Cannot interrupt Codex before turn/started identifies the active turn',
      );
    }
    await _client.request('turn/interrupt', {
      'threadId': threadId,
      'turnId': turnId,
    }, codexInterruptTimeout);
  }

  Future<CodexThreadForkResponse> fork({
    bool excludeTurns = false,
    bool persistExtendedHistory = true,
  }) async {
    final threadId = _currentThreadId;
    if (threadId == null) {
      throw StateError('Codex thread is not ready for fork');
    }
    return _client.forkThread(
      CodexThreadForkParams(
        threadId: threadId,
        cwd: _config.cwd,
        model: _model,
        serviceTier: _config.serviceTier,
        excludeTurns: excludeTurns,
        persistExtendedHistory: persistExtendedHistory,
        includeNullValues: true,
      ),
    );
  }

  Future<CodexThreadRollbackResponse> rollback({
    required String threadId,
    required int numTurns,
  }) async {
    final response = await _client.rollbackThread(
      CodexThreadRollbackParams(threadId: threadId, numTurns: numTurns),
    );
    _currentThreadId = response.thread.id;
    _currentTurnId = null;
    _foregroundTurnActive = false;
    return response;
  }

  Future<void> close() async {
    _connected = false;
    _currentTurnId = null;
    _foregroundTurnActive = false;
    await _client.dispose();
  }

  Future<void> _resolveModelAndThinking() async {
    if (_model != null && _thinkingOptionId != null) {
      return;
    }
    final saved = await _readConfigDefaults(
      'getUserSavedConfig',
      camelCase: true,
    );
    _model ??= saved.$1;
    _thinkingOptionId ??= saved.$2;

    if (_model == null || _thinkingOptionId == null) {
      final config = await _readConfigDefaults('config/read');
      _model ??= config.$1;
      _thinkingOptionId ??= config.$2;
    }
    if (_model != null && _thinkingOptionId != null) {
      return;
    }

    final response = _asRecord(
      await _client.request('model/list', <String, Object?>{}),
    );
    final rawModels = response?['data'];
    if (rawModels is! List) {
      throw StateError('No models available from Codex app-server');
    }
    final models = rawModels
        .map(_asRecord)
        .whereType<Map<String, Object?>>()
        .where((model) => model['id'] is String)
        .toList(growable: false);
    if (models.isEmpty) {
      throw StateError('No models available from Codex app-server');
    }
    final selected =
        models.where((model) => model['id'] == _model).firstOrNull ??
        models.where((model) => model['isDefault'] == true).firstOrNull ??
        models.first;
    _model ??= selected['id']! as String;
    _thinkingOptionId ??= _normalizeThinking(
      selected['defaultReasoningEffort'] as String?,
    );
  }

  Future<(String?, String?)> _readConfigDefaults(
    String method, {
    bool camelCase = false,
  }) async {
    try {
      final response = _asRecord(
        await _client.request(method, <String, Object?>{}),
      );
      final config = _asRecord(response?['config']);
      return (
        _normalizeValue(config?['model'] as String?),
        _normalizeThinking(
          config?[camelCase ? 'modelReasoningEffort' : 'model_reasoning_effort']
              as String?,
        ),
      );
    } on Object {
      return (null, null);
    }
  }

  void _handleNotification(String method, Object? params) {
    final record = _asRecord(params);
    if (method == 'thread/started') {
      final thread = _asRecord(record?['thread']);
      if (thread?['id'] is String) {
        _currentThreadId = thread!['id']! as String;
      }
    } else if (method == 'turn/started') {
      final turn = _asRecord(record?['turn']);
      if (turn?['id'] is String) {
        _currentTurnId = turn!['id']! as String;
      }
    } else if (method == 'turn/completed') {
      _currentTurnId = null;
      _foregroundTurnActive = false;
    }
    for (final subscriber in _notificationSubscribers.toList(growable: false)) {
      subscriber(method, params);
    }
  }

  String? _composeInstructions() {
    final parts = [
      _config.systemPrompt?.trim(),
      _config.daemonAppendSystemPrompt?.trim(),
    ].whereType<String>().where((part) => part.isNotEmpty);
    final result = parts.join('\n\n');
    return result.isEmpty ? null : result;
  }
}

const codexInitializeParams = <String, Object?>{
  'clientInfo': {
    'name': 'codex_app_server_daemon',
    'title': 'Codex App Server Daemon',
    'version': '0.0.0',
  },
  'capabilities': {
    'experimentalApi': true,
    'mcpServerOpenaiFormElicitation': true,
  },
};

Map<String, Object?> _sandboxPolicy(String type, bool? networkAccess) {
  return switch (type) {
    'read-only' => {'type': 'readOnly'},
    'danger-full-access' => {'type': 'dangerFullAccess'},
    _ => {'type': 'workspaceWrite', 'networkAccess': networkAccess ?? false},
  };
}

Map<String, Object?>? _asRecord(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      return null;
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _normalizeValue(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _normalizeThinking(String? value) {
  final normalized = _normalizeValue(value);
  return normalized == 'default' ? null : normalized;
}
