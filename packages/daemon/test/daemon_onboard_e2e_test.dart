import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/onboard_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'onboard proves API readiness through the real daemon WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-onboard-e2e-');
      addTearDown(() => _deleteDirectoryEventually(home));
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '0.0.0.0',
        port: 0,
        agentClients: const {},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final output = StringBuffer();
      final error = StringBuffer();

      final code = await runOnboardCommand(
        arguments: [
          '--home',
          home.path,
          '--voice',
          'disable',
          '--no-relay',
          '--timeout',
          '5',
        ],
        runtime: OnboardRuntime(
          environment: const {},
          inputIsTerminal: () => false,
          outputIsTerminal: () => false,
          terminalColumns: () => null,
        ),
        writeOutput: output.write,
        writeError: error.write,
      );

      expect(code, 0, reason: error.toString());
      expect(error.toString(), isEmpty);
      expect(output.toString(), contains('Daemon already running (PID $pid)'));
      expect(
        output.toString(),
        contains('Daemon ready on 0.0.0.0:${handle.server.port}'),
      );
      expect(output.toString(), contains('Relay is disabled'));

      final persisted =
          jsonDecode(File(p.join(home.path, 'config.json')).readAsStringSync())
              as Map;
      final features = persisted['features'] as Map;
      expect((features['dictation'] as Map)['enabled'], isFalse);
      expect((features['voiceMode'] as Map)['enabled'], isFalse);
    },
  );
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on PathAccessException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
