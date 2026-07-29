import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'executable forwards argv and publishes the CLI result as process exit code',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final executable = p.join(packageRoot, 'bin', 'coding_agent.dart');

      final results = await Future.wait([
        Process.run(Platform.resolvedExecutable, [
          executable,
          '--version',
        ], workingDirectory: packageRoot),
        Process.run(Platform.resolvedExecutable, [
          executable,
          'definitely-not-a-coding-agent-command',
        ], workingDirectory: packageRoot),
      ]);

      final successful = results[0];
      expect(successful.exitCode, 0);
      expect((successful.stdout as String).trim(), '0.2.0');
      expect(successful.stderr, isEmpty);

      final usageError = results[1];
      expect(usageError.exitCode, 64);
      expect(usageError.stdout, isEmpty);
      expect(usageError.stderr, contains('Usage: coding-agent onboard'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
