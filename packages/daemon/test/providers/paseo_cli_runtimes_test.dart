import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/paseo_cli_runtimes.dart';
import 'package:agent_daemon/src/providers/paseo/paseo_omp_runtime.dart'
    show OmpProtocolMode, OmpStartSessionInput, parseOmpToolArgs;
import 'package:agent_daemon/src/providers/paseo/provider_launch_config.dart';
import 'package:agent_daemon/src/providers/provider_event.dart'
    show PermissionDecision;
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fake child process
// ---------------------------------------------------------------------------

/// Feeds an [IOSink] straight back into a callback so the fake child can see
/// every JSONL frame the transport writes.
final class _StdinConsumer implements StreamConsumer<List<int>> {
  _StdinConsumer(this.onChunk);

  final void Function(List<int> chunk) onChunk;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(onChunk);

  @override
  Future<void> close() async {}
}

/// Stands in for a spawned `omp`/`pi` binary.
final class _FakeProcess implements Process {
  final StreamController<List<int>> _stdout =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderr =
      StreamController<List<int>>.broadcast();
  final Completer<int> _exit = Completer<int>();

  /// Signals the transport sent while shutting the process down.
  final List<ProcessSignal> killedSignals = [];

  /// Every command frame the transport wrote, in order.
  final List<Map<String, Object?>> commands = [];

  /// Invoked for each command frame; usually installed by [_replyToCommands].
  void Function(Map<String, Object?> command)? onCommand;

  String _buffer = '';

  @override
  late final IOSink stdin = IOSink(_StdinConsumer(_handleChunk));

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killedSignals.add(signal);
    exit(-1);
    return true;
  }

  void writeFrame(Map<String, Object?> frame) {
    _stdout.add(utf8.encode('${jsonEncode(frame)}\n'));
  }

  void writeRaw(String text) => _stdout.add(utf8.encode(text));

  void writeStderr(String text) => _stderr.add(utf8.encode(text));

  void exit(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
  }

  void _handleChunk(List<int> chunk) {
    _buffer += utf8.decode(chunk);
    while (true) {
      final newline = _buffer.indexOf('\n');
      if (newline == -1) return;
      final line = _buffer.substring(0, newline);
      _buffer = _buffer.substring(newline + 1);
      if (line.trim().isEmpty) continue;
      final command = (jsonDecode(line) as Map).cast<String, Object?>();
      commands.add(command);
      onCommand?.call(command);
    }
  }
}

/// Answers every command with `handler`'s return value, or with a failure
/// response when it throws — the shape `JsonlRpcProcess` turns into a rejection.
void _replyToCommands(
  _FakeProcess child,
  Object? Function(Map<String, Object?> command) handler,
) {
  child.onCommand = (command) {
    try {
      final data = handler(command);
      child.writeFrame({
        'id': command['id'],
        'type': 'response',
        'command': command['type'],
        'success': true,
        'data': data,
      });
    } on Object catch (error) {
      child.writeFrame({
        'id': command['id'],
        'type': 'response',
        'command': command['type'],
        'success': false,
        'error': '$error',
      });
    }
  };
}

/// Strips the transport-minted request id so a command frame can be compared
/// literally. Only `req_*` ids are removed: a fire-and-forget frame such as
/// `extension_ui_response` carries an `id` of its own that is part of the
/// assertion.
Map<String, Object?> _withoutRequestId(Map<String, Object?> command) => {
  for (final entry in command.entries)
    if (!(entry.key == 'id' &&
        entry.value is String &&
        (entry.value! as String).startsWith('req_')))
      entry.key: entry.value,
};

OmpCliRuntime _ompRuntime(
  _FakeProcess child, {
  List<OmpRuntimeLaunchRecord>? launches,
  ProviderRuntimeSettings? runtimeSettings,
}) => OmpCliRuntime(
  OmpCliRuntimeOptions(
    command: const ['omp'],
    runtimeSettings: runtimeSettings,
    spawnProcess: (launch) async {
      launches?.add(OmpRuntimeLaunchRecord(cwd: launch.cwd, argv: launch.argv));
      return child;
    },
  ),
);

PiCliRuntime _piRuntime(
  _FakeProcess child, {
  List<PiRuntimeLaunch>? launches,
  ProviderRuntimeSettings? runtimeSettings,
  String commandsRpcName = piCommandsRpcName,
}) => PiCliRuntime(
  PiCliRuntimeOptions(
    command: const ['pi'],
    commandsRpcName: commandsRpcName,
    runtimeSettings: runtimeSettings,
    spawnProcess: (launch) async {
      launches?.add(launch);
      return child;
    },
  ),
);

/// Minimal record of an OMP launch, since [OmpRuntimeLaunch] is opaque here.
final class OmpRuntimeLaunchRecord {
  const OmpRuntimeLaunchRecord({required this.cwd, required this.argv});

  final String cwd;
  final List<String> argv;
}

// ---------------------------------------------------------------------------
// Host tool harness
// ---------------------------------------------------------------------------

final class _RecordingHostToolSink implements OmpHostToolSink {
  final List<Map<String, Object?>> results = [];
  final List<Map<String, Object?>> updates = [];
  final List<Completer<Map<String, Object?>>> _resultWaiters = [];

  @override
  void sendHostToolResult(OmpHostToolResultFrame result) {
    final json = result.toJson();
    results.add(json);
    for (final waiter in _resultWaiters) {
      if (!waiter.isCompleted) waiter.complete(json);
    }
    _resultWaiters.clear();
  }

  @override
  void sendHostToolUpdate(OmpHostToolUpdateFrame update) {
    updates.add(update.toJson());
  }

  Future<Map<String, Object?>> nextResult() {
    final completer = Completer<Map<String, Object?>>();
    _resultWaiters.add(completer);
    return completer.future;
  }
}

void main() {
  // =========================================================================
  group('OMP rpc-ui permission mapper', () {
    Map<String, Object?> uiRequest(String id, Map<String, Object?> rest) => {
      'type': 'extension_ui_request',
      'id': id,
      ...rest,
    };

    final cases = <String, Map<String, Object?>>{
      'widget': uiRequest('widget', {
        'method': 'setWidget',
        'widgetKey': 'status',
      }),
      'notify': uiRequest('notify', {'method': 'notify', 'message': 'done'}),
      'bash': uiRequest('bash', {
        'method': 'select',
        'title': 'Allow tool: bash\nCommand: echo rpc-ui-hi',
        'options': ['Approve', 'Deny'],
      }),
      'edit': uiRequest('edit', {
        'method': 'select',
        'title': 'Allow tool: edit\nFile: fixture.txt',
        'options': ['Approve', 'Deny'],
      }),
      'write': uiRequest('write', {
        'method': 'select',
        'title': 'Allow tool: write\nPath: created.txt\nContent:\nhello write',
        'options': ['Approve', 'Deny'],
      }),
    };

    OmpRpcUiPermissionRequest toolApproval(String id) {
      final classification = classifyOmpRpcUiPermissionRequest(cases[id]!);
      expect(classification, isA<OmpRpcUiToolPermission>());
      return (classification as OmpRpcUiToolPermission).request;
    }

    test(
      'classifies tool approvals and passes through unrelated UI requests',
      () {
        expect(
          [
            for (final entry in cases.entries)
              [
                entry.key,
                classifyOmpRpcUiPermissionRequest(entry.value)
                        is OmpRpcUiToolPermission
                    ? 'tool'
                    : 'passthrough',
              ],
          ],
          [
            ['widget', 'passthrough'],
            ['notify', 'passthrough'],
            ['bash', 'tool'],
            ['edit', 'tool'],
            ['write', 'tool'],
          ],
        );
      },
    );

    test('maps bash approvals to a shell detail card', () {
      final request = toolApproval('bash');

      expect(request.id, 'bash');
      expect(request.provider, 'omp');
      expect(request.name, 'bash');
      expect(request.kind, 'tool');
      expect(request.title, 'Allow tool: bash');
      expect(request.description, 'Command: echo rpc-ui-hi');
      expect(request.detail.toJson(), {
        'kind': 'shell',
        'command': 'echo rpc-ui-hi',
      });
      expect(request.metadata['toolName'], 'bash');
      expect(request.metadata['toolArgs'], {'command': 'echo rpc-ui-hi'});
      expect(request.metadata['approveValue'], 'Approve');
      expect(request.metadata['denyValue'], 'Deny');
      expect(request.metadata['extensionUiMethod'], 'select');
      expect(request.metadata['toolApproval'], ompRpcUiToolApprovalMetadata);
    });

    test('maps edit and write approvals to file detail cards', () {
      final edit = toolApproval('edit');
      final write = toolApproval('write');

      expect(edit.detail.toJson(), {'kind': 'edit', 'path': 'fixture.txt'});
      expect(edit.metadata['toolArgs'], {'path': 'fixture.txt'});
      expect(write.detail.toJson(), {
        'kind': 'write',
        'path': 'created.txt',
        'contentPreview': 'hello write',
      });
      expect(write.metadata['toolArgs'], {
        'path': 'created.txt',
        'content': 'hello write',
      });
      expect(write.description, 'Path: created.txt');
    });

    test('orders deny before approve so the safe choice comes first', () {
      final actions = toolApproval('bash').actions;

      expect(actions.map((action) => action.id), ['deny', 'approve']);
      expect(actions.first.behavior, PermissionDecision.deny);
      expect(actions.first.label, 'Deny');
      expect(actions.first.variant, 'danger');
      expect(actions.first.intent, 'dismiss');
      expect(actions.last.behavior, PermissionDecision.allow);
      expect(actions.last.label, 'Approve');
      expect(actions.last.variant, 'primary');
      expect(actions.last.intent, isNull);
    });

    test('preserves destructive multiline CRLF bash commands exactly', () {
      final classification = classifyOmpRpcUiPermissionRequest({
        'type': 'extension_ui_request',
        'id': 'multiline-bash',
        'method': 'select',
        'title':
            'Allow tool: bash\r\nCommand: printf first\r\n\r\n'
            '  rm -rf /tmp/example\r\n',
        'options': ['Approve', 'Deny'],
      });

      expect(classification, isA<OmpRpcUiToolPermission>());
      final request = (classification as OmpRpcUiToolPermission).request;
      expect(request.detail.toJson(), {
        'kind': 'shell',
        'command': 'printf first\r\n\r\n  rm -rf /tmp/example\r\n',
      });
      expect(request.metadata['toolArgs'], {
        'command': 'printf first\r\n\r\n  rm -rf /tmp/example\r\n',
      });
    });

    test('rejects approval lookalikes and unknown tools', () {
      expect(
        classifyOmpRpcUiPermissionRequest({
          'type': 'extension_ui_request',
          'id': 'not-tool',
          'method': 'select',
          'title': 'Allow tool: bash\nCommand: echo hi',
          'options': ['Yes', 'No'],
        }),
        isA<OmpRpcUiPassthrough>(),
      );
      expect(
        classifyOmpRpcUiPermissionRequest({
          'type': 'extension_ui_request',
          'id': 'unknown-tool',
          'method': 'select',
          'title': 'Allow tool: custom_tool\nReason: needs approval',
          'options': ['Approve', 'Deny'],
        }),
        isA<OmpRpcUiPassthrough>(),
      );
      expect(
        classifyOmpRpcUiPermissionRequest({
          'type': 'extension_ui_request',
          'id': 'reordered',
          'method': 'select',
          'title': 'Allow tool: bash\nCommand: echo hi',
          'options': ['Deny', 'Approve'],
        }),
        isA<OmpRpcUiPassthrough>(),
      );
    });

    test('rejects tool approvals whose body does not parse', () {
      for (final title in const [
        'Allow tool: bash\nCommand:',
        'Allow tool: edit\nReason: nope',
        'Allow tool: write\nPath: a.txt',
        'Allow tool: write\nContent:\nbody',
        'Allow tool: bash',
      ]) {
        expect(
          classifyOmpRpcUiPermissionRequest({
            'type': 'extension_ui_request',
            'id': 'body',
            'method': 'select',
            'title': title,
            'options': ['Approve', 'Deny'],
          }),
          isA<OmpRpcUiPassthrough>(),
          reason: title,
        );
      }
    });

    test('mapOmpRpcUiPermissionRequest returns null for passthroughs', () {
      expect(mapOmpRpcUiPermissionRequest(cases['notify']!), isNull);
      expect(mapOmpRpcUiPermissionRequest(cases['bash']!)?.name, 'bash');
      expect(
        mapOmpRpcUiPermissionRequest(
          cases['bash']!,
          provider: 'omp-fork',
        )?.provider,
        'omp-fork',
      );
    });

    test('responds to tool approvals with exact select values', () {
      final request = toolApproval('bash');

      expect(
        buildOmpRpcUiPermissionResponse(request, PermissionDecision.allow),
        {'value': 'Approve'},
      );
      expect(
        buildOmpRpcUiPermissionResponse(request, PermissionDecision.deny),
        {'value': 'Deny'},
      );
    });

    test('echoes the prompt-supplied select literals back verbatim', () {
      final localized = OmpRpcUiPermissionRequest(
        id: 'localized',
        provider: 'omp',
        name: 'bash',
        kind: 'tool',
        title: 'Allow tool: bash',
        detail: const ShellDetail(command: 'ls'),
        actions: const [],
        metadata: const {
          'toolApproval': ompRpcUiToolApprovalMetadata,
          'approveValue': 'Zulassen',
          'denyValue': 'Ablehnen',
        },
      );

      expect(
        buildOmpRpcUiPermissionResponse(localized, PermissionDecision.allow),
        {'value': 'Zulassen'},
      );
      expect(
        buildOmpRpcUiPermissionResponse(localized, PermissionDecision.deny),
        {'value': 'Ablehnen'},
      );
    });

    test('declines to answer permissions it did not create', () {
      final foreign = OmpRpcUiPermissionRequest(
        id: 'foreign',
        provider: 'claude',
        name: 'bash',
        kind: 'tool',
        title: 'Allow tool: bash',
        detail: const ShellDetail(command: 'ls'),
        actions: const [],
        metadata: const {},
      );

      expect(
        buildOmpRpcUiPermissionResponse(foreign, PermissionDecision.allow),
        isNull,
      );
    });
  });

  // =========================================================================
  group('OMP host tools', () {
    test('serializes the caller-scoped Paseo catalog for set_host_tools', () {
      final catalog = PaseoToolMapCatalog([
        PaseoToolDefinition(
          name: 'create_agent',
          title: 'Create agent',
          description: 'Create a Paseo agent.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'initialPrompt': {'type': 'string'},
            },
            'required': ['initialPrompt'],
          },
          handler: (_, _) async => const PaseoToolResult(content: []),
        ),
        PaseoToolDefinition(
          name: 'schemaless',
          description: 'No declared arguments.',
          handler: (_, _) async => const PaseoToolResult(content: []),
        ),
      ]);

      expect(
        serializeOmpHostTools(catalog).map((tool) => tool.toJson()).toList(),
        [
          {
            'name': 'create_agent',
            'label': 'Create agent',
            'description': 'Create a Paseo agent.',
            'parameters': {
              'type': 'object',
              'properties': {
                'initialPrompt': {'type': 'string'},
              },
              'required': ['initialPrompt'],
            },
          },
          {
            'name': 'schemaless',
            'description': 'No declared arguments.',
            'parameters': {'type': 'object', 'properties': <String, Object?>{}},
          },
        ],
      );
    });

    test('routes calls and progress through the typed OMP runtime', () async {
      final sink = _RecordingHostToolSink();
      final catalog = PaseoToolMapCatalog([
        PaseoToolDefinition(
          name: 'create_agent',
          description: 'Create a Paseo agent.',
          handler: (input, context) async {
            context.sendUpdate?.call(
              const PaseoToolResult(
                content: [
                  {'type': 'text', 'text': 'creating'},
                ],
              ),
            );
            return PaseoToolResult(
              content: const [],
              structuredContent: {'input': input, 'agentId': 'child-1'},
            );
          },
        ),
      ]);

      final pending = sink.nextResult();
      expect(
        handleOmpHostToolRuntimeEvent(
          {
            'type': 'host_tool_call',
            'id': 'host-1',
            'toolCallId': 'tool-1',
            'toolName': 'create_agent',
            'arguments': {'initialPrompt': 'Inspect the bug'},
          },
          runtimeSession: sink,
          paseoTools: catalog,
        ),
        isTrue,
      );

      final result = await pending;
      expect(result['type'], 'host_tool_result');
      expect(result['id'], 'host-1');
      final payload = result['result']! as Map<String, Object?>;
      expect(payload['details'], {
        'input': {'initialPrompt': 'Inspect the bug'},
        'agentId': 'child-1',
      });
      final content = payload['content']! as List;
      expect(content, hasLength(1));
      expect((content.single as Map)['text'], contains('"agentId": "child-1"'));
      // The tool never said whether it failed, so no isError key is emitted.
      expect(result.containsKey('isError'), isFalse);
      expect(sink.updates, [
        {
          'type': 'host_tool_update',
          'id': 'host-1',
          'partialResult': {
            'content': [
              {'type': 'text', 'text': 'creating'},
            ],
          },
        },
      ]);

      clearOmpHostToolState(sink);
    });

    test('summarizes array-valued structured content for the model', () {
      final text = formatPaseoStructuredContentForModel({
        'agents': [
          {'id': 'a1'},
          {'id': 'a2'},
        ],
        'note': 'ignored',
      });

      expect(text, startsWith('agents_count=2\nagents_ids=a1,a2\n\n'));
      expect(text, contains('"note": "ignored"'));
    });

    test('leaves a result that already has content alone', () {
      const result = PaseoToolResult(
        content: [
          {'type': 'text', 'text': 'prose'},
        ],
        structuredContent: {'ignored': true},
      );

      expect(addModelVisibleStructuredContent(result).content, result.content);
    });

    test('cancels an in-flight host tool and drops its late result', () async {
      final sink = _RecordingHostToolSink();
      final started = Completer<void>();
      final release = Completer<PaseoToolResult>();
      PaseoToolCancellation? observed;
      final catalog = PaseoToolMapCatalog([
        PaseoToolDefinition(
          name: 'wait_for_agent',
          description: 'Wait for a Paseo agent.',
          handler: (_, context) async {
            observed = context.cancellation;
            if (!started.isCompleted) started.complete();
            return await release.future;
          },
        ),
      ]);

      handleOmpHostToolRuntimeEvent(
        {
          'type': 'host_tool_call',
          'id': 'host-cancel',
          'toolCallId': 'tool-cancel',
          'toolName': 'wait_for_agent',
          'arguments': {'agentId': 'child-1'},
        },
        runtimeSession: sink,
        paseoTools: catalog,
      );
      await started.future;

      handleOmpHostToolRuntimeEvent(
        {
          'type': 'host_tool_cancel',
          'id': 'cancel-1',
          'targetId': 'host-cancel',
        },
        runtimeSession: sink,
        paseoTools: catalog,
      );
      release.complete(
        const PaseoToolResult(
          content: [
            {'type': 'text', 'text': 'late'},
          ],
        ),
      );
      await waitForOmpHostToolsIdle(sink);

      expect(observed?.isAborted, isTrue);
      expect(sink.results, isEmpty);
      expect(sink.updates, isEmpty);
      clearOmpHostToolState(sink);
    });

    test('reports a tool failure as an error result on both levels', () async {
      final sink = _RecordingHostToolSink();
      final catalog = PaseoToolMapCatalog([
        PaseoToolDefinition(
          name: 'explode',
          description: 'Always throws.',
          handler: (_, _) async => throw StateError('boom'),
        ),
      ]);

      final pending = sink.nextResult();
      handleOmpHostToolRuntimeEvent(
        {
          'type': 'host_tool_call',
          'id': 'host-err',
          'toolCallId': 'tool-err',
          'toolName': 'explode',
          'arguments': <String, Object?>{},
        },
        runtimeSession: sink,
        paseoTools: catalog,
      );

      expect(await pending, {
        'type': 'host_tool_result',
        'id': 'host-err',
        'result': {
          'content': [
            {'type': 'text', 'text': 'boom'},
          ],
          'details': <String, Object?>{},
          'isError': true,
        },
        'isError': true,
      });
      clearOmpHostToolState(sink);
    });

    test('answers a call that arrives before the catalog is registered', () {
      final sink = _RecordingHostToolSink();

      expect(
        handleOmpHostToolRuntimeEvent({
          'type': 'host_tool_call',
          'id': 'host-early',
          'toolCallId': 'tool-early',
          'toolName': 'create_agent',
          'arguments': <String, Object?>{},
        }, runtimeSession: sink),
        isTrue,
      );

      expect(sink.results.single['id'], 'host-early');
      expect(
        ((sink.results.single['result']! as Map)['content']! as List).single,
        {
          'type': 'text',
          'text':
              'Host tool "create_agent" was called before Paseo tools were '
              'registered',
        },
      );
    });

    test('claims malformed host-tool frames and ignores everything else', () {
      final sink = _RecordingHostToolSink();
      final dropped = <String>[];

      expect(
        handleOmpHostToolRuntimeEvent(
          {'type': 'host_tool_call', 'id': 'no-tool-name'},
          runtimeSession: sink,
          logger: (message, _) => dropped.add(message),
        ),
        isTrue,
      );
      expect(dropped, ['Dropped malformed OMP host tool frame']);
      expect(sink.results, isEmpty);

      expect(
        handleOmpHostToolRuntimeEvent({
          'type': 'notice',
          'level': 'info',
          'message': 'ready',
        }, runtimeSession: sink),
        isFalse,
      );
      expect(
        handleOmpHostToolRuntimeEvent('not a frame', runtimeSession: sink),
        isFalse,
      );
    });

    test('ignores an inbound host_tool_update instead of dropping it', () {
      final sink = _RecordingHostToolSink();
      final logged = <String>[];

      expect(
        handleOmpHostToolRuntimeEvent(
          {
            'type': 'host_tool_update',
            'id': 'host-1',
            'partialResult': {
              'content': [
                {'type': 'text', 'text': 'echo'},
              ],
            },
          },
          runtimeSession: sink,
          logger: (message, _) => logged.add(message),
        ),
        isTrue,
      );

      expect(logged, ['Ignoring unexpected inbound OMP host tool update']);
    });

    test(
      'waitForOmpHostToolsIdle resolves immediately with no router',
      () async {
        await waitForOmpHostToolsIdle(_RecordingHostToolSink());
      },
    );
  });

  // =========================================================================
  group('OMP CLI runtime', () {
    test('assembles the argv and honours OMP_COMMAND', () async {
      final child = _FakeProcess();
      final launches = <OmpRuntimeLaunchRecord>[];
      _replyToCommands(child, (_) => null);
      final session = await _ompRuntime(child, launches: launches).startSession(
        const OmpStartSessionInput(
          cwd: '/workspace/project',
          model: 'gpt-5.6',
          protocolMode: OmpProtocolMode.rpcUi,
        ),
      );
      addTearDown(session.close);

      expect(launches.single.cwd, '/workspace/project');
      expect(launches.single.argv, [
        'omp',
        '--mode',
        'rpc-ui',
        '--model',
        'gpt-5.6',
      ]);
      expect(defaultOmpCommand(), ['omp']);
      expect(defaultOmpCommand({'OMP_COMMAND': '/opt/omp'}), ['/opt/omp']);
      expect(defaultOmpCommand({'OMP_COMMAND': ''}), ['omp']);
    });

    test(
      'validates session state with the documented queued message count',
      () async {
        final child = _FakeProcess();
        _replyToCommands(
          child,
          (_) => {
            'model': null,
            'thinkingLevel': 'medium',
            'isStreaming': false,
            'isCompacting': false,
            'sessionId': 'session-1',
            'messageCount': 3,
            'queuedMessageCount': 1,
          },
        );
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final state = await session.getState();
        expect(state.sessionId, 'session-1');
        expect(state.messageCount, 3);
        expect(state.queuedMessageCount, 1);
        expect(state.thinkingLevel, 'medium');
        expect(state.raw['model'], isNull);
      },
    );

    test(
      'accepts session state without thinkingLevel for non-reasoning models',
      () async {
        // Models like cursor-grok-4.5-high-fast encode effort in the model id,
        // so OMP marks them reasoning: false and omits thinkingLevel.
        final child = _FakeProcess();
        _replyToCommands(
          child,
          (_) => {
            'model': null,
            'isStreaming': false,
            'isCompacting': false,
            'sessionId': 'session-1',
            'messageCount': 0,
            'queuedMessageCount': 0,
            'contextUsage': {'tokens': 12, 'contextWindow': 200000},
          },
        );
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final state = await session.getState();
        expect(state.sessionId, 'session-1');
        expect(state.thinkingLevel, isNull);
        expect(state.contextUsage?.tokens, 12);
        expect(state.toSessionState().contextUsage?.contextWindow, 200000);
      },
    );

    test(
      'rejects malformed RPC results instead of trusting transport data',
      () async {
        final child = _FakeProcess();
        _replyToCommands(
          child,
          (_) => {
            'thinkingLevel': 'medium',
            'isStreaming': 'no',
            'isCompacting': false,
            'sessionId': 'session-1',
            'messageCount': 0,
            'queuedMessageCount': 0,
          },
        );
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        await expectLater(session.getState(), throwsFormatException);
      },
    );

    test('emits validated known events and drops unknown frames', () async {
      final child = _FakeProcess();
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);
      final types = <String>[];
      final unsubscribe = session.onEvent(
        (event) => types.add(event['type']! as String),
      );

      child.writeFrame({'type': 'future_control', 'enabled': true});
      // Known type, but `level` is outside the enum — dropped as well.
      child.writeFrame({'type': 'notice', 'level': 'shout', 'message': 'hi'});
      child.writeFrame({'type': 'notice', 'level': 'info', 'message': 'ready'});
      child.writeFrame({
        'type': 'tool_execution_start',
        'toolCallId': 'call-1',
        'toolName': 'bash',
        'args': {'command': 'ls'},
      });
      await pumpEventQueue();

      expect(types, ['notice', 'tool_execution_start']);
      unsubscribe();
      child.writeFrame({'type': 'turn_start'});
      await pumpEventQueue();
      expect(types, ['notice', 'tool_execution_start']);
    });

    test('turns the process exit into a synthetic event', () async {
      final child = _FakeProcess();
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      final events = <Map<String, Object?>>[];
      session.onEvent(events.add);

      child.writeStderr('boom');
      await pumpEventQueue();
      child.exit(1);
      await pumpEventQueue();

      expect(events.single['type'], 'process_exit');
      expect(events.single['error'], contains('boom'));
    });

    test('lists commands through get_available_commands', () async {
      final child = _FakeProcess();
      final commandTypes = <String>[];
      _replyToCommands(child, (command) {
        commandTypes.add('${command['type']}');
        return {
          'commands': [
            {
              'name': 'prewalk',
              'description': 'Prewalk at the next action',
              'source': 'builtin',
            },
          ],
        };
      });
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final commands = await session.getCommands();
      expect(commands.single.name, 'prewalk');
      expect(commands.single.description, 'Prewalk at the next action');
      expect(commands.single.source, 'builtin');
      expect(commandTypes, ['get_available_commands']);
    });

    test(
      'accepts model catalogs with null maxTokens from newer OMP binaries',
      () async {
        final child = _FakeProcess();
        _replyToCommands(
          child,
          (_) => {
            'models': [
              {
                'provider': 'openai-codex',
                'id': 'gpt-5.6-sol',
                'name': 'gpt-5.6-sol',
                'maxTokens': null,
              },
            ],
          },
        );
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        expect(await session.getAvailableModels(), [
          {
            'provider': 'openai-codex',
            'id': 'gpt-5.6-sol',
            'name': 'gpt-5.6-sol',
            'maxTokens': null,
          },
        ]);
      },
    );

    test('rejects a model catalog entry with the wrong types', () async {
      final child = _FakeProcess();
      _replyToCommands(
        child,
        (_) => {
          'models': [
            {'provider': 'openai-codex', 'id': 7},
          ],
        },
      );
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await expectLater(session.getAvailableModels(), throwsFormatException);
    });

    test('wraps OMP subagent and host-tool RPC commands', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => null);
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await session.setSubagentSubscription('events');
      session.steer('stop that');
      session.followUp('then do this', images: const []);
      session.cancelExtensionUiRequest('ui-1');
      await pumpEventQueue();

      expect(child.commands.map(_withoutRequestId), [
        {'type': 'set_subagent_subscription', 'level': 'events'},
        {'type': 'steer', 'message': 'stop that'},
        {'type': 'follow_up', 'message': 'then do this'},
        {'type': 'extension_ui_response', 'id': 'ui-1', 'cancelled': true},
      ]);
    });

    test(
      'accepts the empty prompt acknowledgement emitted by OMP 17',
      () async {
        final child = _FakeProcess();
        _replyToCommands(child, (_) => null);
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final ack = await session.prompt('hello');
        expect(ack.requestId, 'req_1');
        expect(ack.agentInvoked, isNull);
      },
    );

    test('rejects a prompt acknowledgement that is not an object', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => 'sure');
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await expectLater(session.prompt('hello'), throwsFormatException);
    });

    test('branch rejects a cancelled or textless response', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => {'cancelled': true});
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await expectLater(session.branch('entry-1'), throwsStateError);
      expect(session.activeBranchEntryId, isNull);

      _replyToCommands(child, (_) => {'text': 'restored prompt'});
      expect(await session.branch('entry-2'), 'restored prompt');
      expect(session.activeBranchEntryId, 'entry-2');
    });

    test('advertises host tools and reports the accepted names', () async {
      final child = _FakeProcess();
      _replyToCommands(
        child,
        (_) => {
          'toolNames': ['create_agent'],
        },
      );
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final catalog = PaseoToolMapCatalog([
        PaseoToolDefinition(
          name: 'create_agent',
          description: 'Create a Paseo agent.',
          handler: (_, _) async => const PaseoToolResult(content: []),
        ),
      ]);

      expect(await setOmpHostTools(session, catalog), ['create_agent']);
      expect(_withoutRequestId(child.commands.single), {
        'type': 'set_host_tools',
        'tools': [
          {
            'name': 'create_agent',
            'description': 'Create a Paseo agent.',
            'parameters': {'type': 'object', 'properties': <String, Object?>{}},
          },
        ],
      });
    });

    test('rejects an unknown thinking level before it reaches OMP', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => null);
      final session = await _ompRuntime(
        child,
      ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await expectLater(
        session.setThinkingLevel('ludicrous'),
        throwsFormatException,
      );
      await session.setThinkingLevel('xhigh');
      expect(child.commands, hasLength(1));
    });

    test(
      'falls back to get_state when get_session_stats is unsupported',
      () async {
        final child = _FakeProcess();
        final sequence = <String>[];
        _replyToCommands(child, (command) {
          sequence.add('${command['type']}');
          if (command['type'] == 'get_session_stats') {
            throw StateError('Unknown command: ${command['type']}');
          }
          return {
            'sessionId': 'session-1',
            'thinkingLevel': 'medium',
            'isStreaming': false,
            'isCompacting': false,
            'messageCount': 0,
            'queuedMessageCount': 0,
            'contextUsage': {'tokens': 1100, 'contextWindow': 200000},
          };
        });
        final session = await _ompRuntime(
          child,
        ).startSession(const OmpStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final stats = await session.getSessionStats();
        expect(stats.contextUsage?.tokens, 1100);
        expect(stats.contextUsage?.contextWindow, 200000);
        expect(sequence, ['get_session_stats', 'get_state']);
      },
    );

    test('drops a subagent frame whose payload is malformed', () {
      expect(
        parseOmpRuntimeEvent({
          'type': 'subagent_lifecycle',
          'payload': {
            'id': 'sub-1',
            'agent': 'reviewer',
            'status': 'started',
            'index': -1,
          },
        }),
        isNull,
      );
      expect(
        parseOmpRuntimeEvent({
          'type': 'subagent_lifecycle',
          'payload': {
            'id': 'sub-1',
            'agent': 'reviewer',
            'status': 'started',
            'index': 0,
          },
        }),
        isNotNull,
      );
      expect(
        parseOmpRuntimeEvent({
          'type': 'subagent_event',
          'payload': {
            'id': 'sub-1',
            'event': {'type': 'turn_start'},
          },
        }),
        isNotNull,
      );
      expect(
        parseOmpRuntimeEvent({
          'type': 'subagent_event',
          'payload': {
            'id': 'sub-1',
            'event': {'type': 'extension_ui_request', 'id': 'x', 'method': 'y'},
          },
        }),
        isNull,
      );
    });

    test('accepts every documented runtime event type', () {
      expect(
        ompKnownRuntimeEventTypes,
        containsAll(const [
          'agent_start',
          'turn_start',
          'message_start',
          'message_end',
          'message_update',
          'tool_execution_start',
          'tool_execution_update',
          'tool_execution_end',
          'compaction_start',
          'compaction_end',
          'agent_end',
          'extension_ui_request',
          'command_output',
          'prompt_result',
          'process_exit',
          'subagent_lifecycle',
          'subagent_progress',
          'subagent_event',
          'todo_reminder',
          'notice',
          'goal_updated',
          'auto_retry_start',
          'auto_retry_end',
          'retry_fallback_applied',
          'retry_fallback_succeeded',
          'auto_compaction_start',
          'auto_compaction_end',
          'available_commands_update',
          'host_tool_call',
          'host_tool_cancel',
          'host_tool_update',
        ]),
      );
      expect(
        parseOmpRuntimeEvent({
          'type': 'message_start',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        }),
        isNotNull,
      );
      expect(
        parseOmpRuntimeEvent({
          'type': 'message_start',
          'message': {'role': 'assistant', 'content': 'hi'},
        }),
        isNull,
      );
    });
  });

  // =========================================================================
  group('Pi CLI runtime', () {
    test('starts pi in rpc mode and resolves command responses', () async {
      final child = _FakeProcess();
      final launches = <PiRuntimeLaunch>[];
      _replyToCommands(
        child,
        (command) => command['type'] == 'get_state'
            ? {
                'sessionId': 'pi-session-1',
                'thinkingLevel': 'medium',
                'isStreaming': false,
                'isCompacting': false,
                'messageCount': 0,
                'pendingMessageCount': 0,
              }
            : <String, Object?>{},
      );
      final session = await _piRuntime(
        child,
        launches: launches,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final state = await session.getState();
      expect(state['sessionId'], 'pi-session-1');
      expect(state['thinkingLevel'], 'medium');
      expect(launches.single.cwd, '/workspace/project');
      expect(launches.single.argv, ['pi', '--mode', 'rpc']);
      expect(launches.single.env, isNull);
    });

    test('passes an MCP config path and extension bundles to Pi', () async {
      final child = _FakeProcess();
      final launches = <PiRuntimeLaunch>[];
      _replyToCommands(child, (_) => <String, Object?>{});
      final session = await _piRuntime(child, launches: launches).startSession(
        const PiStartSessionInput(
          cwd: '/workspace/project',
          mcpConfigPath: '/tmp/paseo-pi-mcp/mcp.json',
          extensionPaths: ['/ext/a', '/ext/b'],
        ),
      );
      addTearDown(session.close);

      expect(launches.single.mcpConfigPath, '/tmp/paseo-pi-mcp/mcp.json');
      expect(launches.single.argv, [
        'pi',
        '--mode',
        'rpc',
        '--mcp-config',
        '/tmp/paseo-pi-mcp/mcp.json',
        '--extension',
        '/ext/a',
        '--extension',
        '/ext/b',
      ]);
    });

    test('uses the configured command when resuming a session', () async {
      final child = _FakeProcess();
      final launches = <PiRuntimeLaunch>[];
      _replyToCommands(child, (_) => <String, Object?>{});
      final session =
          await _piRuntime(
            child,
            launches: launches,
            runtimeSettings: const ProviderRuntimeSettings(
              command: ProviderCommand.replace(['custom-pi']),
              environment: {'PI_DEBUG': '1'},
            ),
          ).startSession(
            const PiStartSessionInput(
              cwd: '/workspace/project',
              session: '/tmp/pi-session.jsonl',
              env: {'EXTRA': '2'},
            ),
          );
      addTearDown(session.close);

      expect(launches.single.session, '/tmp/pi-session.jsonl');
      expect(launches.single.argv, [
        'custom-pi',
        '--mode',
        'rpc',
        '--session',
        '/tmp/pi-session.jsonl',
      ]);
      expect(launches.single.env, {'PI_DEBUG': '1', 'EXTRA': '2'});
    });

    test(
      'does not append rpc mode when the configured command already includes '
      'a mode flag',
      () async {
        final child = _FakeProcess();
        final launches = <PiRuntimeLaunch>[];
        _replyToCommands(child, (_) => <String, Object?>{});
        final session = await _piRuntime(
          child,
          launches: launches,
          runtimeSettings: const ProviderRuntimeSettings(
            command: ProviderCommand.replace(['custom-pi', '--mode', 'json']),
          ),
        ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        expect(launches.single.argv, ['custom-pi', '--mode', 'json']);
      },
    );

    test('no-session wins over a session file, and extras come first', () {
      final launch = buildPiLaunch(
        command: const ['pi'],
        session: const PiStartSessionInput(
          cwd: '/workspace/project',
          extraArgs: ['--verbose'],
          model: 'pi-mini',
          thinkingOptionId: 'high',
          session: '/tmp/ignored.jsonl',
          noSession: true,
          modeId: 'plan',
        ),
      );

      expect(launch.argv, [
        'pi',
        '--mode',
        'rpc',
        '--verbose',
        '--model',
        'pi-mini',
        '--thinking',
        'high',
        '--no-session',
      ]);
      // modeId is carried but never becomes a flag; Pi applies it over RPC.
      expect(launch.modeId, 'plan');
      expect(launch.protocolMode, OmpProtocolMode.rpc);
    });

    test('discards a replace override that names no executable', () {
      final launch = buildPiLaunch(
        command: const ['pi'],
        runtimeSettings: const ProviderRuntimeSettings(
          command: ProviderCommand.replace(['']),
        ),
        session: const PiStartSessionInput(cwd: '/workspace/project'),
      );

      expect(launch.argv, ['pi', '--mode', 'rpc']);
    });

    test('resolves the default Pi command from the environment', () {
      expect(defaultPiCommand(), ['pi']);
      expect(defaultPiCommand({'PI_ACP_PI_COMMAND': '/opt/pi'}), ['/opt/pi']);
      expect(
        defaultPiCommand({'PI_COMMAND': '/a', 'PI_ACP_PI_COMMAND': '/b'}),
        ['/a'],
      );
    });

    test('delivers events separately from command responses', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => {'models': <Object?>[]});
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);
      final events = <Map<String, Object?>>[];
      session.onEvent(events.add);

      child.writeFrame({'type': 'turn_start'});
      expect(await session.getAvailableModels(), isEmpty);

      expect(events, [
        {'type': 'turn_start'},
      ]);
    });

    test('forwards frames Pi never validates, unlike OMP', () async {
      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);
      final events = <Map<String, Object?>>[];
      session.onEvent(events.add);

      child.writeFrame({'type': 'future_control', 'enabled': true});
      await pumpEventQueue();

      expect(events, [
        {'type': 'future_control', 'enabled': true},
      ]);
    });

    test('lists commands through the default Pi get_commands RPC', () async {
      final child = _FakeProcess();
      final commandTypes = <String>[];
      _replyToCommands(child, (command) {
        commandTypes.add('${command['type']}');
        return {
          'commands': [
            {
              'name': 'review',
              'description': 'Review changes',
              'source': 'extension',
            },
          ],
        };
      });
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      expect(await session.getCommands(), [
        {
          'name': 'review',
          'description': 'Review changes',
          'source': 'extension',
        },
      ]);
      expect(commandTypes, ['get_commands']);
    });

    test('keeps unicode line separators inside one JSONL record', () async {
      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);
      final events = <Map<String, Object?>>[];
      session.onEvent(events.add);

      // U+2028 and U+2029 terminate a line for a JavaScript parser but not
      // for a JSONL framer; splitting on them would tear one event apart.
      const text = 'a\u2028b\u2029c';
      child.writeRaw('${jsonEncode({'type': 'message', 'text': text})}\n');
      await pumpEventQueue();

      expect(events, [
        {'type': 'message', 'text': text},
      ]);
    });

    test('rejects pending commands when the Pi process exits', () async {
      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));

      final state = session.getState();
      child.writeStderr('boom');
      await pumpEventQueue();
      child.exit(1);

      await expectLater(
        state,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test('rejects pending commands when the Pi session closes', () async {
      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));

      final state = session.getState();
      final rejection = expectLater(
        state,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Pi RPC session is closed',
          ),
        ),
      );
      await session.close();
      await rejection;
    });

    test('compact carries no wall-clock timeout', () async {
      expect(piCompactRequestTimeout, isNull);

      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));

      final compact = session.compact('focus on tests');
      await pumpEventQueue();
      expect(_withoutRequestId(child.commands.single), {
        'type': 'compact',
        'customInstructions': 'focus on tests',
      });

      final rejection = expectLater(
        compact,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Pi RPC session is closed',
          ),
        ),
      );
      await session.close();
      await rejection;
    });

    test('compact resolves when the late response finally arrives', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => {'summary': 'done'});
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await session.compact();
      expect(_withoutRequestId(child.commands.single), {'type': 'compact'});
    });

    test('disposes the Pi process', () async {
      final child = _FakeProcess();
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));

      await session.close();

      expect(child.killedSignals, contains(ProcessSignal.sigterm));
    });

    test('reads a prompt acknowledgement without ever throwing', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => 'not an object');
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final loose = await session.prompt('hi');
      expect(loose.requestId, 'req_1');
      expect(loose.agentInvoked, isNull);

      _replyToCommands(child, (_) => {'agentInvoked': true});
      final ack = await session.prompt('hi again', images: const []);
      expect(ack.requestId, 'req_2');
      expect(ack.agentInvoked, isTrue);
    });

    test('sends raw frames and thinking levels without validation', () async {
      final child = _FakeProcess();
      _replyToCommands(child, (_) => <String, Object?>{});
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      await session.setThinkingLevel('ludicrous');
      session.sendRawFrame({'type': 'pi_only', 'value': 1});
      session.respondToExtensionUiRequest(
        'ui-1',
        const OmpExtensionUiResponse(value: 'Approve'),
      );
      await pumpEventQueue();

      expect(child.commands.map(_withoutRequestId), [
        {'type': 'set_thinking_level', 'level': 'ludicrous'},
        {'type': 'pi_only', 'value': 1},
        {'type': 'extension_ui_response', 'id': 'ui-1', 'value': 'Approve'},
      ]);
    });

    test(
      'falls back to get_state when get_session_stats is unsupported',
      () async {
        final child = _FakeProcess();
        final sequence = <String>[];
        _replyToCommands(child, (command) {
          sequence.add('${command['type']}');
          if (command['type'] == 'get_session_stats') {
            throw StateError('Unknown command: ${command['type']}');
          }
          return {
            'sessionId': 'pi-session-1',
            'contextUsage': {'tokens': 1100, 'contextWindow': 200000},
          };
        });
        final session = await _piRuntime(
          child,
        ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final stats = await session.getSessionStats();
        expect(stats.contextUsage?.tokens, 1100);
        expect(stats.contextUsage?.contextWindow, 200000);
        expect(sequence, ['get_session_stats', 'get_state']);
      },
    );

    test(
      'returns full stats from get_session_stats without falling back',
      () async {
        final child = _FakeProcess();
        var fallbackCalled = false;
        _replyToCommands(child, (command) {
          if (command['type'] == 'get_state') fallbackCalled = true;
          return {
            'tokens': {'input': 500, 'output': 300, 'cacheRead': 100},
            'cost': 0.02,
            'contextUsage': {'tokens': 800, 'contextWindow': 200000},
          };
        });
        final session = await _piRuntime(
          child,
        ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
        addTearDown(session.close);

        final stats = await session.getSessionStats();
        expect(stats.tokens, {'input': 500, 'output': 300, 'cacheRead': 100});
        expect(stats.cost, 0.02);
        expect(stats.contextUsage?.tokens, 800);
        expect(fallbackCalled, isFalse);
      },
    );

    test('does not fall back when get_session_stats returns cost:0', () async {
      final child = _FakeProcess();
      var fallbackCalled = false;
      _replyToCommands(child, (command) {
        if (command['type'] == 'get_state') fallbackCalled = true;
        return {
          'tokens': {'input': 200, 'output': 100},
          'cost': 0,
          'contextUsage': {'tokens': 500, 'contextWindow': 200000},
        };
      });
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final stats = await session.getSessionStats();
      expect(stats.cost, 0);
      expect(stats.isEmpty, isFalse);
      expect(fallbackCalled, isFalse);
    });

    test('returns empty stats when both RPCs fail', () async {
      final child = _FakeProcess();
      _replyToCommands(
        child,
        (command) => throw StateError('Unknown command: ${command['type']}'),
      );
      final session = await _piRuntime(
        child,
      ).startSession(const PiStartSessionInput(cwd: '/workspace/project'));
      addTearDown(session.close);

      final stats = await session.getSessionStats();
      expect(stats.isEmpty, isTrue);
      expect(stats.raw, isEmpty);
    });
  });

  // =========================================================================
  group('Pi history mapper', () {
    List<Map<String, Object?>> project(
      List<Object?> messages, [
      List<PiCapturedUserMessageEntry> userEntries = const [],
    ]) => projectPiHistory(
      'pi',
      messages,
      userEntries: userEntries,
    ).map((item) => item.toJson()).toList();

    test('replays user, assistant, reasoning, and completed tool calls', () {
      expect(
        project([
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'read this'},
              {'type': 'image', 'data': 'base64', 'mimeType': 'image/png'},
              {'type': 'text', 'text': 'then answer'},
            ],
          },
          {
            'role': 'assistant',
            'responseId': 'response-1',
            'content': [
              {'type': 'thinking', 'thinking': 'checking file'},
              {
                'type': 'toolCall',
                'id': 'tool-1',
                'name': 'read',
                'arguments': {'path': 'note.txt'},
              },
              {'type': 'text', 'text': 'done'},
            ],
          },
          {
            'role': 'toolResult',
            'toolCallId': 'tool-1',
            'toolName': 'read',
            'content': [
              {'type': 'text', 'text': 'file contents'},
            ],
          },
        ]),
        [
          {
            'id': 'pi-history-user-1',
            'kind': 'user_message',
            'text': 'read this\n\nthen answer',
          },
          {
            'id': 'pi-history-reasoning-1',
            'kind': 'reasoning',
            'text': 'checking file',
            'complete': true,
          },
          {
            'id': 'tool-1',
            'kind': 'tool_call',
            'toolName': 'read',
            'status': 'running',
            'detail': {'kind': 'read', 'path': 'note.txt'},
          },
          {
            'id': 'response-1',
            'kind': 'assistant_message',
            'text': 'done',
            'complete': true,
          },
          {
            'id': 'tool-1',
            'kind': 'tool_call',
            'toolName': 'read',
            'status': 'success',
            'detail': {
              'kind': 'read',
              'path': 'note.txt',
              'content': 'file contents',
            },
          },
        ],
      );
    });

    test('replays bash execution records as completed shell calls', () {
      expect(
        project([
          {
            'role': 'bashExecution',
            'command': 'echo hi',
            'output': 'hi\n',
            'exitCode': 0,
            'timestamp': 123,
          },
          {
            'role': 'bashExecution',
            'command': 'sleep 100',
            'cancelled': true,
            'timestamp': 456,
          },
        ]),
        [
          {
            'id': 'pi-bash-123',
            'kind': 'tool_call',
            'toolName': 'bash',
            'status': 'success',
            'detail': {
              'kind': 'shell',
              'command': 'echo hi',
              'output': 'hi\n',
              'exitCode': 0,
            },
          },
          {
            'id': 'pi-bash-456',
            'kind': 'tool_call',
            'toolName': 'bash',
            'status': 'canceled',
            'detail': {'kind': 'shell', 'command': 'sleep 100'},
          },
        ],
      );
    });

    test('replays non-notice custom messages as assistant text, matching the '
        'live path', () {
      expect(
        project([
          {'role': 'custom', 'content': 'Extension command output'},
        ]),
        [
          {
            'id': 'pi-history-custom-1',
            'kind': 'assistant_message',
            'text': 'Extension command output',
            'complete': true,
          },
        ],
      );
    });

    test('lets a hook re-render a custom message', () {
      final items = projectPiHistory(
        'pi',
        [
          {'role': 'custom', 'content': 'notice text'},
        ],
        hooks: PiHistoryHooks(
          mapCustomMessage: (text, provider) =>
              ErrorItem(id: '$provider-notice', message: text),
        ),
      );

      expect(items.single, isA<ErrorItem>());
      expect((items.single as ErrorItem).message, 'notice text');
    });

    test('uses Pi tree entry ids for replayed user messages', () {
      expect(
        project(
          [
            {'role': 'user', 'content': 'first prompt'},
            {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'first answer'},
              ],
            },
            {'role': 'user', 'content': 'second prompt'},
            {'role': 'user', 'content': 'third prompt'},
          ],
          const [
            PiCapturedUserMessageEntry(
              id: 'entry-user-1',
              text: 'first prompt',
            ),
            PiCapturedUserMessageEntry(
              id: 'entry-user-2',
              text: 'second prompt',
            ),
          ],
        ),
        [
          {
            'id': 'entry-user-1',
            'kind': 'user_message',
            'text': 'first prompt',
          },
          {
            'id': 'pi-history-assistant-1',
            'kind': 'assistant_message',
            'text': 'first answer',
            'complete': true,
          },
          {
            'id': 'entry-user-2',
            'kind': 'user_message',
            'text': 'second prompt',
          },
          {
            'id': 'pi-history-user-3',
            'kind': 'user_message',
            'text': 'third prompt',
          },
        ],
      );
    });

    test('marks a failed tool result and carries its text as the error', () {
      // A `toolResult` with no preceding `toolCall` has no arguments to
      // recover, so upstream re-parses with `null` args and every tool — bash
      // included — degrades to the unknown branch's generic card.
      expect(
        project([
          {
            'role': 'toolResult',
            'toolCallId': 'tool-9',
            'toolName': 'bash',
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'command not found'},
            ],
          },
          {
            'role': 'toolResult',
            'toolCallId': 'tool-10',
            'toolName': 'bash',
            'isError': true,
          },
        ]),
        [
          {
            'id': 'tool-9',
            'kind': 'tool_call',
            'toolName': 'bash',
            'status': 'error',
            'detail': {
              'kind': 'generic',
              'input': {'value': null},
              'output': {
                'content': [
                  {'type': 'text', 'text': 'command not found'},
                ],
              },
            },
            'errorMessage': 'command not found',
          },
          {
            'id': 'tool-10',
            'kind': 'tool_call',
            'toolName': 'bash',
            'status': 'error',
            'detail': {
              'kind': 'generic',
              'input': {'value': null},
              'output': <String, Object?>{},
            },
            'errorMessage': 'Tool call failed',
          },
        ],
      );
    });

    test('recovers tool arguments from the preceding tool call', () {
      expect(
        project([
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'toolCall',
                'id': 'tool-11',
                'name': 'bash',
                'arguments': {'command': 'echo hi'},
              },
            ],
          },
          {
            'role': 'toolResult',
            'toolCallId': 'tool-11',
            'toolName': 'bash',
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        ]).last,
        {
          'id': 'tool-11',
          'kind': 'tool_call',
          'toolName': 'bash',
          'status': 'success',
          'detail': {'kind': 'shell', 'command': 'echo hi', 'output': 'hi'},
        },
      );
    });

    test('honours the tool-call id and detail hooks', () {
      final items = projectPiHistory(
        'pi',
        [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'toolCall',
                'id': 'tool-a',
                'name': 'todo',
                'arguments': <String, Object?>{},
              },
              {
                'type': 'toolCall',
                'id': 'tool-b',
                'name': 'read',
                'arguments': {'path': 'x.txt'},
              },
            ],
          },
        ],
        hooks: PiHistoryHooks(
          resolveToolCallId: (id, _) => 'pi:$id',
          mapToolDetail: (toolCall, result, toolCallId) =>
              toolCall.toolName == 'todo'
              ? null
              : const PlainTextDetail(text: 'hooked'),
        ),
      );

      expect(items.map((item) => item.id), ['pi:tool-b']);
      expect((items.single as ToolCallItem).detail, isA<PlainTextDetail>());
    });

    test('skips unknown roles and non-object entries', () {
      expect(
        project([
          'not a message',
          42,
          {'role': 'future'},
        ]),
        isEmpty,
      );
    });
  });

  // =========================================================================
  group('Pi tool call naming', () {
    test('resolves an MCP proxy call from its result details', () {
      final call = parseOmpToolArgs('mcp', {
        'server': 'github',
        'tool': 'github_list_issues',
      });

      expect(
        resolvePiToolCallName(call, {
          'details': {'server': 'linear', 'tool': 'create_issue'},
        }),
        'linear.create_issue',
      );
    });

    test('falls back to the requested server and tool arguments', () {
      expect(
        resolvePiToolCallName(
          parseOmpToolArgs('mcp', {
            'server': 'github',
            'tool': 'github_list_issues',
          }),
        ),
        // The `<server>_` proxy prefix is stripped so the card reads cleanly.
        'github.list_issues',
      );
      expect(
        resolvePiToolCallName(
          parseOmpToolArgs('mcp', {'tool': 'github_list_issues'}),
        ),
        'github.list_issues',
      );
      expect(
        resolvePiToolCallName(parseOmpToolArgs('mcp', {'tool': 'bare'})),
        'mcp',
      );
      expect(resolvePiToolCallName(parseOmpToolArgs('mcp', null)), 'mcp');
    });

    test('keeps the shared xdev rule ahead of the MCP branch', () {
      final call = parseOmpToolArgs('write', {'path': 'a.txt', 'content': 'x'});

      expect(
        resolvePiToolCallName(call, {
          'details': {
            'xdev': {'tool': ' deploy ', 'mode': 'execute'},
          },
        }),
        'deploy',
      );
      expect(resolvePiToolCallName(call), 'write');
    });
  });
}
