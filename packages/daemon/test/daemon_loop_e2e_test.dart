import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/loop_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('loop CLI and runtime cross the real daemon WebSocket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-loop-home-');
    final workspace = Directory.systemTemp.createTempSync(
      'daemon-loop-workspace-',
    );
    addTearDown(() async {
      if (home.existsSync()) await _deleteEventually(home);
      if (workspace.existsSync()) await _deleteEventually(workspace);
    });
    final client = _LoopClient();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'codex': client},
      log: (_) {},
    );
    addTearDown(handle.stop);
    final host = '127.0.0.1:${handle.server.port}';

    Future<Object?> command(List<String> arguments) async {
      final output = StringBuffer();
      final error = StringBuffer();
      final code = await runLoopCommand(
        arguments: [...arguments, '--host', host, '--json'],
        currentDirectory: workspace.path,
        writeOutput: output.write,
        writeError: error.write,
      );
      expect(code, 0, reason: error.toString());
      return jsonDecode(output.toString());
    }

    final created =
        await command([
              'run',
              'finish through websocket',
              '--provider',
              'codex/gpt-5.4',
              '--verify-check',
              Platform.isWindows ? 'exit /b 0' : 'exit 0',
              '--name',
              'socket-loop',
            ])
            as Map<String, Object?>;
    final id = created['id']! as String;
    expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(created['status'], 'running');

    final terminal = await _waitForTerminal(handle, id);
    expect(terminal.status, LoopStatus.succeeded);
    expect(client.prompts, contains('finish through websocket'));

    final listed = await command(['ls']) as List;
    expect(listed.single, containsPair('id', id));
    final inspected = await command(['inspect', id]) as Map;
    expect(inspected['status'], 'succeeded');
    expect((inspected['iterations'] as List).single['status'], 'succeeded');

    final logs = StringBuffer();
    final logsError = StringBuffer();
    expect(
      await runLoopCommand(
        arguments: ['logs', id, '--host', host, '--poll-interval', '1'],
        writeOutput: logs.write,
        writeError: logsError.write,
      ),
      0,
      reason: logsError.toString(),
    );
    expect(logs.toString(), contains('Loop created in'));
    expect(logs.toString(), contains('passed verification'));
  });

  test('loop stop interrupts the active provider across the socket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-loop-stop-home-');
    final workspace = Directory.systemTemp.createTempSync(
      'daemon-loop-stop-workspace-',
    );
    addTearDown(() async {
      if (home.existsSync()) await _deleteEventually(home);
      if (workspace.existsSync()) await _deleteEventually(workspace);
    });
    final client = _LoopClient();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'codex': client},
      log: (_) {},
    );
    addTearDown(handle.stop);
    final host = '127.0.0.1:${handle.server.port}';
    final output = StringBuffer();
    final error = StringBuffer();
    expect(
      await runLoopCommand(
        arguments: [
          'run',
          'block until interrupted',
          '--provider',
          'codex',
          '--verify-check',
          Platform.isWindows ? 'exit /b 0' : 'exit 0',
          '--host',
          host,
          '--json',
        ],
        currentDirectory: workspace.path,
        writeOutput: output.write,
        writeError: error.write,
      ),
      0,
      reason: error.toString(),
    );
    final id = (jsonDecode(output.toString()) as Map)['id']! as String;
    await client.blockStarted.future.timeout(const Duration(seconds: 3));

    final stoppedOutput = StringBuffer();
    expect(
      await runLoopCommand(
        arguments: ['stop', id, '--host', host, '--json'],
        writeOutput: stoppedOutput.write,
        writeError: error.write,
      ),
      0,
      reason: error.toString(),
    );
    expect((jsonDecode(stoppedOutput.toString()) as Map)['status'], 'stopped');
    expect(client.interrupts, 1);
    expect((await handle.loops.inspectLoop(id)).status, LoopStatus.stopped);
  });
}

Future<LoopRecord> _waitForTerminal(
  DaemonServerHandle handle,
  String id,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final loop = await handle.loops.inspectLoop(id);
    if (loop.status != LoopStatus.running) return loop;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('loop $id did not finish');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _LoopClient implements AgentClient {
  final List<String> prompts = [];
  final Completer<void> blockStarted = Completer<void>();
  int interrupts = 0;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async => _LoopSession(this);
}

final class _LoopSession implements AgentSession {
  _LoopSession(this.client);

  final _LoopClient client;
  final _events = StreamController<ProviderEvent>.broadcast();
  bool blocking = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    client.prompts.add(text);
    if (text == 'block until interrupted') {
      blocking = true;
      if (!client.blockStarted.isCompleted) client.blockStarted.complete();
      return;
    }
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events
        ..add(
          const AssistantMessageComplete(
            itemId: 'loop-output',
            fullText: 'done',
          ),
        )
        ..add(const TurnCompleted());
    });
  }

  @override
  Future<void> interrupt() async {
    client.interrupts++;
    if (blocking && !_events.isClosed) {
      blocking = false;
      _events.add(const TurnFailed(error: 'interrupted'));
    }
  }

  @override
  Future<void> dispose() => _events.close();
}

Future<void> _deleteEventually(Directory directory) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  if (directory.existsSync()) await directory.delete(recursive: true);
}
