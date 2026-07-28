/// [AgentSession] driven by direct LLM API calls instead of a CLI subprocess.
///
/// Runs its own agentic loop: call the model, execute any tool calls it
/// requests (gated by [AgentMode] through the existing [PermissionBroker]),
/// feed results back, and repeat until the model answers without further
/// tool calls. Emits the same [ProviderEvent]s the CLI-backed sessions did,
/// so `AgentManager`/timeline/RPC broadcast layers need no changes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../agent_session.dart';
import '../provider_event.dart';
import 'llm_backend.dart';
import 'tool_schema.dart';
import 'tools/tool_executor.dart';

class _ToolCallBuilder {
  String? id;
  String? name;
  final arguments = StringBuffer();
}

class NativeSession implements AgentSession {
  NativeSession({
    required this.backend,
    required this.model,
    required this.cwd,
    required this.mode,
    required this.apiKey,
    List<LlmMessage>? initialMessages,
  }) : _messages = List.of(initialMessages ?? const []),
       _executor = ToolExecutor(cwd: cwd) {
    _events = StreamController<ProviderEvent>.broadcast(
      onListen: () => _events.add(SessionStarted(sessionId: _uuid.v4())),
    );
  }

  final LlmBackend backend;
  final String model;
  final String cwd;
  final AgentMode mode;
  final String apiKey;

  final List<LlmMessage> _messages;
  final ToolExecutor _executor;
  static const _uuid = Uuid();

  late final StreamController<ProviderEvent> _events;
  StreamSubscription<LlmStreamEvent>? _activeStream;
  Completer<void>? _turnCompleter;
  bool _interruptRequested = false;
  bool _disposed = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    _interruptRequested = false;
    _messages.add(LlmUserMessage(text));
    await _runTurn();
  }

  Future<void> _runTurn() async {
    while (true) {
      if (_interruptRequested) {
        _events.add(const TurnFailed(error: 'interrupted'));
        return;
      }

      final assistantItemId = _uuid.v4();
      final textBuffer = StringBuffer();
      final toolCallBuilders = <int, _ToolCallBuilder>{};
      LlmFinishReason? finishReason;
      String? streamError;

      final completer = Completer<void>();
      _turnCompleter = completer;
      _activeStream = backend
          .chat(
            messages: List.unmodifiable(_messages),
            tools: nativeToolSchemas,
            model: model,
            apiKey: apiKey,
          )
          .listen(
            (event) {
              switch (event) {
                case LlmTextDelta(:final text):
                  textBuffer.write(text);
                  _events.add(
                    AssistantTextDelta(itemId: assistantItemId, text: text),
                  );
                case LlmToolCallDelta(
                  :final index,
                  :final id,
                  :final name,
                  :final argumentsChunk,
                ):
                  final builder = toolCallBuilders.putIfAbsent(
                    index,
                    _ToolCallBuilder.new,
                  );
                  if (id != null) builder.id = id;
                  if (name != null) builder.name = name;
                  if (argumentsChunk != null)
                    builder.arguments.write(argumentsChunk);
                case LlmStreamDone(finishReason: final reason):
                  finishReason = reason;
                case LlmStreamError(:final message):
                  streamError = message;
              }
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object e) {
              streamError = '$e';
              if (!completer.isCompleted) completer.complete();
            },
          );

      await completer.future;
      _activeStream = null;
      _turnCompleter = null;

      if (_interruptRequested) {
        if (textBuffer.isNotEmpty) {
          _events.add(
            AssistantMessageComplete(
              itemId: assistantItemId,
              fullText: textBuffer.toString(),
            ),
          );
        }
        _events.add(const TurnFailed(error: 'interrupted'));
        return;
      }

      if (streamError != null) {
        _events.add(TurnFailed(error: streamError!));
        return;
      }

      if (textBuffer.isNotEmpty) {
        _events.add(
          AssistantMessageComplete(
            itemId: assistantItemId,
            fullText: textBuffer.toString(),
          ),
        );
      }

      final toolCalls = toolCallBuilders.values
          .where((b) => b.name != null)
          .map(
            (b) => LlmToolCall(
              id: b.id ?? _uuid.v4(),
              name: b.name!,
              argumentsJson: b.arguments.toString(),
            ),
          )
          .toList();

      _messages.add(
        LlmAssistantMessage(
          text: textBuffer.isEmpty ? null : textBuffer.toString(),
          toolCalls: toolCalls,
        ),
      );

      if (toolCalls.isEmpty || finishReason != LlmFinishReason.toolCalls) {
        _events.add(const TurnCompleted());
        return;
      }

      for (final call in toolCalls) {
        if (_interruptRequested) {
          _events.add(const TurnFailed(error: 'interrupted'));
          return;
        }
        final resultContent = await _executeToolCall(call);
        _messages.add(
          LlmToolResultMessage(toolCallId: call.id, content: resultContent),
        );
      }
      // Loop again: feed tool results back to the model.
    }
  }

  Future<String> _executeToolCall(LlmToolCall call) async {
    final itemId = 'tool_${call.id}';
    Map<String, Object?> args;
    try {
      args = call.argumentsJson.isEmpty
          ? const {}
          : jsonDecode(call.argumentsJson) as Map<String, Object?>;
    } catch (_) {
      args = const {};
    }

    _events.add(
      ToolCallStarted(
        itemId: itemId,
        toolName: call.name,
        status: ToolCallStatus.pending,
        detail: GenericDetail(input: args),
      ),
    );

    if (mode == AgentMode.plan &&
        ToolExecutor.mutatingTools.contains(call.name)) {
      _events.add(
        ToolCallUpdated(
          itemId: itemId,
          toolName: call.name,
          status: ToolCallStatus.error,
          detail: GenericDetail(input: args),
        ),
      );
      return 'error: "${call.name}" is not allowed in plan mode';
    }

    final requiresApproval =
        mode != AgentMode.fullAccess &&
        ToolExecutor.mutatingTools.contains(call.name);
    if (requiresApproval) {
      final decision = await _awaitPermission(call.name, args);
      if (decision == PermissionDecision.deny) {
        _events.add(
          ToolCallUpdated(
            itemId: itemId,
            toolName: call.name,
            status: ToolCallStatus.error,
            detail: GenericDetail(input: args),
          ),
        );
        return 'denied by user';
      }
    }

    _events.add(
      ToolCallStarted(
        itemId: itemId,
        toolName: call.name,
        status: ToolCallStatus.running,
        detail: GenericDetail(input: args),
      ),
    );
    final result = await _executor.execute(call.name, args);
    _events.add(
      ToolCallUpdated(
        itemId: itemId,
        toolName: call.name,
        status: result.isError ? ToolCallStatus.error : ToolCallStatus.success,
        detail: result.detail,
      ),
    );
    return result.content;
  }

  Future<PermissionDecision> _awaitPermission(
    String toolName,
    Map<String, Object?> args,
  ) {
    final completer = Completer<PermissionDecision>();
    _events.add(
      PermissionRequested(
        permissionId: _uuid.v4(),
        toolName: toolName,
        detail: GenericDetail(input: args),
        respond: (decision, {message}) async {
          if (!completer.isCompleted) completer.complete(decision);
        },
      ),
    );
    return completer.future;
  }

  @override
  Future<void> interrupt() async {
    _interruptRequested = true;
    await _activeStream?.cancel();
    _activeStream = null;
    final completer = _turnCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _interruptRequested = true;
    await _activeStream?.cancel();
    if (!_events.isClosed) {
      _events.add(const SessionExited());
      await _events.close();
    }
  }
}
