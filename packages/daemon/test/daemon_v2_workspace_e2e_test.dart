import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/terminal/agent_hook_installer.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'native v2 project and workspace lifecycle crosses daemon assembly',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'daemon-v2-workspace-',
      );
      addTearDown(() async {
        if (temp.existsSync()) await temp.delete(recursive: true);
      });
      final project = Directory('${temp.path}${Platform.pathSeparator}project')
        ..createSync();
      const attentionAgentId = 'attention-agent';
      await AgentStore(dataDir: temp.path).save(
        const PersistedAgent(
          summary: AgentSummary(
            agentId: attentionAgentId,
            title: 'Attention E2E',
            cwd: 'project',
            provider: 'codex',
            model: 'gpt-5',
            mode: AgentMode.normal,
            runState: AgentRunState.idle,
            createdAtMs: 1,
            requiresAttention: true,
            attentionReason: AgentAttentionReason.finished,
            attentionTimestamp: '2026-07-26T00:00:00.000Z',
          ),
          archived: false,
          epoch: 1,
          lastSeq: 0,
          items: [],
        ),
      );
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        enableTerminalAgentHooks: true,
        hookInstallOptions: AgentHookInstallOptions(
          configDir: '${temp.path}${Platform.pathSeparator}provider-hooks',
          homeDir: temp.path,
          environment: const {},
        ),
        log: (_) {},
      );
      addTearDown(handle.stop);
      final hookRoot = '${temp.path}${Platform.pathSeparator}provider-hooks';
      expect(
        File('$hookRoot${Platform.pathSeparator}settings.json').existsSync(),
        isTrue,
      );
      expect(
        File('$hookRoot${Platform.pathSeparator}hooks.json').existsSync(),
        isTrue,
      );
      expect(
        File(
          '$hookRoot${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}tinyrack-terminal-activity.js',
        ).existsSync(),
        isTrue,
      );

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
            clientId: 'v2-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      expect(
        await frames.firstWhere((frame) => frame['status'] == 'server_info'),
        containsPair('serverId', isNotEmpty),
      );

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const FetchAgentsRequest(
            requestId: 'invalid-agent-cursor',
            activeScope: true,
            limit: 1,
            cursor: '0',
          ).toJson(),
        }),
      );
      final invalidCursor = _sessionMessage(
        await frames.firstWhere(
          (frame) =>
              _sessionMessage(frame)['type'] == 'rpc_error' &&
              ((_sessionMessage(frame)['payload'] as Map?)?['requestId']) ==
                  'invalid-agent-cursor',
        ),
      );
      expect(invalidCursor['payload'], containsPair('code', 'invalid_cursor'));
      expect(
        invalidCursor['payload'],
        containsPair('error', 'Invalid fetch_agents cursor'),
      );

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const WorkspaceSetupStatusRequest(
            workspaceId: 'workspace-not-yet-created',
            requestId: 'setup-status',
          ).toJson(),
        }),
      );
      final setupStatus = WorkspaceSetupStatusResponse.fromJson(
        _sessionMessage(
          await frames.firstWhere(
            (frame) =>
                _sessionMessage(frame)['type'] ==
                WorkspaceSetupStatusResponse.type,
          ),
        ),
      );
      expect(setupStatus.workspaceId, 'workspace-not-yet-created');
      expect(setupStatus.snapshot, isNull);

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'get_daemon_config_request',
            'requestId': 'config-get',
          },
        }),
      );
      final getConfig = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'get_daemon_config_response',
      );
      final getPayload = ((getConfig['message'] as Map)['payload'] as Map)
          .cast<String, Object?>();
      expect(getPayload['requestId'], 'config-get');
      expect((getPayload['config'] as Map)['enableTerminalAgentHooks'], isTrue);

      final changedFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'status',
      );
      final setFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'set_daemon_config_response',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'set_daemon_config_request',
            'requestId': 'config-set',
            'config': {'enableTerminalAgentHooks': false},
          },
        }),
      );
      final changed = await changedFuture;
      final changedMessage = (changed['message'] as Map)['message'] as Map;
      expect(changedMessage['status'], 'daemon_config_changed');
      expect(
        (changedMessage['config'] as Map)['enableTerminalAgentHooks'],
        isFalse,
      );
      final setConfig = await setFuture;
      expect(
        (((setConfig['message'] as Map)['payload'] as Map)['config']
            as Map)['enableTerminalAgentHooks'],
        isFalse,
      );
      expect(
        registeredAgentHooksAreInstalled(
          options: AgentHookInstallOptions(
            configDir: hookRoot,
            homeDir: temp.path,
            environment: const {},
          ),
        ),
        isFalse,
      );

      final fullPatchResponse = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                'set_daemon_config_response' &&
            (((frame['message'] as Map)['payload'] as Map)['requestId']) ==
                'config-full-set',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'set_daemon_config_request',
            'requestId': 'config-full-set',
            'config': {
              'mcp': {'injectIntoAgents': true},
              'browserTools': {'enabled': true},
              'autoArchiveAfterMerge': true,
              'appendSystemPrompt': 'Tinyrack',
              'terminalProfiles': [
                {
                  'id': 'codex',
                  'name': 'Codex',
                  'command': 'codex',
                  'args': ['--search'],
                },
              ],
            },
          },
        }),
      );
      final fullPatch = await fullPatchResponse;
      final fullConfig =
          (((fullPatch['message'] as Map)['payload'] as Map)['config'] as Map);
      expect((fullConfig['mcp'] as Map)['injectIntoAgents'], isTrue);
      expect((fullConfig['browserTools'] as Map)['enabled'], isTrue);
      expect(fullConfig['autoArchiveAfterMerge'], isTrue);
      expect(fullConfig['appendSystemPrompt'], 'Tinyrack');
      expect(
        (((fullConfig['terminalProfiles'] as List).single as Map)['args']),
        ['--search'],
      );
      final persistedConfig =
          jsonDecode(
                File(
                  '${temp.path}${Platform.pathSeparator}config.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(
        ((persistedConfig['daemon'] as Map)['browserTools'] as Map)['enabled'],
        isTrue,
      );

      final activityAt = DateTime.now().toUtc();
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'client_heartbeat',
            'deviceType': 'web',
            'focusedAgentId': attentionAgentId,
            'focusedTerminalId': null,
            'lastActivityAt': activityAt.toIso8601String(),
            'appVisible': true,
          },
        }),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        if (handle
                .server
                .authenticatedV2Connections
                .single
                .clientPresence
                .lastActivityAtMs !=
            null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final presence =
          handle.server.authenticatedV2Connections.single.clientPresence;
      expect(presence.focusedAgentId, attentionAgentId);
      expect(presence.appVisible, isTrue);

      final shouldPush = broadcastAgentAttention(
        server: handle.server,
        agentId: attentionAgentId,
        reason: AgentAttentionReason.finished,
        timestamp: '2026-07-26T00:00:00.000Z',
        nowMs: activityAt.millisecondsSinceEpoch,
      );
      expect(shouldPush, isFalse);
      final attentionOuter = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map<String, Object?>)['type'] ==
                'agent_attention_required',
      );
      final attentionMessage =
          attentionOuter['message'] as Map<String, Object?>;
      final attentionPayload =
          attentionMessage['payload'] as Map<String, Object?>;
      expect(attentionPayload['agentId'], attentionAgentId);
      expect(attentionPayload['reason'], 'finished');
      expect(attentionPayload['shouldNotify'], isFalse);

      final terminalShouldPush = broadcastTerminalAttention(
        server: handle.server,
        transition: const TerminalActivityTransition(
          terminalId: 'terminal-notification',
          terminalName: 'PowerShell',
          cwd: 'project',
          workspaceId: 'workspace-notification',
          activity: TerminalActivity(
            state: TerminalActivityState.idle,
            attentionReason: TerminalActivityAttentionReason.finished,
            changedAt: 2,
          ),
          previous: TerminalActivity(
            state: TerminalActivityState.working,
            changedAt: 1,
          ),
        ),
        nowMs: activityAt.millisecondsSinceEpoch,
      );
      expect(terminalShouldPush, isFalse);
      final terminalAttentionOuter = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map<String, Object?>)['type'] ==
                'terminal_attention_required',
      );
      final terminalAttention =
          (terminalAttentionOuter['message'] as Map<String, Object?>)['payload']
              as Map<String, Object?>;
      expect(terminalAttention, {
        'serverId': handle.server.serverId,
        'terminalId': 'terminal-notification',
        'cwd': 'project',
        'workspaceId': 'workspace-notification',
        'reason': 'finished',
        'title': 'Terminal finished',
        'body': 'PowerShell',
        'shouldNotify': true,
      });

      Future<Map<String, Object?>> request(
        Map<String, Object?> message,
        String responseType,
      ) async {
        channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
        final outer = await frames.firstWhere(
          (frame) =>
              frame['type'] == 'session' &&
              (frame['message'] as Map<String, Object?>)['type'] ==
                  responseType,
        );
        return outer['message'] as Map<String, Object?>;
      }

      final providers = GetProvidersSnapshotResponse.fromJson(
        await request(
          const GetProvidersSnapshotRequest(requestId: 'providers').toJson(),
          'get_providers_snapshot_response',
        ),
      );
      expect(providers.entries.map((entry) => entry.provider), [
        'claude',
        'codex',
        'copilot',
        'opencode',
        'pi',
        'omp',
      ]);

      final forgeSearch = ForgeSearchResponse.fromJson(
        await request(
          ForgeSearchRequest(
            cwd: project.path,
            query: '',
            requestId: 'forge-search',
          ).toJson(),
          ForgeSearchResponse.type,
        ),
      );
      expect(forgeSearch.authState, 'no_remote');
      expect(forgeSearch.items, isEmpty);
      expect(forgeSearch.error, isNull);

      final pullRequestStatus = CheckoutPrStatusResponse.fromJson(
        await request(
          CheckoutPrStatusRequest(
            cwd: project.path,
            requestId: 'pr-status',
          ).toJson(),
          CheckoutPrStatusResponse.type,
        ),
      );
      expect(pullRequestStatus.authState, 'no_remote');
      expect(pullRequestStatus.githubFeaturesEnabled, isFalse);
      expect(pullRequestStatus.status, isNull);
      expect(pullRequestStatus.hasExplicitForge, isFalse);

      final pullRequestTimeline = PullRequestTimelineResponse.fromJson(
        await request(
          PullRequestTimelineRequest(
            cwd: project.path,
            prNumber: 1,
            repoOwner: 'acme',
            repoName: 'repo',
            requestId: 'pr-timeline',
          ).toJson(),
          PullRequestTimelineResponse.type,
        ),
      );
      expect(pullRequestTimeline.authState, 'no_remote');
      expect(pullRequestTimeline.githubFeaturesEnabled, isFalse);
      expect(pullRequestTimeline.items, isEmpty);
      expect(
        pullRequestTimeline.error?.message,
        contains('No supported forge remote'),
      );

      final checkDetails = CheckoutForgeGetCheckDetailsResponse.fromJson(
        await request(
          CheckoutForgeGetCheckDetailsRequest(
            type: CheckoutForgeGetCheckDetailsRequest.modernType,
            cwd: project.path,
            checkRunId: 1,
            requestId: 'check-details',
          ).toJson(),
          CheckoutForgeGetCheckDetailsResponse.modernType,
        ),
      );
      expect(checkDetails.success, isFalse);
      expect(checkDetails.details, isNull);
      expect(checkDetails.error?.code, CheckoutErrorCode.unknown);
      expect(
        checkDetails.error?.message,
        contains('No supported forge remote'),
      );

      final createPullRequest = CheckoutPrCreateResponse.fromJson(
        await request(
          CheckoutPrCreateRequest(
            cwd: project.path,
            requestId: 'create-pr',
          ).toJson(),
          CheckoutPrCreateResponse.type,
        ),
      );
      expect(createPullRequest.url, isNull);
      expect(createPullRequest.number, isNull);
      expect(createPullRequest.error?.code, CheckoutErrorCode.notGitRepo);

      final autoMerge = CheckoutForgeSetAutoMergeResponse.fromJson(
        await request(
          CheckoutForgeSetAutoMergeRequest(
            type: CheckoutForgeSetAutoMergeRequest.modernType,
            cwd: project.path,
            enabled: true,
            mergeMethod: CheckoutPrMergeMethod.squash,
            requestId: 'auto-merge',
          ).toJson(),
          CheckoutForgeSetAutoMergeResponse.modernType,
        ),
      );
      expect(autoMerge.success, isFalse);
      expect(autoMerge.error?.code, CheckoutErrorCode.notGitRepo);

      final clearedAttention = await request({
        'type': 'clear_agent_attention',
        'agentId': attentionAgentId,
        'requestId': 'clear-attention',
      }, 'clear_agent_attention_response');
      final clearPayload = clearedAttention['payload'] as Map<String, Object?>;
      expect(clearPayload['requestId'], 'clear-attention');
      expect(clearPayload['agentId'], attentionAgentId);
      expect(clearPayload['agents'], hasLength(1));
      expect(
        ((clearPayload['agents'] as List).single as Map)['requiresAttention'],
        isFalse,
      );

      final added = ProjectAddResponse.fromJson(
        await request(
          ProjectAddRequest(cwd: project.path, requestId: 'add').toJson(),
          'project.add.response',
        ),
      );
      expect(added.project, isNotNull);

      final created = WorkspaceCreateResponse.fromJson(
        await request(
          WorkspaceCreateRequest(
            requestId: 'create',
            source: DirectoryWorkspaceCreateSource(
              path: project.path,
              projectId: added.project!.projectId,
            ),
          ).toJson(),
          'workspace.create.response',
        ),
      );
      expect(created.workspace?.workspaceDirectory, project.path);

      final fetched = FetchWorkspacesResponse.fromJson(
        await request(
          const FetchWorkspacesRequest(
            requestId: 'fetch',
            hasSubscription: true,
            subscriptionId: 'workspaces',
          ).toJson(),
          'fetch_workspaces_response',
        ),
      );
      expect(fetched.entries.single.id, created.workspace!.id);

      final title = WorkspaceTitleSetResponse.fromJson(
        await request(
          WorkspaceTitleSetRequest(
            workspaceId: created.workspace!.id,
            title: '  E2E workspace  ',
            requestId: 'title',
          ).toJson(),
          'workspace.title.set.response',
        ),
      );
      expect(title.title, 'E2E workspace');

      final pinned = WorkspacePinSetResponse.fromJson(
        await request(
          WorkspacePinSetRequest(
            workspaceId: created.workspace!.id,
            pinned: true,
            requestId: 'pin',
          ).toJson(),
          'workspace.pin.set.response',
        ),
      );
      expect(pinned.pinnedAt, isNotNull);

      final archived = ArchiveWorkspaceResponse.fromJson(
        await request(
          ArchiveWorkspaceRequest(
            workspaceId: created.workspace!.id,
            requestId: 'archive',
          ).toJson(),
          'archive_workspace_response',
        ),
      );
      expect(archived.archivedAt, isNotNull);

      final recovery = WorkspaceRecoveryInspectResponse.fromJson(
        await request(
          WorkspaceRecoveryInspectRequest(
            workspaceId: created.workspace!.id,
            requestId: 'inspect',
          ).toJson(),
          'workspace.recovery.inspect.response',
        ),
      );
      expect((recovery.state as RecoverableWorkspaceState).action, 'unarchive');

      final restored = WorkspaceRecoveryRestoreResponse.fromJson(
        await request(
          WorkspaceRecoveryRestoreRequest(
            workspaceId: created.workspace!.id,
            requestId: 'restore',
          ).toJson(),
          'workspace.recovery.restore.response',
        ),
      );
      expect(restored.accepted, isTrue);

      final projectsOnDisk =
          jsonDecode(
                await File(
                  '${temp.path}${Platform.pathSeparator}projects.json',
                ).readAsString(),
              )
              as List;
      final workspacesOnDisk =
          jsonDecode(
                await File(
                  '${temp.path}${Platform.pathSeparator}workspaces.json',
                ).readAsString(),
              )
              as List;
      expect(projectsOnDisk, hasLength(1));
      expect(workspacesOnDisk, hasLength(1));
      expect((workspacesOnDisk.single as Map)['archivedAt'], isNull);
    },
  );
}

Map<String, Object?> _sessionMessage(Map<String, Object?> frame) {
  final message = frame['message'];
  if (frame['type'] != 'session' || message is! Map) {
    return const {};
  }
  return message.cast<String, Object?>();
}
