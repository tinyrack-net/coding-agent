import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

final class _RecordingClient implements AgentClient {
  final systemPrompts = <String?>[];

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
  }) async {
    systemPrompts.add(systemPrompt);
    return _IdleSession();
  }
}

final class _IdleSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

void main() {
  test(
    'daemon config injects initial and live append prompts at launch',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'daemon-append-system-prompt-',
      );
      addTearDown(() async {
        if (temp.existsSync()) await temp.delete(recursive: true);
      });
      File(
        '${temp.path}${Platform.pathSeparator}config.json',
      ).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'daemon': {'appendSystemPrompt': '  Initial daemon prompt.  '},
        }),
      );
      final client = _RecordingClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'codex': client},
        log: (_) {},
      );
      addTearDown(handle.stop);

      final first = await handle.manager.createAgent(
        cwd: temp.path,
        provider: 'codex',
        model: 'gpt-5.4',
        mode: AgentMode.normal,
        systemPrompt: 'Agent prompt.',
      );
      expect(
        client.systemPrompts.single,
        'Agent prompt.\n\nInitial daemon prompt.',
      );
      expect(first.systemPrompt, 'Agent prompt.');

      handle.configStore.patch(
        const MutableDaemonConfigPatch(
          appendSystemPrompt: '  Updated daemon prompt.  ',
        ),
      );
      final second = await handle.manager.createAgent(
        cwd: temp.path,
        provider: 'codex',
        model: 'gpt-5.4',
        mode: AgentMode.normal,
      );
      expect(client.systemPrompts.last, 'Updated daemon prompt.');
      expect(second.systemPrompt, isNull);
    },
  );
}
