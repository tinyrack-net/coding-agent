/// [LlmBackend] for the Anthropic Messages API — covers Claude and any
/// Claude-compatible gateway. Differs from the OpenAI dialect in four ways
/// that all live in [_encodeMessages]/[chat]:
///
///   * `system` is a top-level request field, not a message role.
///   * `max_tokens` is mandatory on every request.
///   * tool results are `user` messages carrying `tool_result` blocks, and
///     consecutive results must be merged into one message.
///   * `tool_use.input` is a decoded JSON object, not a string.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;

import 'llm_backend.dart';

class AnthropicBackend implements LlmBackend {
  AnthropicBackend({
    required this.config,
    http.Client? httpClient,
    this.anthropicVersion = '2023-06-01',
  }) : _http = httpClient ?? http.Client();

  final ProviderConfig config;
  final String anthropicVersion;
  final http.Client _http;

  Map<String, String> _headers(String apiKey) => {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': anthropicVersion,
        ...config.extraHeaders,
      };

  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) async* {
    final system = messages
        .whereType<LlmSystemMessage>()
        .map((m) => m.text)
        .where((text) => text.isNotEmpty)
        .join('\n\n');

    final request = http.Request('POST', Uri.parse('${config.baseUrl}/messages'))
      ..headers.addAll(_headers(apiKey))
      ..body = jsonEncode({
        'model': model,
        'max_tokens': config.maxTokens,
        'stream': true,
        if (system.isNotEmpty) 'system': system,
        'messages': _encodeMessages(messages),
        if (tools.isNotEmpty) 'tools': tools.map(_encodeTool).toList(),
      });

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (e) {
      yield LlmStreamError('request failed: $e');
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      yield LlmStreamError('HTTP ${response.statusCode}: $body');
      return;
    }

    var sawDone = false;
    try {
      loop:
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        // `event:` lines carry the same `type` as the JSON payload, so only
        // `data:` needs parsing.
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;

        final Map<String, Object?> json;
        try {
          json = jsonDecode(data) as Map<String, Object?>;
        } catch (_) {
          continue;
        }

        switch (json['type'] as String?) {
          case 'content_block_start':
            final block = json['content_block'] as Map<String, Object?>?;
            if (block?['type'] == 'tool_use') {
              yield LlmToolCallDelta(
                index: (json['index'] as num?)?.toInt() ?? 0,
                id: block?['id'] as String?,
                name: block?['name'] as String?,
              );
            }
          case 'content_block_delta':
            final delta = json['delta'] as Map<String, Object?>?;
            switch (delta?['type'] as String?) {
              case 'text_delta':
                final text = delta?['text'] as String?;
                if (text != null && text.isNotEmpty) yield LlmTextDelta(text);
              case 'input_json_delta':
                yield LlmToolCallDelta(
                  index: (json['index'] as num?)?.toInt() ?? 0,
                  argumentsChunk: delta?['partial_json'] as String?,
                );
            }
          case 'message_delta':
            final stopReason =
                (json['delta'] as Map<String, Object?>?)?['stop_reason']
                    as String?;
            if (stopReason != null) {
              sawDone = true;
              yield LlmStreamDone(_parseStopReason(stopReason));
            }
          case 'error':
            final error = json['error'] as Map<String, Object?>?;
            yield LlmStreamError(
              (error?['message'] as String?) ?? 'provider reported an error',
            );
            return;
          case 'message_stop':
            break loop;
        }
      }
    } catch (e) {
      yield LlmStreamError('stream read failed: $e');
      return;
    }
    if (!sawDone) {
      // Stream closed without a message_delta carrying stop_reason.
      yield const LlmStreamDone(LlmFinishReason.stop);
    }
  }

  @override
  Future<bool> testCredential(String apiKey) async {
    try {
      final response = await _http.get(
        Uri.parse('${config.baseUrl}/models'),
        headers: _headers(apiKey),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ProviderModel>> fetchModels(String apiKey) async {
    try {
      final response = await _http
          .get(
            Uri.parse('${config.baseUrl}/models'),
            headers: _headers(apiKey),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return config.models;

      final body = jsonDecode(response.body) as Map<String, Object?>;
      final data = body['data'] as List?;
      if (data == null || data.isEmpty) return config.models;

      final models = <ProviderModel>[];
      for (final item in data) {
        if (item is Map<String, Object?>) {
          final id = item['id'] as String?;
          if (id != null && id.isNotEmpty) {
            models.add(ProviderModel(
              id: id,
              displayName: (item['display_name'] as String?) ?? id,
            ));
          }
        }
      }
      return models.isNotEmpty ? models : config.models;
    } catch (_) {
      return config.models;
    }
  }

  static LlmFinishReason _parseStopReason(String raw) => switch (raw) {
        'tool_use' => LlmFinishReason.toolCalls,
        'max_tokens' => LlmFinishReason.length,
        _ => LlmFinishReason.stop,
      };

  /// Whole-list transform (not a per-message map): system messages are hoisted
  /// out by [chat], and consecutive tool results collapse into one user
  /// message because the API rejects parallel results split across messages.
  static List<Map<String, Object?>> _encodeMessages(List<LlmMessage> messages) {
    final encoded = <Map<String, Object?>>[];
    // Blocks of the tool-result user message currently being accumulated.
    var pendingResults = <Map<String, Object?>>[];

    void flushResults() {
      if (pendingResults.isEmpty) return;
      encoded.add({'role': 'user', 'content': pendingResults});
      pendingResults = [];
    }

    for (final message in messages) {
      switch (message) {
        case LlmSystemMessage():
          // Hoisted into the top-level `system` field.
          break;
        case LlmToolResultMessage(:final toolCallId, :final content):
          pendingResults.add({
            'type': 'tool_result',
            'tool_use_id': toolCallId,
            'content': content,
          });
        case LlmUserMessage(:final text):
          flushResults();
          encoded.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text},
            ],
          });
        case LlmAssistantMessage(:final text, :final toolCalls):
          flushResults();
          final blocks = <Map<String, Object?>>[
            if (text != null && text.isNotEmpty)
              {'type': 'text', 'text': text},
            for (final call in toolCalls)
              {
                'type': 'tool_use',
                'id': call.id,
                'name': call.name,
                'input': _decodeArguments(call.argumentsJson),
              },
          ];
          // An assistant message with an empty content array is rejected.
          if (blocks.isEmpty) break;
          encoded.add({'role': 'assistant', 'content': blocks});
      }
    }
    flushResults();
    return encoded;
  }

  /// `tool_use.input` must be a JSON object. Streamed arguments can arrive
  /// truncated or empty, so fall back to `{}` rather than failing the turn.
  static Map<String, Object?> _decodeArguments(String argumentsJson) {
    if (argumentsJson.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(argumentsJson);
      return decoded is Map<String, Object?> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static Map<String, Object?> _encodeTool(LlmToolSchema tool) => {
        'name': tool.name,
        'description': tool.description,
        'input_schema': tool.parameters,
      };
}
