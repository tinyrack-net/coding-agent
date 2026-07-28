import 'dart:async';
import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

Future<void> main() async {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) async {
    final message = (jsonDecode(line) as Map).cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];

    if (method is String &&
        {
          'initialize',
          'initialized',
          'getUserSavedConfig',
          'config/read',
          'model/list',
          'thread/loaded/list',
          'thread/resume',
          'thread/read',
          'thread/start',
          'thread/fork',
          'thread/rollback',
          'turn/start',
          'turn/interrupt',
        }.contains(method)) {
      send({
        'method': 'test/request',
        'params': {'method': method, 'params': message['params']},
      });
    }

    if (id is int && method == 'initialize') {
      send({'id': id, 'result': <String, Object?>{}});
      return;
    }
    if (method == 'initialized') {
      return;
    }
    if (id is int && method == 'getUserSavedConfig') {
      if (Platform.environment['CODEX_FIXTURE_CONFIG_MODE'] == 'model-list') {
        send({'id': id, 'error': true});
      } else {
        send({
          'id': id,
          'result': {
            'config': {'model': 'gpt-saved', 'modelReasoningEffort': 'high'},
          },
        });
      }
      return;
    }
    if (id is int && method == 'config/read') {
      final mode = Platform.environment['CODEX_FIXTURE_CONFIG_MODE'];
      send({
        'id': id,
        'result': {
          'config': mode == 'config-read'
              ? {'model': 'gpt-config', 'model_reasoning_effort': 'medium'}
              : <String, Object?>{},
        },
      });
      return;
    }
    if (id is int && method == 'model/list') {
      send({
        'id': id,
        'result': {
          'data': [
            {
              'id': 'gpt-fallback',
              'isDefault': true,
              'defaultReasoningEffort': 'low',
            },
          ],
        },
      });
      return;
    }
    if (id is int && method == 'thread/loaded/list') {
      send({
        'id': id,
        'result': {
          'data': Platform.environment['CODEX_FIXTURE_THREAD_LOADED'] == 'true'
              ? ['resume-thread']
              : <String>[],
        },
      });
      return;
    }
    if (id is int && method == 'thread/resume') {
      send({'id': id, 'result': <String, Object?>{}});
      return;
    }
    if (id is int && method == 'thread/read') {
      final params = message['params'] as Map?;
      final threadId = params?['threadId'];
      if (Platform.environment['CODEX_FIXTURE_SUBAGENTS'] == 'true') {
        send({
          'id': id,
          'result': {
            'thread': {
              'turns': [
                {
                  'items': threadId == 'resume-thread'
                      ? [
                          {
                            'id': 'spawn-child',
                            'type': 'collabAgentToolCall',
                            'prompt': 'Inspect history',
                            'receiverThreadIds': ['child-thread'],
                            'agentsStates': {
                              'child-thread': {'status': 'completed'},
                            },
                          },
                        ]
                      : threadId == 'child-thread'
                      ? [
                          {
                            'id': 'child-answer',
                            'type': 'agentMessage',
                            'text': 'nested answer',
                          },
                          {
                            'id': 'spawn-grandchild',
                            'type': 'collabAgentToolCall',
                            'receiverThreadIds': ['grandchild-thread'],
                          },
                        ]
                      : [
                          {
                            'id': 'grandchild-answer',
                            'type': 'agentMessage',
                            'text': 'deep answer',
                          },
                        ],
                },
              ],
            },
          },
        });
        return;
      }
      send({
        'id': id,
        'result': {
          'thread': {
            'turns': [
              {
                'items': [
                  {
                    'id': 'history-user',
                    'type': 'userMessage',
                    'content': [
                      {'type': 'text', 'text': 'persisted prompt'},
                    ],
                  },
                  {
                    'id': 'history-assistant',
                    'type': 'agentMessage',
                    'text': 'persisted answer',
                  },
                ],
              },
            ],
          },
        },
      });
      return;
    }
    if (id is int && method == 'thread/start') {
      send({
        'id': id,
        'result': {
          'thread': {'id': 'thread-1'},
          'approvalsReviewer': message['params'] is Map
              ? (message['params'] as Map)['approvalsReviewer']
              : null,
        },
      });
      return;
    }
    if (id is int && method == 'turn/start') {
      send({'id': id, 'result': <String, Object?>{}});
      send({
        'method': 'turn/started',
        'params': {
          'threadId': 'thread-1',
          'turn': {'id': 'turn-1'},
        },
      });
      return;
    }
    if (id is int && method == 'turn/interrupt') {
      send({'id': id, 'result': <String, Object?>{}});
      send({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thread-1',
          'turn': {'status': 'interrupted'},
        },
      });
      return;
    }
    if (id is int && method == 'thread/fork') {
      send({
        'id': id,
        'result': {
          'thread': {
            'id': 'fork-1',
            'sessionId': 'session-1',
            'forkedFromId': 'thread-1',
            'turns': <Object?>[],
          },
          'model': 'gpt-saved',
          'modelProvider': 'openai',
          'serviceTier': null,
          'cwd': Directory.current.path,
          'runtimeWorkspaceRoots': [Directory.current.path],
          'instructionSources': ['AGENTS.md'],
          'approvalPolicy': 'on-request',
          'approvalsReviewer': null,
          'sandbox': 'workspace-write',
          'reasoningEffort': 'high',
        },
      });
      return;
    }
    if (id is int && method == 'thread/rollback') {
      send({
        'id': id,
        'result': {
          'thread': {'id': 'rollback-1'},
        },
      });
      return;
    }

    if (id is int && method == 'echo') {
      send({'id': id, 'result': message['params']});
      return;
    }
    if (id is int && method == 'null-result') {
      send({'id': id, 'result': null});
      return;
    }
    if (id is int && method == 'fail') {
      send({
        'id': id,
        'error': {'message': 'codex rejected the request'},
      });
      return;
    }
    if (id is int && method == 'unknown-fail') {
      send({'id': id, 'error': true});
      return;
    }
    if (id is int && method == 'hang') {
      return;
    }
    if (id is int && method == 'exit') {
      stderr.write('app-server exploded');
      await stderr.flush();
      exit(9);
    }
    if (method == 'trigger-notification') {
      send({'method': 'turn/completed', 'params': message['params']});
      return;
    }
    if (method == 'trigger-request') {
      send({
        'id': 700,
        'method': 'item/commandExecution/requestApproval',
        'params': message['params'],
      });
      return;
    }
    if (id == 700 && message.containsKey('result')) {
      send({'method': 'test/serverRequestResult', 'params': message['result']});
      return;
    }
    if (id == 700 && message.containsKey('error')) {
      send({'method': 'test/serverRequestError', 'params': message['error']});
    }
  });
}
