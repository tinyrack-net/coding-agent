import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/permit_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'permit CLI lists and resolves live permissions over the real WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-permit-e2e-');
      addTearDown(() => _deleteDirectoryEventually(home));
      final registries = WorkspaceRegistries(dataDir: home.path);
      await registries.initialize();
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'project-permit',
          rootPath: home.path,
          kind: PersistedProjectKind.nonGit,
          displayName: 'permit',
          createdAt: '2026-07-30T00:00:00.000Z',
          updatedAt: '2026-07-30T00:00:00.000Z',
        ),
      );
      await registries.workspaces.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'workspace-permit',
          projectId: 'project-permit',
          cwd: home.path,
          kind: PersistedWorkspaceKind.directory,
          displayName: 'permit',
          createdAt: '2026-07-30T00:00:00.000Z',
          updatedAt: '2026-07-30T00:00:00.000Z',
        ),
      );
      final provider = _PermissionClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': provider},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final agent = await handle.manager.createAgent(
        cwd: home.path,
        provider: 'codex',
        model: 'gpt-5.4',
        mode: AgentMode.normal,
        title: 'Permission agent',
        workspaceId: 'workspace-permit',
      );
      final host = '127.0.0.1:${handle.server.port}';

      provider.session.emitPermission(id: 'permission-allow-123', tool: 'Bash');
      await _waitFor(
        () => handle.manager
            .fetchCanonicalTimeline(agent.agentId)
            .rows
            .map((row) => row.item)
            .whereType<PermissionItem>()
            .any((item) => item.status == PermissionStatus.pending),
      );

      final listed = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: ['ls', '--host', host, '--json'],
          environment: const {},
          writeOutput: listed.write,
        ),
        0,
      );
      final listedRows = (jsonDecode(listed.toString()) as List).cast<Map>();
      expect(listedRows, hasLength(1));
      expect(listedRows.single['agentId'], agent.agentId);
      expect(listedRows.single['id'], 'permissi');
      expect(listedRows.single['name'], 'Bash');

      final allowed = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: [
            'allow',
            agent.agentId.substring(0, 8),
            'permission-allow',
            '--input',
            '{"command":"dart test"}',
            '--host',
            host,
            '--json',
          ],
          environment: const {},
          writeOutput: allowed.write,
        ),
        0,
      );
      await _waitFor(() => provider.session.resolutions.length == 1);
      final allowResolution = provider.session.resolutions.single;
      expect(allowResolution.decision, PermissionDecision.allow);
      expect(allowResolution.updatedInput, {'command': 'dart test'});
      expect(
        (jsonDecode(allowed.toString()) as List).single['result'],
        'allowed',
      );
      await _waitFor(
        () => handle.manager
            .fetchCanonicalTimeline(agent.agentId)
            .rows
            .map((row) => row.item)
            .whereType<PermissionItem>()
            .any(
              (item) =>
                  item.permissionId == 'permission-allow-123' &&
                  item.status == PermissionStatus.allowed,
            ),
      );
      final afterAllow = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: ['ls', '--host', host, '--json'],
          environment: const {},
          writeOutput: afterAllow.write,
        ),
        0,
      );
      expect(jsonDecode(afterAllow.toString()), isEmpty);

      provider.session.emitPermission(id: 'permission-deny-456', tool: 'Write');
      await _waitFor(
        () => handle.manager
            .fetchCanonicalTimeline(agent.agentId)
            .rows
            .map((row) => row.item)
            .whereType<PermissionItem>()
            .any(
              (item) =>
                  item.permissionId == 'permission-deny-456' &&
                  item.status == PermissionStatus.pending,
            ),
      );

      final denied = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: [
            'deny',
            agent.agentId,
            '--all',
            '--message',
            'Not safe',
            '--interrupt',
            '--host',
            host,
            '--json',
          ],
          environment: const {},
          writeOutput: denied.write,
        ),
        0,
      );
      await _waitFor(() => provider.session.resolutions.length == 2);
      final denyResolution = provider.session.resolutions.last;
      expect(denyResolution.decision, PermissionDecision.deny);
      expect(denyResolution.message, 'Not safe');
      expect(denyResolution.interrupt, isTrue);
      expect(
        (jsonDecode(denied.toString()) as List).single['result'],
        'denied',
      );
    },
  );
}

final class _PermissionClient implements AgentClient {
  final _PermissionSession session = _PermissionSession();

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
  }) async => session;
}

final class _PermissionResolution {
  const _PermissionResolution({
    required this.decision,
    required this.message,
    required this.updatedInput,
    required this.interrupt,
  });

  final PermissionDecision decision;
  final String? message;
  final Map<String, Object?>? updatedInput;
  final bool? interrupt;
}

final class _PermissionSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  final resolutions = <_PermissionResolution>[];

  @override
  Stream<ProviderEvent> get events => _events.stream;

  void emitPermission({required String id, required String tool}) {
    _events.add(
      PermissionRequested(
        permissionId: id,
        toolName: tool,
        detail: PlainTextDetail(label: tool, text: '$tool needs approval'),
        respond:
            (
              decision, {
              message,
              selectedActionId,
              updatedInput,
              updatedPermissions,
              interrupt,
            }) async {
              resolutions.add(
                _PermissionResolution(
                  decision: decision,
                  message: message,
                  updatedInput: updatedInput,
                  interrupt: interrupt,
                ),
              );
            },
      ),
    );
  }

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
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
