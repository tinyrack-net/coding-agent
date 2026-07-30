import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/generic_acp_agent_client.dart';
import 'package:agent_daemon/src/providers/paseo/acp_rpc_process.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
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

GenericAcpAgentClient client({
  Future<String?> Function()? resolveCommand,
  Map<String, String> environment = const {'ACP_FIXTURE_ENV': 'configured'},
  AcpRpcProcessStarter? processStarter,
}) => GenericAcpAgentClient(
  provider: 'fixture-acp',
  command: 'dart',
  commandArgs: [fixturePath()],
  environment: environment,
  providerParams: const {'supportsMcpServers': false},
  resolveCommand: resolveCommand ?? () async => Platform.resolvedExecutable,
  processStarter: processStarter,
);

Future<T> eventOf<T extends ProviderEvent>(Stream<ProviderEvent> events) =>
    events.firstWhere((event) => event is T).then((event) => event as T);

void main() {
  test('rejects unsupported system prompts before spawning ACP', () async {
    var resolved = false;
    final configured = client(
      resolveCommand: () async {
        resolved = true;
        return Platform.resolvedExecutable;
      },
    );

    await expectLater(
      configured.createSession(
        cwd: Directory.current.path,
        model: 'fixture-model',
        mode: AgentMode.normal,
        systemPrompt: 'Voice instructions',
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('does not advertise system-prompt support'),
        ),
      ),
    );
    expect(resolved, isFalse);
  });

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

  test(
    'forwards one image block while suppressing the ACP user echo',
    () async {
      final session =
          await client(
            environment: const {'ACP_FIXTURE_ECHO_IMAGE_PROMPT': 'true'},
          ).createSession(
            cwd: Directory.current.path,
            model: '',
            mode: AgentMode.normal,
          );
      addTearDown(session.dispose);
      final events = <ProviderEvent>[];
      final completed = Completer<void>();
      final subscription = session.events.listen((event) {
        events.add(event);
        if (event is TurnCompleted && !completed.isCompleted) {
          completed.complete();
        }
      });
      addTearDown(subscription.cancel);

      await (session as ImagePromptAgentSession).promptWithImagesAndAttachments(
        'see this',
        const [AgentPromptImage(data: 'AA==', mimeType: 'image/png')],
        const [],
      );
      await completed.future.timeout(const Duration(seconds: 5));

      expect(
        events.whereType<AssistantTextDelta>().single,
        isA<AssistantTextDelta>()
            .having((event) => event.itemId, 'item id', 'image-reply')
            .having((event) => event.text, 'text', 'image-ok'),
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
    'loads with cwd and MCP context when the agent advertises load',
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

  test('falls back to ACP resume when session/load is absent', () async {
    final session =
        await client(
          environment: const {'ACP_FIXTURE_NO_LOAD': 'true'},
        ).createSession(
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
    expect((session as HistoryRestoringAgentSession).restoredHistory, isNull);
  });

  test(
    'advertises client overrides and projects configured MCP servers',
    () async {
      final configured = client(
        environment: const {
          'ACP_FIXTURE_EXPECT_CLIENT_RUNTIME': 'true',
          'ACP_FIXTURE_REQUIRE_SESSION_ENV': 'true',
        },
      );
      final runtimeClient = GenericAcpAgentClient(
        provider: configured.provider,
        command: configured.command,
        commandArgs: configured.commandArgs,
        environment: configured.environment,
        providerParams: const {
          'supportsMcpServers': true,
          'clientCapabilities': {
            'fs': {'readTextFile': true, 'writeTextFile': true},
            'terminal': true,
          },
        },
        resolveCommand: () async => Platform.resolvedExecutable,
      );
      final session = await runtimeClient.createSessionWithMcpAndEnvironment(
        cwd: Directory.current.path,
        model: '',
        mode: AgentMode.normal,
        mcpServers: const {
          'local': {
            'type': 'stdio',
            'command': 'dart',
            'args': ['run', 'server.dart'],
            'env': {'TOKEN': 'test'},
          },
          'remote': {
            'type': 'http',
            'url': 'http://127.0.0.1/mcp',
            'headers': {'Authorization': 'Bearer test'},
          },
        },
        environment: const {'RUN_TOKEN': 'session-value'},
      );
      addTearDown(session.dispose);
      expect(
        await eventOf<SessionStarted>(session.events),
        isA<SessionStarted>(),
      );
    },
  );

  test(
    'drops configured MCP servers when provider support is disabled',
    () async {
      final session =
          await GenericAcpAgentClient(
            provider: 'fixture-acp',
            command: 'dart',
            commandArgs: [fixturePath()],
            environment: const {'ACP_FIXTURE_EXPECT_NO_MCP': 'true'},
            providerParams: const {'supportsMcpServers': false},
            resolveCommand: () async => Platform.resolvedExecutable,
          ).createSessionWithMcp(
            cwd: Directory.current.path,
            model: '',
            mode: AgentMode.normal,
            mcpServers: const {
              'remote': {'type': 'http', 'url': 'http://127.0.0.1/mcp'},
            },
          );
      addTearDown(session.dispose);
      expect(
        await eventOf<SessionStarted>(session.events),
        isA<SessionStarted>(),
      );
    },
  );

  test(
    'serves ACP filesystem and terminal client requests end to end',
    () async {
      final session =
          await GenericAcpAgentClient(
            provider: 'fixture-acp',
            command: 'dart',
            commandArgs: [fixturePath()],
            environment: const {'ACP_FIXTURE_EXERCISE_CLIENT_RUNTIME': 'true'},
            providerParams: const {
              'clientCapabilities': {
                'fs': {'readTextFile': true, 'writeTextFile': true},
                'terminal': true,
              },
            },
            resolveCommand: () async => Platform.resolvedExecutable,
          ).createSession(
            cwd: Directory.current.path,
            model: '',
            mode: AgentMode.normal,
          );
      addTearDown(session.dispose);

      expect(
        await eventOf<SessionStarted>(session.events),
        isA<SessionStarted>(),
      );
    },
  );

  test('lists paginated ACP sessions with cwd filtering and limit', () async {
    final cwd = Directory.current.path;
    final sessions = await client().listImportableSessions(
      ListImportableSessionsOptions(cwd: cwd),
    );

    expect(sessions, hasLength(2));
    expect(
      sessions.first,
      isA<ImportableProviderSession>()
          .having(
            (session) => session.providerHandleId,
            'provider handle',
            'restored-session',
          )
          .having((session) => session.cwd, 'cwd', cwd)
          .having((session) => session.title, 'title', 'Imported ACP session')
          .having(
            (session) => session.lastActivityAt,
            'last activity',
            DateTime.utc(2026, 6, 13),
          ),
    );
    expect(
      await client().listImportableSessions(
        ListImportableSessionsOptions(cwd: cwd, limit: 1),
      ),
      hasLength(1),
    );
  });

  test('returns no ACP sessions when list capability is absent', () async {
    expect(
      await client(
        environment: const {'ACP_FIXTURE_NO_LIST': 'true'},
      ).listImportableSessions(),
      isEmpty,
    );
  });

  test('rejects a malformed ACP session list response', () async {
    await expectLater(
      client(
        environment: const {'ACP_FIXTURE_MALFORMED_LIST': 'true'},
      ).listImportableSessions(),
      throwsA(isA<FormatException>()),
    );
  });

  test('restores authoritative ACP history from session/load', () async {
    final session = await client().createSession(
      cwd: Directory.current.path,
      model: '',
      mode: AgentMode.normal,
      sessionId: 'restored-session',
    );
    addTearDown(session.dispose);

    final history = (session as HistoryRestoringAgentSession).restoredHistory;
    expect(history, hasLength(5));
    expect(
      history?[0],
      isA<UserMessageItem>().having(
        (item) => item.text,
        'text',
        'Restore [image]',
      ),
    );
    expect(
      history?[1],
      isA<AssistantMessageItem>()
          .having((item) => item.id, 'id', 'assistant-replay-1')
          .having((item) => item.text, 'text', 'Loaded response'),
    );
    expect(
      history?[2],
      isA<ReasoningItem>().having(
        (item) => item.text,
        'text',
        'Recovered thought',
      ),
    );
    expect(
      history?[3],
      isA<ToolCallItem>().having(
        (item) => item.status,
        'status',
        ToolCallStatus.success,
      ),
    );
    expect(history?[4], isA<TodoItem>());
  });

  test('terminates the ACP process when session/new fails', () async {
    Process? spawned;
    final configured = client(
      environment: const {'ACP_FIXTURE_NEW_FAIL': 'true'},
      processStarter: (launch) async {
        spawned = await Process.start(
          launch.command,
          launch.args,
          workingDirectory: launch.cwd,
          environment: launch.environment,
          includeParentEnvironment: launch.includeParentEnvironment,
        );
        return spawned!;
      },
    );

    await expectLater(
      configured.createSession(
        cwd: Directory.current.path,
        model: '',
        mode: AgentMode.normal,
      ),
      throwsA(
        isA<AcpRpcError>().having(
          (error) => error.message,
          'message',
          'session/new failed',
        ),
      ),
    );

    expect(spawned, isNotNull);
    await expectLater(
      spawned!.exitCode.timeout(const Duration(seconds: 2)),
      completes,
    );
  });

  test(
    'terminates the ACP process and surfaces session/load failure',
    () async {
      Process? spawned;
      await expectLater(
        client(
          environment: const {'ACP_FIXTURE_LOAD_FAIL': 'true'},
          processStarter: (launch) async {
            spawned = await Process.start(
              launch.command,
              launch.args,
              workingDirectory: launch.cwd,
              environment: launch.environment,
              includeParentEnvironment: launch.includeParentEnvironment,
            );
            return spawned!;
          },
        ).createSession(
          cwd: Directory.current.path,
          model: '',
          mode: AgentMode.normal,
          sessionId: 'restored-session',
        ),
        throwsA(
          isA<AcpRpcError>().having(
            (error) => error.message,
            'message',
            'session/load failed',
          ),
        ),
      );

      expect(spawned, isNotNull);
      await expectLater(
        spawned!.exitCode.timeout(const Duration(seconds: 2)),
        completes,
      );
    },
  );

  test(
    'probes ACP models, modes and thinking without interactive auth',
    () async {
      final catalog = await client().fetchCatalog(cwd: Directory.current.path);

      expect(catalog.models, [
        isA<ProviderModelDefinition>()
            .having((model) => model.id, 'id', 'fixture-model')
            .having((model) => model.isDefault, 'default', isTrue)
            .having(
              (model) => model.description,
              'probe environment',
              'Probe fixture model',
            ),
        isA<ProviderModelDefinition>().having(
          (model) => model.id,
          'id',
          'fixture-fast',
        ),
      ]);
      expect(catalog.modes.map((mode) => mode.id), ['agent', 'plan']);
      expect(catalog.models.first.defaultThinkingOptionId, 'medium');
      expect(catalog.models.first.thinkingOptions?.map((option) => option.id), [
        'low',
        'medium',
        'high',
      ]);
    },
  );

  test(
    'uses config-option selection when explicit ACP selectors are absent',
    () async {
      final session =
          await client(
            environment: const {'ACP_FIXTURE_CONFIG_ONLY': 'true'},
          ).createSession(
            cwd: Directory.current.path,
            model: 'config-model',
            mode: AgentMode.normal,
            modeId: 'review',
            thinkingOptionId: 'high',
          );
      addTearDown(session.dispose);

      final catalog = (session as GenericAcpAgentSession).catalog;
      expect(catalog.currentModeId, 'review');
      expect(catalog.currentModelId, 'config-model');
      expect(catalog.currentThinkingOptionId, 'high');
      expect(catalog.hasExplicitModes, isFalse);
      expect(catalog.hasExplicitModels, isFalse);
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
