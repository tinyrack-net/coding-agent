import 'dart:convert';
import 'dart:io';

Object? pendingPromptId;
var pendingPromptWaitsForCancel = false;

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
        send({
          'jsonrpc': '2.0',
          'id': '$id',
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              'sessionCapabilities': {'resume': true},
            },
          },
        });
      case 'session/new':
        respond(id, {
          'sessionId': 'session-1',
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
      case 'session/set_config_option':
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
