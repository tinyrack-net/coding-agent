import 'dart:async';
import 'dart:convert';
import 'dart:io';

void respond(Object? id, Object? result) {
  stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
}

Future<void> main() async {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) async {
    final message = (jsonDecode(line) as Map).cast<String, Object?>();
    final method = message['method'];
    final params = ((message['params'] as Map?) ?? const {})
        .cast<String, Object?>();
    switch (method) {
      case 'echo':
        await Future<void>.delayed(
          Duration(milliseconds: params['delayMs'] as int? ?? 0),
        );
        respond(message['id'], {'value': params['value']});
      case 'hang':
        stderr.write('still summarizing');
        await stderr.flush();
      case 'exit':
        stderr.write('provider exited');
        await stderr.flush();
        exit(7);
    }
  });
}
