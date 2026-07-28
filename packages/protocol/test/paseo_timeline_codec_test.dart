import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('PaseoTimelineCodec', () {
    test('matches the frozen worktree setup tool-call fixture exactly', () {
      const item = ToolCallItem(
        id: 'worktree-setup:agent-1',
        toolName: 'paseo_worktree_setup',
        status: ToolCallStatus.success,
        detail: WorktreeSetupToolDetail(
          worktreePath: r'C:\repo\worktree',
          branchName: 'feature/test',
          log: 'done',
          commands: [
            WorkspaceSetupCommand(
              index: 1,
              command: 'flutter pub get',
              cwd: r'C:\repo\worktree',
              log: 'Resolving dependencies...',
              status: WorkspaceSetupCommandStatus.completed,
              exitCode: 0,
              durationMs: 1250,
            ),
          ],
          truncated: true,
        ),
        metadata: {'source': 'workspace.create'},
      );

      final wire = PaseoTimelineCodec.encode(item);
      expect(wire, {
        'type': 'tool_call',
        'callId': 'worktree-setup:agent-1',
        'name': 'paseo_worktree_setup',
        'detail': {
          'type': 'worktree_setup',
          'worktreePath': r'C:\repo\worktree',
          'branchName': 'feature/test',
          'log': 'done',
          'commands': [
            {
              'index': 1,
              'command': 'flutter pub get',
              'cwd': r'C:\repo\worktree',
              'log': 'Resolving dependencies...',
              'status': 'completed',
              'exitCode': 0,
              'durationMs': 1250,
            },
          ],
          'truncated': true,
        },
        'metadata': {'source': 'workspace.create'},
        'status': 'completed',
        'error': null,
      });

      final decoded =
          PaseoTimelineCodec.decode(wire, fallbackId: 'ignored-for-tools')
              as ToolCallItem;
      expect(decoded.id, 'worktree-setup:agent-1');
      expect(decoded.status, ToolCallStatus.success);
      expect(decoded.metadata, {'source': 'workspace.create'});
      expect(decoded.detail, isA<WorktreeSetupToolDetail>());
    });

    test('maps every frozen tool status and error invariant', () {
      for (final entry in const [
        (ToolCallStatus.pending, 'running', null),
        (ToolCallStatus.running, 'running', null),
        (ToolCallStatus.success, 'completed', null),
        (ToolCallStatus.error, 'failed', 'boom'),
        (ToolCallStatus.canceled, 'canceled', null),
      ]) {
        final item = ToolCallItem(
          id: 'call-${entry.$2}-${entry.$1.name}',
          toolName: 'tool',
          status: entry.$1,
          detail: const GenericDetail(input: {}, output: null),
          errorMessage: entry.$3,
        );
        final wire = PaseoTimelineCodec.encode(item);
        expect(wire['status'], entry.$2);
        expect(wire['error'], entry.$3);
        final decoded =
            PaseoTimelineCodec.decode(wire, fallbackId: 'row') as ToolCallItem;
        expect(
          decoded.status,
          entry.$1 == ToolCallStatus.pending
              ? ToolCallStatus.running
              : entry.$1,
        );
      }

      expect(
        () => PaseoTimelineCodec.decode(
          _toolWire(status: 'failed', error: null),
          fallbackId: 'row',
        ),
        throwsFormatException,
      );
      expect(
        () => PaseoTimelineCodec.decode(
          _toolWire(status: 'completed', error: 'unexpected'),
          fallbackId: 'row',
        ),
        throwsFormatException,
      );
    });

    test('round-trips every frozen tool detail variant', () {
      const details = <ToolCallDetail>[
        ShellDetail(
          command: 'dart test',
          cwd: '/repo',
          output: 'ok',
          exitCode: 0,
        ),
        ReadDetail(
          path: 'a.dart',
          content: 'void main() {}',
          offset: 1,
          limit: 5,
        ),
        EditDetail(
          path: 'a.dart',
          oldString: 'old',
          newString: 'new',
          diff: '-old\n+new',
        ),
        WriteDetail(path: 'b.dart', contentPreview: 'class B {}'),
        SearchDetail(
          query: 'TODO',
          toolName: 'grep',
          content: 'a.dart:1',
          filePaths: ['a.dart'],
          webResults: [
            SearchWebResult(title: 'Result', url: 'https://example.com'),
          ],
          annotations: ['source'],
          numFiles: 1,
          numMatches: 2,
          durationMs: 12,
          durationSeconds: 0.012,
          truncated: false,
          mode: 'content',
        ),
        FetchDetail(
          url: 'https://example.com',
          prompt: 'summarize',
          result: 'result',
          code: 200,
          codeText: 'OK',
          bytes: 42,
          durationMs: 25,
        ),
        SubAgentDetail(
          subAgentType: 'research',
          description: 'inspect',
          childSessionId: 'child-1',
          log: 'done',
          actions: [
            SubAgentAction(index: 1, toolName: 'read', summary: 'a.dart'),
          ],
        ),
        PlainTextDetail(label: 'Info', text: 'hello', icon: 'sparkles'),
        PlanDetail(text: '# Plan'),
        GenericDetail(input: {'raw': true}, output: ['done']),
      ];

      for (var index = 0; index < details.length; index++) {
        final original = details[index];
        final wire = PaseoTimelineCodec.encode(
          ToolCallItem(
            id: 'call-$index',
            toolName: 'tool-$index',
            status: ToolCallStatus.running,
            detail: original,
          ),
        );
        final decoded =
            PaseoTimelineCodec.decode(wire, fallbackId: 'row') as ToolCallItem;
        expect(decoded.detail.runtimeType, original.runtimeType);
        expect(decoded.detail.toPaseoJson(), original.toPaseoJson());
      }
    });

    test('encodes and decodes non-tool timeline variants', () {
      const items = <TimelineItem>[
        UserMessageItem(
          id: 'user-local',
          text: 'hello',
          clientMessageId: 'client-user',
        ),
        AssistantMessageItem(
          id: 'assistant-local',
          text: 'hi',
          complete: false,
        ),
        ReasoningItem(id: 'reason-local', text: 'thinking', complete: false),
        TodoItem(
          id: 'todo-local',
          items: [
            TodoEntry(text: 'one', completed: false),
            TodoEntry(text: 'two', completed: true),
          ],
        ),
        ErrorItem(id: 'error-local', message: 'failed'),
        CompactionItem(
          id: 'compact-local',
          status: CompactionStatus.loading,
          trigger: CompactionTrigger.auto,
          preTokens: 100,
        ),
      ];

      for (var index = 0; index < items.length; index++) {
        final wire = PaseoTimelineCodec.encode(items[index]);
        expect(wire.containsKey('id'), isFalse);
        final decoded = PaseoTimelineCodec.decode(
          wire,
          fallbackId: 'row-$index',
        );
        expect(decoded.id, index < 2 ? items[index].id : 'row-$index');
        expect(decoded.runtimeType, items[index].runtimeType);
        if (index == 0) {
          expect(wire['clientMessageId'], 'client-user');
          expect((decoded as UserMessageItem).clientMessageId, 'client-user');
        }
      }
    });

    test('keeps legacy encoding explicit and rejects stream-only rows', () {
      const legacy = ToolCallItem(
        id: 'legacy',
        toolName: 'bash',
        status: ToolCallStatus.success,
        detail: ShellDetail(command: 'pwd'),
      );
      final encoded = LegacyTimelineCodec.encode(legacy);
      expect(encoded['kind'], 'tool_call');
      expect(encoded['toolName'], 'bash');
      expect(LegacyTimelineCodec.decode(encoded), isA<ToolCallItem>());

      expect(
        () => PaseoTimelineCodec.encode(
          const TurnItem(id: 'turn', phase: TurnPhase.started),
        ),
        throwsFormatException,
      );
      expect(
        () => PaseoTimelineCodec.encode(
          const PermissionItem(
            id: 'permission',
            permissionId: 'p1',
            toolName: 'bash',
            status: PermissionStatus.pending,
            detail: GenericDetail(input: {}),
          ),
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed frozen boundaries', () {
      for (final wire in <Map<String, Object?>>[
        const {},
        const {'type': 'mystery'},
        _toolWire(status: 'mystery', error: null),
        {..._toolWire(), 'detail': 'bad'},
        {..._toolWire(), 'metadata': 'bad'},
        const {'type': 'todo', 'items': 'bad'},
        const {'type': 'compaction', 'status': 'bad'},
        const {'type': 'compaction', 'status': 'completed', 'trigger': 'bad'},
        const {'type': 'compaction', 'status': 'completed', 'preTokens': 1.5},
      ]) {
        expect(
          () => PaseoTimelineCodec.decode(wire, fallbackId: 'row'),
          throwsFormatException,
        );
      }
    });
  });

  group('ToolCallDetail frozen validation', () {
    test('rejects unknown and malformed canonical details', () {
      for (final detail in <Map<String, Object?>>[
        const {},
        const {'type': 'mystery'},
        const {'type': 'shell'},
        const {
          'type': 'search',
          'query': 'x',
          'filePaths': [1],
        },
        const {'type': 'search', 'query': 'x', 'webResults': 'bad'},
        const {'type': 'sub_agent', 'log': 'x', 'actions': 'bad'},
        const {'type': 'read', 'filePath': 'a', 'offset': 1.5},
        const {'type': 'fetch', 'url': 'x', 'durationMs': 'bad'},
      ]) {
        expect(
          () => ToolCallDetail.fromPaseoJson(detail),
          throwsFormatException,
        );
      }
    });

    test('accepts optional fields omitted by frozen producers', () {
      final details = [
        ToolCallDetail.fromPaseoJson(const {
          'type': 'shell',
          'command': 'pwd',
          'exitCode': null,
        }),
        ToolCallDetail.fromPaseoJson(const {'type': 'search', 'query': 'x'}),
        ToolCallDetail.fromPaseoJson(const {'type': 'sub_agent', 'log': ''}),
        ToolCallDetail.fromPaseoJson(const {'type': 'plain_text'}),
      ];
      expect(details, [
        isA<ShellDetail>(),
        isA<SearchDetail>(),
        isA<SubAgentDetail>(),
        isA<PlainTextDetail>(),
      ]);
    });
  });

  group('PaseoAgentStreamCodec', () {
    test('wraps canonical timeline rows with frozen stream metadata', () {
      const stream = AgentStreamPayload(
        agentId: 'agent-1',
        epoch: 3,
        seq: 7,
        provider: 'codex',
        timestamp: '2026-07-28T00:00:00.000Z',
        item: ToolCallItem(
          id: 'call-1',
          toolName: 'shell',
          status: ToolCallStatus.running,
          detail: ShellDetail(command: 'pwd'),
        ),
      );

      expect(PaseoAgentStreamCodec.encode(stream), {
        'type': 'agent_stream',
        'payload': {
          'agentId': 'agent-1',
          'event': {
            'type': 'timeline',
            'provider': 'codex',
            'item': {
              'type': 'tool_call',
              'callId': 'call-1',
              'name': 'shell',
              'detail': {'type': 'shell', 'command': 'pwd'},
              'status': 'running',
              'error': null,
            },
          },
          'timestamp': '2026-07-28T00:00:00.000Z',
          'seq': 7,
          'epoch': '3',
        },
      });
    });

    test('maps turn lifecycle to frozen stream events', () {
      for (final entry in const [
        (TurnPhase.started, 'turn_started', null),
        (TurnPhase.completed, 'turn_completed', null),
        (TurnPhase.failed, 'turn_failed', 'failed'),
        (TurnPhase.canceled, 'turn_canceled', 'stopped'),
      ]) {
        final wire = PaseoAgentStreamCodec.encode(
          AgentStreamPayload(
            agentId: 'agent',
            epoch: 1,
            seq: 1,
            provider: 'claude',
            item: TurnItem(id: 'turn', phase: entry.$1, errorMessage: entry.$3),
          ),
          timestamp: 'now',
        );
        final event =
            (wire['payload'] as Map<String, Object?>)['event']
                as Map<String, Object?>;
        expect(event['type'], entry.$2);
        expect(event['provider'], 'claude');
        if (entry.$1 == TurnPhase.failed) {
          expect(event['error'], 'failed');
        }
        if (entry.$1 == TurnPhase.canceled) {
          expect(event['reason'], 'stopped');
        }
      }
    });

    test('maps permission request and resolutions to frozen events', () {
      for (final status in PermissionStatus.values) {
        final wire = PaseoAgentStreamCodec.encode(
          AgentStreamPayload(
            agentId: 'agent',
            epoch: 1,
            seq: status.index,
            provider: 'codex',
            item: PermissionItem(
              id: 'permission-row',
              permissionId: 'permission-1',
              toolName: 'shell',
              status: status,
              detail: const ShellDetail(command: 'rm file'),
            ),
          ),
          timestamp: 'now',
        );
        final event =
            (wire['payload'] as Map<String, Object?>)['event']
                as Map<String, Object?>;
        if (status == PermissionStatus.pending) {
          expect(event['type'], 'permission_requested');
          expect(event['request'], {
            'id': 'permission-1',
            'provider': 'codex',
            'name': 'shell',
            'kind': 'tool',
            'detail': {'type': 'shell', 'command': 'rm file'},
          });
        } else {
          expect(event['type'], 'permission_resolved');
          expect(event['requestId'], 'permission-1');
          expect(event['resolution'], {
            'behavior': status == PermissionStatus.allowed ? 'allow' : 'deny',
          });
        }
      }
    });

    test('decodes native timeline, turn, and permission events', () {
      final timeline = PaseoAgentStreamCodec.decode({
        'type': 'agent_stream',
        'payload': {
          'agentId': 'agent-1',
          'event': {
            'type': 'timeline',
            'provider': 'codex',
            'item': {
              'type': 'assistant_message',
              'messageId': 'assistant-1',
              'text': 'hello',
            },
          },
          'timestamp': 'now',
          'seq': 7,
          'epoch': '3',
        },
      });
      expect(timeline.agentId, 'agent-1');
      expect(timeline.epoch, 3);
      expect(timeline.seq, 7);
      expect(timeline.item, isA<AssistantMessageItem>());
      expect(timeline.item.id, 'assistant-1');

      final failed = PaseoAgentStreamCodec.decode({
        'type': 'agent_stream',
        'payload': {
          'agentId': 'agent-1',
          'event': {
            'type': 'turn_failed',
            'provider': 'claude',
            'error': 'failed',
          },
          'timestamp': 'now',
          'seq': 8,
          'epoch': 3,
        },
      });
      expect(
        failed.item,
        isA<TurnItem>()
            .having((item) => item.phase, 'phase', TurnPhase.failed)
            .having((item) => item.errorMessage, 'error', 'failed'),
      );

      final requested = PaseoAgentStreamCodec.decode({
        'type': 'agent_stream',
        'payload': {
          'agentId': 'agent-1',
          'event': {
            'type': 'permission_requested',
            'provider': 'codex',
            'request': {
              'id': 'permission-1',
              'name': 'shell',
              'detail': {'type': 'shell', 'command': 'rm file'},
            },
          },
          'timestamp': 'now',
          'seq': 9,
          'epoch': '3',
        },
      });
      expect(
        requested.item,
        isA<PermissionItem>()
            .having((item) => item.status, 'status', PermissionStatus.pending)
            .having((item) => item.toolName, 'toolName', 'shell')
            .having((item) => item.detail, 'detail', isA<ShellDetail>()),
      );

      final resolved = PaseoAgentStreamCodec.decode({
        'type': 'agent_stream',
        'payload': {
          'agentId': 'agent-1',
          'event': {
            'type': 'permission_resolved',
            'provider': 'codex',
            'requestId': 'permission-1',
            'resolution': {'behavior': 'deny'},
          },
          'timestamp': 'now',
          'seq': 10,
          'epoch': '3',
        },
      });
      expect(
        resolved.item,
        isA<PermissionItem>().having(
          (item) => item.status,
          'status',
          PermissionStatus.denied,
        ),
      );
    });

    test('rejects malformed native stream boundaries', () {
      expect(
        () => PaseoAgentStreamCodec.decode(const {'type': 'other'}),
        throwsFormatException,
      );
      expect(
        () => PaseoAgentStreamCodec.decode({
          'type': 'agent_stream',
          'payload': {
            'agentId': 'agent',
            'event': {'type': 'unknown', 'provider': 'codex'},
            'timestamp': 'now',
            'seq': 1,
            'epoch': '1',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => PaseoAgentStreamCodec.decode({
          'type': 'agent_stream',
          'payload': {
            'agentId': 'agent',
            'event': {
              'type': 'permission_resolved',
              'provider': 'codex',
              'requestId': 'permission',
              'resolution': {'behavior': 'ask'},
            },
            'timestamp': 'now',
            'seq': 1.5,
            'epoch': 'bad',
          },
        }),
        throwsFormatException,
      );
    });
  });
}

Map<String, Object?> _toolWire({String status = 'running', Object? error}) => {
  'type': 'tool_call',
  'callId': 'call-1',
  'name': 'tool',
  'detail': const {'type': 'unknown', 'input': {}, 'output': null},
  'status': status,
  'error': error,
};
