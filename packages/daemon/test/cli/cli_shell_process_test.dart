import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'binary dispatches hooks and existing project directory invocations',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;

      final hooks = await Process.run(Platform.resolvedExecutable, const [
        'run',
        'agent_daemon:coding_agent',
        'hooks',
        '--help',
      ], workingDirectory: packageRoot);
      expect(hooks.exitCode, 0);
      expect(hooks.stdout, contains('Record agent hook activity'));
      expect(hooks.stderr, isEmpty);

      final project = Directory.systemTemp.createTempSync('cli-open-shell-');
      try {
        final opened = await Process.run(
          Platform.resolvedExecutable,
          [
            p.join(packageRoot, 'bin', 'coding_agent.dart'),
            p.basename(project.path),
          ],
          workingDirectory: project.parent.path,
          environment: {...Platform.environment, 'TINYRACK_DESKTOP_CLI': '1'},
        );
        expect(opened.exitCode, 1, reason: '${opened.stderr}');
        expect(opened.stdout, isEmpty);
        expect(
          opened.stderr,
          contains(
            'Cannot open Tinyrack Desktop while running in desktop CLI '
            'passthrough mode.',
          ),
        );
        expect(opened.stderr, isNot(contains('Usage: coding-agent')));
      } finally {
        project.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
