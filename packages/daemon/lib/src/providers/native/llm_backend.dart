/// Normalized chat-completion contract that native LLM backends implement.
///
/// Kept independent of any single vendor's wire format so [NativeSession]'s
/// tool-call loop never needs to know which backend it's talking to.
library;

import 'package:agent_protocol/agent_protocol.dart';

sealed class LlmMessage {
  const LlmMessage();
}

final class LlmSystemMessage extends LlmMessage {
  const LlmSystemMessage(this.text);
  final String text;
}

final class LlmUserMessage extends LlmMessage {
  const LlmUserMessage(this.text);
  final String text;
}

final class LlmAssistantMessage extends LlmMessage {
  const LlmAssistantMessage({this.text, this.toolCalls = const []});
  final String? text;
  final List<LlmToolCall> toolCalls;
}

final class LlmToolResultMessage extends LlmMessage {
  const LlmToolResultMessage({required this.toolCallId, required this.content});
  final String toolCallId;
  final String content;
}

/// A tool call requested by the model; [argumentsJson] is the raw JSON
/// object string as emitted by the API (may need repair if streamed in
/// fragments — see [NativeSession]).
final class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;
}

/// A tool definition advertised to the model (JSON-schema parameters).
final class LlmToolSchema {
  const LlmToolSchema({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

final class LlmTextDelta extends LlmStreamEvent {
  const LlmTextDelta(this.text);
  final String text;
}

/// One chunk of a tool call under construction; [index] identifies which
/// parallel tool call this chunk belongs to. Backends may emit `id`/`name`
/// once (first chunk) and `argumentsChunk` across many chunks.
final class LlmToolCallDelta extends LlmStreamEvent {
  const LlmToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsChunk,
  });

  final int index;
  final String? id;
  final String? name;
  final String? argumentsChunk;
}

enum LlmFinishReason { stop, toolCalls, length }

final class LlmStreamDone extends LlmStreamEvent {
  const LlmStreamDone(this.finishReason);
  final LlmFinishReason finishReason;
}

final class LlmStreamError extends LlmStreamEvent {
  const LlmStreamError(this.message);
  final String message;
}

abstract interface class LlmBackend {
  /// Streams one assistant turn for [messages]. Terminates with exactly one
  /// of [LlmStreamDone] or [LlmStreamError].
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  });

  /// Lightweight call to confirm [apiKey] is valid for this provider.
  Future<bool> testCredential(String apiKey);

  /// Fetches available models dynamically from the provider API.
  Future<List<ProviderModel>> fetchModels(String apiKey);
}
