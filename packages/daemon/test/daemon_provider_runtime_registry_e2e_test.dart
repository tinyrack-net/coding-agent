import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/agent_run_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'runtime client joins provider snapshots and passes create readiness',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'daemon-provider-runtime-home-',
      );
      final workspace = Directory.systemTemp.createTempSync(
        'daemon-provider-runtime-workspace-',
      );
      addTearDown(() => _deleteDirectoryEventually(home));
      addTearDown(() => _deleteDirectoryEventually(workspace));
      final client = _RuntimeClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'fixture': client},
        log: (_) {},
      );
      addTearDown(handle.stop);

      final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
      );
      await channel.ready;
      addTearDown(channel.sink.close);
      final frames = channel.stream
          .where((frame) => frame is String)
          .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
          .asBroadcastStream();
      channel.sink.add(
        jsonEncode(
          const WebSocketHello(
            clientId: 'provider-runtime-registry-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      Future<Map<String, Object?>> request(
        Map<String, Object?> message,
        String responseType,
      ) async {
        final requestId = message['requestId'];
        final response = frames.firstWhere((frame) {
          if (frame['type'] != 'session' || frame['message'] is! Map) {
            return false;
          }
          final session = (frame['message'] as Map).cast<String, Object?>();
          if (session['type'] != responseType) return false;
          final payload = session['payload'];
          return session['requestId'] == requestId ||
              payload is Map && payload['requestId'] == requestId;
        });
        channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
        return ((await response)['message'] as Map).cast<String, Object?>();
      }

      final refreshed = RefreshProvidersSnapshotResponse.fromJson(
        await request(
          RefreshProvidersSnapshotRequest(
            requestId: 'refresh-runtime-provider',
            cwd: workspace.path,
            providers: const ['fixture'],
          ).toJson(),
          'refresh_providers_snapshot_response',
        ),
      );
      expect(refreshed.acknowledged, isTrue);

      final snapshot = GetProvidersSnapshotResponse.fromJson(
        await request(
          GetProvidersSnapshotRequest(
            requestId: 'snapshot-runtime-provider',
            cwd: workspace.path,
          ).toJson(),
          'get_providers_snapshot_response',
        ),
      );
      final providers = {
        for (final entry in snapshot.entries) entry.provider: entry,
      };
      expect(
        providers.keys,
        containsAll(<String>[
          'claude',
          'codex',
          'copilot',
          'opencode',
          'pi',
          'omp',
          'fixture',
        ]),
      );
      expect(providers['codex']?.label, 'Codex');
      expect(providers['codex']?.source, 'builtin');
      expect(providers['fixture']?.status, ProviderCatalogStatus.ready);
      expect(providers['fixture']?.enabled, isTrue);
      expect(providers['fixture']?.source, 'custom');

      final output = StringBuffer();
      final errors = StringBuffer();
      final exitCode = await runAgentRunCommand(
        arguments: [
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--provider',
          'fixture/runtime-model',
          '--json',
          'complete through injected runtime',
        ],
        currentDirectory: workspace.path,
        environment: const {},
        writeOutput: output.write,
        writeError: errors.write,
      );

      expect(exitCode, 0, reason: errors.toString());
      final result = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(result['status'], 'completed');
      expect(result['provider'], 'fixture');
      expect(client.models, ['runtime-model']);
      expect(client.prompts, ['complete through injected runtime']);
    },
  );
}

final class _RuntimeClient implements AgentClient {
  final models = <String>[];
  final prompts = <String>[];

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
    models.add(model);
    return _RuntimeSession(prompts);
  }
}

final class _RuntimeSession implements AgentSession {
  _RuntimeSession(this.prompts);

  final List<String> prompts;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    scheduleMicrotask(() {
      _events
        ..add(
          const AssistantMessageComplete(
            itemId: 'runtime-response',
            fullText: 'Runtime provider completed.',
          ),
        )
        ..add(const TurnCompleted());
    });
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
