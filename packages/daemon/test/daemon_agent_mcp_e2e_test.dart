import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final class _McpSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  final prompts = <String>[];
  var interrupted = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async => prompts.add(text);

  @override
  Future<void> interrupt() async => interrupted = true;

  @override
  Future<void> dispose() => _events.close();
}

final class _McpClient implements AgentClient, McpAgentClient {
  final mcpCalls = <Map<String, Object?>>[];
  final sessions = <_McpSession>[];

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
  }) => createSessionWithMcp(
    cwd: cwd,
    model: model,
    mode: mode,
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    featureValues: featureValues,
    sessionId: sessionId,
    initialHistory: initialHistory,
  );

  @override
  Future<AgentSession> createSessionWithMcp({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  }) async {
    mcpCalls.add(mcpServers);
    final session = _McpSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  test(
    'injects the runtime MCP server and serves an authenticated stateless endpoint',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-mcp-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      DaemonConfigStore(
        home: home.path,
      ).patch(const MutableDaemonConfigPatch(injectMcpIntoAgents: true));
      final client = _McpClient();
      final passwordHash = hashDaemonPassword('daemon-password');
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        passwordHash: passwordHash,
        agentClients: {'fixture': client},
        log: (_) {},
      );
      addTearDown(handle.stop);

      final created = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'MCP fixture',
        mcpServers: const {
          'tinyrack': {
            'type': 'http',
            'url': 'http://127.0.0.1:6767/mcp/agents?callerAgentId=stale',
          },
          'paseo': {'type': 'sse', 'url': 'http://127.0.0.1:6767/mcp/agents'},
          'local': {'type': 'stdio', 'command': 'dart'},
        },
      );

      expect(client.mcpCalls, hasLength(1));
      final launched = client.mcpCalls.single;
      expect(launched.keys, ['tinyrack', 'local']);
      final runtime = Map<String, Object?>.from(launched['tinyrack']! as Map);
      final runtimeUrl = Uri.parse(runtime['url']! as String);
      expect(runtimeUrl.path, '/mcp/agents');
      expect(runtimeUrl.port, handle.server.port);
      expect(runtimeUrl.queryParameters['callerAgentId'], created.agentId);
      expect(runtime['headers'], {
        'Authorization': 'Bearer ${handle.manager.mcpAuthToken}',
      });

      final endpoint = Uri.parse(
        'http://127.0.0.1:${handle.server.port}/mcp/agents'
        '?callerAgentId=${created.agentId}',
      );
      final unauthorized = await _post(endpoint, {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-03-26'},
      });
      expect(unauthorized.statusCode, 401);

      final initialized = await _post(endpoint, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-03-26'},
      }, bearer: handle.manager.mcpAuthToken);
      expect(initialized.statusCode, 200);
      expect(_result(initialized)['serverInfo'], {
        'name': 'agent-mcp',
        'version': '2.0.0',
      });

      final listed = await _post(endpoint, const {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
        'params': <String, Object?>{},
      }, bearer: 'daemon-password');
      final tools = (_result(listed)['tools']! as List)
          .cast<Map>()
          .map((tool) => tool['name'])
          .toSet();
      expect(tools, {
        'list_agents',
        'get_agent_status',
        'send_agent_prompt',
        'archive_agent',
      });

      final status = await _post(endpoint, {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'get_agent_status',
          'arguments': {'agentId': created.agentId},
        },
      }, bearer: handle.manager.mcpAuthToken);
      final structured = Map<String, Object?>.from(
        _result(status)['structuredContent']! as Map,
      );
      expect(structured['status'], created.runState.name);
      expect((structured['snapshot'] as Map)['agentId'], created.agentId);

      final getResponse = await http.get(
        endpoint,
        headers: {'Authorization': 'Bearer ${handle.manager.mcpAuthToken}'},
      );
      expect(getResponse.statusCode, 405);
      await handle.manager.archive(created.agentId);
      final stored = (await AgentStore(dataDir: home.path).loadAll())
          .singleWhere((record) => record.summary.agentId == created.agentId);
      expect(stored.mcpServers, {
        'local': {'type': 'stdio', 'command': 'dart'},
      });

      handle.configStore.patch(
        const MutableDaemonConfigPatch(injectMcpIntoAgents: false),
      );
      await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'No MCP fixture',
      );
      expect(client.mcpCalls.last, isEmpty);
    },
  );
}

Future<http.Response> _post(
  Uri endpoint,
  Map<String, Object?> message, {
  String? bearer,
}) => http.post(
  endpoint,
  headers: {
    'content-type': 'application/json',
    if (bearer != null) 'authorization': 'Bearer $bearer',
  },
  body: jsonEncode(message),
);

Map<String, Object?> _result(http.Response response) {
  expect(response.statusCode, 200);
  final body = jsonDecode(response.body) as Map<String, Object?>;
  expect(body['error'], isNull);
  return Map<String, Object?>.from(body['result']! as Map);
}
