import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'open derives the server ID from the real WebSocket handshake',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-open-');
      addTearDown(() => _deleteDirectoryEventually(home));
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: const {},
        log: (_) {},
      );
      addTearDown(handle.stop);
      AgentDeepLinkTarget? opened;
      final output = StringBuffer();

      expect(
        await runAgentCommand(
          arguments: [
            'open',
            ' agent-open-id ',
            '--host',
            '127.0.0.1:${handle.server.port}',
            '--json',
          ],
          environment: const {},
          openAgentDesktop: (target) async => opened = target,
          writeOutput: output.write,
        ),
        0,
      );
      expect(
        opened,
        AgentDeepLinkTarget(
          serverId: handle.server.serverId,
          agentId: 'agent-open-id',
        ),
      );
      expect(jsonDecode(output.toString()), {
        'agentId': 'agent-open-id',
        'serverId': handle.server.serverId,
        'status': 'opened',
      });
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
