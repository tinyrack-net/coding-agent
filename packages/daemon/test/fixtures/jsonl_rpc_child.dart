import 'dart:async';
import 'dart:convert';
import 'dart:io';

void respond(
  Map<String, Object?> command, {
  required bool success,
  Object? data,
  String? error,
}) {
  stdout.writeln(
    jsonEncode({
      'type': 'response',
      'id': command['id'],
      'command': command['type'],
      'success': success,
      'data': data,
      'error': error,
    }),
  );
}

Future<void> main(List<String> args) async {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) async {
    final command = (jsonDecode(line) as Map).cast<String, Object?>();
    switch (command['type']) {
      case 'echo':
        await Future<void>.delayed(
          Duration(milliseconds: command['delayMs'] as int? ?? 0),
        );
        respond(
          command,
          success: true,
          data: {
            'value': command['value'],
            'cwd': Directory.current.path,
            'env': Platform.environment['JSONL_RPC_TEST_VALUE'],
            'args': args,
          },
        );
      case 'emit':
        stdout.writeln('not json');
        stdout.write('{"type":"notice","text":"a');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        stdout.write('\\u2028b"}\r\n');
        respond(command, success: true);
      case 'fail':
        respond(command, success: false, error: 'child rejected the request');
      case 'default-fail':
        respond(command, success: false);
      case 'hang':
        stderr.write('still waiting');
      case 'large-stderr':
        stderr.write('${'x' * 9000}tail');
        await stderr.flush();
        respond(command, success: true);
      case 'exit':
        stderr.write('child exploded');
        await stderr.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        exit(7);
    }
  });
}
