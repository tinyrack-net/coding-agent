import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/providers/native/anthropic_backend.dart';
import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _config = ProviderConfig(
  id: 'claude-1',
  displayName: 'Claude',
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.example/v1',
  models: [ProviderModel(id: 'fallback-model', displayName: 'Fallback')],
  maxTokens: 4096,
);

/// Anthropic emits `event:` + `data:` pairs; only `data:` carries the payload.
http.StreamedResponse _sse(List<Object> events, {int statusCode = 200}) {
  final body = events.map((e) {
    final json = e is String ? e : jsonEncode(e);
    final type = e is Map ? e['type'] : 'message';
    return 'event: $type\ndata: $json\n\n';
  }).join();
  return http.StreamedResponse(Stream.value(utf8.encode(body)), statusCode);
}

Future<List<LlmStreamEvent>> _run(
  AnthropicBackend backend, {
  List<LlmMessage> messages = const [LlmUserMessage('hi')],
  List<LlmToolSchema> tools = const [],
}) =>
    backend
        .chat(
          messages: messages,
          tools: tools,
          model: 'claude-opus-4-8',
          apiKey: 'sk-ant-test',
        )
        .toList();

void main() {
  group('AnthropicBackend.chat request shape', () {
    test('sends the required headers, endpoint, and max_tokens', () async {
      late http.BaseRequest request;
      Map<String, Object?>? body;
      final client = MockClient.streaming((req, bodyStream) async {
        request = req;
        body = jsonDecode(await utf8.decoder.bind(bodyStream).join())
            as Map<String, Object?>;
        return _sse([
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          },
        ]);
      });

      await _run(AnthropicBackend(config: _config, httpClient: client));

      expect(request.url.toString(),
          'https://api.anthropic.example/v1/messages');
      expect(request.method, 'POST');
      expect(request.headers['x-api-key'], 'sk-ant-test');
      expect(request.headers['anthropic-version'], '2023-06-01');
      // max_tokens is mandatory — omitting it 400s every request.
      expect(body!['max_tokens'], 4096);
      expect(body!['stream'], isTrue);
      expect(body!['model'], 'claude-opus-4-8');
      expect(body!.containsKey('system'), isFalse);
    });

    test('merges configured extraHeaders', () async {
      late http.BaseRequest request;
      final client = MockClient.streaming((req, _) async {
        request = req;
        return _sse([]);
      });
      await _run(AnthropicBackend(
        config: _config.copyWith(extraHeaders: {'X-Title': 'coding-agent'}),
        httpClient: client,
      ));
      expect(request.headers['X-Title'], 'coding-agent');
    });

    test('hoists system messages into the top-level system field', () async {
      Map<String, Object?>? body;
      final client = MockClient.streaming((_, bodyStream) async {
        body = jsonDecode(await utf8.decoder.bind(bodyStream).join())
            as Map<String, Object?>;
        return _sse([]);
      });

      await _run(
        AnthropicBackend(config: _config, httpClient: client),
        messages: const [
          LlmSystemMessage('be terse'),
          LlmSystemMessage('use tools'),
          LlmUserMessage('hi'),
        ],
      );

      expect(body!['system'], 'be terse\n\nuse tools');
      final messages = body!['messages'] as List;
      // System must not remain in the messages array — the API rejects it.
      expect(messages, hasLength(1));
      expect((messages.single as Map)['role'], 'user');
    });

    test('encodes tools with input_schema, not function/parameters', () async {
      Map<String, Object?>? body;
      final client = MockClient.streaming((_, bodyStream) async {
        body = jsonDecode(await utf8.decoder.bind(bodyStream).join())
            as Map<String, Object?>;
        return _sse([]);
      });

      await _run(
        AnthropicBackend(config: _config, httpClient: client),
        tools: const [
          LlmToolSchema(
            name: 'read_file',
            description: 'Read a file',
            parameters: {'type': 'object'},
          ),
        ],
      );

      final tool = (body!['tools'] as List).single as Map<String, Object?>;
      expect(tool['name'], 'read_file');
      expect(tool['description'], 'Read a file');
      expect(tool['input_schema'], {'type': 'object'});
      expect(tool.containsKey('function'), isFalse);
    });

    test('omits tools entirely when none are given', () async {
      Map<String, Object?>? body;
      final client = MockClient.streaming((_, bodyStream) async {
        body = jsonDecode(await utf8.decoder.bind(bodyStream).join())
            as Map<String, Object?>;
        return _sse([]);
      });
      await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(body!.containsKey('tools'), isFalse);
    });
  });

  group('AnthropicBackend message encoding', () {
    Future<List<Object?>> encode(List<LlmMessage> messages) async {
      Map<String, Object?>? body;
      final client = MockClient.streaming((_, bodyStream) async {
        body = jsonDecode(await utf8.decoder.bind(bodyStream).join())
            as Map<String, Object?>;
        return _sse([]);
      });
      await _run(
        AnthropicBackend(config: _config, httpClient: client),
        messages: messages,
      );
      return body!['messages'] as List;
    }

    test('user text becomes a text content block', () async {
      final messages = await encode(const [LlmUserMessage('hello')]);
      expect(messages.single, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
      });
    });

    test('tool_use input is a decoded object, not a JSON string', () async {
      final messages = await encode(const [
        LlmUserMessage('read it'),
        LlmAssistantMessage(
          text: 'Reading.',
          toolCalls: [
            LlmToolCall(
              id: 'toolu_1',
              name: 'read_file',
              argumentsJson: '{"path":"a.txt"}',
            ),
          ],
        ),
      ]);
      final blocks = (messages.last as Map)['content'] as List;
      expect(blocks.first, {'type': 'text', 'text': 'Reading.'});
      expect(blocks.last, {
        'type': 'tool_use',
        'id': 'toolu_1',
        'name': 'read_file',
        'input': {'path': 'a.txt'},
      });
    });

    test('undecodable or empty tool arguments fall back to {}', () async {
      final messages = await encode(const [
        LlmUserMessage('go'),
        LlmAssistantMessage(
          toolCalls: [
            LlmToolCall(id: 't1', name: 'a', argumentsJson: '{"trunc'),
            LlmToolCall(id: 't2', name: 'b', argumentsJson: ''),
            LlmToolCall(id: 't3', name: 'c', argumentsJson: '"a string"'),
          ],
        ),
      ]);
      final blocks = (messages.last as Map)['content'] as List;
      for (final block in blocks) {
        expect((block as Map)['input'], isEmpty);
      }
    });

    // NativeSession appends one LlmToolResultMessage per tool call, and the
    // API rejects parallel results split across messages.
    test('consecutive tool results merge into one user message', () async {
      final messages = await encode(const [
        LlmUserMessage('go'),
        LlmAssistantMessage(
          toolCalls: [
            LlmToolCall(id: 't1', name: 'a', argumentsJson: '{}'),
            LlmToolCall(id: 't2', name: 'b', argumentsJson: '{}'),
          ],
        ),
        LlmToolResultMessage(toolCallId: 't1', content: 'first'),
        LlmToolResultMessage(toolCallId: 't2', content: 'second'),
      ]);

      expect(messages, hasLength(3));
      final resultMessage = messages.last as Map;
      expect(resultMessage['role'], 'user');
      final blocks = resultMessage['content'] as List;
      expect(blocks, hasLength(2));
      expect(blocks[0], {
        'type': 'tool_result',
        'tool_use_id': 't1',
        'content': 'first',
      });
      expect(blocks[1], {
        'type': 'tool_result',
        'tool_use_id': 't2',
        'content': 'second',
      });
    });

    test('non-consecutive tool results stay in separate messages', () async {
      final messages = await encode(const [
        LlmToolResultMessage(toolCallId: 't1', content: 'a'),
        LlmUserMessage('interjection'),
        LlmToolResultMessage(toolCallId: 't2', content: 'b'),
      ]);
      expect(messages, hasLength(3));
      expect(((messages[0] as Map)['content'] as List), hasLength(1));
      expect((messages[1] as Map)['role'], 'user');
      expect(((messages[2] as Map)['content'] as List), hasLength(1));
    });

    test('an assistant message with no text and no tools is dropped', () async {
      // An empty content array is rejected by the API.
      final messages = await encode(const [
        LlmUserMessage('hi'),
        LlmAssistantMessage(),
      ]);
      expect(messages, hasLength(1));
      expect((messages.single as Map)['role'], 'user');
    });

    test('an empty-string assistant text emits no text block', () async {
      final messages = await encode(const [
        LlmUserMessage('hi'),
        LlmAssistantMessage(
          text: '',
          toolCalls: [LlmToolCall(id: 't1', name: 'a', argumentsJson: '{}')],
        ),
      ]);
      final blocks = (messages.last as Map)['content'] as List;
      expect(blocks, hasLength(1));
      expect((blocks.single as Map)['type'], 'tool_use');
    });
  });

  group('AnthropicBackend.chat streaming', () {
    test('streams text deltas then a stop event', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'Hello'},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': ', world'},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
            {'type': 'message_stop'},
          ]));

      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));

      expect(events, hasLength(3));
      expect((events[0] as LlmTextDelta).text, 'Hello');
      expect((events[1] as LlmTextDelta).text, ', world');
      expect((events[2] as LlmStreamDone).finishReason, LlmFinishReason.stop);
    });

    test('empty text deltas are skipped', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': ''},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events.whereType<LlmTextDelta>(), isEmpty);
    });

    test('tool_use start then input_json_delta chunks', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'content_block_start',
              'index': 1,
              'content_block': {
                'type': 'tool_use',
                'id': 'toolu_abc',
                'name': 'read_file',
              },
            },
            {
              'type': 'content_block_delta',
              'index': 1,
              'delta': {'type': 'input_json_delta', 'partial_json': '{"path"'},
            },
            {
              'type': 'content_block_delta',
              'index': 1,
              'delta': {'type': 'input_json_delta', 'partial_json': ':"a.txt"}'},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'tool_use'},
            },
          ]));

      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));

      final deltas = events.whereType<LlmToolCallDelta>().toList();
      expect(deltas, hasLength(3));
      // Block index is preserved: it mixes text and tool blocks and is not
      // zero-based for tools. NativeSession keys builders on it.
      expect(deltas[0].index, 1);
      expect(deltas[0].id, 'toolu_abc');
      expect(deltas[0].name, 'read_file');
      expect(deltas[0].argumentsChunk, isNull);
      expect(deltas[1].argumentsChunk, '{"path"');
      expect(deltas[2].argumentsChunk, ':"a.txt"}');
      expect(
        (events.last as LlmStreamDone).finishReason,
        LlmFinishReason.toolCalls,
      );
    });

    test('a text content_block_start emits nothing', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'text', 'text': ''},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events.whereType<LlmToolCallDelta>(), isEmpty);
      expect(events, hasLength(1));
    });

    test('maps max_tokens stop_reason to length', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'max_tokens'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect((events.single as LlmStreamDone).finishReason,
          LlmFinishReason.length);
    });

    test('maps an unrecognized stop_reason to stop', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'pause_turn'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(
          (events.single as LlmStreamDone).finishReason, LlmFinishReason.stop);
    });

    test('an error event terminates with LlmStreamError', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'error',
              'error': {'type': 'overloaded_error', 'message': 'overloaded'},
            },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events, hasLength(1));
      expect((events.single as LlmStreamError).message, 'overloaded');
    });

    test('an error event without a message still errors', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {'type': 'error'},
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect((events.single as LlmStreamError).message,
          'provider reported an error');
    });

    test('a non-200 response yields LlmStreamError with the body', () async {
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"bad key"}')),
          401,
        ),
      );
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events.single, isA<LlmStreamError>());
      expect((events.single as LlmStreamError).message,
          'HTTP 401: {"error":"bad key"}');
    });

    test('a transport failure yields LlmStreamError', () async {
      final client = MockClient.streaming(
        (_, __) async => throw const SocketExceptionStub(),
      );
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect((events.single as LlmStreamError).message,
          startsWith('request failed:'));
    });

    test('a mid-stream read failure yields LlmStreamError', () async {
      // The connection drops after headers but before the stream completes.
      final client = MockClient.streaming(
        (_, __) async => http.StreamedResponse(
          Stream<List<int>>.error(const SocketExceptionStub()),
          200,
        ),
      );
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events.single, isA<LlmStreamError>());
      expect((events.single as LlmStreamError).message,
          startsWith('stream read failed:'));
    });

    test('a malformed data line is skipped', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            '{not json',
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events, hasLength(1));
      expect(events.single, isA<LlmStreamDone>());
    });

    test('a stream closing without stop_reason still terminates', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'partial'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events.last, isA<LlmStreamDone>());
      expect(
          (events.last as LlmStreamDone).finishReason, LlmFinishReason.stop);
    });

    test('message_stop ends the loop without a duplicate Done', () async {
      final client = MockClient.streaming((_, __) async => _sse([
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
            {'type': 'message_stop'},
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'after stop'},
            },
          ]));
      final events =
          await _run(AnthropicBackend(config: _config, httpClient: client));
      expect(events, hasLength(1));
      expect(events.single, isA<LlmStreamDone>());
    });
  });

  group('AnthropicBackend.testCredential', () {
    test('true on 200', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(),
            'https://api.anthropic.example/v1/models');
        expect(request.headers['x-api-key'], 'sk-ant-test');
        expect(request.headers['anthropic-version'], '2023-06-01');
        return http.Response(jsonEncode({'data': []}), 200);
      });
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('sk-ant-test'), isTrue);
    });

    test('false on 401', () async {
      final client = MockClient((_) async => http.Response('nope', 401));
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('bad'), isFalse);
    });

    test('false when the request throws', () async {
      final client =
          MockClient((_) async => throw const SocketExceptionStub());
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect(await backend.testCredential('x'), isFalse);
    });
  });

  group('AnthropicBackend.fetchModels', () {
    test('maps display_name from the models endpoint', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'data': [
                {'id': 'claude-opus-4-8', 'display_name': 'Claude Opus 4.8'},
                {'id': 'claude-sonnet-5'},
              ],
            }),
            200,
          ));
      final backend = AnthropicBackend(config: _config, httpClient: client);
      final models = await backend.fetchModels('sk-ant-test');
      expect(models, hasLength(2));
      expect(models[0].id, 'claude-opus-4-8');
      expect(models[0].displayName, 'Claude Opus 4.8');
      // Falls back to the id when display_name is absent.
      expect(models[1].displayName, 'claude-sonnet-5');
    });

    test('falls back to config models on non-200', () async {
      final client = MockClient((_) async => http.Response('nope', 403));
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect((await backend.fetchModels('x')).single.id, 'fallback-model');
    });

    test('falls back to config models on an empty list', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode({'data': []}), 200),
      );
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect((await backend.fetchModels('x')).single.id, 'fallback-model');
    });

    test('falls back when every entry lacks a usable id', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'id': ''},
              'not-a-map',
            ],
          }),
          200,
        ),
      );
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect((await backend.fetchModels('x')).single.id, 'fallback-model');
    });

    // Claude-compatible gateways often don't implement /models at all.
    test('falls back when the request throws', () async {
      final client =
          MockClient((_) async => throw const SocketExceptionStub());
      final backend = AnthropicBackend(config: _config, httpClient: client);
      expect((await backend.fetchModels('x')).single.id, 'fallback-model');
    });
  });
}

/// Stand-in for a transport failure; avoids importing dart:io for one type.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'connection refused';
}
