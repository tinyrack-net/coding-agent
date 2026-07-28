import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
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
    'v2 agent config mutates the live provider across daemon WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-config-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      const agentId = 'agent-config-e2e';
      await AgentStore(dataDir: home.path).save(
        const PersistedAgent(
          summary: AgentSummary(
            agentId: agentId,
            title: 'Agent config',
            cwd: '.',
            provider: 'codex',
            model: 'gpt-5',
            mode: AgentMode.normal,
            runState: AgentRunState.idle,
            createdAtMs: 1,
          ),
          archived: false,
          epoch: 1,
          lastSeq: 0,
          items: [],
        ),
      );
      final client = _ConfigClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': client},
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
            clientId: 'agent-config-e2e',
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
        final future = frames.firstWhere(
          (frame) =>
              frame['type'] == 'session' &&
              (frame['message'] as Map?)?['type'] == responseType,
        );
        channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
        return ((await future)['message'] as Map).cast<String, Object?>();
      }

      final mode = await request({
        'type': 'set_agent_mode_request',
        'agentId': agentId,
        'modeId': 'full-access',
        'requestId': 'mode',
      }, 'set_agent_mode_response');
      expect((mode['payload'] as Map)['accepted'], isTrue);
      expect((mode['payload'] as Map)['notice'], {
        'type': 'info',
        'message': 'mode changed',
      });
      await request({
        'type': 'set_agent_model_request',
        'agentId': agentId,
        'modelId': 'gpt-5.1',
        'requestId': 'model',
      }, 'set_agent_model_response');
      await request({
        'type': 'set_agent_thinking_request',
        'agentId': agentId,
        'thinkingOptionId': 'high',
        'requestId': 'thinking',
      }, 'set_agent_thinking_response');
      await request({
        'type': 'set_agent_feature_request',
        'agentId': agentId,
        'featureId': 'fast',
        'value': true,
        'requestId': 'feature',
      }, 'set_agent_feature_response');

      expect(client.session.modeId, 'full-access');
      expect(client.session.modelId, 'gpt-5.1');
      expect(client.session.thinkingOptionId, 'high');
      expect(client.session.features, {'fast': true});
      final summary = handle.manager.list().single;
      expect(summary.mode, AgentMode.fullAccess);
      expect(summary.model, 'gpt-5.1');
      expect(summary.thinkingOptionId, 'high');
      expect(summary.featureValues, {'fast': true});
    },
  );
}

final class _ConfigClient implements AgentClient {
  final _ConfigSession session = _ConfigSession();

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async => session;
}

final class _ConfigSession implements ConfigurableAgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  String? modeId;
  String? modelId;
  String? thinkingOptionId;
  final Map<String, Object?> features = {};

  @override
  Stream<ProviderEvent> get events => _events.stream;
  @override
  Future<void> prompt(String text) async {}
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> dispose() => _events.close();
  @override
  Future<AgentProviderNotice?> setMode(String modeId) async {
    this.modeId = modeId;
    return const AgentProviderNotice(
      type: AgentProviderNoticeType.info,
      message: 'mode changed',
    );
  }

  @override
  Future<void> setModel(String? modelId) async => this.modelId = modelId;
  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async {
    this.thinkingOptionId = thinkingOptionId;
    return null;
  }

  @override
  Future<void> setFeature(String featureId, Object? value) async {
    features[featureId] = value;
  }
}
