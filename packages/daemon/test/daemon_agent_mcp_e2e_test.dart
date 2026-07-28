import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_daemon/src/voice/voice_types.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final class _McpSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  final prompts = <String>[];
  var interrupted = false;
  var disposed = false;
  var completeNextPrompt = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    if (completeNextPrompt) {
      completeNextPrompt = false;
      scheduleMicrotask(() {
        emit(
          const AssistantMessageComplete(
            itemId: 'fixture-answer',
            fullText: 'Fixture completed',
          ),
        );
        emit(const TurnCompleted());
      });
    }
  }

  @override
  Future<void> interrupt() async => interrupted = true;

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _events.close();
  }

  void emit(ProviderEvent event) => _events.add(event);
}

final class _McpClient implements AgentClient, McpAgentClient {
  final mcpCalls = <Map<String, Object?>>[];
  final sessions = <_McpSession>[];
  var completeNewSessions = false;

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
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  }) async {
    mcpCalls.add(mcpServers);
    final session = _McpSession()..completeNextPrompt = completeNewSessions;
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
        agentClients: {'fixture': client, 'opencode': client},
        agentMcpWaitTimeout: const Duration(milliseconds: 30),
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
      final mcpAuthToken = handle.manager.mcpAuthToken!;
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
      }, bearer: mcpAuthToken);
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
      final listedTools = (_result(listed)['tools']! as List).cast<Map>();
      final tools = listedTools.map((tool) => tool['name']).toSet();
      expect(tools, {
        'create_workspace',
        'list_workspaces',
        'archive_workspace',
        'create_agent',
        'rename_workspace',
        'list_workspace_scripts',
        'start_workspace_script',
        'stop_workspace_script',
        'list_terminals',
        'create_terminal',
        'kill_terminal',
        'capture_terminal',
        'send_terminal_keys',
        'create_schedule',
        'create_heartbeat',
        'delete_heartbeat',
        'list_schedules',
        'inspect_schedule',
        'pause_schedule',
        'resume_schedule',
        'delete_schedule',
        'update_schedule',
        'schedule_logs',
        'run_schedule_once',
        'list_agents',
        'get_agent_status',
        'send_agent_prompt',
        'cancel_agent',
        'archive_agent',
        'kill_agent',
        'update_agent',
        'get_agent_activity',
        'set_agent_mode',
        'list_pending_permissions',
        'respond_to_permission',
        'list_providers',
        'list_models',
        'inspect_provider',
      });
      final captureTerminalTool = listedTools.singleWhere(
        (tool) => tool['name'] == 'capture_terminal',
      );
      expect((captureTerminalTool['outputSchema']! as Map)['required'], [
        'terminalId',
        'lines',
        'totalLines',
      ]);
      final listTerminalsTool = listedTools.singleWhere(
        (tool) => tool['name'] == 'list_terminals',
      );
      expect(
        ((listTerminalsTool['outputSchema']! as Map)['properties']! as Map)
            .keys,
        ['terminals'],
      );
      final createScheduleTool = listedTools.singleWhere(
        (tool) => tool['name'] == 'create_schedule',
      );
      expect(
        (createScheduleTool['outputSchema']! as Map)['required'],
        containsAll(['id', 'cadence', 'target', 'nextRunAt']),
      );

      final speakEntered = Completer<void>();
      final releaseSpeak = Completer<void>();
      String? spokenText;
      String? spokenCaller;
      handle.voiceBridge.registerCallerContext(
        created.agentId,
        const VoiceCallerContext(allowCustomCwd: false, enableVoiceTools: true),
      );
      handle.voiceBridge.registerSpeakHandler(created.agentId, ({
        required text,
        required callerAgentId,
        signal,
      }) async {
        spokenText = text;
        spokenCaller = callerAgentId;
        speakEntered.complete();
        await releaseSpeak.future;
      });
      final voiceToolsResponse = await _post(endpoint, const {
        'jsonrpc': '2.0',
        'id': 'voice-tools',
        'method': 'tools/list',
        'params': <String, Object?>{},
      }, bearer: mcpAuthToken);
      final voiceTools = (_result(voiceToolsResponse)['tools']! as List)
          .cast<Map>();
      final speakTool = voiceTools.singleWhere(
        (tool) => tool['name'] == 'speak',
      );
      expect((speakTool['inputSchema']! as Map)['required'], ['text']);
      expect(
        (((speakTool['inputSchema']! as Map)['properties']! as Map)['text']
            as Map)['maxLength'],
        4000,
      );

      var speakCompleted = false;
      final speakResult = _call(endpoint, mcpAuthToken, 'speak', const {
        'text': '  Hello from voice agent.  ',
      }).whenComplete(() => speakCompleted = true);
      await speakEntered.future;
      await pumpEventQueue();
      expect(speakCompleted, isFalse);
      expect(spokenText, 'Hello from voice agent.');
      expect(spokenCaller, created.agentId);
      releaseSpeak.complete();
      expect(await speakResult, {'ok': true});

      handle.voiceBridge.unregisterSpeakHandler(created.agentId);
      expect(
        await _callError(endpoint, mcpAuthToken, 'speak', const {
          'text': 'Hello.',
        }),
        contains('No speak handler registered for your session'),
      );
      expect(
        await _callError(endpoint, mcpAuthToken, 'speak', {'text': 'x' * 4001}),
        contains('text must be 4000 characters or fewer'),
      );
      handle.voiceBridge.unregisterCallerContext(created.agentId);
      expect(
        await _callError(endpoint, mcpAuthToken, 'speak', const {
          'text': 'Hidden again',
        }),
        contains('Unknown tool: speak'),
      );
      expect(
        await _callError(
          endpoint.replace(queryParameters: const {}),
          mcpAuthToken,
          'speak',
          const {'text': 'Top-level'},
        ),
        contains('Unknown tool: speak'),
      );

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
      expect(structured['status'], 'initializing');
      expect((structured['snapshot'] as Map)['id'], created.agentId);

      final updated = await _call(endpoint, mcpAuthToken, 'update_agent', {
        'agentId': created.agentId,
        'name': 'Renamed fixture',
        'labels': {'surface': 'mcp'},
      });
      expect(updated, {'success': true});
      expect(handle.manager.get(created.agentId)?.title, 'Renamed fixture');
      expect(handle.manager.get(created.agentId)?.labels, {'surface': 'mcp'});
      final agentList = await _call(
        endpoint,
        mcpAuthToken,
        'list_agents',
        const {},
      );
      final compactAgent = (agentList['agents']! as List).single as Map;
      expect(compactAgent['id'], created.agentId);
      expect(compactAgent['shortId'], created.agentId.substring(0, 7));
      expect(compactAgent['title'], 'Renamed fixture');
      expect(compactAgent['labels'], {'surface': 'mcp'});

      final prompted =
          await _call(endpoint, mcpAuthToken, 'send_agent_prompt', {
            'agentId': created.agentId,
            'prompt': 'Inspect the workspace',
            'notifyOnFinish': false,
          });
      expect(prompted['success'], true);
      expect(prompted['status'], 'running');
      expect(client.sessions.single.prompts, ['Inspect the workspace']);

      final activity = await _call(
        endpoint,
        mcpAuthToken,
        'get_agent_activity',
        {'agentId': created.agentId},
      );
      expect(activity['agentId'], created.agentId);
      expect(activity['content'], contains('[User] Inspect the workspace'));

      PermissionDecision? permissionDecision;
      String? permissionMessage;
      String? permissionActionId;
      Map<String, Object?>? permissionInput;
      List<Map<String, Object?>>? permissionUpdates;
      bool? permissionInterrupt;
      client.sessions.single.emit(
        PermissionRequested(
          permissionId: 'permission-1',
          toolName: 'Write',
          detail: const WriteDetail(path: 'README.md'),
          respond:
              (
                decision, {
                message,
                selectedActionId,
                updatedInput,
                updatedPermissions,
                interrupt,
              }) async {
                permissionDecision = decision;
                permissionMessage = message;
                permissionActionId = selectedActionId;
                permissionInput = updatedInput;
                permissionUpdates = updatedPermissions;
                permissionInterrupt = interrupt;
              },
        ),
      );
      await pumpEventQueue();
      final pendingPermissions = await _call(
        endpoint,
        mcpAuthToken,
        'list_pending_permissions',
        const {},
      );
      final pending =
          (pendingPermissions['permissions']! as List).single as Map;
      expect(pending['agentId'], created.agentId);
      expect((pending['request'] as Map)['id'], 'permission-1');
      expect((pending['request'] as Map)['name'], 'Write');

      final permissionResponse = await _call(
        endpoint,
        mcpAuthToken,
        'respond_to_permission',
        {
          'agentId': created.agentId,
          'requestId': 'permission-1',
          'response': {
            'behavior': 'allow',
            'selectedActionId': 'allow_always',
            'updatedInput': {'path': 'CHANGELOG.md'},
            'updatedPermissions': [
              {'type': 'allow', 'scope': 'workspace'},
            ],
          },
        },
      );
      expect(permissionResponse, {'success': true});
      expect(permissionDecision, PermissionDecision.allow);
      expect(permissionMessage, isNull);
      expect(permissionActionId, 'allow_always');
      expect(permissionInput, {'path': 'CHANGELOG.md'});
      expect(permissionUpdates, [
        {'type': 'allow', 'scope': 'workspace'},
      ]);
      expect(permissionInterrupt, isNull);

      final cancelled = await _call(endpoint, mcpAuthToken, 'cancel_agent', {
        'agentId': created.agentId,
      });
      expect(cancelled, {'success': true});
      expect(client.sessions.single.interrupted, true);

      final providerList = await _call(
        endpoint,
        mcpAuthToken,
        'list_providers',
        const {},
      );
      expect(providerList['providers'], isNotEmpty);

      final blockingAgent = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'Blocking fixture',
      );
      client.sessions.last.completeNextPrompt = true;
      final blocking =
          await _call(endpoint, mcpAuthToken, 'send_agent_prompt', {
            'agentId': blockingAgent.agentId,
            'prompt': 'Wait for completion',
            'background': false,
          });
      expect(blocking['status'], 'idle');
      expect(blocking['lastMessage'], 'Fixture completed');
      expect(blocking['permission'], isNull);

      final timeoutAgent = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'Timeout fixture',
      );
      final timedOut = await _call(
        endpoint,
        mcpAuthToken,
        'send_agent_prompt',
        {
          'agentId': timeoutAgent.agentId,
          'prompt': 'Keep running',
          'background': false,
        },
      );
      expect(timedOut['status'], 'running');
      expect(timedOut['lastMessage'], contains('timed out after 0s'));
      expect(timedOut['lastMessage'], contains('[User] Keep running'));

      final caller = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'Caller fixture',
      );
      final callerSession = client.sessions.last;
      final child = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'Child fixture',
      );
      client.sessions.last.completeNextPrompt = true;
      final callerEndpoint = endpoint.replace(
        queryParameters: {'callerAgentId': caller.agentId},
      );
      final background = await _call(
        callerEndpoint,
        mcpAuthToken,
        'send_agent_prompt',
        {'agentId': child.agentId, 'prompt': 'Finish in background'},
      );
      expect(background['guidance'], contains('You will get notified'));
      await _waitUntil(() => callerSession.prompts.isNotEmpty);
      expect(
        callerSession.prompts.single,
        '<paseo-system>\n'
        'Agent ${child.agentId} (Child fixture) finished.\n\n'
        '<agent-response>\n'
        'Fixture completed\n'
        '</agent-response>\n'
        '</paseo-system>',
      );

      final killAgent = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        title: 'Kill fixture',
      );
      final killedSession = client.sessions.last;
      final killed = await _call(endpoint, mcpAuthToken, 'kill_agent', {
        'agentId': killAgent.agentId,
      });
      expect(killed, {'success': true});
      expect(killedSession.disposed, isTrue);
      expect(
        handle.manager.get(killAgent.agentId)?.runState,
        AgentRunState.closed,
      );

      final getResponse = await http.get(
        endpoint,
        headers: {'Authorization': 'Bearer $mcpAuthToken'},
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

      final workspaceA = await _call(
        endpoint,
        mcpAuthToken,
        'create_workspace',
        {'isolation': 'local', 'path': home.path, 'title': 'MCP workspace A'},
      );
      final otherDirectory = Directory(
        '${home.path}${Platform.pathSeparator}other',
      )..createSync();
      File(
        '${otherDirectory.path}${Platform.pathSeparator}tinyrack.json',
      ).writeAsStringSync(
        jsonEncode({
          'scripts': {
            'watch': {
              'command': Platform.isWindows ? 'ping -t 127.0.0.1' : 'sleep 30',
            },
          },
        }),
      );
      final workspaceB = await _call(
        endpoint,
        mcpAuthToken,
        'create_workspace',
        {
          'isolation': 'local',
          'path': otherDirectory.path,
          'title': 'MCP workspace B',
        },
      );
      expect(workspaceA, {
        'workspaceId': isA<String>(),
        'projectId': isA<String>(),
        'cwd': home.path,
        'isolation': 'local',
        'kind': 'directory',
        'title': 'MCP workspace A',
      });
      final workspaceList = await _call(
        endpoint,
        mcpAuthToken,
        'list_workspaces',
        const {},
      );
      expect(
        (workspaceList['workspaces']! as List).cast<Map>().map(
          (workspace) => workspace['workspaceId'],
        ),
        containsAll([workspaceA['workspaceId'], workspaceB['workspaceId']]),
      );

      final topLevelEndpoint = endpoint.replace(queryParameters: const {});
      final sessionsBeforeInvalidCreates = client.sessions.length;
      final workspacesBeforeInvalidCreates =
          ((await _call(
                    topLevelEndpoint,
                    mcpAuthToken,
                    'list_workspaces',
                    const {},
                  ))['workspaces']!
                  as List)
              .length;
      final canonicalCreate = <String, Object?>{
        'title': 'Strict create fixture',
        'provider': 'fixture/fixture-model',
        'workspaceId': workspaceA['workspaceId'],
        'initialPrompt': 'Validate without side effects',
        'background': true,
      };
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...canonicalCreate,
          'unexpected': true,
        }),
        contains('create_agent contains unknown fields: unexpected'),
      );
      expect(
        await _callError(endpoint, mcpAuthToken, 'create_agent', {
          ...canonicalCreate,
          'background': true,
        }),
        contains('create_agent contains unknown fields: background'),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...canonicalCreate,
          'settings': {'modeId': 'plan', 'unexpected': true},
        }),
        contains('create_agent.settings contains unknown fields: unexpected'),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...canonicalCreate,
          'workspaceId': null,
        }),
        contains('create_agent.workspaceId must be a string'),
      );
      final legacyCreate = <String, Object?>{
        'title': 'Strict legacy fixture',
        'provider': 'fixture/fixture-model',
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'existing',
          'workspaceId': workspaceB['workspaceId'],
        },
        'initialPrompt': 'Validate legacy shape',
        'background': true,
      };
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...legacyCreate,
          'relationship': {'kind': 'detached', 'unexpected': true},
        }),
        contains(
          'create_agent.relationship contains unknown fields: unexpected',
        ),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...legacyCreate,
          'workspace': {
            'kind': 'existing',
            'workspaceId': workspaceB['workspaceId'],
            'unexpected': true,
          },
        }),
        contains('create_agent.workspace contains unknown fields: unexpected'),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          ...legacyCreate,
          'workspace': {
            'kind': 'create',
            'source': {
              'kind': 'worktree',
              'cwd': otherDirectory.path,
              'target': {
                'kind': 'branch-off',
                'branchName': 'strict-fixture',
                'unexpected': true,
              },
            },
          },
        }),
        contains(
          'create_agent.workspace.source.target contains unknown fields: '
          'unexpected',
        ),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          'title': 'Partial legacy fixture',
          'provider': 'fixture/fixture-model',
          'relationship': {'kind': 'detached'},
          'initialPrompt': 'Reject partial placement',
        }),
        contains('relationship and workspace must be provided together'),
      );
      expect(client.sessions, hasLength(sessionsBeforeInvalidCreates));
      expect(
        ((await _call(
                  topLevelEndpoint,
                  mcpAuthToken,
                  'list_workspaces',
                  const {},
                ))['workspaces']!
                as List)
            .length,
        workspacesBeforeInvalidCreates,
      );
      final topLevelToolsResponse = await _post(topLevelEndpoint, const {
        'jsonrpc': '2.0',
        'id': 'top-level-tools',
        'method': 'tools/list',
        'params': <String, Object?>{},
      }, bearer: mcpAuthToken);
      final topLevelTools = (_result(topLevelToolsResponse)['tools']! as List)
          .cast<Map>();
      final topLevelCreateSchedule = topLevelTools.singleWhere(
        (tool) => tool['name'] == 'create_schedule',
      );
      expect((topLevelCreateSchedule['inputSchema']! as Map)['required'], [
        'prompt',
        'cron',
        'provider',
      ]);
      expect(
        await _callError(
          topLevelEndpoint,
          mcpAuthToken,
          'list_terminals',
          const {},
        ),
        contains('cwd is required'),
      );
      expect(
        await _callError(
          topLevelEndpoint,
          mcpAuthToken,
          'kill_terminal',
          const {'terminalId': 'missing-terminal-id'},
        ),
        contains('Terminal missing-terminal-id not found'),
      );
      final renamed = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'rename_workspace',
        {'workspaceId': workspaceA['workspaceId'], 'title': 'Renamed A'},
      );
      expect(renamed, {
        'success': true,
        'workspaceId': workspaceA['workspaceId'],
        'title': 'Renamed A',
      });
      final renamedWorkspaceList = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'list_workspaces',
        const {},
      );
      expect(
        (renamedWorkspaceList['workspaces']! as List).cast<Map>().singleWhere(
          (workspace) => workspace['workspaceId'] == workspaceA['workspaceId'],
        )['title'],
        'Renamed A',
      );

      final configuredScripts = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'list_workspace_scripts',
        {'workspaceId': workspaceB['workspaceId']},
      );
      final configuredScript =
          (configuredScripts['scripts']! as List).single as Map;
      expect(configuredScript['scriptName'], 'watch');
      expect(configuredScript['type'], 'script');
      expect(configuredScript['lifecycle'], 'stopped');
      expect(configuredScript['terminalId'], isNull);

      final startedScript = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'start_workspace_script',
        {'workspaceId': workspaceB['workspaceId'], 'scriptName': 'watch'},
      );
      final runningScript = startedScript['script']! as Map;
      expect(runningScript['lifecycle'], 'running');
      expect(runningScript['terminalId'], isA<String>());
      expect(
        handle.terminals.contains(runningScript['terminalId']! as String),
        isTrue,
      );

      final stoppedScript = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'stop_workspace_script',
        {'workspaceId': workspaceB['workspaceId'], 'scriptName': 'watch'},
      );
      expect((stoppedScript['script']! as Map)['lifecycle'], 'stopped');
      expect(
        (stoppedScript['script']! as Map)['terminalId'],
        runningScript['terminalId'],
      );

      final topLevelTerminal = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'create_terminal',
        {'cwd': otherDirectory.path, 'name': '  Top-level terminal  '},
      );
      expect(topLevelTerminal['name'], 'Top-level terminal');
      expect(topLevelTerminal['cwd'], otherDirectory.path);
      final topLevelTerminalId = topLevelTerminal['id']! as String;
      final topLevelTerminalRecord = handle.terminals.listV2().singleWhere(
        (terminal) => terminal['id'] == topLevelTerminalId,
      );
      expect(
        topLevelTerminalRecord['workspaceId'],
        isNot(workspaceB['workspaceId']),
      );
      final workspacesAfterTerminal = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'list_workspaces',
        const {},
      );
      final topLevelTerminalWorkspace =
          (workspacesAfterTerminal['workspaces']! as List)
              .cast<Map>()
              .singleWhere(
                (workspace) =>
                    workspace['workspaceId'] ==
                    topLevelTerminalRecord['workspaceId'],
              );
      expect(topLevelTerminalWorkspace['cwd'], otherDirectory.path);
      final listedTopLevelTerminals =
          (await _call(topLevelEndpoint, mcpAuthToken, 'list_terminals', {
                'cwd': otherDirectory.path,
              }))['terminals']!
              as List;
      expect(
        listedTopLevelTerminals.cast<Map>().map((terminal) => terminal['id']),
        contains(topLevelTerminalId),
      );
      expect(
        await _call(topLevelEndpoint, mcpAuthToken, 'kill_terminal', {
          'terminalId': topLevelTerminalId,
        }),
        {'success': true},
      );
      await _waitUntil(() => !handle.terminals.contains(topLevelTerminalId));

      final sourceRepo = Directory(
        '${home.path}${Platform.pathSeparator}source-repo',
      )..createSync();
      final remoteRepo = Directory(
        '${home.path}${Platform.pathSeparator}source-remote.git',
      );
      await _git(['init', '-b', 'main'], sourceRepo.path);
      await _git(['config', 'user.email', 'test@example.com'], sourceRepo.path);
      await _git(['config', 'user.name', 'Test'], sourceRepo.path);
      File(
        '${sourceRepo.path}${Platform.pathSeparator}README.md',
      ).writeAsStringSync('fixture\n');
      await _git(['add', '-A'], sourceRepo.path);
      await _git(['commit', '-m', 'initial'], sourceRepo.path);
      await _git(['init', '--bare', remoteRepo.path], home.path);
      await _git(['remote', 'add', 'origin', remoteRepo.path], sourceRepo.path);
      await _git(['push', 'origin', 'HEAD:refs/pull/5/head'], sourceRepo.path);
      final reviewWorkspace =
          await _call(topLevelEndpoint, mcpAuthToken, 'create_workspace', {
            'isolation': 'worktree',
            'path': sourceRepo.path,
            'mode': 'checkout-pr',
            'prNumber': 5,
            'forge': 'github',
            'worktreeSlug': 'review-5',
          });
      expect(reviewWorkspace['isolation'], 'worktree');
      expect(reviewWorkspace['kind'], 'worktree');
      expect(Directory(reviewWorkspace['cwd']! as String).existsSync(), isTrue);
      expect(
        await _gitOutput([
          'branch',
          '--show-current',
        ], reviewWorkspace['cwd']! as String),
        'review-5',
      );
      final archivedReviewWorkspace = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'archive_workspace',
        {'workspaceId': reviewWorkspace['workspaceId']},
      );
      expect(archivedReviewWorkspace['removedDirectory'], isTrue);
      expect(
        Directory(reviewWorkspace['cwd']! as String).existsSync(),
        isFalse,
      );

      final legacyWorktreeAgent = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'create_agent',
        {
          'title': 'Legacy worktree agent',
          'provider': 'fixture/fixture-model',
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'create',
            'source': {
              'kind': 'worktree',
              'cwd': sourceRepo.path,
              'target': {'kind': 'branch-off'},
            },
          },
          'initialPrompt': 'Implement in an isolated worktree',
          'settings': {'modeId': 'plan'},
          'background': true,
        },
      );
      final legacyWorktreeSession = client.sessions.last;
      final legacyWorktreeSummary = handle.manager.get(
        legacyWorktreeAgent['agentId']! as String,
      )!;
      expect(legacyWorktreeAgent['workspaceId'], isA<String>());
      expect(
        legacyWorktreeSummary.workspaceId,
        legacyWorktreeAgent['workspaceId'],
      );
      expect(legacyWorktreeSummary.parentAgentId, isNull);
      expect(legacyWorktreeSummary.currentModeId, 'plan');
      expect(legacyWorktreeSummary.isWorktree, isTrue);
      expect(Directory(legacyWorktreeSummary.cwd).existsSync(), isTrue);
      final placeholderBranch = await _gitOutput([
        'branch',
        '--show-current',
      ], legacyWorktreeSummary.cwd);
      expect(placeholderBranch, matches(RegExp(r'^[a-z]+-[a-z]+$')));
      await _waitUntil(
        () =>
            readWorktreeMetadata(
              legacyWorktreeSummary.cwd,
            )?.firstAgentBranchAutoName?['status'] ==
            'attempted',
      );
      expect(
        readWorktreeMetadata(
          legacyWorktreeSummary.cwd,
        )?.firstAgentBranchAutoName,
        containsPair('placeholderBranchName', placeholderBranch),
      );
      await pumpEventQueue();
      expect(legacyWorktreeSession.prompts, [
        'Implement in an isolated worktree',
      ]);
      final archivedLegacyWorktree = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'archive_workspace',
        {'workspaceId': legacyWorktreeAgent['workspaceId']},
      );
      expect(archivedLegacyWorktree['archivedAgentIds'], [
        legacyWorktreeAgent['agentId'],
      ]);
      expect(archivedLegacyWorktree['removedDirectory'], isTrue);
      expect(Directory(legacyWorktreeSummary.cwd).existsSync(), isFalse);

      final autonomous = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'create_agent',
        {
          'title': 'Automation fixture',
          'provider': 'fixture/fixture-model',
          'workspaceId': workspaceA['workspaceId'],
          'labels': {'surface': 'automation'},
          'settings': {
            'modeId': 'plan',
            'thinkingOptionId': 'high',
            'features': {'fast': true},
          },
          'initialPrompt': 'Start automation',
          'background': true,
        },
      );
      final autonomousSession = client.sessions.last;
      expect(autonomous['type'], 'fixture');
      expect(autonomous['workspaceId'], workspaceA['workspaceId']);
      expect(autonomous['currentModeId'], 'plan');
      final autonomousSummary = handle.manager.get(
        autonomous['agentId']! as String,
      )!;
      expect(autonomousSummary.labels, {'surface': 'automation'});
      expect(autonomousSummary.thinkingOptionId, 'high');
      expect(autonomousSummary.featureValues, {'fast': true});

      final legacyOpenCode = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'create_agent',
        {
          'title': 'OpenCode legacy full access',
          'provider': 'opencode/fixture-model',
          'workspaceId': workspaceB['workspaceId'],
          'settings': {
            'modeId': 'full-access',
            'features': {'auto_accept': false, 'custom': 'kept'},
          },
          'initialPrompt': 'Normalize provider create settings',
          'background': true,
        },
      );
      final legacyOpenCodeSession = client.sessions.last;
      final legacyOpenCodeSummary = handle.manager.get(
        legacyOpenCode['agentId']! as String,
      )!;
      expect(legacyOpenCodeSummary.currentModeId, 'build');
      expect(legacyOpenCodeSummary.featureValues, {
        'auto_accept': true,
        'custom': 'kept',
      });
      await pumpEventQueue();
      expect(legacyOpenCodeSession.prompts, [
        'Normalize provider create settings',
      ]);
      expect(
        await _call(topLevelEndpoint, mcpAuthToken, 'archive_agent', {
          'agentId': legacyOpenCode['agentId'],
        }),
        {'success': true},
      );

      final workspaceParent = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'fixture',
        model: 'fixture-model',
        mode: AgentMode.normal,
        modeId: 'full-access',
        title: 'Workspace parent',
        workspaceId: workspaceA['workspaceId']! as String,
      );
      final scopedEndpoint = endpoint.replace(
        queryParameters: {'callerAgentId': workspaceParent.agentId},
      );
      final renamedFromCaller = await _call(
        scopedEndpoint,
        mcpAuthToken,
        'rename_workspace',
        {'title': 'Caller workspace'},
      );
      expect(renamedFromCaller['workspaceId'], workspaceA['workspaceId']);
      expect(renamedFromCaller['title'], 'Caller workspace');
      final terminalChild = Directory(
        '${home.path}${Platform.pathSeparator}terminal-child',
      )..createSync();
      final scopedTerminal = await _call(
        scopedEndpoint,
        mcpAuthToken,
        'create_terminal',
        {'cwd': 'terminal-child', 'name': '  Scoped terminal  '},
      );
      final scopedTerminalId = scopedTerminal['id']! as String;
      expect(scopedTerminal['name'], 'Scoped terminal');
      expect(scopedTerminal['cwd'], terminalChild.path);
      expect(
        handle.terminals.listV2().singleWhere(
          (terminal) => terminal['id'] == scopedTerminalId,
        )['workspaceId'],
        workspaceA['workspaceId'],
      );
      final listedScopedTerminals =
          (await _call(
                scopedEndpoint,
                mcpAuthToken,
                'list_terminals',
                const {},
              ))['terminals']!
              as List;
      expect(
        listedScopedTerminals.cast<Map>().map((terminal) => terminal['id']),
        contains(scopedTerminalId),
      );
      final listedAllTerminals =
          (await _call(topLevelEndpoint, mcpAuthToken, 'list_terminals', const {
                'all': true,
              }))['terminals']!
              as List;
      expect(
        listedAllTerminals.cast<Map>().map((terminal) => terminal['id']),
        contains(scopedTerminalId),
      );
      await _call(scopedEndpoint, mcpAuthToken, 'send_terminal_keys', {
        'terminalId': scopedTerminalId,
        'keys': 'echo PASEO_MCP_TERMINAL',
        'literal': true,
      });
      await _call(scopedEndpoint, mcpAuthToken, 'send_terminal_keys', {
        'terminalId': scopedTerminalId,
        'keys': 'Enter',
      });
      final capturedTerminal = await _waitForTerminalText(
        scopedEndpoint,
        mcpAuthToken,
        scopedTerminalId,
        'PASEO_MCP_TERMINAL',
      );
      expect(capturedTerminal['terminalId'], scopedTerminalId);
      expect(capturedTerminal['totalLines'], greaterThan(0));
      expect(
        (capturedTerminal['lines']! as List).cast<String>().join('\n'),
        contains('PASEO_MCP_TERMINAL'),
      );
      expect(
        await _call(scopedEndpoint, mcpAuthToken, 'kill_terminal', {
          'terminalId': scopedTerminalId,
        }),
        {'success': true},
      );
      await _waitUntil(() => !handle.terminals.contains(scopedTerminalId));

      expect(
        await _callError(
          topLevelEndpoint,
          mcpAuthToken,
          'create_heartbeat',
          const {'prompt': 'Check status', 'cron': '0 * * * *'},
        ),
        contains('requires an agent-scoped session'),
      );
      final heartbeat =
          await _call(scopedEndpoint, mcpAuthToken, 'create_heartbeat', const {
            'prompt': 'Check status',
            'cron': '0 0 1 1 *',
            'timezone': 'UTC',
            'name': '  Daily heartbeat  ',
            'maxRuns': 3,
            'expiresIn': '1h',
          });
      expect(heartbeat['name'], 'Daily heartbeat');
      expect((heartbeat['target'] as Map)['agentId'], workspaceParent.agentId);
      final replacedHeartbeat =
          await _call(scopedEndpoint, mcpAuthToken, 'create_heartbeat', const {
            'prompt': 'Check status again',
            'cron': '0 0 1 1 *',
            'timezone': 'UTC',
            'name': 'Daily heartbeat',
          });
      expect(replacedHeartbeat['id'], heartbeat['id']);
      expect(replacedHeartbeat['prompt'], 'Check status again');
      expect(
        await _callError(callerEndpoint, mcpAuthToken, 'delete_heartbeat', {
          'id': heartbeat['id'],
        }),
        contains('does not belong to caller'),
      );
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'inspect_schedule', {
          'id': heartbeat['id'],
        }),
        contains('Schedule not found'),
      );
      expect(
        (await _call(
          topLevelEndpoint,
          mcpAuthToken,
          'list_schedules',
          const {},
        ))['schedules'],
        isEmpty,
      );
      expect(
        await _call(scopedEndpoint, mcpAuthToken, 'delete_heartbeat', {
          'id': heartbeat['id'],
        }),
        {'success': true},
      );

      expect(
        await _callError(
          topLevelEndpoint,
          mcpAuthToken,
          'create_schedule',
          const {'prompt': 'Run checks', 'cron': '0 0 1 1 *'},
        ),
        contains('provider is required'),
      );
      final scheduled =
          await _call(topLevelEndpoint, mcpAuthToken, 'create_schedule', {
            'prompt': 'Run checks',
            'cron': '0 0 1 1 *',
            'timezone': 'UTC',
            'name': '  Scheduled checks  ',
            'provider': 'fixture/fixture-model',
            'cwd': home.path,
            'isolation': 'local',
            'maxRuns': 3,
            'expiresIn': '1h',
          });
      final scheduleId = scheduled['id']! as String;
      final replacedSchedule =
          await _call(topLevelEndpoint, mcpAuthToken, 'create_schedule', {
            'prompt': 'Run checks again',
            'cron': '0 0 1 1 *',
            'timezone': 'UTC',
            'name': 'Scheduled checks',
            'provider': 'fixture/fixture-model',
            'cwd': home.path,
            'isolation': 'local',
          });
      expect(replacedSchedule['id'], scheduleId);
      expect(replacedSchedule['prompt'], 'Run checks again');
      final listedSchedules = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'list_schedules',
        const {},
      );
      expect(
        (listedSchedules['schedules']! as List).cast<Map>().map(
          (entry) => entry['id'],
        ),
        contains(scheduleId),
      );
      final inspectedSchedule = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'inspect_schedule',
        {'id': scheduleId},
      );
      expect(inspectedSchedule['runs'], isEmpty);
      expect(
        await _call(topLevelEndpoint, mcpAuthToken, 'pause_schedule', {
          'id': scheduleId,
        }),
        {'success': true},
      );
      expect(
        await _call(topLevelEndpoint, mcpAuthToken, 'resume_schedule', {
          'id': scheduleId,
        }),
        {'success': true},
      );
      final updatedSchedule =
          await _call(topLevelEndpoint, mcpAuthToken, 'update_schedule', {
            'id': scheduleId,
            'every': '1h',
            'name': 'Hourly checks',
            'prompt': 'Run hourly checks',
            'maxRuns': null,
            'provider': 'fixture',
            'model': 'fixture-model',
            'mode': null,
            'cwd': home.path,
            'expiresIn': '2h',
          });
      expect(updatedSchedule['name'], 'Hourly checks');
      expect((updatedSchedule['cadence'] as Map)['expression'], '0 * * * *');
      expect(updatedSchedule['maxRuns'], isNull);

      client.completeNewSessions = true;
      final runSchedule = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'run_schedule_once',
        {'id': scheduleId},
      );
      client.completeNewSessions = false;
      expect((runSchedule['runs']! as List), hasLength(1));
      expect(
        ((runSchedule['runs']! as List).single as Map)['status'],
        'succeeded',
      );
      final scheduleLogs = await _call(
        topLevelEndpoint,
        mcpAuthToken,
        'schedule_logs',
        {'id': scheduleId},
      );
      expect((scheduleLogs['runs']! as List), hasLength(1));
      expect(
        await _call(topLevelEndpoint, mcpAuthToken, 'delete_schedule', {
          'id': scheduleId,
        }),
        {'success': true},
      );

      final crossWorkspaceChild =
          await _call(scopedEndpoint, mcpAuthToken, 'create_agent', {
            'title': 'Cross workspace child',
            'provider': 'fixture/fixture-model',
            'workspaceId': workspaceB['workspaceId'],
            'initialPrompt': 'Work elsewhere',
            'notifyOnFinish': false,
          });
      final crossWorkspaceChildSession = client.sessions.last;
      expect(crossWorkspaceChild['guidance'], isNull);
      final childSummary = handle.manager.get(
        crossWorkspaceChild['agentId']! as String,
      )!;
      expect(childSummary.workspaceId, workspaceB['workspaceId']);
      expect(childSummary.parentAgentId, workspaceParent.agentId);
      expect(childSummary.currentModeId, 'full-access');
      expect(
        childSummary.labels[paseoParentAgentIdLabel],
        workspaceParent.agentId,
      );
      final detachedChild = await _call(
        scopedEndpoint,
        mcpAuthToken,
        'create_agent',
        {
          'title': 'Detached workspace child',
          'provider': 'fixture/fixture-model',
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'existing',
            'workspaceId': workspaceB['workspaceId'],
          },
          'labels': {
            'surface': 'detached',
            paseoParentAgentIdLabel: 'spoofed-parent',
          },
          'initialPrompt': 'Work independently',
        },
      );
      final detachedChildSession = client.sessions.last;
      expect(detachedChild['guidance'], isNull);
      final detachedSummary = handle.manager.get(
        detachedChild['agentId']! as String,
      )!;
      expect(detachedSummary.workspaceId, workspaceB['workspaceId']);
      expect(detachedSummary.parentAgentId, isNull);
      expect(detachedSummary.currentModeId, 'full-access');
      expect(detachedSummary.labels, {'surface': 'detached'});
      expect(
        await _callError(topLevelEndpoint, mcpAuthToken, 'create_agent', {
          'title': 'Invalid root subagent',
          'provider': 'fixture/fixture-model',
          'relationship': {'kind': 'subagent'},
          'workspace': {
            'kind': 'existing',
            'workspaceId': workspaceB['workspaceId'],
          },
          'initialPrompt': 'Cannot attach without a caller',
        }),
        contains('relationship subagent requires an agent-scoped tool session'),
      );
      await pumpEventQueue();
      expect(autonomousSession.prompts, ['Start automation']);
      expect(crossWorkspaceChildSession.prompts, ['Work elsewhere']);
      expect(detachedChildSession.prompts, ['Work independently']);

      final archivedWorkspace = await _call(
        endpoint,
        mcpAuthToken,
        'archive_workspace',
        {'workspaceId': workspaceA['workspaceId']},
      );
      expect(archivedWorkspace['workspaceId'], workspaceA['workspaceId']);
      expect((archivedWorkspace['archivedAgentIds']! as List).toSet(), {
        autonomous['agentId'],
        workspaceParent.agentId,
      });
      expect(archivedWorkspace['removedDirectory'], isFalse);
      expect(home.existsSync(), isTrue);
      expect(
        handle.manager
            .get(crossWorkspaceChild['agentId']! as String)
            ?.archivedAt,
        isNull,
      );
      expect(
        handle.manager.get(detachedChild['agentId']! as String)?.archivedAt,
        isNull,
      );
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

Future<Map<String, Object?>> _call(
  Uri endpoint,
  String bearer,
  String name,
  Map<String, Object?> arguments,
) async {
  final response = await _post(endpoint, {
    'jsonrpc': '2.0',
    'id': name,
    'method': 'tools/call',
    'params': {'name': name, 'arguments': arguments},
  }, bearer: bearer);
  final result = _result(response);
  if (result['structuredContent'] is! Map) {
    fail('MCP tool $name failed: ${result['content']}');
  }
  return Map<String, Object?>.from(result['structuredContent']! as Map);
}

Future<String> _callError(
  Uri endpoint,
  String bearer,
  String name,
  Map<String, Object?> arguments,
) async {
  final response = await _post(endpoint, {
    'jsonrpc': '2.0',
    'id': name,
    'method': 'tools/call',
    'params': {'name': name, 'arguments': arguments},
  }, bearer: bearer);
  final result = _result(response);
  expect(result['isError'], isTrue);
  final content = (result['content']! as List).single as Map;
  return content['text']! as String;
}

Future<Map<String, Object?>> _waitForTerminalText(
  Uri endpoint,
  String bearer,
  String terminalId,
  String expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final capture = await _call(endpoint, bearer, 'capture_terminal', {
      'terminalId': terminalId,
      'scrollback': true,
    });
    final lines = (capture['lines']! as List).cast<String>();
    if (lines.any((line) => line.contains(expected))) return capture;
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for terminal output containing $expected');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous MCP notification');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _git(List<String> arguments, String cwd) async {
  final result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    fail(
      'git ${arguments.join(' ')} failed (${result.exitCode}): '
      '${result.stderr}',
    );
  }
}

Future<String> _gitOutput(List<String> arguments, String cwd) async {
  final result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    fail(
      'git ${arguments.join(' ')} failed (${result.exitCode}): '
      '${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}
