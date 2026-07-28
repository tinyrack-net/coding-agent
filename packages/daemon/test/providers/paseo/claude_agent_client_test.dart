import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/paseo/claude_agent_client.dart';
import 'package:agent_daemon/src/providers/paseo/claude_agent_session.dart';
import 'package:agent_daemon/src/providers/paseo/claude_history.dart';
import 'package:agent_daemon/src/providers/paseo/claude_stream_connection.dart';
import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:agent_daemon/src/providers/paseo/provider_launch_config.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X1r0AAAAASUVORK5CYII=';

void main() {
  test('lists model-scoped draft features without launching Claude', () async {
    final client = ClaudeAgentClient(
      resolveExecutable: () async => throw StateError('must not probe'),
    );

    final features = await client.listFeatures(
      const ListCommandsDraftConfig(
        provider: 'claude',
        cwd: '/repo',
        model: 'claude-opus-4-6',
        featureValues: {'fast_mode': true},
      ),
    );

    expect(features, hasLength(1));
    expect((features.single as AgentFeatureToggle).value, isTrue);
  });

  test('lists recent importable Claude sessions for a cwd', () async {
    final temp = Directory.systemTemp.createTempSync('claude_sessions_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cwd = p.join(temp.path, 'workspace');
    Directory(cwd).createSync();
    final project = Directory(claudeProjectDir(cwd, configDir: temp.path))
      ..createSync(recursive: true);
    final session = File(p.join(project.path, 'session-1.jsonl'));
    session.writeAsStringSync(
      [
        '{corrupt',
        jsonEncode({
          'type': 'user',
          'isSidechain': true,
          'sessionId': 'sidechain',
          'cwd': cwd,
          'message': {'content': 'ignore'},
        }),
        jsonEncode({
          'type': 'user',
          'sessionId': 'session-1',
          'cwd': cwd,
          'message': {'content': '  Fix   the build  '},
        }),
      ].join('\n'),
    );
    final modified = DateTime.utc(2026, 7, 28, 3);
    session.setLastModifiedSync(modified);
    final client = ClaudeAgentClient(
      runtimeSettings: ProviderRuntimeSettings(
        environment: {'CLAUDE_CONFIG_DIR': temp.path},
      ),
    );

    final sessions = await client.listImportableSessions(
      ListImportableSessionsOptions(cwd: cwd, limit: 1),
    );

    expect(sessions, hasLength(1));
    expect(sessions.single.providerHandleId, 'session-1');
    expect(sessions.single.cwd, cwd);
    expect(sessions.single.title, 'Fix   the build');
    expect(sessions.single.firstPromptPreview, 'Fix the build');
    expect(sessions.single.lastActivityAt.toUtc(), modified);
  });

  test('returns no Claude imports when the history root is absent', () async {
    final temp = Directory.systemTemp.createTempSync('claude_missing_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final client = ClaudeAgentClient(
      environment: {'CLAUDE_CONFIG_DIR': temp.path},
    );

    expect(await client.listImportableSessions(), isEmpty);
  });

  test('launches Claude with Paseo stream-json session options', () async {
    final connection = _FakeClaudeConnection();
    JsonlRpcLaunch? launch;
    final client = ClaudeAgentClient(
      resolveExecutable: () async => 'C:/bin/claude.exe',
      environment: const {'CLAUDE_CONFIG_DIR': 'C:/claude'},
      startConnection: (value) async {
        launch = value;
        return connection;
      },
    );

    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'claude-opus-4-1',
      mode: AgentMode.normal,
      modeId: 'acceptEdits',
      thinkingOptionId: 'high',
      featureValues: const {'fast_mode': true},
      systemPrompt: 'Voice instructions',
      sessionId: 'resume-id',
    );
    addTearDown(session.dispose);

    expect(launch?.command, 'C:/bin/claude.exe');
    expect(launch?.cwd, 'C:/workspace');
    expect(
      launch?.args,
      containsAllInOrder([
        '--output-format',
        'stream-json',
        '--verbose',
        '--input-format',
        'stream-json',
        '--permission-prompt-tool',
        'stdio',
        '--permission-mode',
        'acceptEdits',
        '--allow-dangerously-skip-permissions',
        '--include-partial-messages',
        '--setting-sources=user,project,local',
        '--model',
        'claude-opus-4-1',
        '--append-system-prompt',
        'Voice instructions',
        '--effort',
        'high',
        '--resume=resume-id',
        '--settings={"fastMode":true}',
      ]),
    );
    expect(launch?.environment, containsPair('PATH', isNotEmpty));
    expect(
      launch?.environment,
      containsPair('CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING', 'true'),
    );
    expect(launch?.environment, containsPair('MCP_TIMEOUT', '600000'));
    expect(launch?.environment, containsPair('MCP_TOOL_TIMEOUT', '600000'));
    expect(launch?.environment, containsPair('CLAUDE_CONFIG_DIR', 'C:/claude'));
    expect(launch?.environment, isNot(contains('CLAUDE_CODE_ENTRYPOINT')));
    expect(launch?.includeParentEnvironment, isFalse);
    expect(connection.sent.single['type'], 'control_request');
    expect((connection.sent.single['request'] as Map)['subtype'], 'initialize');
  });

  test(
    'lists initialized commands with Paseo classification and rewind',
    () async {
      final connection = _FakeClaudeConnection();
      final session = ClaudeAgentSession(connection);
      addTearDown(session.dispose);
      session.initialize();
      final requestId = connection.sent.single['request_id']! as String;

      connection.emit({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': requestId,
          'response': {
            'commands': [
              {
                'name': 'compact',
                'description': 'Compact context',
                'argumentHint': '',
              },
              {
                'name': 'taste',
                'description': 'Apply taste',
                'argumentHint': '<file>',
              },
              {'name': 'taste', 'description': 'duplicate', 'argumentHint': ''},
            ],
          },
        },
      });

      final commands = await (session as CommandListingAgentSession)
          .listCommands();
      expect(commands.map((command) => command.name), [
        'compact',
        'rewind',
        'taste',
      ]);
      expect(commands.first.kind, AgentSlashCommandKind.command);
      expect(commands.last.kind, AgentSlashCommandKind.skill);
      expect(commands[1].argumentHint, '[user_message_uuid]');

      connection.emit({
        'type': 'system',
        'subtype': 'commands_changed',
        'commands': [
          {'name': 'usage', 'description': 'Show usage', 'argumentHint': ''},
        ],
      });
      final changed = await (session as CommandListingAgentSession)
          .listCommands();
      expect(changed.map((command) => command.name), ['rewind', 'usage']);
      expect(changed.last.kind, AgentSlashCommandKind.command);
    },
  );

  test('applies provider command prefix and runtime environment', () async {
    final connection = _FakeClaudeConnection();
    JsonlRpcLaunch? launch;
    final client = ClaudeAgentClient(
      runtimeSettings: ProviderRuntimeSettings(
        command: ProviderCommand.replace([
          Platform.resolvedExecutable,
          'claude-wrapper',
        ]),
        environment: const {'CLAUDE_RUNTIME': 'configured'},
      ),
      startConnection: (value) async {
        launch = value;
        return connection;
      },
    );

    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'claude-sonnet-4',
      mode: AgentMode.normal,
    );
    addTearDown(session.dispose);

    expect(launch?.command, Platform.resolvedExecutable);
    expect(launch?.args.first, 'claude-wrapper');
    expect(launch?.environment, containsPair('CLAUDE_RUNTIME', 'configured'));
  });

  test(
    'surfaces Claude initialize control errors from command listing',
    () async {
      final connection = _FakeClaudeConnection();
      final session = ClaudeAgentSession(connection);
      addTearDown(session.dispose);
      session.initialize();
      final requestId = connection.sent.single['request_id']! as String;
      connection.emit({
        'type': 'control_response',
        'response': {
          'subtype': 'error',
          'request_id': requestId,
          'error': 'commands unavailable',
        },
      });

      await expectLater(
        (session as CommandListingAgentSession).listCommands(),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('rejects a missing Claude executable', () async {
    final client = ClaudeAgentClient(resolveExecutable: () async => null);
    await expectLater(
      client.createSession(
        cwd: 'C:/workspace',
        model: '',
        mode: AgentMode.normal,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Claude Code CLI is not installed'),
        ),
      ),
    );
  });

  test('restores provider-native history before returning a session', () async {
    final root = Directory.systemTemp.createTempSync('claude_client_history_');
    addTearDown(() => root.deleteSync(recursive: true));
    final cwd = Directory(p.join(root.path, 'workspace'))
      ..createSync(recursive: true);
    final configDir = Directory(p.join(root.path, 'claude'))
      ..createSync(recursive: true);
    final projectDir = Directory(
      claudeProjectDir(cwd.path, configDir: configDir.path),
    )..createSync(recursive: true);
    await File(p.join(projectDir.path, 'resume-id.jsonl')).writeAsString(
      '${jsonEncode({
        'type': 'assistant',
        'uuid': 'restored-reply',
        'message': {'content': 'from disk'},
      })}\n',
    );
    final client = ClaudeAgentClient(
      resolveExecutable: () async => 'claude',
      environment: {'CLAUDE_CONFIG_DIR': configDir.path},
      startConnection: (_) async => _FakeClaudeConnection(),
    );

    final session = await client.createSession(
      cwd: cwd.path,
      model: 'claude-sonnet-4',
      mode: AgentMode.normal,
      sessionId: 'resume-id',
    );
    addTearDown(session.dispose);

    final history = (session as HistoryRestoringAgentSession).restoredHistory;
    expect(history?.whereType<AssistantMessageItem>().single.text, 'from disk');
  });

  test('maps disabled and ultracode thinking to frozen SDK options', () async {
    for (final entry in {
      'off': ['--thinking', 'disabled'],
      'ultracode': ['--thinking', 'adaptive', '--settings={"ultracode":true}'],
    }.entries) {
      JsonlRpcLaunch? launch;
      final connection = _FakeClaudeConnection();
      final client = ClaudeAgentClient(
        resolveExecutable: () async => 'claude',
        startConnection: (value) async {
          launch = value;
          return connection;
        },
      );
      final session = await client.createSession(
        cwd: 'C:/workspace',
        model: 'claude-opus-4-8',
        mode: AgentMode.normal,
        thinkingOptionId: entry.key,
      );
      expect(launch?.args, containsAllInOrder(entry.value));
      expect(launch?.args, isNot(contains('--effort')));
      await session.dispose();
    }
  });

  test('rejects an unknown Claude thinking option before launch', () async {
    var launched = false;
    final client = ClaudeAgentClient(
      resolveExecutable: () async => 'claude',
      startConnection: (_) async {
        launched = true;
        return _FakeClaudeConnection();
      },
    );

    await expectLater(
      client.createSession(
        cwd: 'C:/workspace',
        model: 'claude-sonnet-4',
        mode: AgentMode.normal,
        thinkingOptionId: 'turbo',
      ),
      throwsArgumentError,
    );
    expect(launched, isFalse);
  });

  test(
    'recreates the Claude query with exact live config and resume id',
    () async {
      final launches = <JsonlRpcLaunch>[];
      final connections = <_FakeClaudeConnection>[];
      final client = ClaudeAgentClient(
        resolveExecutable: () async => 'claude',
        startConnection: (launch) async {
          launches.add(launch);
          final connection = _FakeClaudeConnection();
          connections.add(connection);
          return connection;
        },
      );
      final session =
          await client.createSession(
                cwd: 'C:/workspace',
                model: 'claude-sonnet-4',
                mode: AgentMode.normal,
              )
              as ClaudeAgentSession;
      addTearDown(session.dispose);
      connections.single.emit({
        'type': 'system',
        'subtype': 'init',
        'session_id': 'claude-session',
      });

      await session.setMode('plan');
      await session.setModel('claude-opus-4-1');
      await session.setFeature('fast_mode', true);
      expect(await session.setThinkingOption('high'), isNull);
      await session.prompt('after restart');

      expect(connections, hasLength(2));
      expect(connections.first.closed, isTrue);
      expect(
        launches.last.args,
        containsAllInOrder([
          '--permission-mode',
          'plan',
          '--model',
          'claude-opus-4-1',
          '--effort',
          'high',
          '--resume=claude-session',
          '--settings={"fastMode":true}',
        ]),
      );
      expect(
        (connections.last.sent.first['request'] as Map)['subtype'],
        'initialize',
      );
      expect(connections.last.sent.last['type'], 'user');
    },
  );

  test(
    'defers an active-turn thinking restart until the next prompt',
    () async {
      final launches = <JsonlRpcLaunch>[];
      final connections = <_FakeClaudeConnection>[];
      final client = ClaudeAgentClient(
        resolveExecutable: () async => 'claude',
        startConnection: (launch) async {
          launches.add(launch);
          final connection = _FakeClaudeConnection();
          connections.add(connection);
          return connection;
        },
      );
      final session =
          await client.createSession(
                cwd: 'C:/workspace',
                model: 'claude-sonnet-4',
                mode: AgentMode.normal,
              )
              as ClaudeAgentSession;
      addTearDown(session.dispose);
      connections.single.emit({
        'type': 'system',
        'subtype': 'init',
        'session_id': 'active-session',
      });

      await session.prompt('first');
      await expectLater(session.prompt('overlap'), throwsStateError);
      final notice = await session.setThinkingOption('max');
      expect(notice?.message, contains('next Claude turn'));
      expect(launches, hasLength(1));
      connections.single.emit({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
      });
      await session.prompt('second');

      expect(launches, hasLength(2));
      expect(launches.last.args, contains('--effort'));
      expect(launches.last.args, contains('max'));
      expect(launches.last.args, contains('--resume=active-session'));
    },
  );

  test('a failed query recreation exits the provider session', () async {
    var launchCount = 0;
    final firstConnection = _FakeClaudeConnection();
    final client = ClaudeAgentClient(
      resolveExecutable: () async => 'claude',
      startConnection: (_) async {
        launchCount += 1;
        if (launchCount == 1) return firstConnection;
        throw StateError('restart failed');
      },
    );
    final session =
        await client.createSession(
              cwd: 'C:/workspace',
              model: 'claude-sonnet-4',
              mode: AgentMode.normal,
            )
            as ClaudeAgentSession;
    firstConnection.emit({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'failed-session',
    });
    final exited = session.events
        .where((event) => event is SessionExited)
        .cast<SessionExited>()
        .first;

    await session.setThinkingOption('high');
    await expectLater(session.prompt('restart'), throwsStateError);
    expect((await exited).exitCode, isNull);
    expect(firstConnection.closed, isTrue);
    await session.dispose();
  });

  test(
    'Claude JSONL connection carries messages over a real process',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('claude_jsonl_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final script = File('${tempDir.path}${Platform.pathSeparator}echo.dart');
      await script.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void main() {
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stdout.writeln);
}
''');
      final connection = await ClaudeJsonlConnection.start(
        launch: JsonlRpcLaunch(
          command: Platform.resolvedExecutable,
          args: [script.path],
          cwd: tempDir.path,
        ),
      );
      addTearDown(connection.dispose);
      final received = Completer<Map<String, Object?>>();
      final unsubscribe = connection.onMessage(received.complete);
      addTearDown(unsubscribe);

      connection.send({
        'type': 'system',
        'subtype': 'init',
        'session_id': 'echo',
      });

      expect(await received.future, {
        'type': 'system',
        'subtype': 'init',
        'session_id': 'echo',
      });
      expect(connection.isClosed, isFalse);
      await connection.dispose();
      expect(connection.isClosed, isTrue);
    },
  );

  test('normalizes init, partial text, usage, and completion', () async {
    final connection = _FakeClaudeConnection();
    final session = ClaudeAgentSession(connection);
    final events = <ProviderEvent>[];
    final subscription = session.events.listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(session.dispose);

    connection.emit({
      'type': 'system',
      'subtype': 'init',
      'session_id': 'claude-session',
    });
    connection.emit({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text'},
      },
    });
    connection.emit({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'hello'},
      },
    });
    connection.emit({
      'type': 'stream_event',
      'event': {'type': 'content_block_stop', 'index': 0},
    });
    connection.emit({
      'type': 'result',
      'subtype': 'success',
      'is_error': false,
      'usage': {'input_tokens': 10, 'output_tokens': 4},
      'total_cost_usd': 0.25,
    });
    await pumpEventQueue();

    expect(
      events.whereType<SessionStarted>().single.sessionId,
      'claude-session',
    );
    expect(events.whereType<AssistantTextDelta>().single.text, 'hello');
    expect(
      events.whereType<AssistantMessageComplete>().single.fullText,
      'hello',
    );
    expect(events.whereType<UsageUpdated>().single.usage.inputTokens, 10);
    expect(events.whereType<UsageUpdated>().single.usage.outputTokens, 4);
    expect(events.whereType<TurnCompleted>(), hasLength(1));
  });

  test('round-trips Claude can_use_tool decisions', () async {
    final connection = _FakeClaudeConnection();
    final session = ClaudeAgentSession(connection);
    final permission = session.events
        .where((event) => event is PermissionRequested)
        .cast<PermissionRequested>()
        .first;

    connection.emit({
      'type': 'control_request',
      'request_id': 'permission-1',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'Bash',
        'tool_use_id': 'tool-1',
        'input': {'command': 'git status'},
      },
    });
    final request = await permission;
    expect(request.permissionId, 'permission-1');
    expect(request.toolName, 'Bash');
    expect((request.detail as GenericDetail).input, {'command': 'git status'});

    await request.respond(
      PermissionDecision.allow,
      selectedActionId: 'allow_always',
      updatedInput: {'command': 'git diff'},
      updatedPermissions: [
        {'type': 'allow', 'scope': 'workspace'},
      ],
    );
    final response = connection.sent.single;
    expect(response['type'], 'control_response');
    expect((response['response'] as Map)['request_id'], 'permission-1');
    expect(
      ((response['response'] as Map)['response'] as Map)['behavior'],
      'allow',
    );
    expect(
      ((response['response'] as Map)['response'] as Map)['toolUseID'],
      'tool-1',
    );
    expect(((response['response'] as Map)['response'] as Map)['updatedInput'], {
      'command': 'git diff',
    });
    expect(
      ((response['response'] as Map)['response'] as Map)['updatedPermissions'],
      [
        {'type': 'allow', 'scope': 'workspace'},
      ],
    );
    await session.dispose();
  });

  test('sends prompts, interrupts, and live provider configuration', () async {
    final connection = _FakeClaudeConnection();
    final session = ClaudeAgentSession(connection);

    await session.prompt('hello');
    await session.interrupt();
    expect(await session.setMode('plan'), isNull);
    await session.setModel(' claude-sonnet-4 ');
    final notice = await session.setThinkingOption(' high ');
    await session.setFeature('fast_mode', true);

    expect(((connection.sent[0]['message'] as Map)['content'] as List).single, {
      'type': 'text',
      'text': 'hello',
    });
    expect(
      connection.sent
          .skip(1)
          .map((message) => (message['request'] as Map)['subtype']),
      ['interrupt', 'set_permission_mode', 'set_model', 'apply_flag_settings'],
    );
    expect((connection.sent[3]['request'] as Map)['model'], 'claude-sonnet-4');
    expect((connection.sent[4]['request'] as Map)['settings'], {
      'fastMode': true,
    });
    expect(notice?.type, AgentProviderNoticeType.info);
    await expectLater(
      session.setFeature('unknown', true),
      throwsUnsupportedError,
    );

    await session.dispose();
    await session.dispose();
    await expectLater(session.prompt('again'), throwsStateError);
  });

  test(
    'preserves frozen Claude prompt block ordering and native images',
    () async {
      final connection = _FakeClaudeConnection();
      final session = ClaudeAgentSession(connection);
      addTearDown(session.dispose);

      await session.promptWithImagesAndAttachments(
        '  Inspect this image  ',
        const [
          AgentPromptImage(data: _onePixelPng, mimeType: 'image/png'),
          AgentPromptImage(data: 'ignored', mimeType: 'image/svg+xml'),
        ],
        const [
          TextAgentAttachment(
            text: 'Prior conversation',
            contextKind: 'chat_history',
          ),
          TextAgentAttachment(text: 'Additional context'),
        ],
      );

      expect((connection.sent.single['message'] as Map)['content'], [
        {'type': 'text', 'text': 'Prior conversation'},
        {'type': 'text', 'text': 'Inspect this image'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': _onePixelPng,
          },
        },
        {'type': 'text', 'text': 'Additional context'},
      ]);
    },
  );

  test(
    'normalizes thinking, tools, assistant snapshots, and failures',
    () async {
      final connection = _FakeClaudeConnection();
      final session = ClaudeAgentSession(connection);
      final events = <ProviderEvent>[];
      final subscription = session.events.listen(events.add);
      addTearDown(subscription.cancel);
      addTearDown(session.dispose);

      connection.emit({
        'type': 'stream_event',
        'event': {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'thinking', 'id': 'think-1'},
        },
      });
      connection.emit({
        'type': 'stream_event',
        'event': {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'thinking_delta', 'thinking': 'reason'},
        },
      });
      connection.emit({
        'type': 'stream_event',
        'event': {'type': 'content_block_stop', 'index': 1},
      });
      connection.emit({
        'type': 'stream_event',
        'event': {
          'type': 'content_block_start',
          'index': 2,
          'content_block': {
            'type': 'tool_use',
            'id': 'tool-2',
            'name': 'Read',
            'input': {'file_path': 'README.md'},
          },
        },
      });
      connection.emit({
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'id': 'tool-3',
              'name': 'Bash',
              'input': {'command': 'pwd'},
            },
            {'type': 'text', 'text': 'ignored snapshot text'},
          ],
        },
      });
      connection.emit({
        'type': 'result',
        'subtype': 'error_during_execution',
        'is_error': true,
        'errors': ['first', 'second'],
        'usage': {
          'input_tokens': 7,
          'output_tokens': 2,
          'cache_read_input_tokens': 3,
          'cache_creation_input_tokens': 4,
        },
      });
      await pumpEventQueue();

      expect(events.whereType<ReasoningDelta>().single.text, 'reason');
      expect(events.whereType<ReasoningComplete>().single.fullText, 'reason');
      expect(events.whereType<ToolCallStarted>().map((event) => event.itemId), [
        'tool-2',
        'tool-3',
      ]);
      expect(
        events.whereType<UsageUpdated>().single.usage.cachedInputTokens,
        7,
      );
      expect(events.whereType<TurnFailed>().single.error, 'first; second');
    },
  );

  test('completes streamed Claude tools from tool_result messages', () async {
    final connection = _FakeClaudeConnection();
    final session = ClaudeAgentSession(connection);
    final events = <ProviderEvent>[];
    final subscription = session.events.listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(session.dispose);

    connection.emit({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'tool_use',
          'id': 'bash-1',
          'name': 'Bash',
          'input': <String, Object?>{},
        },
      },
    });
    connection.emit({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 1,
        'delta': {
          'type': 'input_json_delta',
          'partial_json': '{"command":"pwd"}',
        },
      },
    });
    connection.emit({
      'type': 'stream_event',
      'event': {'type': 'content_block_stop', 'index': 1},
    });
    connection.emit({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'bash-1',
            'content': [
              {'type': 'text', 'text': 'C:/workspace'},
            ],
          },
        ],
      },
    });
    connection.emit({
      'type': 'assistant',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'write-1',
            'name': 'Write',
            'input': {'file_path': 'x'},
          },
        ],
      },
    });
    connection.emit({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'write-1',
            'content': 'denied',
            'is_error': true,
          },
        ],
      },
    });
    await pumpEventQueue();

    final bash = events
        .whereType<ToolCallUpdated>()
        .where((event) => event.itemId == 'bash-1')
        .toList();
    expect(bash.map((event) => event.status), [
      ToolCallStatus.running,
      ToolCallStatus.success,
    ]);
    expect((bash.first.detail as GenericDetail).input, {'command': 'pwd'});
    expect((bash.last.detail as GenericDetail).output, 'C:/workspace');
    final write = events.whereType<ToolCallUpdated>().singleWhere(
      (event) => event.itemId == 'write-1',
    );
    expect(write.status, ToolCallStatus.error);
    expect((write.detail as GenericDetail).errorMessage, 'denied');
  });

  test(
    'materializes live Claude tool-result images without leaking base64',
    () async {
      final connection = _FakeClaudeConnection();
      final session = ClaudeAgentSession(connection);
      final events = <ProviderEvent>[];
      final subscription = session.events.listen(events.add);
      addTearDown(subscription.cancel);
      addTearDown(session.dispose);

      connection.emit({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'read-image',
              'tool_name': 'Read',
              'content': [
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/png',
                    'data': _onePixelPng,
                  },
                },
              ],
            },
          ],
        },
      });
      await pumpEventQueue();

      final tool = events.whereType<ToolCallUpdated>().single;
      expect((tool.detail as GenericDetail).output, '[image]');
      final markdown = events
          .whereType<AssistantMessageComplete>()
          .single
          .fullText;
      expect(markdown, startsWith('![](file:'));
      expect(
        jsonEncode(events.map((event) => '$event').toList()),
        isNot(contains(_onePixelPng)),
      );
      final source = markdown.substring(4, markdown.length - 1);
      final file = File.fromUri(Uri.parse(source));
      expect(file.existsSync(), isTrue);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
    },
  );

  test('denies permissions and publishes process exit once', () async {
    final connection = _FakeClaudeConnection();
    final session = ClaudeAgentSession(connection);
    final events = <ProviderEvent>[];
    final subscription = session.events.listen(events.add);
    addTearDown(subscription.cancel);

    final permission = session.events
        .where((event) => event is PermissionRequested)
        .cast<PermissionRequested>()
        .first;
    connection.emit({
      'type': 'control_request',
      'request_id': 'permission-deny',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'Write',
        'input': {'file_path': 'x'},
      },
    });
    await (await permission).respond(
      PermissionDecision.deny,
      message: 'not now',
    );
    expect(((connection.sent.single['response'] as Map)['response'] as Map), {
      'behavior': 'deny',
      'message': 'not now',
      'interrupt': false,
    });

    connection.exit(9);
    connection.exit(10);
    await pumpEventQueue();
    expect(events.whereType<SessionExited>().single.exitCode, 9);
    await expectLater(session.interrupt(), throwsStateError);
    await session.dispose();
  });
}

final class _FakeClaudeConnection implements ClaudeStreamConnection {
  final sent = <Map<String, Object?>>[];
  final _messages = <void Function(Map<String, Object?>)>[];
  final _exits = <void Function(JsonlRpcExit)>[];
  var closed = false;

  @override
  bool get isClosed => closed;

  void emit(Map<String, Object?> message) {
    for (final handler in _messages.toList()) {
      handler(message);
    }
  }

  void exit(int code) {
    final exit = JsonlRpcExit(
      code: code,
      error: StateError('Claude exited with $code'),
    );
    for (final handler in _exits.toList()) {
      handler(exit);
    }
  }

  @override
  void send(Map<String, Object?> message) => sent.add(message);

  @override
  void Function() onMessage(
    void Function(Map<String, Object?> message) handler,
  ) {
    _messages.add(handler);
    return () => _messages.remove(handler);
  }

  @override
  void Function() onExit(void Function(JsonlRpcExit exit) handler) {
    _exits.add(handler);
    return () => _exits.remove(handler);
  }

  @override
  Future<void> dispose() async => closed = true;
}
