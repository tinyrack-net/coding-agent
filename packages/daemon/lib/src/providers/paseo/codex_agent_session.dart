import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../../agent/prompt_attachments.dart';
import '../agent_session.dart';
import '../provider_event.dart';
import 'codex_session_runtime.dart';
import 'provider_notices.dart';
import 'jsonl_rpc_process.dart';

/// Normalizes Codex app-server lifecycle, text, reasoning, tool, and approval
/// events into the daemon's provider-neutral session contract.
final class CodexAgentSession
    implements
        HistoryRestoringAgentSession,
        ProviderSubagentRestoringAgentSession,
        ConfigurableAgentSession,
        StructuredPromptAgentSession,
        RunOptionsAgentSession,
        CommandListingAgentSession {
  CodexAgentSession(this._runtime) {
    _unsubscribeNotification = _runtime.onNotification(_handleNotification);
    _unsubscribeExit = _runtime.onExit(_handleExit);
    _runtime.setRequestHandler(
      'item/commandExecution/requestApproval',
      _handleCommandApproval,
    );
    _runtime.setRequestHandler(
      'item/fileChange/requestApproval',
      _handleFileChangeApproval,
    );
    _runtime.setRequestHandler(
      'item/tool/requestUserInput',
      _handleToolUserInput,
    );
    _runtime.setRequestHandler('tool/requestUserInput', _handleToolUserInput);
    _runtime.setRequestHandler(
      'mcpServer/elicitation/request',
      _handleMcpElicitation,
    );
  }

  final CodexSessionRuntime _runtime;
  final StreamController<ProviderEvent> _events =
      StreamController<ProviderEvent>.broadcast();
  final Map<String, StringBuffer> _assistantText = {};
  final Map<String, StringBuffer> _reasoningText = {};
  final Map<String, _CodexSubagentRoute> _subagentsByThread = {};
  final Map<String, List<(String, Map<String, Object?>)>> _pendingSubagent = {};
  late final void Function() _unsubscribeNotification;
  late final void Function() _unsubscribeExit;
  var _disposed = false;
  var _processExited = false;
  var _compactionSequence = 0;
  var _unpairedCompactionNotifications = 0;
  var _unpairedCompactionItems = 0;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  List<TimelineItem>? get restoredHistory => _runtime.restoredHistory;

  @override
  List<RestoredProviderSubagent> get restoredProviderSubagents =>
      _runtime.restoredProviderSubagents;

  @override
  Future<void> prompt(String text) {
    if (_disposed || _processExited) {
      throw StateError('Codex session is disposed');
    }
    return _runtime.startTurn(text);
  }

  @override
  Future<void> promptWithAttachments(
    String text,
    List<AgentAttachment> attachments,
  ) {
    if (_disposed || _processExited) {
      throw StateError('Codex session is disposed');
    }
    final chatHistory = <AgentAttachment>[];
    final context = <AgentAttachment>[];
    for (final attachment in attachments) {
      if (isChatHistoryAttachment(attachment)) {
        chatHistory.add(attachment);
      } else {
        context.add(attachment);
      }
    }
    final input = <Map<String, Object?>>[
      for (final attachment in chatHistory)
        _textInput(renderPromptAttachmentAsText(attachment)),
      if (text.trim().isNotEmpty) _textInput(text.trim()),
      for (final attachment in context)
        _textInput(renderPromptAttachmentAsText(attachment)),
    ];
    return _runtime.startTurnInput(input);
  }

  @override
  Future<void> promptWithRunOptions(
    String text, {
    required List<AgentPromptImage> images,
    required List<AgentAttachment> attachments,
    Map<String, Object?>? outputSchema,
  }) {
    if (_disposed || _processExited) {
      throw StateError('Codex session is disposed');
    }
    final history = attachments.where(isChatHistoryAttachment);
    final context = attachments.where(
      (attachment) => !isChatHistoryAttachment(attachment),
    );
    return _runtime.startTurnInput([
      for (final attachment in history)
        _textInput(renderPromptAttachmentAsText(attachment)),
      if (text.trim().isNotEmpty) _textInput(text.trim()),
      for (final image in images)
        {'type': 'image', 'url': 'data:${image.mimeType};base64,${image.data}'},
      for (final attachment in context)
        _textInput(renderPromptAttachmentAsText(attachment)),
    ], outputSchema: outputSchema);
  }

  @override
  Future<void> interrupt() => _runtime.interrupt();

  @override
  Future<List<AgentSlashCommand>> listCommands() => _runtime.listCommands();

  @override
  Future<AgentProviderNotice?> setMode(String modeId) async {
    _runtime.setMode(modeId);
    return _runtime.isTurnActive ? modeAppliesNextTurnNotice : null;
  }

  @override
  Future<void> setModel(String? modelId) async {
    _runtime.setModel(modelId);
  }

  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async {
    _runtime.setThinkingOption(thinkingOptionId);
    return _runtime.isTurnActive ? thinkingAppliesNextTurnNotice : null;
  }

  @override
  Future<void> setFeature(String featureId, Object? value) {
    throw UnsupportedError('Agent session does not support setting features');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _unsubscribeNotification();
    _unsubscribeExit();
    await _runtime.close();
    if (!_events.isClosed) {
      if (!_processExited) {
        _events.add(const SessionExited());
      }
      await _events.close();
    }
  }

  void _handleNotification(String method, Object? params) {
    if (_disposed) {
      return;
    }
    final record = _record(params);
    final notificationThreadId = record?['threadId'];
    if (notificationThreadId is String &&
        notificationThreadId != _runtime.threadId) {
      if (_subagentsByThread.containsKey(notificationThreadId)) {
        _handleSubagentNotification(method, record!, notificationThreadId);
      } else {
        _bufferSubagentNotification(method, record!, notificationThreadId);
      }
      return;
    }
    switch (method) {
      case 'thread/started':
        final thread = _record(record?['thread']);
        final id = thread?['id'];
        if (id is String) {
          _emit(SessionStarted(sessionId: id));
        }
      case 'item/agentMessage/delta':
        _handleTextDelta(record, reasoning: false);
      case 'item/reasoning/summaryTextDelta':
        _handleTextDelta(record, reasoning: true);
      case 'item/started':
        _handleItem(record, completed: false);
      case 'item/completed':
        _handleItem(record, completed: true);
      case 'thread/tokenUsage/updated':
        _handleTokenUsage(record);
      case 'thread/compacted':
        _handleThreadCompacted(record);
      case 'turn/completed':
        final turn = _record(record?['turn']);
        final status = turn?['status'];
        if (status == 'failed') {
          final error = _record(turn?['error']);
          _emit(
            TurnFailed(
              error: error?['message'] is String
                  ? error!['message']! as String
                  : 'Codex turn failed',
            ),
          );
        } else if (status == 'interrupted') {
          _emit(const TurnFailed(error: 'interrupted'));
        } else {
          _emit(const TurnCompleted());
        }
        _assistantText.clear();
        _reasoningText.clear();
    }
  }

  void _handleTextDelta(
    Map<String, Object?>? params, {
    required bool reasoning,
  }) {
    final itemId = params?['itemId'];
    final delta = params?['delta'];
    if (itemId is! String || delta is! String) {
      return;
    }
    final buffers = reasoning ? _reasoningText : _assistantText;
    buffers.putIfAbsent(itemId, StringBuffer.new).write(delta);
    _emit(
      reasoning
          ? ReasoningDelta(itemId: itemId, text: delta)
          : AssistantTextDelta(itemId: itemId, text: delta),
    );
  }

  void _handleItem(Map<String, Object?>? params, {required bool completed}) {
    final item = _record(params?['item']);
    final itemId = item?['id'];
    final type = item?['type'];
    if (itemId is! String || type is! String) {
      return;
    }

    if (type == 'contextCompaction' || type == 'context_compaction') {
      if (completed && _unpairedCompactionNotifications > 0) {
        _unpairedCompactionNotifications -= 1;
        return;
      }
      if (completed) {
        _unpairedCompactionItems += 1;
      }
      _emit(
        CompactionUpdated(
          itemId: itemId,
          status: completed
              ? CompactionStatus.completed
              : CompactionStatus.loading,
        ),
      );
      return;
    }

    if (completed && type == 'agentMessage') {
      final fullText = _itemText(item!) ?? _assistantText[itemId]?.toString();
      if (fullText != null) {
        _assistantText.remove(itemId);
        _emit(AssistantMessageComplete(itemId: itemId, fullText: fullText));
      }
      return;
    }
    if (completed && type == 'reasoning') {
      final fullText = _itemText(item!) ?? _reasoningText[itemId]?.toString();
      if (fullText != null) {
        _reasoningText.remove(itemId);
        _emit(ReasoningComplete(itemId: itemId, fullText: fullText));
      }
      return;
    }

    final mapped = _mapToolItem(item!, completed: completed);
    if (mapped == null) {
      return;
    }
    _emit(
      completed
          ? ToolCallUpdated(
              itemId: itemId,
              toolName: mapped.$1,
              status: mapped.$2,
              detail: mapped.$3,
            )
          : ToolCallStarted(
              itemId: itemId,
              toolName: mapped.$1,
              status: mapped.$2,
              detail: mapped.$3,
            ),
    );
    if (mapped.$3 case final SubAgentDetail detail) {
      _registerSubagents(item, itemId, mapped.$2, detail);
    }
  }

  void _registerSubagents(
    Map<String, Object?> item,
    String callId,
    ToolCallStatus status,
    SubAgentDetail detail,
  ) {
    final threadIds = <String>{
      if (item['agentThreadId'] is String) item['agentThreadId']! as String,
      if (item['receiverThreadIds'] case final List<Object?> ids)
        ...ids.whereType<String>(),
    }..remove(_runtime.threadId);
    for (final threadId in threadIds) {
      final existing = _subagentsByThread[threadId];
      final route = _CodexSubagentRoute(
        callId: existing?.callId ?? callId,
        title: detail.subAgentType ?? existing?.title,
        description: detail.description ?? existing?.description,
      );
      _subagentsByThread[threadId] = route;
      _emit(
        ProviderSubagentUpserted(
          subagentId: threadId,
          title: route.title,
          description: route.description,
          status: _providerStatus(status),
          toolCallId: route.callId,
          cwd: null,
        ),
      );
      final pending = _pendingSubagent.remove(threadId);
      if (pending != null) {
        for (final (method, params) in pending) {
          _handleSubagentNotification(method, params, threadId);
        }
      }
    }
  }

  void _bufferSubagentNotification(
    String method,
    Map<String, Object?> params,
    String threadId,
  ) {
    if (_pendingSubagent.length >= 32 &&
        !_pendingSubagent.containsKey(threadId)) {
      _pendingSubagent.remove(_pendingSubagent.keys.first);
    }
    final pending = _pendingSubagent.putIfAbsent(threadId, () => []);
    if (pending.length >= 128) {
      pending.removeAt(0);
    }
    pending.add((method, params));
  }

  void _handleSubagentNotification(
    String method,
    Map<String, Object?> params,
    String threadId,
  ) {
    switch (method) {
      case 'item/agentMessage/delta':
        _handleSubagentTextDelta(params, threadId, reasoning: false);
      case 'item/reasoning/summaryTextDelta':
        _handleSubagentTextDelta(params, threadId, reasoning: true);
      case 'item/started':
        _handleSubagentItem(params, threadId, completed: false);
      case 'item/completed':
        _handleSubagentItem(params, threadId, completed: true);
      case 'thread/compacted':
        final turnId = params['turnId'];
        _emit(
          ProviderSubagentTimelineChanged(
            subagentId: threadId,
            item: CompactionItem(
              id: turnId is String
                  ? 'compaction-$turnId'
                  : 'compaction-$threadId',
              status: CompactionStatus.completed,
            ),
          ),
        );
      case 'turn/completed':
        final turn = _record(params['turn']);
        final status = turn?['status'];
        final route = _subagentsByThread[threadId];
        if (route != null) {
          _emit(
            ProviderSubagentUpserted(
              subagentId: threadId,
              title: route.title,
              description: route.description,
              status: status == 'failed'
                  ? ProviderSubagentStatus.failed
                  : status == 'interrupted'
                  ? ProviderSubagentStatus.canceled
                  : ProviderSubagentStatus.completed,
              toolCallId: route.callId,
            ),
          );
        }
    }
  }

  void _handleSubagentTextDelta(
    Map<String, Object?> params,
    String threadId, {
    required bool reasoning,
  }) {
    final itemId = params['itemId'];
    final delta = params['delta'];
    if (itemId is! String || delta is! String) return;
    final key = '$threadId:$itemId';
    final buffers = reasoning ? _reasoningText : _assistantText;
    final text = (buffers.putIfAbsent(
      key,
      StringBuffer.new,
    )..write(delta)).toString();
    _emit(
      ProviderSubagentTimelineChanged(
        subagentId: threadId,
        item: reasoning
            ? ReasoningItem(id: itemId, text: text, complete: false)
            : AssistantMessageItem(id: itemId, text: text, complete: false),
      ),
    );
  }

  void _handleSubagentItem(
    Map<String, Object?> params,
    String threadId, {
    required bool completed,
  }) {
    final item = _record(params['item']);
    final itemId = item?['id'];
    final type = item?['type'];
    if (itemId is! String || type is! String) return;
    final key = '$threadId:$itemId';
    if (type == 'agentMessage' && completed) {
      final text = _itemText(item!) ?? _assistantText.remove(key)?.toString();
      if (text != null) {
        _emit(
          ProviderSubagentTimelineChanged(
            subagentId: threadId,
            item: AssistantMessageItem(id: itemId, text: text, complete: true),
          ),
        );
      }
      return;
    }
    if (type == 'reasoning' && completed) {
      final text = _itemText(item!) ?? _reasoningText.remove(key)?.toString();
      if (text != null) {
        _emit(
          ProviderSubagentTimelineChanged(
            subagentId: threadId,
            item: ReasoningItem(id: itemId, text: text, complete: true),
          ),
        );
      }
      return;
    }
    final mapped = _mapToolItem(item!, completed: completed);
    if (mapped == null) return;
    final timelineItem = ToolCallItem(
      id: itemId,
      toolName: mapped.$1,
      status: mapped.$2,
      detail: mapped.$3,
    );
    _emit(
      ProviderSubagentTimelineChanged(subagentId: threadId, item: timelineItem),
    );
    if (mapped.$3 case final SubAgentDetail detail) {
      _registerSubagents(item, itemId, mapped.$2, detail);
    }
  }

  Future<Object?> _handleCommandApproval(Object? params, int requestId) {
    final parsed = _requiredApproval(params);
    final command = parsed['command'] is String
        ? parsed['command']! as String
        : '';
    final cwd = parsed['cwd'] is String ? parsed['cwd']! as String : null;
    return _requestPermission(
      itemId: parsed['itemId']! as String,
      toolName: 'CodexBash',
      detail: ShellDetail(
        command: cwd == null || cwd.isEmpty ? command : 'cd $cwd && $command',
      ),
    );
  }

  Future<Object?> _handleFileChangeApproval(Object? params, int requestId) {
    final parsed = _requiredApproval(params);
    return _requestPermission(
      itemId: parsed['itemId']! as String,
      toolName: 'CodexFileChange',
      detail: GenericDetail(
        input: {if (parsed['reason'] is String) 'reason': parsed['reason']},
      ),
    );
  }

  Future<Object?> _handleToolUserInput(Object? params, int requestId) {
    final parsed = _requiredApproval(params);
    final rawQuestions = parsed['questions'];
    if (rawQuestions is! List) {
      throw const FormatException(
        'Codex user input request requires questions',
      );
    }
    final questions = _normalizeQuestions(rawQuestions);
    final itemId = parsed['itemId']! as String;
    final detail = GenericDetail(
      input: {
        'kind': 'question',
        'text': _formatQuestions(questions),
        'questions': questions,
      },
    );
    _emit(
      ToolCallStarted(
        itemId: itemId,
        toolName: 'request_user_input',
        status: ToolCallStatus.running,
        detail: detail,
      ),
    );

    final completer = Completer<Object?>();
    _emit(
      PermissionRequested(
        permissionId: 'permission-$itemId',
        toolName: 'request_user_input',
        detail: detail,
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {
              if (completer.isCompleted) {
                return;
              }
              final allowed = decision == PermissionDecision.allow;
              final answers = <String, Object?>{
                if (allowed)
                  for (final question in questions)
                    if ((question['options'] as List<Object?>).isNotEmpty)
                      question['id']! as String: {
                        'answers': [
                          ((question['options'] as List<Object?>).first
                              as Map<String, Object?>)['label'],
                        ],
                      },
              };
              _emit(
                ToolCallUpdated(
                  itemId: itemId,
                  toolName: 'request_user_input',
                  status: allowed
                      ? ToolCallStatus.success
                      : ToolCallStatus.error,
                  detail: GenericDetail(
                    input: {
                      ...detail.input,
                      if (allowed) 'answers': answers,
                      if (!allowed)
                        'error': message?.trim().isNotEmpty == true
                            ? message
                            : 'Question dismissed',
                    },
                  ),
                ),
              );
              completer.complete({'answers': answers});
            },
      ),
    );
    return completer.future;
  }

  Future<Object?> _handleMcpElicitation(Object? params, int requestId) {
    final parsed = _record(params);
    if (parsed == null ||
        parsed['threadId'] is! String ||
        parsed['serverName'] is! String ||
        parsed['message'] is! String ||
        parsed['mode'] is! String ||
        (parsed['turnId'] != null && parsed['turnId'] is! String)) {
      throw const FormatException('Invalid Codex MCP elicitation request');
    }
    final mode = parsed['mode']! as String;
    if (mode != 'form' && mode != 'openai/form' && mode != 'url') {
      throw const FormatException('Invalid Codex MCP elicitation mode');
    }
    final schema = _record(parsed['requestedSchema']);
    final required = schema?['required'];
    if (mode == 'url' || (required is List && required.isNotEmpty)) {
      return Future<Object?>.value({
        'action': 'decline',
        'content': null,
        '_meta': null,
      });
    }

    final completer = Completer<Object?>();
    _emit(
      PermissionRequested(
        permissionId: 'permission-mcp-$requestId',
        toolName: 'CodexMcpElicitation',
        detail: GenericDetail(
          input: {
            'mode': mode,
            'serverName': parsed['serverName'],
            'message': parsed['message'],
            'requestedSchema': parsed['requestedSchema'],
            'url': parsed['url'],
            'elicitationId': parsed['elicitationId'],
          },
        ),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {
              if (!completer.isCompleted) {
                completer.complete({
                  'action': decision == PermissionDecision.allow
                      ? 'accept'
                      : 'decline',
                  'content': decision == PermissionDecision.allow
                      ? <String, Object?>{}
                      : null,
                  '_meta': null,
                });
              }
            },
      ),
    );
    return completer.future;
  }

  void _handleTokenUsage(Map<String, Object?>? params) {
    final usage = _record(params?['tokenUsage']);
    if (usage == null) {
      return;
    }
    final last = _record(usage['last']);
    final maxTokens = _firstPositiveInt(
      usage['model_context_window'],
      usage['modelContextWindow'],
    );
    final usedTokens = _firstPositiveInt(
      last?['total_tokens'],
      last?['totalTokens'],
    );
    _emit(
      UsageUpdated(
        usage: AgentUsage(
          inputTokens: _intValue(last?['inputTokens']),
          cachedInputTokens: _intValue(last?['cachedInputTokens']),
          outputTokens: _intValue(last?['outputTokens']),
          contextWindowMaxTokens: maxTokens,
          contextWindowUsedTokens: usedTokens,
        ),
      ),
    );
  }

  void _handleThreadCompacted(Map<String, Object?>? params) {
    final threadId = params?['threadId'];
    if (threadId is! String || threadId != _runtime.threadId) {
      return;
    }
    if (_unpairedCompactionItems > 0) {
      _unpairedCompactionItems -= 1;
      return;
    }
    _unpairedCompactionNotifications += 1;
    final turnId = params?['turnId'];
    _compactionSequence += 1;
    _emit(
      CompactionUpdated(
        itemId: turnId is String && turnId.isNotEmpty
            ? 'compaction-$turnId'
            : 'compaction-$_compactionSequence',
        status: CompactionStatus.completed,
      ),
    );
  }

  Future<Object?> _requestPermission({
    required String itemId,
    required String toolName,
    required ToolCallDetail detail,
  }) {
    final completer = Completer<Object?>();
    final permissionId = 'permission-$itemId';
    _emit(
      PermissionRequested(
        permissionId: permissionId,
        toolName: toolName,
        detail: detail,
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {
              if (!completer.isCompleted) {
                completer.complete({
                  'decision': decision == PermissionDecision.allow
                      ? 'accept'
                      : 'decline',
                });
              }
            },
      ),
    );
    return completer.future;
  }

  void _emit(ProviderEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _handleExit(JsonlRpcExit exit) {
    if (_disposed || _processExited) {
      return;
    }
    _processExited = true;
    _unsubscribeNotification();
    _unsubscribeExit();
    _emit(SessionExited(exitCode: exit.code));
    unawaited(_events.close());
  }
}

final class _CodexSubagentRoute {
  const _CodexSubagentRoute({
    required this.callId,
    this.title,
    this.description,
  });

  final String callId;
  final String? title;
  final String? description;
}

ProviderSubagentStatus _providerStatus(ToolCallStatus status) =>
    switch (status) {
      ToolCallStatus.success => ProviderSubagentStatus.completed,
      ToolCallStatus.error => ProviderSubagentStatus.failed,
      ToolCallStatus.canceled => ProviderSubagentStatus.canceled,
      ToolCallStatus.pending ||
      ToolCallStatus.running => ProviderSubagentStatus.running,
    };

List<Map<String, Object?>> _normalizeQuestions(List<Object?> raw) {
  final questions = <Map<String, Object?>>[];
  for (final value in raw) {
    final record = _record(value);
    final id = _nonEmptyString(record?['id']);
    final header = _nonEmptyString(record?['header']);
    final question = _nonEmptyString(record?['question']);
    if (id == null || header == null || question == null) {
      continue;
    }
    final options = <Map<String, Object?>>[];
    final rawOptions = record?['options'];
    if (rawOptions is List) {
      for (final optionValue in rawOptions) {
        final option = _record(optionValue);
        final label = _nonEmptyString(option?['label']);
        if (label == null) {
          continue;
        }
        options.add({
          'label': label,
          if (_nonEmptyString(option?['description']) case final description?)
            'description': description,
        });
      }
    }
    questions.add({
      'id': id,
      'header': header,
      'question': question,
      'options': options,
      if (record?['multiSelect'] == true) 'multiSelect': true,
      if (record?['isOther'] == true) 'isOther': true,
      if (record?['isSecret'] == true) 'isSecret': true,
    });
  }
  return questions;
}

String _formatQuestions(List<Map<String, Object?>> questions) {
  return questions
      .map((question) {
        final lines = ['${question['header']}: ${question['question']}'];
        final options = question['options']! as List<Object?>;
        if (options.isNotEmpty) {
          lines.add(
            'Options: ${options.map((option) => (option as Map<String, Object?>)['label']).join(', ')}',
          );
        }
        return lines.join('\n');
      })
      .join('\n\n')
      .trim();
}

String? _nonEmptyString(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value;
}

int? _intValue(Object? value) => value is num ? value.toInt() : null;

int? _firstPositiveInt(Object? first, Object? second) {
  for (final value in [first, second]) {
    if (value is num && value.isFinite && value > 0) {
      return value.toInt();
    }
  }
  return null;
}

Map<String, Object?> _requiredApproval(Object? value) {
  final record = _record(value);
  if (record == null ||
      record['itemId'] is! String ||
      record['threadId'] is! String ||
      record['turnId'] is! String) {
    throw const FormatException(
      'Codex approval requires itemId, threadId, and turnId',
    );
  }
  return record;
}

Map<String, Object?>? _record(Object? value) {
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

String? _itemText(Map<String, Object?> item) {
  for (final key in ['text', 'content', 'summaryText']) {
    if (item[key] is String) {
      return item[key]! as String;
    }
  }
  return null;
}

Map<String, Object?> _textInput(String text) => {
  'type': 'text',
  'text': text,
  'text_elements': <Object?>[],
};

(String, ToolCallStatus, ToolCallDetail)? _mapToolItem(
  Map<String, Object?> item, {
  required bool completed,
}) {
  final type = item['type'];
  final status = completed
      ? item['status'] == 'failed'
            ? ToolCallStatus.error
            : ToolCallStatus.success
      : ToolCallStatus.running;
  if (type == 'commandExecution') {
    final command = item['command'] is String ? item['command']! as String : '';
    final output = item['aggregatedOutput'] is String
        ? item['aggregatedOutput']! as String
        : item['output'] is String
        ? item['output']! as String
        : null;
    final exitCode = item['exitCode'] is num
        ? (item['exitCode']! as num).toInt()
        : null;
    return (
      'shell',
      status,
      ShellDetail(command: command, output: output, exitCode: exitCode),
    );
  }
  if (type == 'fileChange') {
    final path = item['path'] is String ? item['path']! as String : '';
    final diff = item['diff'] is String ? item['diff']! as String : null;
    return ('apply_patch', status, EditDetail(path: path, diff: diff));
  }
  if (type == 'collabAgentToolCall' || type == 'CollabAgentToolCall') {
    final states = _record(item['agentsStates']);
    final childStates = states?.values
        .map(_record)
        .whereType<Map<String, Object?>>()
        .toList();
    final resolvedStatus =
        item['status'] == 'failed' ||
            childStates?.any((state) => state['status'] == 'failed') == true
        ? ToolCallStatus.error
        : childStates?.isNotEmpty == true &&
              childStates!.every((state) => state['status'] == 'completed')
        ? ToolCallStatus.success
        : ToolCallStatus.running;
    final ids = item['receiverThreadIds'];
    final childIds = ids is List
        ? ids.whereType<String>().toList()
        : <String>[];
    final childId = childIds.isEmpty ? null : childIds.first;
    return (
      'Sub-agent',
      resolvedStatus,
      SubAgentDetail(
        subAgentType: 'Sub-agent',
        description: item['prompt'] as String?,
        childSessionId: childId,
      ),
    );
  }
  if (type == 'subAgentActivity' || type == 'SubAgentActivity') {
    final kind = item['kind'];
    final (title, description) = _subagentName(item['agentPath']);
    return (
      'Sub-agent',
      kind == 'interrupted' ? ToolCallStatus.canceled : ToolCallStatus.running,
      SubAgentDetail(
        subAgentType: title,
        description: description,
        childSessionId: item['agentThreadId'] as String?,
      ),
    );
  }
  if (type == 'mcpToolCall' || type == 'webSearch') {
    return (
      type == 'webSearch' ? 'web_search' : 'mcp',
      status,
      GenericDetail(input: Map<String, Object?>.from(item)),
    );
  }
  return null;
}

(String, String) _subagentName(Object? value) {
  var path = value is String ? value : '';
  if (path == '/root') {
    path = '';
  } else if (path.startsWith('/root/')) {
    path = path.substring('/root/'.length);
  } else if (path.contains('/') || path.contains(r'\')) {
    final index = [
      path.lastIndexOf('/'),
      path.lastIndexOf(r'\'),
    ].reduce((a, b) => a > b ? a : b);
    path = path.substring(index + 1);
  }
  final name = path
      .split('/')
      .map((segment) => segment.replaceAll(RegExp('[_-]+'), ' ').trim())
      .where((segment) => segment.isNotEmpty)
      .map((segment) => '${segment[0].toUpperCase()}${segment.substring(1)}')
      .join(' / ');
  return (name.isEmpty ? 'Sub-agent' : name, path);
}
