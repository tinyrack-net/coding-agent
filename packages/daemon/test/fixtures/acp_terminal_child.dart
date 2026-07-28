import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.contains('wait')) {
    await Completer<void>().future;
  }
  if (args.contains('unicode')) {
    stdout.write('🙂🙂🙂');
    return;
  }
  stdout.write('stdout:${Platform.environment['ACP_TERMINAL_ENV'] ?? ''}');
  stderr.write(':stderr:${args.join(',')}');
}
