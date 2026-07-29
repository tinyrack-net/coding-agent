import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../terminal/terminal_activity_hook.dart';

typedef HookInputReader = Future<String?> Function();
typedef HookActivityReporter =
    Future<void> Function({
      required String provider,
      required String event,
      required TerminalHookEnvironment environment,
      String? input,
      required bool inputIsTerminal,
    });

Future<int> runHooksCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  bool? inputIsTerminal,
  HookInputReader? readInput,
  HookActivityReporter report = _reportHookActivity,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    (writeOutput ?? stdout.write)(hooksHelp);
    return 0;
  }
  if (arguments.length != 2 ||
      arguments.any((value) => value.startsWith('-'))) {
    (writeError ?? stderr.write)('$hooksUsage\n');
    return 64;
  }

  final terminal = inputIsTerminal ?? stdin.hasTerminal;
  final input = terminal
      ? null
      : await (readInput ?? readHookInputWithTimeout)();
  await report(
    provider: arguments[0],
    event: arguments[1],
    environment: environment ?? Platform.environment,
    input: input,
    inputIsTerminal: terminal,
  );
  return 0;
}

Future<void> _reportHookActivity({
  required String provider,
  required String event,
  required TerminalHookEnvironment environment,
  String? input,
  required bool inputIsTerminal,
}) => reportTerminalHookActivity(
  provider: provider,
  event: event,
  environment: environment,
  input: input,
  inputIsTerminal: inputIsTerminal,
);

Future<String?> readHookInputWithTimeout() async {
  final iterator = StreamIterator<List<int>>(stdin);
  final bytes = <int>[];
  try {
    while (await iterator.moveNext().timeout(
      const Duration(milliseconds: 100),
    )) {
      bytes.addAll(iterator.current);
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on TimeoutException {
    await iterator.cancel();
    return null;
  }
}

const hooksUsage = 'Usage: coding-agent hooks <agent> <event>';
const hooksHelp =
    'Usage: coding-agent hooks <agent> <event>\n'
    'Record agent hook activity\n';
