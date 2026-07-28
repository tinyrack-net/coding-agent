import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/server/agent_commands_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _command = AgentSlashCommand(
  name: 'review',
  description: 'Review changes',
  argumentHint: '<path>',
  kind: AgentSlashCommandKind.skill,
);

final class _CommandSession implements CommandListingAgentSession {
  final controller = StreamController<ProviderEvent>.broadcast();
  bool disposed = false;

  @override
  Stream<ProviderEvent> get events => controller.stream;

  @override
  Future<List<AgentSlashCommand>> listCommands() async => const [_command];

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

final class _CommandClient implements DraftCommandListingAgentClient {
  final sessions = <_CommandSession>[];
  ListCommandsDraftConfig? lastDraft;

  @override
  Future<List<AgentSlashCommand>> listCommands(
    ListCommandsDraftConfig config,
  ) async {
    lastDraft = config;
    return const [_command];
  }

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
    final session = _CommandSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  late Directory temp;
  late _CommandClient client;
  late AgentManager manager;
  late AgentCommandsService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('agent-commands-');
    client = _CommandClient();
    manager = AgentManager(
      clients: {'codex': client},
      store: AgentStore(dataDir: temp.path, debounce: Duration.zero),
    );
    service = AgentCommandsService(manager);
  });

  tearDown(() async {
    await manager.dispose();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {}
  });

  test('lists commands for live agents and draft configurations', () async {
    final agent = await manager.createAgent(
      cwd: temp.path,
      provider: 'codex',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
    );
    final active = ListCommandsResponse.fromJson(
      (await service.handle(
        ListCommandsRequest(
          agentId: agent.agentId,
          requestId: 'active',
        ).toJson(),
      ))!,
    );
    expect(active.commands, hasLength(1));
    expect(active.error, isNull);

    final draft = ListCommandsResponse.fromJson(
      (await service.handle(
        const ListCommandsRequest(
          agentId: '__new_agent__',
          requestId: 'draft',
          draftConfig: ListCommandsDraftConfig(
            provider: 'codex',
            cwd: 'C:/repo',
            model: 'gpt-5.4',
            featureValues: {'fast_mode': true},
          ),
        ).toJson(),
      ))!,
    );
    expect(draft.commands.single.name, 'review');
    expect(client.lastDraft?.featureValues, {'fast_mode': true});
  });

  test('returns frozen empty and error responses', () async {
    expect(await service.handle({'type': 'other'}), isNull);

    final noModel = ListCommandsResponse.fromJson(
      (await service.handle(
        const ListCommandsRequest(
          agentId: '__new_agent__',
          requestId: 'no-model',
          draftConfig: ListCommandsDraftConfig(
            provider: 'codex',
            cwd: 'C:/repo',
          ),
        ).toJson(),
      ))!,
    );
    expect(noModel.commands, isEmpty);
    expect(noModel.error, isNull);

    final missing = ListCommandsResponse.fromJson(
      (await service.handle(
        const ListCommandsRequest(
          agentId: 'missing',
          requestId: 'missing',
        ).toJson(),
      ))!,
    );
    expect(missing.commands, isEmpty);
    expect(missing.error, 'Agent not found: missing');

    final unavailable = ListCommandsResponse.fromJson(
      (await service.handle(
        const ListCommandsRequest(
          agentId: '__new_agent__',
          requestId: 'unavailable',
          draftConfig: ListCommandsDraftConfig(
            provider: 'claude',
            cwd: 'C:/repo',
            model: 'sonnet',
          ),
        ).toJson(),
      ))!,
    );
    expect(unavailable.error, contains("Provider 'claude' is not available"));
  });
}
