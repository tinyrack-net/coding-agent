import 'dart:convert';
import 'dart:io';

Object? pendingPromptId;
Object? pendingRuntimeSessionId;
String? pendingRuntimeTerminalId;
String? pendingRuntimeFile;
var pendingPromptWaitsForCancel = false;
var configMode = 'default';
var configModel = 'base-model';
var configThinking = 'low';

bool get configOnly =>
    Platform.environment['ACP_FIXTURE_CONFIG_ONLY'] == 'true';
bool get supportsSessionList =>
    Platform.environment['ACP_FIXTURE_NO_LIST'] != 'true';
bool get supportsSessionLoad =>
    Platform.environment['ACP_FIXTURE_NO_LOAD'] != 'true';
bool get malformedSessionList =>
    Platform.environment['ACP_FIXTURE_MALFORMED_LIST'] == 'true';
bool get failSessionLoad =>
    Platform.environment['ACP_FIXTURE_LOAD_FAIL'] == 'true';
bool get expectClientRuntime =>
    Platform.environment['ACP_FIXTURE_EXPECT_CLIENT_RUNTIME'] == 'true';
bool get expectNoMcp =>
    Platform.environment['ACP_FIXTURE_EXPECT_NO_MCP'] == 'true';
bool get expectRuntimeMcp =>
    Platform.environment['ACP_FIXTURE_EXPECT_RUNTIME_MCP'] == 'true';
bool get exerciseClientRuntime =>
    Platform.environment['ACP_FIXTURE_EXERCISE_CLIENT_RUNTIME'] == 'true';
bool get requireSessionEnvironment =>
    Platform.environment['ACP_FIXTURE_REQUIRE_SESSION_ENV'] == 'true';

List<Map<String, Object?>> configOnlyOptions() => [
  {
    'id': 'agent-mode',
    'name': 'Mode',
    'category': 'mode',
    'type': 'select',
    'currentValue': configMode,
    'options': [
      {'value': 'default', 'name': 'Default'},
      {'value': 'review', 'name': 'Review'},
    ],
  },
  {
    'id': 'model-picker',
    'name': 'Model',
    'category': 'model',
    'type': 'select',
    'currentValue': configModel,
    'options': [
      {'value': 'base-model', 'name': 'Base Model'},
      {'value': 'config-model', 'name': 'Config Model'},
    ],
  },
  {
    'id': 'reasoning',
    'name': 'Reasoning',
    'category': 'thought_level',
    'type': 'select',
    'currentValue': configThinking,
    'options': [
      {'value': 'low', 'name': 'Low'},
      {'value': 'high', 'name': 'High'},
    ],
  },
];

void send(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

void respond(Object? id, Object? result) {
  send({'jsonrpc': '2.0', 'id': id, 'result': result});
}

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final message = map(jsonDecode(line));
    final method = message['method'];
    final id = message['id'];
    final params = map(message['params'] ?? const {});

    if (method == null && exerciseClientRuntime) {
      switch ('$id') {
        case '600':
          if (map(message['result']).isNotEmpty) {
            throw StateError('unexpected write result');
          }
          send({
            'jsonrpc': '2.0',
            'id': 601,
            'method': 'fs/read_text_file',
            'params': {
              'sessionId': 'session-1',
              'path': pendingRuntimeFile,
              'line': 2,
              'limit': 1,
            },
          });
          return;
        case '601':
          final result = map(message['result']);
          if (result['content'] != 'two') {
            throw StateError('unexpected read result: ${result['content']}');
          }
          File(pendingRuntimeFile!).deleteSync();
          send({
            'jsonrpc': '2.0',
            'id': 602,
            'method': 'terminal/create',
            'params': {
              'sessionId': 'session-1',
              'command': Platform.resolvedExecutable,
              'args': [
                Platform.script.resolve('acp_terminal_child.dart').toFilePath(),
                'rpc',
              ],
              'cwd': Directory.current.path,
              'env': [
                {'name': 'ACP_TERMINAL_ENV', 'value': 'rpc'},
              ],
              'outputByteLimit': 200,
            },
          });
          return;
        case '602':
          pendingRuntimeTerminalId =
              map(message['result'])['terminalId']! as String;
          send({
            'jsonrpc': '2.0',
            'id': 603,
            'method': 'terminal/wait_for_exit',
            'params': {
              'sessionId': 'session-1',
              'terminalId': pendingRuntimeTerminalId,
            },
          });
          return;
        case '603':
          if (map(message['result'])['exitCode'] != 0) {
            throw StateError('terminal did not exit successfully');
          }
          send({
            'jsonrpc': '2.0',
            'id': 604,
            'method': 'terminal/output',
            'params': {
              'sessionId': 'session-1',
              'terminalId': pendingRuntimeTerminalId,
            },
          });
          return;
        case '604':
          final output = map(message['result'])['output'] as String;
          if (!output.contains('stdout:rpc') ||
              !output.contains(':stderr:rpc')) {
            throw StateError('unexpected terminal output: $output');
          }
          send({
            'jsonrpc': '2.0',
            'id': 605,
            'method': 'terminal/release',
            'params': {
              'sessionId': 'session-1',
              'terminalId': pendingRuntimeTerminalId,
            },
          });
          return;
        case '605':
          respond(pendingRuntimeSessionId, {'sessionId': 'session-1'});
          pendingRuntimeSessionId = null;
          pendingRuntimeTerminalId = null;
          return;
      }
    }

    if (method == null && '$id' == '500') {
      final result = map(message['result']);
      final outcome = map(result['outcome']);
      if (outcome['outcome'] != 'selected' ||
          outcome['optionId'] != 'allow-once') {
        send({
          'jsonrpc': '2.0',
          'id': pendingPromptId,
          'error': {
            'code': -32000,
            'message': 'unexpected permission response',
          },
        });
        return;
      }
      send({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'session-1',
          'update': {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'tool-1',
            'status': 'completed',
            'rawOutput': {'text': 'done'},
          },
        },
      });
      respond(pendingPromptId, {
        'stopReason': 'end_turn',
        'usage': {
          'totalTokens': 10,
          'inputTokens': 6,
          'outputTokens': 4,
          'cachedReadTokens': 2,
        },
      });
      pendingPromptId = null;
      return;
    }

    switch (method) {
      case 'initialize':
        if (params['protocolVersion'] != 1 ||
            map(params['clientInfo'])['name'] != 'Tinyrack') {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'invalid initialize'},
          });
          return;
        }
        if (expectClientRuntime) {
          final clientCapabilities = map(params['clientCapabilities']);
          final filesystem = map(clientCapabilities['fs']);
          if (filesystem['readTextFile'] != true ||
              filesystem['writeTextFile'] != true ||
              clientCapabilities['terminal'] != true) {
            send({
              'jsonrpc': '2.0',
              'id': id,
              'error': {
                'code': -32602,
                'message': 'missing client runtime capabilities',
              },
            });
            return;
          }
        }
        send({
          'jsonrpc': '2.0',
          'id': '$id',
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              if (supportsSessionLoad) 'loadSession': true,
              'sessionCapabilities': {
                'resume': true,
                if (supportsSessionList) 'list': const {},
              },
            },
          },
        });
      case 'session/list':
        if (!supportsSessionList) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'session/list unsupported'},
          });
          return;
        }
        if (malformedSessionList) {
          respond(id, {'sessions': 'invalid', 'nextCursor': null});
          return;
        }
        final requestedCwd = params['cwd'] as String?;
        if (params['cursor'] == 'cursor-2') {
          respond(id, {
            'sessions': [
              {
                'sessionId': 'restored-session-2',
                'cwd': requestedCwd ?? Directory.current.path,
                'title': null,
                'updatedAt': null,
              },
            ],
            'nextCursor': null,
          });
          return;
        }
        respond(id, {
          'sessions': [
            {
              'sessionId': 'restored-session',
              'cwd': requestedCwd ?? Directory.current.path,
              'title': 'Imported ACP session',
              'updatedAt': '2026-06-13T00:00:00.000Z',
            },
          ],
          'nextCursor': 'cursor-2',
        });
      case 'session/load':
        if (params['cwd'] == null || params['mcpServers'] is! List) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'missing load context'},
          });
          return;
        }
        if (failSessionLoad) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32000, 'message': 'session/load failed'},
          });
          return;
        }
        final loadedSessionId = params['sessionId']! as String;
        for (final update in [
          {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': 'Restore '},
          },
          {
            'sessionUpdate': 'user_message_chunk',
            'content': {
              'type': 'image',
              'data': 'AA==',
              'mimeType': 'image/png',
            },
          },
          {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'assistant-replay-1',
            'content': {'type': 'text', 'text': 'Loaded'},
          },
          {
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'assistant-replay-1',
            'content': {'type': 'text', 'text': ' response'},
          },
          {
            'sessionUpdate': 'agent_thought_chunk',
            'messageId': 'reasoning-replay-1',
            'content': {'type': 'text', 'text': 'Recovered thought'},
          },
          {
            'sessionUpdate': 'tool_call',
            'toolCallId': 'tool-replay-1',
            'title': 'Read source',
            'kind': 'read',
            'status': 'pending',
            'rawInput': {'path': 'README.md'},
          },
          {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'tool-replay-1',
            'status': 'completed',
            'rawOutput': {'text': 'done'},
          },
          {
            'sessionUpdate': 'plan',
            'id': 'plan-replay-1',
            'entries': [
              {'content': 'Inspect repository', 'status': 'completed'},
              {'content': 'Continue port', 'status': 'pending'},
            ],
          },
        ]) {
          send({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {'sessionId': loadedSessionId, 'update': update},
          });
        }
        respond(id, {'sessionId': loadedSessionId});
      case 'session/new':
        final mcpServers = params['mcpServers'];
        if (requireSessionEnvironment &&
            Platform.environment['RUN_TOKEN'] != 'session-value') {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'missing session environment'},
          });
          return;
        }
        if (expectNoMcp && (mcpServers is! List || mcpServers.isNotEmpty)) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'MCP must be disabled'},
          });
          return;
        }
        if (expectClientRuntime &&
            Platform.environment['NO_BROWSER'] != 'true') {
          final expectedLength = expectRuntimeMcp ? 3 : 2;
          if (mcpServers is! List || mcpServers.length != expectedLength) {
            send({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32602, 'message': 'missing MCP servers'},
            });
            return;
          }
          final projected = mcpServers.map(map).toList(growable: false);
          final stdio = projected.singleWhere(
            (server) => server['name'] == 'local',
          );
          final http = projected.singleWhere(
            (server) => server['name'] == 'remote',
          );
          if (stdio['name'] != 'local' ||
              stdio['command'] != 'dart' ||
              (stdio['args'] as List).join(' ') != 'run server.dart' ||
              map((stdio['env'] as List).single)['name'] != 'TOKEN' ||
              http['type'] != 'http' ||
              http['name'] != 'remote' ||
              map((http['headers'] as List).single)['name'] !=
                  'Authorization') {
            send({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32602, 'message': 'invalid MCP projection'},
            });
            return;
          }
          if (expectRuntimeMcp) {
            final runtime = projected.singleWhere(
              (server) => server['name'] == 'tinyrack',
            );
            final runtimeUrl = Uri.tryParse('${runtime['url']}');
            final headers = runtime['headers'] as List?;
            if (runtime['type'] != 'http' ||
                runtimeUrl?.path != '/mcp/agents' ||
                runtimeUrl?.queryParameters['callerAgentId']?.isEmpty !=
                    false ||
                headers == null ||
                headers.length != 1 ||
                map(headers.single)['name'] != 'Authorization' ||
                !'${map(headers.single)['value']}'.startsWith('Bearer ')) {
              send({
                'jsonrpc': '2.0',
                'id': id,
                'error': {
                  'code': -32602,
                  'message': 'invalid runtime MCP projection',
                },
              });
              return;
            }
          }
        }
        if (exerciseClientRuntime) {
          pendingRuntimeSessionId = id;
          pendingRuntimeFile =
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'acp-runtime-$pid.txt';
          send({
            'jsonrpc': '2.0',
            'id': 600,
            'method': 'fs/write_text_file',
            'params': {
              'sessionId': 'session-1',
              'path': pendingRuntimeFile,
              'content': 'one\ntwo\nthree',
            },
          });
          return;
        }
        if (configOnly) {
          respond(id, {
            'sessionId': 'session-1',
            'configOptions': configOnlyOptions(),
          });
          return;
        }
        respond(id, {
          'sessionId': 'session-1',
          'models': {
            'availableModels': [
              {
                'modelId': 'fixture-model',
                'name': 'Fixture Model',
                'description': Platform.environment['NO_BROWSER'] == 'true'
                    ? 'Probe fixture model'
                    : 'Primary fixture model',
              },
              {
                'modelId': 'fixture-fast',
                'name': 'Fixture Fast',
                'description': 'Fast fixture model',
              },
            ],
            'currentModelId': 'fixture-model',
          },
          'modes': {
            'availableModes': [
              {'id': 'agent', 'name': 'Agent'},
              {'id': 'plan', 'name': 'Plan'},
            ],
            'currentModeId': 'agent',
          },
          'configOptions': [
            {
              'id': 'reasoning',
              'name': 'Reasoning',
              'category': 'thought_level',
              'type': 'select',
              'currentValue': 'medium',
              'options': [
                {'value': 'low', 'name': 'Low'},
                {'value': 'medium', 'name': 'Medium'},
                {'value': 'high', 'name': 'High'},
              ],
            },
          ],
          'availableCommands': [
            {
              'name': 'review',
              'description': 'Review changes',
              'input': {'hint': '[path]'},
            },
          ],
        });
      case 'session/resume':
        if (params['cwd'] == null || params['mcpServers'] is! List) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'missing resume context'},
          });
          return;
        }
        respond(id, {'sessionId': params['sessionId']});
      case 'session/set_mode':
      case 'session/set_model':
        if (configOnly) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32601,
              'message': 'explicit selection is unavailable',
            },
          });
          return;
        }
        respond(id, const {});
      case 'session/set_config_option':
        if (configOnly) {
          final configId = params['configId'];
          final value = params['value'];
          switch (configId) {
            case 'agent-mode':
              configMode = value! as String;
            case 'model-picker':
              configModel = value! as String;
            case 'reasoning':
              configThinking = value! as String;
            default:
              send({
                'jsonrpc': '2.0',
                'id': id,
                'error': {
                  'code': -32602,
                  'message': 'unexpected config option $configId',
                },
              });
              return;
          }
          respond(id, {'configOptions': configOnlyOptions()});
          return;
        }
        respond(id, const {});
      case 'session/prompt':
        pendingPromptId = id;
        final prompt = params['prompt'] as List;
        final text = prompt
            .map((item) => map(item)['text'])
            .whereType<String>()
            .join('|');
        pendingPromptWaitsForCancel = text.contains('wait-for-cancel');
        send({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'session-1',
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'messageId': 'message-1',
              'content': {'type': 'text', 'text': 'reply:$text'},
            },
          },
        });
        if (pendingPromptWaitsForCancel) return;
        send({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'session-1',
            'update': {
              'sessionUpdate': 'agent_thought_chunk',
              'messageId': 'thought-1',
              'content': {'type': 'text', 'text': 'thinking'},
            },
          },
        });
        send({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'session-1',
            'update': {
              'sessionUpdate': 'tool_call',
              'toolCallId': 'tool-1',
              'title': 'Run check',
              'kind': 'execute',
              'status': 'pending',
              'rawInput': {'command': 'dart test'},
            },
          },
        });
        send({
          'jsonrpc': '2.0',
          'id': 500,
          'method': 'session/request_permission',
          'params': {
            'sessionId': 'session-1',
            'toolCall': {
              'toolCallId': 'tool-1',
              'title': 'Run check',
              'kind': 'execute',
              'status': 'pending',
              'rawInput': {'command': 'dart test'},
            },
            'options': [
              {'optionId': 'allow-once', 'name': 'Allow', 'kind': 'allow_once'},
              {
                'optionId': 'reject-once',
                'name': 'Reject',
                'kind': 'reject_once',
              },
            ],
          },
        });
      case 'session/cancel':
        if (pendingPromptWaitsForCancel && pendingPromptId != null) {
          respond(pendingPromptId, {'stopReason': 'cancelled'});
          pendingPromptId = null;
          pendingPromptWaitsForCancel = false;
        }
    }
  });
}
