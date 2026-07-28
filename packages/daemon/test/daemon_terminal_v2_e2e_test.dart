import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'terminal CLI crosses open-project and v2 daemon session boundary',
    () async {
      final home = Directory.systemTemp.createTempSync('terminal-v2-e2e-');
      final project = Directory('${home.path}${Platform.pathSeparator}project')
        ..createSync();
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        log: (_) {},
      );
      addTearDown(handle.stop);
      final host = '127.0.0.1:${handle.server.port}';

      var output = '';
      expect(
        await runTerminalCommand(
          arguments: [
            'create',
            '--cwd',
            project.path,
            '--name',
            'E2E',
            '--host',
            host,
            '--json',
          ],
          writeOutput: (value) => output += value,
        ),
        0,
      );
      final terminal = jsonDecode(output) as Map<String, dynamic>;
      final terminalId = terminal['id']! as String;
      expect(terminal['name'], 'E2E');

      output = '';
      expect(
        await runTerminalCommand(
          arguments: ['ls', '--all', '--host', host, '--json'],
          writeOutput: (value) => output += value,
        ),
        0,
      );
      expect(
        (jsonDecode(output) as List).single,
        containsPair('id', terminalId),
      );

      expect(
        await runTerminalCommand(
          arguments: [
            'send-keys',
            terminalId.substring(0, 8),
            'echo terminal-e2e',
            'Enter',
            '--host',
            host,
          ],
        ),
        0,
      );
      Map<String, dynamic>? capture;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        output = '';
        expect(
          await runTerminalCommand(
            arguments: [
              'capture',
              'E2E',
              '--scrollback',
              '--host',
              host,
              '--json',
            ],
            writeOutput: (value) => output += value,
          ),
          0,
        );
        capture = jsonDecode(output) as Map<String, dynamic>;
        if ((capture['lines'] as List).join('\n').contains('terminal-e2e')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(capture, isNotNull);
      expect(capture!['terminalId'], terminalId);
      expect((capture['lines'] as List).join('\n'), contains('terminal-e2e'));

      expect(
        await runTerminalCommand(
          arguments: ['kill', terminalId, '--host', host, '--json'],
          writeOutput: (_) {},
        ),
        0,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
