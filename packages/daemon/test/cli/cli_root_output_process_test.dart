import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'binary forwards root output options which precede a command',
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

      final results = await Future.wait([
        Process.run(
          Platform.resolvedExecutable,
          [binary, '--json', 'provider', 'ls'],
          workingDirectory: packageRoot,
          environment: environment,
        ),
        Process.run(
          Platform.resolvedExecutable,
          [binary, '--format', 'yaml', 'provider', 'ls'],
          workingDirectory: packageRoot,
          environment: environment,
        ),
        Process.run(
          Platform.resolvedExecutable,
          [binary, '--quiet', 'provider', 'ls'],
          workingDirectory: packageRoot,
          environment: environment,
        ),
      ]);

      for (final result in results) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stderr, isEmpty);
      }

      final json = jsonDecode(results[0].stdout as String) as List<dynamic>;
      expect(json, isNotEmpty);
      expect((json.first as Map<String, dynamic>)['provider'], isNotEmpty);
      expect(results[1].stdout, contains('- provider:'));
      expect(results[2].stdout, contains('claude\n'));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
