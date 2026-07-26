import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_daemon/src/providers/native/openai_compatible_backend.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _config = ProviderConfig(
  id: 'openai-1',
  displayName: 'OpenAI',
  kind: ProviderKind.openaiCompatible,
  baseUrl: 'https://api.openai.example/v1',
  models: [ProviderModel(id: 'fallback-model', displayName: 'Fallback')],
);

http.StreamedResponse _sseResponse(
  List<String> lines, {
  int statusCode = 200,
}) {
  final body = lines.map((l) => 'data: $l\n\n').join();
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    statusCode,
  );
}

void main() {
  group('OpenAiCompatibleBackend.chat', () {
    test('streams text deltas then a stop-finish event', () async {
      late http.BaseRequest capturedRequest;
      String? capturedBody;
      final client = MockClient.streaming((request, bodyStream) async {
        capturedRequest = request;
        capturedBody = await utf8.decoder.bind(bodyStream).join();
        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Hello'},
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {
                'delta': {'content': ', world'},
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
          }),
          '[DONE]',
        ]);
      });
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);

      final events = await backend
          .chat(
            messages: const [LlmUserMessage('hi')],
            tools: const [],
            model: 'gpt-5.4-codex',
            apiKey: 'sk-test',
          )
          .toList();

      expect(events, [
        isA<LlmTextDelta>().having((e) => e.text, 'text', 'Hello'),
        isA<LlmTextDelta>().having((e) => e.text, 'text', ', world'),
        isA<LlmStreamDone>()
            .having((e) => e.finishReason, 'finishReason', LlmFinishReason.stop),
      ]);

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.toString(),
          'https://api.openai.example/v1/chat/completions');
      expect(capturedRequest.headers['Authorization'], 'Bearer sk-test');

      final decodedBody = jsonDecode(capturedBody!) as Map<String, Object?>;
      expect(decodedBody['model'], 'gpt-5.4-codex');
      expect(decodedBody['stream'], isTrue);
      expect(decodedBody['messages'], [
        {'role': 'user', 'content': 'hi'},
      ]);
    });

    test('adds provider extraHeaders (e.g. OpenRouter)', () async {
      late http.BaseRequest capturedRequest;
      final client = MockClient.streaming((request, bodyStream) async {
        capturedRequest = request;
        await bodyStream.drain<void>();
        return _sseResponse(['[DONE]']);
      });
      final backend = OpenAiCompatibleBackend(
        config: _config.copyWith(extraHeaders: const {'HTTP-Referer': 'https://tinyrack.net', 'X-Title': 'coding-agent'}),
        httpClient: client,
      );

      await backend
          .chat(
            messages: const [LlmUserMessage('hi')],
            tools: const [],
            model: 'openai/gpt-5.4',
            apiKey: 'or-key',
          )
          .toList();

      expect(capturedRequest.headers['HTTP-Referer'], 'https://tinyrack.net');
      expect(capturedRequest.headers['X-Title'], 'coding-agent');
    });

    test('streams tool-call deltas and a tool_calls-finish event', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'read_file', 'arguments': ''},
                    },
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '{"path":"a.txt"}'},
                    },
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
            ],
          }),
        ]);
      });
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);

      final events = await backend
          .chat(
            messages: const [LlmUserMessage('read a.txt')],
            tools: const [
              LlmToolSchema(
                name: 'read_file',
                description: 'Read a file',
                parameters: {'type': 'object'},
              ),
            ],
            model: 'gpt-5.4-codex',
            apiKey: 'sk-test',
          )
          .toList();

      expect(events, [
        isA<LlmToolCallDelta>()
            .having((e) => e.id, 'id', 'call_1')
            .having((e) => e.name, 'name', 'read_file'),
        isA<LlmToolCallDelta>()
            .having((e) => e.argumentsChunk, 'argumentsChunk', '{"path":"a.txt"}'),
        isA<LlmStreamDone>().having(
            (e) => e.finishReason, 'finishReason', LlmFinishReason.toolCalls),
      ]);
    });

    test('encodes assistant tool-call history and tool-result messages',
        () async {
      String? capturedBody;
      final client = MockClient.streaming((request, bodyStream) async {
        capturedBody = await utf8.decoder.bind(bodyStream).join();
        return _sseResponse(['[DONE]']);
      });
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);

      await backend
          .chat(
            messages: const [
              LlmUserMessage('read a.txt'),
              LlmAssistantMessage(
                toolCalls: [
                  LlmToolCall(
                    id: 'call_1',
                    name: 'read_file',
                    argumentsJson: '{"path":"a.txt"}',
                  ),
                ],
              ),
              LlmToolResultMessage(toolCallId: 'call_1', content: 'file contents'),
            ],
            tools: const [],
            model: 'gpt-5.4-codex',
            apiKey: 'sk-test',
          )
          .toList();

      final messages = (jsonDecode(capturedBody!)
          as Map<String, Object?>)['messages'] as List;
      expect(messages[1], {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{"path":"a.txt"}'},
          },
        ],
      });
      expect(messages[2], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'file contents',
      });
    });

    test('yields LlmStreamError on non-200 status', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream.value(utf8.encode('invalid api key')),
          401,
        );
      });
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);

      final events = await backend
          .chat(
            messages: const [LlmUserMessage('hi')],
            tools: const [],
            model: 'gpt-5.4-codex',
            apiKey: 'bad-key',
          )
          .toList();

      expect(events, hasLength(1));
      expect(events.single, isA<LlmStreamError>());
      expect(
        (events.single as LlmStreamError).message,
        contains('401'),
      );
    });

    test('yields LlmStreamError when the request throws', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        throw const SocketExceptionStub();
      });
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);

      final events = await backend
          .chat(
            messages: const [LlmUserMessage('hi')],
            tools: const [],
            model: 'gpt-5.4-codex',
            apiKey: 'sk-test',
          )
          .toList();

      expect(events, hasLength(1));
      expect(events.single, isA<LlmStreamError>());
    });
  });

  group('OpenAiCompatibleBackend.testCredential', () {
    test('returns true on HTTP 200', () async {
      final client = MockClient((request) async => http.Response('{}', 200));
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('ds-key'), isTrue);
    });

    test('returns false on non-200', () async {
      final client = MockClient((request) async => http.Response('nope', 401));
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('bad-key'), isFalse);
    });

    test('returns false when the request throws', () async {
      final client = MockClient((request) async => throw Exception('boom'));
      final backend =
          OpenAiCompatibleBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('ds-key'), isFalse);
    });
  });
}

/// Minimal stand-in for a thrown I/O error — the backend only cares that
/// [http.Client.send] threw, not the concrete exception type.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
