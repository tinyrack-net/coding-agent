import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/generic_acp_agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
}

GenericAcpAgentClient client({Future<String?> Function()? resolveCommand}) =>
    GenericAcpAgentClient(
      provider: 'fixture-acp',
      command: 'dart',
      commandArgs: [fixturePath()],
      environment: const {'ACP_FIXTURE_ENV': 'configured'},
      providerParams: const {'supportsMcpServers': false},
      resolveCommand: resolveCommand ?? () async => Platform.resolvedExecutable,
    );

Future<T> eventOf<T extends ProviderEvent>(Stream<ProviderEvent> events) =>
    events.firstWhere((event) => event is T).then((event) => event as T);

void main() {
  test(
    'runs ACP initialize, session, stream, tool and permission lifecycle',
    () async {
      final session = await client().createSession(
        cwd: Directory.current.path,
        model: 'fixture-model',
        mode: AgentMode.normal,
        modeId: 'agent',
        thinkingOptionId: 'medium',
        featureValues: const {'enabled': true},
      );
      addTearDown(session.dispose);

      final events = <ProviderEvent>[];
      final completed = Completer<void>();
      final started = Completer<void>();
      final subscription = session.events.listen((event) {
        events.add(event);
        if (event is SessionStarted && !started.isCompleted) {
          started.complete();
        }
        if (event case PermissionRequested(:final respond)) {
          unawaited(respond(PermissionDecision.allow));
        }
        if (event is TurnCompleted && !completed.isCompleted) {
          completed.complete();
        }
      });
      addTearDown(subscription.cancel);

      await started.future.timeout(const Duration(seconds: 5));
      expect(events.single, isA<SessionStarted>());
      expect((events.single as SessionStarted).sessionId, 'session-1');
      expect(session, isA<CommandListingAgentSession>());
      expect(await (session as CommandListingAgentSession).listCommands(), [
        isA<AgentSlashCommand>()
            .having((command) => command.name, 'name', 'review')
            .having((command) => command.argumentHint, 'hint', '[path]'),
      ]);

      await (session as StructuredPromptAgentSession)
          .promptWithAttachments('implement', const [
            TextAgentAttachment(
              text: 'prior context',
              contextKind: 'chat_history',
            ),
            TextAgentAttachment(text: 'file context'),
          ]);
      await completed.future.timeout(const Duration(seconds: 5));

      expect(
        events.whereType<AssistantTextDelta>().single.text,
        'reply:prior context|implement|file context',
      );
      expect(events.whereType<ReasoningDelta>().single.text, 'thinking');
      expect(
        events.whereType<ToolCallStarted>().single,
        isA<ToolCallStarted>()
            .having((event) => event.itemId, 'id', 'tool-1')
            .having((event) => event.status, 'status', ToolCallStatus.pending),
      );
      expect(
        events.whereType<ToolCallUpdated>().single.status,
        ToolCallStatus.success,
      );
      expect(events.whereType<PermissionRequested>(), hasLength(1));
      expect(
        events.whereType<UsageUpdated>().single.usage,
        isA<AgentUsage>()
            .having((usage) => usage.inputTokens, 'input', 6)
            .having((usage) => usage.cachedInputTokens, 'cached', 2)
            .having((usage) => usage.outputTokens, 'output', 4),
      );
      expect(events.whereType<TurnCompleted>(), hasLength(1));
    },
  );

  test('sends cancellation and reports an interrupted turn failure', () async {
    final session = await client().createSession(
      cwd: Directory.current.path,
      model: '',
      mode: AgentMode.normal,
    );
    addTearDown(session.dispose);
    final failed = eventOf<TurnFailed>(session.events);
    final assistant = eventOf<AssistantTextDelta>(session.events);

    await session.prompt('wait-for-cancel');
    await assistant;
    await session.interrupt();

    expect(
      await failed.timeout(const Duration(seconds: 5)),
      isA<TurnFailed>().having((event) => event.error, 'error', 'Interrupted'),
    );
  });

  test(
    'resumes with cwd and MCP context when the agent advertises resume',
    () async {
      final session = await client().createSession(
        cwd: Directory.current.path,
        model: '',
        mode: AgentMode.normal,
        sessionId: 'restored-session',
      );
      addTearDown(session.dispose);

      expect(
        await eventOf<SessionStarted>(session.events),
        isA<SessionStarted>().having(
          (event) => event.sessionId,
          'session id',
          'restored-session',
        ),
      );
    },
  );

  test(
    'fails before spawning when the configured command is unavailable',
    () async {
      await expectLater(
        client(resolveCommand: () async => null).createSession(
          cwd: Directory.current.path,
          model: '',
          mode: AgentMode.normal,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains("ACP provider 'fixture-acp' command is unavailable"),
          ),
        ),
      );
    },
  );
}
