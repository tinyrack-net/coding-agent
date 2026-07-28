import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || arguments.single.trim().isEmpty) {
    stderr.writeln('Usage: dart run tool/package_root.dart <package>');
    exitCode = 64;
    return;
  }
  final configFile = File('.dart_tool/package_config.json');
  if (!await configFile.exists()) {
    stderr.writeln('Missing ${configFile.path}; run flutter pub get first.');
    exitCode = 1;
    return;
  }
  final decoded = jsonDecode(await configFile.readAsString());
  if (decoded is! Map || decoded['packages'] is! List) {
    stderr.writeln('Invalid ${configFile.path}');
    exitCode = 1;
    return;
  }
  final configUri = configFile.absolute.uri;
  for (final entry in decoded['packages']! as List) {
    if (entry is! Map || entry['name'] != arguments.single) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) break;
    stdout.write(configUri.resolve(rootUri).toFilePath());
    return;
  }
  stderr.writeln('Package not found: ${arguments.single}');
  exitCode = 1;
}
