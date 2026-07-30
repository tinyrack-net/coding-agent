import 'dart:async';
import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

void respond(Object? id, Object? result) {
  send({'jsonrpc': '2.0', 'id': id, 'result': result});
}

void update(Map<String, Object?> value) {
  send({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'sessionId': 'opencode-session', 'update': value},
  });
}

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final message = Map<String, Object?>.from(
      jsonDecode(line) as Map<Object?, Object?>,
    );
    final method = message['method'];
    final id = message['id'];

    switch (method) {
      case 'initialize':
        respond(id, {
          'protocolVersion': 1,
          'agentCapabilities': const <String, Object?>{},
        });
      case 'session/new':
        respond(id, {'sessionId': 'opencode-session'});
      case 'session/prompt':
        update({
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'assistant-initial',
          'content': {'type': 'text', 'text': 'Initial work complete.'},
        });
        respond(id, {'stopReason': 'end_turn'});
        Timer(const Duration(milliseconds: 25), () {
          // OpenCode plugins can wake the exact parent session after background
          // work finishes, without Paseo issuing another session/prompt.
          update({
            'sessionUpdate': 'user_message_chunk',
            'messageId': 'background-complete',
            'content': {
              'type': 'text',
              'text':
                  '<system-reminder>All background tasks are complete.</system-reminder>',
            },
          });
          update({
            'sessionUpdate': 'agent_message_chunk',
            'messageId': 'assistant-follow-up',
            'content': {
              'type': 'text',
              'text': 'I incorporated the completed background result.',
            },
          });
          // Observable stream barrier so the test never relies on sleeping.
          update({
            'sessionUpdate': 'usage_update',
            'inputTokens': 41,
            'outputTokens': 9,
          });
        });
      case 'session/cancel':
        return;
    }
  });
}
