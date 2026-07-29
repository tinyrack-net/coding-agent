import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'binary forwards a root output option which precedes a command',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final binary = p.join(packageRoot, 'bin', 'coding_agent.dart');
      final home = Directory.systemTemp.createTempSync('cli-root-output-');
      addTearDown(() => home.deleteSync(recursive: true));
      final environment = {
        ...Platform.environment,
        'TINYRACK_HOME': home.path,
        'TINYRACK_LISTEN': '127.0.0.1:1',
      };

      final result = await Process.run(
        Platform.resolvedExecutable,
        [binary, '--json', 'provider', 'ls', '--host', '127.0.0.1:1'],
        workingDirectory: packageRoot,
        environment: environment,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, isEmpty);
      final json = jsonDecode(result.stdout as String) as List<dynamic>;
      expect(json, isNotEmpty);
      expect((json.first as Map<String, dynamic>)['provider'], isNotEmpty);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
