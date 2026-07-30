import 'dart:async';
import 'dart:convert';
import 'dart:io';

var promptCount = 0;

void send(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

void respond(Object? id, Object? result) {
  send({'jsonrpc': '2.0', 'id': id, 'result': result});
}

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final message = Map<String, Object?>.from(
      jsonDecode(line) as Map<Object?, Object?>,
    );
    final method = message['method'];
    final id = message['id'];
    final params = Map<String, Object?>.from(
      (message['params'] as Map<Object?, Object?>?) ?? const {},
    );

    switch (method) {
      case 'initialize':
        respond(id, {
          'protocolVersion': 1,
          'agentCapabilities': const <String, Object?>{},
        });
      case 'session/new':
        respond(id, {'sessionId': 'opencode-session'});
      case 'session/prompt':
        promptCount += 1;
        final messageId = params['messageId'];
        send({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'opencode-session',
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'messageId': 'assistant-$promptCount',
              'content': {'type': 'text', 'text': 'reply $promptCount'},
            },
          },
        });
        respond(id, {'stopReason': 'end_turn'});
        if (promptCount == 1) {
          Timer(const Duration(milliseconds: 25), () {
            // OpenCode can persist additional metadata for the same user
            // message after the turn has already reached its terminal state.
            send({
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': {
                'sessionId': 'opencode-session',
                'update': {
                  'sessionUpdate': 'user_message_chunk',
                  'messageId': messageId,
                  'content': {'type': 'text', 'text': 'late metadata echo'},
                },
              },
            });
            // A harmless observable update drains the stream after the late
            // metadata so the regression test does not rely on sleeping.
            send({
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': {
                'sessionId': 'opencode-session',
                'update': {
                  'sessionUpdate': 'usage_update',
                  'inputTokens': 99,
                  'outputTokens': 1,
                },
              },
            });
          });
        }
      case 'session/cancel':
        return;
    }
  });
}
