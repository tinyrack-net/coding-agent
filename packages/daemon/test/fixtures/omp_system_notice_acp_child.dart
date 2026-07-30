import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

void respond(Object? id, Object? result) {
  send({'jsonrpc': '2.0', 'id': id, 'result': result});
}

void update(String messageId, String text) {
  send({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {
      'sessionId': 'omp-session',
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'messageId': messageId,
        'content': {'type': 'text', 'text': text},
      },
    },
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
        respond(id, {'sessionId': 'omp-session'});
      case 'session/prompt':
        update('assistant-normal', 'do');
        update('omp-background-notice', '<system-no');
        update('assistant-normal', 'ne');
        update('omp-background-notice', '''tice>
Background job DocsSmokeTwo has completed.
<task-result id="DocsSmokeTwo" agent="explore" status="completed" duration="21.6s">
<output>done</output>''');
        update('assistant-custom', 'plain custom ');
        update('omp-background-notice', '''
</task-result>
</system-notice>''');
        update('assistant-custom', 'status text');
        update(
          'omp-incomplete-notice',
          '<system-notice>\nBackground job StillRunning is pending.',
        );
        respond(id, {'stopReason': 'end_turn'});
      case 'session/cancel':
        return;
    }
  });
}
