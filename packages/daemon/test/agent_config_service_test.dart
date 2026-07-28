import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/agent_config_service.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late _ConfigClient client;
  late AgentManager manager;
  late AgentConfigService service;
  late List<Map<String, Object?>> sent;
  late Connection connection;
  late AgentSummary agent;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('agent-config-service-');
    client = _ConfigClient();
    manager = AgentManager(
      clients: {'codex': client},
      store: AgentStore(dataDir: home.path),
    );
    service = AgentConfigService(manager);
    sent = [];
    connection = Connection.external(
      frames: const Stream.empty(),
      send: (value) {
        if (value is String) {
          sent.add((jsonDecode(value) as Map).cast<String, Object?>());
        }
      },
      close: (_, __) {},
      id: 'agent-config',
      transport: 'direct',
      externalSessionKey: null,
      relayConnectionId: null,
    );
    agent = await manager.createAgent(
      cwd: home.path,
      provider: 'codex',
      model: 'gpt',
      mode: AgentMode.normal,
    );
  });

  tearDown(() async {
    await manager.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test(
    'mode, model, thinking, and feature responses use one envelope',
    () async {
      final mode =
          await service.handle(connection, {
                'type': 'set_agent_mode_request',
                'agentId': agent.agentId,
                'modeId': 'full-access',
                'requestId': 'mode',
              })
              as Map;
      expect(mode['type'], 'set_agent_mode_response');
      expect((mode['payload'] as Map)['notice'], {
        'type': 'info',
        'message': 'changed',
      });

      final model =
          await service.handle(connection, {
                'type': 'set_agent_model_request',
                'agentId': agent.agentId,
                'modelId': null,
                'requestId': 'model',
              })
              as Map;
      expect((model['payload'] as Map)['accepted'], isTrue);
      final thinking =
          await service.handle(connection, {
                'type': 'set_agent_thinking_request',
                'agentId': agent.agentId,
                'thinkingOptionId': 'high',
                'requestId': 'thinking',
              })
              as Map;
      expect(thinking['type'], 'set_agent_thinking_response');
      final feature =
          await service.handle(connection, {
                'type': 'set_agent_feature_request',
                'agentId': agent.agentId,
                'featureId': 'search',
                'value': true,
                'requestId': 'feature',
              })
              as Map;
      expect(feature['type'], 'set_agent_feature_response');
      expect(client.session.features, {'search': true});
      expect(await service.handle(connection, {'type': 'other'}), isNull);
    },
  );

  test('failure emits activity log before rejected response', () async {
    final response =
        await service.handle(connection, {
              'type': 'set_agent_mode_request',
              'agentId': 'missing',
              'modeId': 'read-only',
              'requestId': 'bad',
            })
            as Map;
    expect((response['payload'] as Map)['accepted'], isFalse);
    expect((response['payload'] as Map)['error'], contains('no agent'));
    expect(sent, hasLength(1));
    final activity = ((sent.single['message'] as Map)['payload'] as Map);
    expect(activity['type'], 'error');
    expect(activity['content'], contains('Failed to set agent mode'));
    expect(activity['timestamp'], isA<String>());
  });
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
  Future<AgentProviderNotice?> setMode(String modeId) async =>
      const AgentProviderNotice(
        type: AgentProviderNoticeType.info,
        message: 'changed',
      );
  @override
  Future<void> setModel(String? modelId) async {}
  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async => null;
  @override
  Future<void> setFeature(String featureId, Object? value) async {
    features[featureId] = value;
  }
}
