/// [LlmBackend] for any OpenAI Chat-Completions-compatible API — covers
/// OpenAI/Codex, DeepSeek, and OpenRouter with one implementation; only the
/// [ProviderCatalogEntry] (base URL, headers) differs per provider.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_backend.dart';
import 'provider_catalog.dart';

class OpenAiCompatibleBackend implements LlmBackend {
  OpenAiCompatibleBackend({required this.catalogEntry, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final ProviderCatalogEntry catalogEntry;
  final http.Client _http;

  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) async* {
    final request =
        http.Request('POST', Uri.parse('${catalogEntry.baseUrl}/chat/completions'))
          ..headers['Content-Type'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..headers.addAll(catalogEntry.extraHeaders)
          ..body = jsonEncode({
            'model': model,
            'stream': true,
            'messages': messages.map(_encodeMessage).toList(),
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
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        final Map<String, Object?> json;
        try {
          json = jsonDecode(data) as Map<String, Object?>;
        } catch (_) {
          continue;
        }
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices.first as Map<String, Object?>;

        final delta = choice['delta'] as Map<String, Object?>?;
        if (delta != null) {
          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty) {
            yield LlmTextDelta(content);
          }
          final toolCalls = delta['tool_calls'] as List?;
          if (toolCalls != null) {
            for (final raw in toolCalls) {
              final tc = raw as Map<String, Object?>;
              final fn = tc['function'] as Map<String, Object?>?;
              yield LlmToolCallDelta(
                index: (tc['index'] as num?)?.toInt() ?? 0,
                id: tc['id'] as String?,
                name: fn?['name'] as String?,
                argumentsChunk: fn?['arguments'] as String?,
              );
            }
          }
        }

        final finishReason = choice['finish_reason'] as String?;
        if (finishReason != null) {
          sawDone = true;
          yield LlmStreamDone(_parseFinishReason(finishReason));
        }
      }
    } catch (e) {
      yield LlmStreamError('stream read failed: $e');
      return;
    }
    if (!sawDone) {
      // Stream closed (e.g. plain [DONE] with no prior finish_reason chunk).
      yield const LlmStreamDone(LlmFinishReason.stop);
    }
  }

  @override
  Future<bool> testCredential(String apiKey) async {
    try {
      final response = await _http.get(
        Uri.parse('${catalogEntry.baseUrl}/models'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          ...catalogEntry.extraHeaders,
        },
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static LlmFinishReason _parseFinishReason(String raw) => switch (raw) {
        'tool_calls' => LlmFinishReason.toolCalls,
        'length' => LlmFinishReason.length,
        _ => LlmFinishReason.stop,
      };

  static Map<String, Object?> _encodeMessage(LlmMessage message) =>
      switch (message) {
        LlmSystemMessage(:final text) => {'role': 'system', 'content': text},
        LlmUserMessage(:final text) => {'role': 'user', 'content': text},
        LlmAssistantMessage(:final text, :final toolCalls) => {
            'role': 'assistant',
            'content': text,
            if (toolCalls.isNotEmpty)
              'tool_calls': toolCalls
                  .map((tc) => {
                        'id': tc.id,
                        'type': 'function',
                        'function': {
                          'name': tc.name,
                          'arguments': tc.argumentsJson,
                        },
                      })
                  .toList(),
          },
        LlmToolResultMessage(:final toolCallId, :final content) => {
            'role': 'tool',
            'tool_call_id': toolCallId,
            'content': content,
          },
      };

  static Map<String, Object?> _encodeTool(LlmToolSchema tool) => {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
      };
}
