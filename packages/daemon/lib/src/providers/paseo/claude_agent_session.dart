import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import '../agent_session.dart';
import '../provider_event.dart';
import 'claude_image_output.dart';
import 'claude_process_config.dart';
import 'claude_stream_connection.dart';
import 'provider_notices.dart';
import 'jsonl_rpc_process.dart';

typedef ClaudeConnectionRestarter =
    Future<ClaudeStreamConnection> Function(ClaudeProcessConfig config);

final class ClaudeAgentSession
    implements
        ConfigurableAgentSession,
        HistoryRestoringAgentSession,
        ProviderSubagentRestoringAgentSession,
        ImagePromptAgentSession,
        CommandListingAgentSession {
  ClaudeAgentSession(
    ClaudeStreamConnection connection, {
    ClaudeProcessConfig? config,
    ClaudeConnectionRestarter? restartConnection,
    List<TimelineItem>? restoredHistory,
    List<RestoredProviderSubagent> restoredProviderSubagents = const [],
  }) : _connection = connection,
       _config =
           config ??
           const ClaudeProcessConfig(
             cwd: '',
             permissionMode: 'default',
             fastMode: false,
           ),
       _restartConnection = restartConnection,
       _restoredProviderSubagents = List.unmodifiable(
         restoredProviderSubagents,
       ) {
    _restoredHistory = restoredHistory == null
        ? null
        : List<TimelineItem>.unmodifiable(restoredHistory);
    _bindConnection(connection);
  }

  ClaudeStreamConnection _connection;
  ClaudeProcessConfig _config;
  final ClaudeConnectionRestarter? _restartConnection;
  List<TimelineItem>? _restoredHistory;
  final List<RestoredProviderSubagent> _restoredProviderSubagents;
  final StreamController<ProviderEvent> _events =
      StreamController<ProviderEvent>.broadcast();
  final Map<int, _ClaudeBlock> _blocks = {};
  final Map<String, ({String name, Map<String, Object?> input})> _tools = {};
  final Map<String, Completer<Map<String, Object?>>> _controlRequests = {};
  final Completer<List<AgentSlashCommand>> _initialCommands = Completer();
  List<AgentSlashCommand>? _commands;
  Object? _commandInitializationError;
  late void Function() _unsubscribeMessage;
  late void Function() _unsubscribeExit;
  String? _sessionId;
  Future<void>? _restartFuture;
  var _restartNeeded = false;
  var _turnActive = false;
  var _requestSequence = 0;
  var _disposed = false;
  var _exited = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  List<TimelineItem>? get restoredHistory => _restoredHistory;

  @override
  List<RestoredProviderSubagent> get restoredProviderSubagents =>
      _restoredProviderSubagents;

  void initialize() {
    unawaited(
      _requestControl({
            'subtype': 'initialize',
            'systemPrompt': <String>[],
            'appendSystemPrompt': '',
          })
          .then((response) {
            _replaceCommands(response['commands']);
          })
          .catchError((Object error, StackTrace stackTrace) {
            if (!_disposed && !_initialCommands.isCompleted) {
              _commandInitializationError = error;
              _initialCommands.complete(const []);
            }
          }),
    );
  }

  @override
  Future<List<AgentSlashCommand>> listCommands() async {
    final commands = _commands ?? await _initialCommands.future;
    if (_commandInitializationError case final error?) throw error;
    return List.unmodifiable(commands);
  }

  @override
  Future<void> prompt(String text) => _promptContent([
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
    final chatHistory = <TextAgentAttachment>[];
    final context = <TextAgentAttachment>[];
    for (final attachment in attachments.whereType<TextAgentAttachment>()) {
      if (attachment.contextKind == 'chat_history') {
        chatHistory.add(attachment);
      } else {
        context.add(attachment);
      }
    }
    return _promptContent([
      for (final attachment in chatHistory)
        {'type': 'text', 'text': attachment.text},
      if (text.trim().isNotEmpty) {'type': 'text', 'text': text.trim()},
      for (final image in images)
        if (_claudeImageMimeTypes.contains(image.mimeType))
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': image.mimeType,
              'data': image.data,
            },
          },
      for (final attachment in context)
        {'type': 'text', 'text': attachment.text},
    ]);
  }

  Future<void> _promptContent(List<Map<String, Object?>> content) async {
    _ensureActive();
    if (_turnActive) {
      throw StateError('A Claude turn is already active');
    }
    await _ensureCurrentConnection();
    _ensureActive();
    _connection.send({
      'type': 'user',
      'message': {'role': 'user', 'content': content},
      'parent_tool_use_id': null,
      'session_id': '',
    });
    _turnActive = true;
  }

  @override
  Future<void> interrupt() async {
    _ensureActive();
    _sendControl({'subtype': 'interrupt'});
  }

  @override
  Future<AgentProviderNotice?> setMode(String modeId) async {
    _ensureActive();
    _config = ClaudeProcessConfig(
      cwd: _config.cwd,
      permissionMode: modeId,
      fastMode: _config.fastMode,
      model: _config.model,
      thinkingOptionId: _config.thinkingOptionId,
      systemPrompt: _config.systemPrompt,
      sessionId: _config.sessionId,
    );
    _sendControl({'subtype': 'set_permission_mode', 'mode': modeId});
    return null;
  }

  @override
  Future<void> setModel(String? modelId) async {
    _ensureActive();
    final model = _normalize(modelId);
    _config = ClaudeProcessConfig(
      cwd: _config.cwd,
      permissionMode: _config.permissionMode,
      fastMode: _config.fastMode,
      model: model,
      thinkingOptionId: _config.thinkingOptionId,
      systemPrompt: _config.systemPrompt,
      sessionId: _config.sessionId,
    );
    _sendControl({'subtype': 'set_model', 'model': model});
  }

  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async {
    _ensureActive();
    final thinking = normalizeClaudeThinkingOption(thinkingOptionId);
    if (_config.thinkingOptionId == thinking) {
      return null;
    }
    _config = ClaudeProcessConfig(
      cwd: _config.cwd,
      permissionMode: _config.permissionMode,
      fastMode: _config.fastMode,
      model: _config.model,
      thinkingOptionId: thinking,
      systemPrompt: _config.systemPrompt,
      sessionId: _config.sessionId,
    );
    _restartNeeded = true;
    return _turnActive ? thinkingAppliesNextTurnNotice : null;
  }

  @override
  Future<void> setFeature(String featureId, Object? value) async {
    _ensureActive();
    if (featureId != 'fast_mode') {
      throw UnsupportedError('Unknown Claude feature: $featureId');
    }
    final enabled = value == true;
    _config = ClaudeProcessConfig(
      cwd: _config.cwd,
      permissionMode: _config.permissionMode,
      fastMode: enabled,
      model: _config.model,
      thinkingOptionId: _config.thinkingOptionId,
      systemPrompt: _config.systemPrompt,
      sessionId: _config.sessionId,
    );
    _sendControl({
      'subtype': 'apply_flag_settings',
      'settings': {'fastMode': enabled},
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _unsubscribeMessage();
    _unsubscribeExit();
    for (final request in _controlRequests.values) {
      if (!request.isCompleted) {
        request.completeError(StateError('Claude session is disposed'));
      }
    }
    _controlRequests.clear();
    await _connection.dispose();
    if (!_events.isClosed) {
      if (!_exited) _events.add(const SessionExited());
      await _events.close();
    }
  }

  void _handleMessage(Map<String, Object?> message) {
    if (_disposed) return;
    switch (message['type']) {
      case 'system':
        if (message['subtype'] == 'init') {
          final sessionId = message['session_id'];
          if (sessionId is String && sessionId.isNotEmpty) {
            _sessionId = sessionId;
            _emit(SessionStarted(sessionId: sessionId));
          }
        } else if (message['subtype'] == 'commands_changed') {
          _replaceCommands(message['commands']);
        }
      case 'stream_event':
        _handleStreamEvent(_record(message['event']));
      case 'assistant':
        _handleAssistant(_record(message['message']));
      case 'user':
        _handleUser(_record(message['message']));
      case 'result':
        _handleResult(message);
      case 'control_request':
        _handleControlRequest(message);
      case 'control_response':
        _handleControlResponse(message);
    }
  }

  void _handleStreamEvent(Map<String, Object?>? event) {
    if (event == null) return;
    final index = (event['index'] as num?)?.toInt();
    switch (event['type']) {
      case 'content_block_start':
        if (index == null) return;
        final block = _record(event['content_block']);
        final type = block?['type'];
        final id = block?['id'] is String
            ? block!['id']! as String
            : 'claude-block-$index';
        _blocks[index] = _ClaudeBlock(id: id, type: type as String? ?? '');
        if (type == 'tool_use') {
          final name = block?['name'] as String? ?? 'tool';
          final input = _record(block?['input']) ?? const {};
          _blocks[index]!.toolName = name;
          _blocks[index]!.toolInput = input;
          _tools[id] = (name: name, input: input);
          _emit(
            ToolCallStarted(
              itemId: id,
              toolName: name,
              status: ToolCallStatus.running,
              detail: GenericDetail(input: input),
            ),
          );
        }
      case 'content_block_delta':
        if (index == null) return;
        final block = _blocks[index];
        final delta = _record(event['delta']);
        if (block == null || delta == null) return;
        final partialJson = delta['partial_json'];
        if (partialJson is String && partialJson.isNotEmpty) {
          block.inputJson.write(partialJson);
          return;
        }
        final text = delta['text'] ?? delta['thinking'];
        if (text is! String || text.isEmpty) return;
        block.buffer.write(text);
        _emit(
          block.type == 'thinking'
              ? ReasoningDelta(itemId: block.id, text: text)
              : AssistantTextDelta(itemId: block.id, text: text),
        );
      case 'content_block_stop':
        if (index == null) return;
        final block = _blocks.remove(index);
        if (block == null) return;
        final text = block.buffer.toString();
        if (block.type == 'thinking') {
          _emit(ReasoningComplete(itemId: block.id, fullText: text));
        } else if (block.type == 'text') {
          _emit(AssistantMessageComplete(itemId: block.id, fullText: text));
        } else if (block.type == 'tool_use') {
          final input =
              _decodeInput(block.inputJson.toString()) ??
              block.toolInput ??
              const {};
          final name = block.toolName ?? 'tool';
          _tools[block.id] = (name: name, input: input);
          _emit(
            ToolCallUpdated(
              itemId: block.id,
              toolName: name,
              status: ToolCallStatus.running,
              detail: GenericDetail(input: input),
            ),
          );
        }
    }
  }

  void _handleAssistant(Map<String, Object?>? message) {
    final content = message?['content'];
    if (content is! List) return;
    for (final value in content) {
      final block = _record(value);
      if (block == null) continue;
      final id = block['id'] as String? ?? 'claude-${_requestSequence++}';
      if (block['type'] == 'tool_use') {
        final name = block['name'] as String? ?? 'tool';
        final input = _record(block['input']) ?? const {};
        final existing = _tools.containsKey(id);
        _tools[id] = (name: name, input: input);
        _emit(
          existing
              ? ToolCallUpdated(
                  itemId: id,
                  toolName: name,
                  status: ToolCallStatus.running,
                  detail: GenericDetail(input: input),
                )
              : ToolCallStarted(
                  itemId: id,
                  toolName: name,
                  status: ToolCallStatus.running,
                  detail: GenericDetail(input: input),
                ),
        );
      }
    }
  }

  void _handleUser(Map<String, Object?>? message) {
    final content = message?['content'];
    if (content is! List) return;
    for (final value in content) {
      final block = _record(value);
      if (block?['type'] != 'tool_result') continue;
      final toolUseId = block?['tool_use_id'];
      if (toolUseId is! String || toolUseId.isEmpty) continue;
      final tool = _tools[toolUseId];
      final failed = block?['is_error'] == true;
      final resultContent = splitClaudeToolResultContent(block?['content']);
      final output = _contentText(resultContent.textContent);
      _emit(
        ToolCallUpdated(
          itemId: toolUseId,
          toolName: tool?.name ?? 'tool',
          status: failed ? ToolCallStatus.error : ToolCallStatus.success,
          detail: GenericDetail(
            input: tool?.input ?? const {},
            output: output,
            errorMessage: failed ? output : null,
          ),
        ),
      );
      for (var index = 0; index < resultContent.imageMarkdown.length; index++) {
        _emit(
          AssistantMessageComplete(
            itemId: '$toolUseId-image-$index',
            fullText: resultContent.imageMarkdown[index],
          ),
        );
      }
    }
  }

  void _handleResult(Map<String, Object?> message) {
    final usage = _record(message['usage']);
    if (usage != null) {
      final input = (usage['input_tokens'] as num?)?.toInt();
      final cached =
          ((usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0) +
          ((usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0);
      _emit(
        UsageUpdated(
          usage: AgentUsage(
            inputTokens: input,
            cachedInputTokens: cached == 0 ? null : cached,
            outputTokens: (usage['output_tokens'] as num?)?.toInt(),
            totalCostUsd: (message['total_cost_usd'] as num?)?.toDouble(),
          ),
        ),
      );
    }
    final isError =
        message['is_error'] == true ||
        message['subtype'] == 'error_during_execution';
    if (isError) {
      final errors = message['errors'];
      _emit(
        TurnFailed(
          error: errors is List && errors.isNotEmpty
              ? errors.join('; ')
              : (message['result'] as String? ?? 'Claude turn failed'),
        ),
      );
    } else {
      _emit(const TurnCompleted());
    }
    _turnActive = false;
    _blocks.clear();
    _tools.clear();
  }

  void _handleControlRequest(Map<String, Object?> message) {
    final requestId = message['request_id'];
    final request = _record(message['request']);
    if (requestId is! String || request?['subtype'] != 'can_use_tool') return;
    final name = request?['tool_name'] as String? ?? 'tool';
    final input = _record(request?['input']) ?? const {};
    _emit(
      PermissionRequested(
        permissionId: requestId,
        toolName: name,
        detail: GenericDetail(input: input),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {
              final response = decision == PermissionDecision.allow
                  ? <String, Object?>{
                      'behavior': 'allow',
                      'updatedInput': updatedInput ?? input,
                      if (updatedPermissions != null)
                        'updatedPermissions': updatedPermissions,
                      if (request?['tool_use_id'] case final String toolUseId)
                        'toolUseID': toolUseId,
                    }
                  : <String, Object?>{
                      'behavior': 'deny',
                      'message': message ?? 'Permission denied',
                      'interrupt': interrupt ?? false,
                    };
              _connection.send({
                'type': 'control_response',
                'response': {
                  'subtype': 'success',
                  'request_id': requestId,
                  'response': response,
                },
              });
            },
      ),
    );
  }

  void _sendControl(Map<String, Object?> request) {
    _connection.send({
      'type': 'control_request',
      'request_id': 'tinyrack-${_requestSequence++}',
      'request': request,
    });
  }

  Future<Map<String, Object?>> _requestControl(Map<String, Object?> request) {
    final requestId = 'tinyrack-${_requestSequence++}';
    final completer = Completer<Map<String, Object?>>();
    _controlRequests[requestId] = completer;
    _connection.send({
      'type': 'control_request',
      'request_id': requestId,
      'request': request,
    });
    return completer.future;
  }

  void _handleControlResponse(Map<String, Object?> message) {
    final response = _record(message['response']);
    final requestId = response?['request_id'];
    if (requestId is! String) return;
    final completer = _controlRequests.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (response?['subtype'] == 'success') {
      completer.complete(_record(response?['response']) ?? const {});
    } else {
      completer.completeError(
        StateError(response?['error'] as String? ?? 'Claude request failed'),
      );
    }
  }

  void _replaceCommands(Object? rawCommands) {
    final commands = <String, AgentSlashCommand>{};
    if (rawCommands is List) {
      for (final value in rawCommands) {
        final command = _record(value);
        final name = command?['name'];
        if (name is! String || name.isEmpty || commands.containsKey(name)) {
          continue;
        }
        commands[name] = AgentSlashCommand(
          name: name,
          description: command?['description'] as String? ?? '',
          argumentHint: command?['argumentHint'] as String? ?? '',
          kind: _claudeRootOnlyCommands.contains(name)
              ? AgentSlashCommandKind.command
              : AgentSlashCommandKind.skill,
        );
      }
    }
    commands.putIfAbsent(
      'rewind',
      () => const AgentSlashCommand(
        name: 'rewind',
        description: 'Rewind tracked files to a previous user message',
        argumentHint: '[user_message_uuid]',
      ),
    );
    final next = commands.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    _commands = List.unmodifiable(next);
    if (!_initialCommands.isCompleted) _initialCommands.complete(_commands);
  }

  void _handleExit(JsonlRpcExit exit) {
    if (_disposed || _exited) return;
    _exited = true;
    if (!_initialCommands.isCompleted) {
      _commandInitializationError = exit.error;
      _initialCommands.complete(const []);
    }
    _turnActive = false;
    _emit(SessionExited(exitCode: exit.code));
    unawaited(_events.close());
  }

  void _emit(ProviderEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _ensureActive() {
    if (_disposed || _exited || _connection.isClosed) {
      throw StateError('Claude session is disposed');
    }
  }

  Future<void> _ensureCurrentConnection() {
    if (!_restartNeeded) return Future.value();
    final existing = _restartFuture;
    if (existing != null) return existing;
    final future = _restart();
    _restartFuture = future;
    return future.whenComplete(() {
      if (identical(_restartFuture, future)) {
        _restartFuture = null;
      }
    });
  }

  Future<void> _restart() async {
    final restart = _restartConnection;
    if (restart == null) {
      throw UnsupportedError('Claude session cannot recreate its query');
    }
    _unsubscribeMessage();
    _unsubscribeExit();
    final oldConnection = _connection;
    final nextConfig = ClaudeProcessConfig(
      cwd: _config.cwd,
      permissionMode: _config.permissionMode,
      fastMode: _config.fastMode,
      model: _config.model,
      thinkingOptionId: _config.thinkingOptionId,
      systemPrompt: _config.systemPrompt,
      sessionId: _sessionId ?? _config.sessionId,
    );
    try {
      await oldConnection.dispose();
      final nextConnection = await restart(nextConfig);
      if (_disposed) {
        await nextConnection.dispose();
        throw StateError('Claude session is disposed');
      }
      _config = nextConfig;
      _connection = nextConnection;
      _bindConnection(nextConnection);
      _restartNeeded = false;
      initialize();
    } on Object {
      _exited = true;
      _turnActive = false;
      _emit(const SessionExited());
      if (!_events.isClosed) {
        unawaited(_events.close());
      }
      rethrow;
    }
  }

  void _bindConnection(ClaudeStreamConnection connection) {
    _unsubscribeMessage = connection.onMessage(_handleMessage);
    _unsubscribeExit = connection.onExit(_handleExit);
  }
}

const _claudeImageMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
};

const _claudeRootOnlyCommands = {
  'clear',
  'compact',
  'context',
  'debug',
  'extra-usage',
  'heapdump',
  'init',
  'loop',
  'schedule',
  'usage',
};

final class _ClaudeBlock {
  _ClaudeBlock({required this.id, required this.type});

  final String id;
  final String type;
  final StringBuffer buffer = StringBuffer();
  final StringBuffer inputJson = StringBuffer();
  String? toolName;
  Map<String, Object?>? toolInput;
}

Map<String, Object?>? _record(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _normalize(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

Map<String, Object?>? _decodeInput(String value) {
  if (value.trim().isEmpty) return null;
  try {
    return _record(jsonDecode(value));
  } on FormatException {
    return null;
  }
}

String? _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return null;
  final parts = <String>[];
  for (final value in content) {
    final block = _record(value);
    final text = block?['text'];
    if (text is String && text.isNotEmpty) parts.add(text);
  }
  return parts.isEmpty ? null : parts.join('\n');
}
