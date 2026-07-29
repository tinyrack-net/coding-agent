import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/cli/agent_attach_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'attach replays history and follows the real WebSocket stream',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-attach-');
      addTearDown(() => _deleteDirectoryEventually(home));
      const agentId = 'agent-attach-full-id';
      await AgentStore(dataDir: home.path).save(
        PersistedAgent(
          summary: AgentSummary(
            agentId: agentId,
            title: 'Attach target',
            cwd: home.path,
            provider: 'codex',
            model: 'gpt-5.4',
            mode: AgentMode.normal,
            runState: AgentRunState.idle,
            createdAtMs: 1,
          ),
          archived: false,
          epoch: 1,
          lastSeq: 1,
          items: const [
            AssistantMessageItem(
              id: 'history',
              text: 'history',
              complete: true,
            ),
          ],
        ),
      );
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: const {},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final stops = StreamController<void>();
      addTearDown(stops.close);
      final output = StringBuffer();
      final error = StringBuffer();

      final attached = runAgentAttachCommand(
        arguments: [
          'agent-attach-full',
          '--host',
          '127.0.0.1:${handle.server.port}',
        ],
        environment: const {},
        stopSignals: stops.stream,
        writeOutput: output.write,
        writeError: error.write,
      );
      await _waitFor(() => output.toString().contains('history'));
      expect(
        handle.manager.upsertTimelineItem(
          agentId,
          const ErrorItem(id: 'live', message: 'live failure'),
        ),
        isTrue,
      );
      await _waitFor(() => error.toString().contains('live failure'));
      stops.add(null);

      expect(await attached, 0);
      expect(output.toString(), startsWith('Attaching to agent agent-a...'));
      expect(output.toString(), contains('history'));
      expect(output.toString(), endsWith('\n\nDetaching from agent...\n'));
      expect(error.toString(), '\n[Error] live failure\n');
    },
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached');
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
