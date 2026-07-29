import 'dart:io';

import 'cli_version.dart';

/// Runs Paseo 0.2.0's intentionally empty speech command namespace.
///
/// The frozen command only registers the namespace and its description. As a
/// result, positional arguments and root output flags are accepted and ignored;
/// only the inherited version option and the command help produce output.
Future<int> runSpeechCommand({
  required List<String> arguments,
  void Function(String value)? writeOutput,
}) async {
  final output = writeOutput ?? stdout.write;
  if (arguments.contains('--version') || arguments.contains('-v')) {
    output('${resolveCliVersion()}\n');
    return 0;
  }
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(speechHelp);
  }
  return 0;
}

const speechHelp =
    'Usage: coding-agent speech [options]\n'
    '\n'
    'Speech commands\n'
    '\n'
    'Options:\n'
    '  -h, --help  display help for command\n';
