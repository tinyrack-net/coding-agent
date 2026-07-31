import 'package:agent_daemon/src/providers/paseo/paseo_provider_mappers.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Records every revert issued so tests can assert on the exact wire payload,
/// and replays a canned response — OpenCode reports failures in-band.
final class _FakeOpenCodeClient implements OpenCodeRewindClient {
  final List<Map<String, Object?>> recordedReverts = [];
  OpenCodeRevertResponse revertResponse = const OpenCodeRevertResponse();

  @override
  Future<OpenCodeRevertResponse> revert(OpenCodeRevertRequest request) async {
    recordedReverts.add(request.toJson());
    return revertResponse;
  }
}

const _todoPhases = [
  OmpTodoPhase(
    name: 'Tasks',
    tasks: [
      OmpTodoItem(content: 'alpha task', status: OmpTodoStatus.completed),
      OmpTodoItem(content: 'beta task', status: OmpTodoStatus.inProgress),
      OmpTodoItem(content: 'gamma task', status: OmpTodoStatus.pending),
    ],
  ),
];

const _todoPhasesJson = [
  {
    'name': 'Tasks',
    'tasks': [
      {'content': 'alpha task', 'status': 'completed'},
      {'content': 'beta task', 'status': 'in_progress'},
      {'content': 'gamma task', 'status': 'pending'},
    ],
  },
];

List<Map<String, Object?>> _json(List<AgentSlashCommand> commands) =>
    commands.map((command) => command.toJson()).toList();

Map<String, Object?>? _byName(List<AgentSlashCommand> commands, String name) {
  for (final command in commands) {
    if (command.name == name) return command.toJson();
  }
  return null;
}

void main() {
  group('OMP usage mapper', () {
    test('adds OMP context usage to token and cost totals', () {
      final usage = mapOmpUsage(
        stats: const {
          'tokens': {
            'input': 28237,
            'output': 548,
            'cacheRead': 269824,
            'cacheWrite': 0,
            'total': 298609,
          },
          'cost': 0.29253700000000005,
        },
        state: const OmpSessionState(
          contextUsage: OmpContextUsage(
            tokens: 23656,
            contextWindow: 272000,
            percent: 8.7,
          ),
        ),
        baseUsage: const AgentUsage(
          inputTokens: 28237,
          cachedInputTokens: 269824,
          outputTokens: 548,
          totalCostUsd: 0.29253700000000005,
        ),
      );

      expect(usage!.toJson(), {
        'inputTokens': 28237,
        'cachedInputTokens': 269824,
        'outputTokens': 548,
        'totalCostUsd': 0.29253700000000005,
        'contextWindowMaxTokens': 272000,
        'contextWindowUsedTokens': 23656,
      });
    });

    test('returns the base usage untouched when OMP reports no context', () {
      const base = AgentUsage(inputTokens: 10, contextWindowMaxTokens: 999);

      expect(
        mapOmpUsage(state: const OmpSessionState(), baseUsage: base),
        same(base),
      );
      expect(
        mapOmpUsage(
          state: const OmpSessionState(contextUsage: OmpContextUsage()),
          baseUsage: base,
        ),
        same(base),
      );
      expect(
        mapOmpUsage(
          state: const OmpSessionState(
            contextUsage: OmpContextUsage(tokens: null, contextWindow: null),
          ),
          baseUsage: base,
        ),
        same(base),
      );
      expect(mapOmpUsage(state: const OmpSessionState()), isNull);
    });

    test('keeps base values for the half of the pair OMP omits', () {
      final onlyUsed = mapOmpUsage(
        state: const OmpSessionState(
          contextUsage: OmpContextUsage(tokens: 100),
        ),
        baseUsage: const AgentUsage(contextWindowMaxTokens: 200000),
      );
      expect(onlyUsed!.toJson(), {
        'contextWindowMaxTokens': 200000,
        'contextWindowUsedTokens': 100,
      });

      final onlyMax = mapOmpUsage(
        state: const OmpSessionState(
          contextUsage: OmpContextUsage(contextWindow: 272000),
        ),
        baseUsage: const AgentUsage(contextWindowUsedTokens: 7),
      );
      expect(onlyMax!.toJson(), {
        'contextWindowMaxTokens': 272000,
        'contextWindowUsedTokens': 7,
      });
    });

    test('treats zero as reported but non-finite numbers as absent', () {
      final zero = mapOmpUsage(
        state: const OmpSessionState(
          contextUsage: OmpContextUsage(tokens: 0, contextWindow: 0),
        ),
      );
      expect(zero!.toJson(), {
        'contextWindowMaxTokens': 0,
        'contextWindowUsedTokens': 0,
      });

      expect(
        mapOmpUsage(
          state: const OmpSessionState(
            contextUsage: OmpContextUsage(
              tokens: double.nan,
              contextWindow: double.infinity,
            ),
          ),
          baseUsage: const AgentUsage(inputTokens: 5),
        )!.toJson(),
        {'inputTokens': 5},
      );
    });

    test('synthesises usage when there is no base usage at all', () {
      expect(
        mapOmpUsage(
          state: const OmpSessionState(
            contextUsage: OmpContextUsage(tokens: 12, contextWindow: 34),
          ),
        )!.toJson(),
        {'contextWindowMaxTokens': 34, 'contextWindowUsedTokens': 12},
      );
    });

    test('truncates fractional token counts to int', () {
      expect(
        mapOmpUsage(
          state: const OmpSessionState(
            contextUsage: OmpContextUsage(tokens: 12.9, contextWindow: 34.2),
          ),
        )!.toJson(),
        {'contextWindowMaxTokens': 34, 'contextWindowUsedTokens': 12},
      );
    });
  });

  group('OMP tool call ids', () {
    test('uses stable synthetic ids only for subagent poll calls', () {
      expect(
        resolveOmpEmittedToolCallId(
          'poll-1',
          const OmpToolCallRef(
            toolName: 'subagent',
            args: {
              'poll': ['job-b', 'job-a'],
            },
          ),
        ),
        'omp-poll:job-a,job-b',
      );
      expect(
        resolveOmpEmittedToolCallId(
          'poll-2',
          const OmpToolCallRef(
            toolName: 'subagent',
            args: {
              'poll': ['job-a', 'job-b'],
            },
          ),
        ),
        'omp-poll:job-a,job-b',
      );
      expect(
        resolveOmpEmittedToolCallId(
          'poll-3',
          const OmpToolCallRef(
            toolName: 'subagent',
            args: {
              'poll': ['job-a'],
            },
          ),
        ),
        'omp-poll:job-a',
      );
      expect(
        resolveOmpEmittedToolCallId(
          'spawn-1',
          const OmpToolCallRef(
            toolName: 'subagent',
            args: {
              'spawn': [
                {'prompt': 'go'},
              ],
            },
          ),
        ),
        'spawn-1',
      );
      expect(
        resolveOmpEmittedToolCallId(
          'bash-1',
          const OmpToolCallRef(toolName: 'bash', args: {'command': 'echo hi'}),
        ),
        'bash-1',
      );
    });

    test('keeps the provider id for non-subagent tools that do poll', () {
      expect(
        resolveOmpEmittedToolCallId(
          'bash-2',
          const OmpToolCallRef(
            toolName: 'bash',
            args: {
              'poll': ['job-a'],
            },
          ),
        ),
        'bash-2',
      );
    });

    test('trims poll targets and preserves duplicates', () {
      expect(
        readOmpPollTargets(const {
          'poll': ['  job-b  ', 'job-a', 'job-a'],
        }),
        ['job-a', 'job-a', 'job-b'],
      );
    });

    test('rejects poll lists that are not entirely non-blank strings', () {
      expect(readOmpPollTargets(null), isNull);
      expect(readOmpPollTargets('poll'), isNull);
      expect(readOmpPollTargets(const ['job-a']), isNull);
      expect(readOmpPollTargets(const {}), isNull);
      expect(readOmpPollTargets(const {'poll': 'job-a'}), isNull);
      expect(readOmpPollTargets(const {'poll': []}), isNull);
      expect(
        readOmpPollTargets(const {
          'poll': ['job-a', '   '],
        }),
        isNull,
      );
      expect(
        readOmpPollTargets(const {
          'poll': ['job-a', 7],
        }),
        isNull,
      );
      expect(
        readOmpPollTargets(const {
          'poll': ['job-a', null],
        }),
        isNull,
      );
    });

    test('sorts by UTF-16 code unit, so uppercase precedes lowercase', () {
      expect(
        resolveOmpEmittedToolCallId(
          'poll-4',
          const OmpToolCallRef(
            toolName: 'subagent',
            args: {
              'poll': ['beta', 'Alpha', 'alpha'],
            },
          ),
        ),
        'omp-poll:Alpha,alpha,beta',
      );
    });
  });

  group('OMP todo mapper', () {
    test('maps todo tool results and collapses statuses to completed', () {
      expect(
        mapOmpTodoToolResult(
          parseOmpToolResult(const {
            'content': [],
            'details': {
              'phases': [
                {
                  'name': 'Tasks',
                  'tasks': [
                    {'content': 'alpha task', 'status': 'in_progress'},
                    {'content': 'beta task', 'status': 'pending'},
                    {'content': 'gamma task', 'status': 'pending'},
                  ],
                },
              ],
            },
          }),
          id: 'todo-1',
        )!.toJson(),
        {
          'id': 'todo-1',
          'kind': 'todo',
          'items': [
            {'text': 'alpha task', 'completed': false},
            {'text': 'beta task', 'completed': false},
            {'text': 'gamma task', 'completed': false},
          ],
        },
      );

      expect(
        mapOmpTodoToolResult(
          parseOmpToolResult(const {
            'content': [],
            'details': {'phases': _todoPhasesJson},
          }),
          id: 'todo-2',
        )!.toJson(),
        {
          'id': 'todo-2',
          'kind': 'todo',
          'items': [
            {'text': 'alpha task', 'completed': true},
            {'text': 'beta task', 'completed': false},
            {'text': 'gamma task', 'completed': false},
          ],
        },
      );
    });

    test('maps todo reminder events', () {
      expect(
        mapOmpTodoReminderEvent(const {
          'type': 'todo_reminder',
          'todos': [
            {'content': 'beta task', 'status': 'in_progress'},
            {'content': 'gamma task', 'status': 'pending'},
          ],
        }, id: 'todo-3')!.toJson(),
        {
          'id': 'todo-3',
          'kind': 'todo',
          'items': [
            {'text': 'beta task', 'completed': false},
            {'text': 'gamma task', 'completed': false},
          ],
        },
      );
    });

    test('hydrates current todos from session state', () {
      final items = mapOmpTodoState(
        const OmpSessionState(todoPhases: _todoPhasesJson),
        id: 'todo-4',
      );

      expect(items.map((item) => item.toJson()).toList(), [
        {
          'id': 'todo-4',
          'kind': 'todo',
          'items': [
            {'text': 'alpha task', 'completed': true},
            {'text': 'beta task', 'completed': false},
            {'text': 'gamma task', 'completed': false},
          ],
        },
      ]);
    });

    test('drops malformed todo inputs', () {
      expect(
        mapOmpTodoReminderEvent(const {
          'type': 'todo_reminder',
          'todos': [
            {'content': 1},
          ],
        }, id: 'todo-5'),
        isNull,
      );
      expect(
        mapOmpTodoToolResult(const {
          'details': {
            'phases': [
              {
                'name': 'Bad',
                'tasks': <Object?>[{}],
              },
            ],
          },
        }, id: 'todo-6'),
        isNull,
      );
    });

    test('flattens multiple phases in order and drops phase names', () {
      expect(
        mapOmpTodoPhases(const [
          OmpTodoPhase(
            name: 'Phase A',
            tasks: [
              OmpTodoItem(content: 'a1', status: OmpTodoStatus.completed),
            ],
          ),
          OmpTodoPhase(
            name: 'Phase B',
            tasks: [
              OmpTodoItem(content: 'b1', status: OmpTodoStatus.pending),
              OmpTodoItem(content: 'b2', status: OmpTodoStatus.abandoned),
            ],
          ),
        ], id: 'todo-7')!.toJson(),
        {
          'id': 'todo-7',
          'kind': 'todo',
          'items': [
            {'text': 'a1', 'completed': true},
            {'text': 'b1', 'completed': false},
            {'text': 'b2', 'completed': false},
          ],
        },
      );
    });

    test('an abandoned task is accepted but never counts as completed', () {
      expect(
        mapOmpTodoReminderEvent(const {
          'type': 'todo_reminder',
          'todos': [
            {'content': 'dropped', 'status': 'abandoned'},
          ],
        }, id: 'todo-8')!.toJson(),
        {
          'id': 'todo-8',
          'kind': 'todo',
          'items': [
            {'text': 'dropped', 'completed': false},
          ],
        },
      );
    });

    test('emits nothing for empty phase and task lists', () {
      expect(mapOmpTodoPhases(const [], id: 'todo-9'), isNull);
      expect(
        mapOmpTodoPhases(const [
          OmpTodoPhase(name: 'Empty', tasks: []),
        ], id: 'todo-10'),
        isNull,
      );
      expect(
        mapOmpTodoState(
          const OmpSessionState(todoPhases: <Object?>[]),
          id: 'todo-11',
        ),
        isEmpty,
      );
      expect(
        mapOmpTodoReminderEvent(const {
          'type': 'todo_reminder',
          'todos': <Object?>[],
        }, id: 'todo-12'),
        isNull,
      );
    });

    test('drops results that carry no usable details', () {
      const id = 'todo-13';
      expect(mapOmpTodoToolResult(null, id: id), isNull);
      expect(mapOmpTodoToolResult('phases', id: id), isNull);
      expect(mapOmpTodoToolResult(7, id: id), isNull);
      expect(mapOmpTodoToolResult(const {}, id: id), isNull);
      expect(mapOmpTodoToolResult(const {'details': 'nope'}, id: id), isNull);
      expect(mapOmpTodoToolResult(const {'details': {}}, id: id), isNull);
      expect(
        mapOmpTodoToolResult(const {
          'details': {'phases': 'nope'},
        }, id: id),
        isNull,
      );
    });

    test('rejects reminder events that are not reminder events', () {
      const id = 'todo-14';
      expect(mapOmpTodoReminderEvent(null, id: id), isNull);
      expect(mapOmpTodoReminderEvent('todo_reminder', id: id), isNull);
      expect(mapOmpTodoReminderEvent(const {'type': 'notice'}, id: id), isNull);
      expect(
        mapOmpTodoReminderEvent(const {'type': 'todo_reminder'}, id: id),
        isNull,
      );
      expect(
        mapOmpTodoReminderEvent(const {
          'type': 'todo_reminder',
          'todos': [
            {'content': 'ok', 'status': 'nope'},
          ],
        }, id: id),
        isNull,
      );
    });

    test('one malformed phase rejects the whole session-state list', () {
      expect(
        mapOmpTodoState(
          const OmpSessionState(
            todoPhases: [
              {
                'name': 'Good',
                'tasks': [
                  {'content': 'a', 'status': 'pending'},
                ],
              },
              {'name': 'Bad'},
            ],
          ),
          id: 'todo-15',
        ),
        isEmpty,
      );
      expect(
        mapOmpTodoState(
          const OmpSessionState(todoPhases: 'phases'),
          id: 'todo-16',
        ),
        isEmpty,
      );
      expect(mapOmpTodoState(const OmpSessionState(), id: 'todo-17'), isEmpty);
    });

    test('parseOmpToolResult mirrors the upstream result schema', () {
      expect(parseOmpToolResult('text'), 'text');
      expect(parseOmpToolResult(null), isNull);
      expect(parseOmpToolResult(7), isNull);
      expect(parseOmpToolResult(const []), isNull);

      // Unknown keys pass through untouched (`.passthrough()`).
      expect(parseOmpToolResult(const {'weird': true}), const {'weird': true});
      expect(
        parseOmpToolResult(const {
          'output': 'ok',
          'exitCode': 0,
          'content': [
            {'type': 'text', 'text': 'hi'},
            {'type': 'image', 'data': 'x'},
          ],
          'details': {'diff': 'd'},
        }),
        isA<Map<String, Object?>>(),
      );

      expect(parseOmpToolResult(const {'output': 1}), isNull);
      expect(parseOmpToolResult(const {'output': null}), isNull);
      expect(parseOmpToolResult(const {'exitCode': 'zero'}), isNull);
      expect(parseOmpToolResult(const {'details': 'nope'}), isNull);
      expect(parseOmpToolResult(const {'content': 'nope'}), isNull);
      expect(
        parseOmpToolResult(const {
          'content': <Object?>[{}],
        }),
        isNull,
      );
      expect(
        parseOmpToolResult(const {
          'content': [
            {'type': 'text'},
          ],
        }),
        isNull,
      );
    });

    test('a result rejected on an unrelated field yields no todo item', () {
      const malformed = {
        'content': 'not-an-array',
        'details': {'phases': _todoPhasesJson},
      };

      // Read raw the mapper would happily project it...
      expect(mapOmpTodoToolResult(malformed, id: 'todo-18'), isNotNull);
      // ...but upstream validates first, and validation rejects the whole
      // result, so nothing is emitted.
      expect(
        mapOmpTodoToolResult(parseOmpToolResult(malformed), id: 'todo-18'),
        isNull,
      );
    });

    test('OmpTodoStatus.fromWire covers the union and nothing else', () {
      expect(OmpTodoStatus.fromWire('pending'), OmpTodoStatus.pending);
      expect(OmpTodoStatus.fromWire('in_progress'), OmpTodoStatus.inProgress);
      expect(OmpTodoStatus.fromWire('completed'), OmpTodoStatus.completed);
      expect(OmpTodoStatus.fromWire('abandoned'), OmpTodoStatus.abandoned);
      expect(OmpTodoStatus.fromWire('inProgress'), isNull);
      expect(OmpTodoStatus.fromWire(null), isNull);
      expect(OmpTodoStatus.fromWire(1), isNull);
    });

    test('phase objects survive parsing with their names intact', () {
      final phases = parseOmpTodoPhases(_todoPhasesJson)!;
      expect(phases.single.name, 'Tasks');
      expect(phases.single.tasks.map((task) => task.content), [
        'alpha task',
        'beta task',
        'gamma task',
      ]);
      expect(_todoPhases.single.tasks.length, 3);
    });
  });

  group('OMP slash command mapper', () {
    test('maps command updates and preserves input hints', () {
      final commands = mapOmpAvailableCommandsUpdate(const {
        'type': 'available_commands_update',
        'commands': [
          {
            'name': 'todo',
            'description': 'Manage todos',
            'input': {'hint': '<subcommand>'},
          },
          {
            'name': 'fast',
            'description': 'Toggle fast mode',
            'input': {'hint': '[on|off|status]'},
          },
          {'name': 'handoff', 'description': 'Start a handoff'},
        ],
      });

      expect(_byName(commands!, 'todo'), {
        'name': 'todo',
        'description': 'Manage todos',
        'argumentHint': '<subcommand>',
        'kind': 'command',
      });
      expect(_byName(commands, 'fast'), {
        'name': 'fast',
        'description': 'Toggle fast mode',
        'argumentHint': '[on|off|status]',
        'kind': 'command',
      });
      expect(_byName(commands, 'handoff'), {
        'name': 'handoff',
        'description': 'Start a handoff',
        'argumentHint': '[instructions]',
        'kind': 'command',
      });
    });

    test('maps source-attributed OMP 17 commands', () {
      final commands = mapOmpAvailableCommandsUpdate(const {
        'type': 'available_commands_update',
        'commands': [
          {
            'name': 'prewalk',
            'description': 'Prewalk at the next action',
            'source': 'builtin',
          },
        ],
      });

      expect(_byName(commands!, 'prewalk'), {
        'name': 'prewalk',
        'description': 'Prewalk at the next action',
        'argumentHint': '',
        'kind': 'command',
      });
    });

    test('drops malformed command updates', () {
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': <Object?>[{}],
        }),
        isNull,
      );
      expect(mapOmpAvailableCommandsUpdate(null), isNull);
      expect(mapOmpAvailableCommandsUpdate('update'), isNull);
      expect(mapOmpAvailableCommandsUpdate(const {'type': 'notice'}), isNull);
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
        }),
        isNull,
      );
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': 'nope',
        }),
        isNull,
      );
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': [
            {'name': 'ok'},
            {'name': 7},
          ],
        }),
        isNull,
      );
      // `description` / `source` are `.optional()`, so an explicit null is a
      // schema violation even though an absent key is fine.
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': [
            {'name': 'ok', 'description': null},
          ],
        }),
        isNull,
      );
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': [
            {'name': 'ok', 'input': 'hint'},
          ],
        }),
        isNull,
      );
      expect(
        mapOmpAvailableCommandsUpdate(const {
          'type': 'available_commands_update',
          'commands': [
            {
              'name': 'ok',
              'input': {'hint': 7},
            },
          ],
        }),
        isNull,
      );
    });

    test('accepts an explicitly null input, which is nullable upstream', () {
      final commands = mapOmpAvailableCommandsUpdate(const {
        'type': 'available_commands_update',
        'commands': [
          {'name': 'plain', 'description': 'No hint', 'input': null},
        ],
      });

      expect(_byName(commands!, 'plain'), {
        'name': 'plain',
        'description': 'No hint',
        'argumentHint': '',
        'kind': 'command',
      });
    });

    test('adds OMP-only out-of-band commands to handled built-ins', () {
      expect(mapOmpSlashCommands(const []).map((command) => command.name), [
        'compact',
        'autocompact',
        'handoff',
        'steer',
        'follow-up',
      ]);
      expect(
        _json(mapOmpSlashCommands(const [])),
        _json(ompHandledBuiltinSlashCommands),
      );
    });

    test('overrides keep built-in menu position, new commands append', () {
      final commands = mapOmpSlashCommands(const [
        OmpAvailableCommand(name: 'zeta', description: 'Zeta'),
        OmpAvailableCommand(name: 'steer', description: 'Custom steer'),
        OmpAvailableCommand(name: 'alpha', description: 'Alpha'),
      ]);

      expect(commands.map((command) => command.name), [
        'compact',
        'autocompact',
        'handoff',
        'steer',
        'follow-up',
        'zeta',
        'alpha',
      ]);
      expect(_byName(commands, 'steer'), {
        'name': 'steer',
        'description': 'Custom steer',
        // Inherited from the built-in it overrode.
        'argumentHint': '<message>',
        'kind': 'command',
      });
    });

    test('falls back description to source, then to the literal command', () {
      final commands = mapOmpSlashCommands(const [
        OmpAvailableCommand(name: 'sourced', source: 'plugin'),
        OmpAvailableCommand(name: 'bare'),
        OmpAvailableCommand(name: 'blank', description: ''),
      ]);

      expect(_byName(commands, 'sourced')!['description'], 'plugin');
      expect(_byName(commands, 'bare')!['description'], 'command');
      // The event path keeps an empty description; only the RPC path drops it.
      expect(_byName(commands, 'blank')!['description'], '');
    });

    test('tags skill-sourced commands as skills', () {
      final commands = mapOmpSlashCommands(const [
        OmpAvailableCommand(name: 'diagnose', source: 'skill'),
        OmpAvailableCommand(name: 'prewalk', source: 'builtin'),
      ]);

      expect(_byName(commands, 'diagnose'), {
        'name': 'diagnose',
        'description': 'skill',
        'argumentHint': '',
        'kind': 'skill',
      });
      expect(_byName(commands, 'prewalk')!['kind'], 'command');
    });

    test(
      'runtime commands drop an empty description, unlike the event path',
      () {
        final commands = mapOmpRuntimeSlashCommands(const [
          OmpRpcSlashCommand(name: 'blank', description: '', source: 'plugin'),
          OmpRpcSlashCommand(
            name: 'hinted',
            description: 'Hinted',
            input: OmpCommandInput(hint: '<arg>'),
          ),
          OmpRpcSlashCommand(name: 'skilled', source: 'skill'),
        ]);

        expect(_byName(commands, 'blank')!['description'], 'plugin');
        expect(_byName(commands, 'hinted'), {
          'name': 'hinted',
          'description': 'Hinted',
          'argumentHint': '<arg>',
          'kind': 'command',
        });
        expect(_byName(commands, 'skilled')!['kind'], 'skill');
      },
    );

    test('runtime commands still seed the handled built-ins', () {
      expect(
        mapOmpRuntimeSlashCommands(const []).map((command) => command.name),
        ['compact', 'autocompact', 'handoff', 'steer', 'follow-up'],
      );
    });

    test('a null hint falls back to the built-in hint then to empty', () {
      final commands = mapOmpSlashCommands(const [
        OmpAvailableCommand(
          name: 'handoff',
          description: 'Overridden',
          input: OmpCommandInput(),
        ),
        OmpAvailableCommand(
          name: 'fresh',
          description: 'Fresh',
          input: OmpCommandInput(),
        ),
      ]);

      expect(_byName(commands, 'handoff')!['argumentHint'], '[instructions]');
      expect(_byName(commands, 'fresh')!['argumentHint'], '');
    });
  });

  group('OpenCode rewind', () {
    test(
      'rewinds conversation and files to the OpenCode user message',
      () async {
        final opencode = _FakeOpenCodeClient();

        await revertOpenCodeConversationAndFiles(
          client: opencode,
          sessionId: 'session-1',
          cwd: '/workspace/project',
          messageId: 'user-message-1',
        );

        expect(opencode.recordedReverts, [
          {
            'sessionID': 'session-1',
            'directory': '/workspace/project',
            'messageID': 'user-message-1',
          },
        ]);
      },
    );

    test('surfaces OpenCode revert errors', () async {
      final opencode = _FakeOpenCodeClient();
      opencode.revertResponse = const OpenCodeRevertResponse(
        error: {'name': 'NotFoundError', 'message': 'missing message'},
      );

      await expectLater(
        revertOpenCodeConversationAndFiles(
          client: opencode,
          sessionId: 'session-1',
          cwd: '/workspace/project',
          messageId: 'missing-message',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('missing message'),
          ),
        ),
      );
      expect(opencode.recordedReverts, [
        {
          'sessionID': 'session-1',
          'directory': '/workspace/project',
          'messageID': 'missing-message',
        },
      ]);
    });

    test('surfaces a plain string error verbatim', () async {
      final opencode = _FakeOpenCodeClient();
      opencode.revertResponse = const OpenCodeRevertResponse(
        error: '  revert failed  ',
      );

      await expectLater(
        revertOpenCodeConversationAndFiles(
          client: opencode,
          sessionId: 's',
          cwd: '/w',
          messageId: 'm',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'revert failed',
          ),
        ),
      );
    });

    test('treats JS-falsy error payloads as success', () async {
      for (final error in <Object?>[null, false, 0, '']) {
        final opencode = _FakeOpenCodeClient();
        opencode.revertResponse = OpenCodeRevertResponse(error: error);

        await revertOpenCodeConversationAndFiles(
          client: opencode,
          sessionId: 's',
          cwd: '/w',
          messageId: 'm',
        );
        expect(opencode.recordedReverts, hasLength(1));
      }
    });

    test('diagnostic messages degrade gracefully', () {
      expect(toProviderDiagnosticErrorMessage(null), 'Unknown error');
      expect(toProviderDiagnosticErrorMessage('   '), 'Unknown error');
      expect(toProviderDiagnosticErrorMessage(const {}), '{}');
      expect(toProviderDiagnosticErrorMessage(42), '42');
      expect(
        toProviderDiagnosticErrorMessage(StateError('boom')),
        contains('boom'),
      );
      expect(
        toProviderDiagnosticErrorMessage(const {'message': 'nope'}),
        '{"message":"nope"}',
      );
      // Not JSON-encodable: falls through to `toString()`.
      expect(toProviderDiagnosticErrorMessage(#symbol), contains('symbol'));
    });
  });

  group('provider tool-call status normalization', () {
    test('an error outranks every status word', () {
      for (final status in const [
        'completed',
        'running',
        'aborted',
        null,
        '',
      ]) {
        expect(
          normalizeProviderToolCallStatus(status, 'boom', 'output'),
          NormalizedToolCallStatus.failed,
        );
      }
    });

    test('recognises each status vocabulary', () {
      for (final status in const [
        'failed',
        'failure',
        'error',
        'errored',
        'rejected',
        'denied',
      ]) {
        expect(
          normalizeProviderToolCallStatus(status, null, null),
          NormalizedToolCallStatus.failed,
        );
      }
      for (final status in const [
        'canceled',
        'cancelled',
        'interrupted',
        'aborted',
      ]) {
        expect(
          normalizeProviderToolCallStatus(status, null, null),
          NormalizedToolCallStatus.canceled,
        );
      }
      for (final status in const [
        'completed',
        'complete',
        'done',
        'success',
        'succeeded',
      ]) {
        expect(
          normalizeProviderToolCallStatus(status, null, null),
          NormalizedToolCallStatus.completed,
        );
      }
    });

    test('is case- and whitespace-insensitive', () {
      expect(
        normalizeProviderToolCallStatus('  COMPLETE  ', null, null),
        NormalizedToolCallStatus.completed,
      );
    });

    test('an unknown status word means still running, never done', () {
      expect(
        normalizeProviderToolCallStatus('queued', null, 'output'),
        NormalizedToolCallStatus.running,
      );
    });

    test('falls back to output presence when no status word is usable', () {
      expect(
        normalizeProviderToolCallStatus(null, null, 'output'),
        NormalizedToolCallStatus.completed,
      );
      expect(
        normalizeProviderToolCallStatus('   ', null, 'output'),
        NormalizedToolCallStatus.completed,
      );
      expect(
        normalizeProviderToolCallStatus(null, null, null),
        NormalizedToolCallStatus.running,
      );
      // Falsy-but-present output still counts as output.
      expect(
        normalizeProviderToolCallStatus(null, null, ''),
        NormalizedToolCallStatus.completed,
      );
    });

    test('projects onto the protocol timeline statuses', () {
      expect(
        NormalizedToolCallStatus.running.toolCallStatus,
        ToolCallStatus.running,
      );
      expect(
        NormalizedToolCallStatus.completed.toolCallStatus,
        ToolCallStatus.success,
      );
      expect(
        NormalizedToolCallStatus.failed.toolCallStatus,
        ToolCallStatus.error,
      );
      expect(
        NormalizedToolCallStatus.canceled.toolCallStatus,
        ToolCallStatus.canceled,
      );
    });
  });

  group('opencode tool-call mapper', () {
    test('maps running shell calls', () {
      final item = mapOpencodeToolCall(
        toolName: 'shell',
        callId: 'opencode-call-1',
        status: 'running',
        input: const {'command': 'pwd', 'cwd': '/tmp/repo'},
        output: null,
      )!;

      expect(item.status, ToolCallStatus.running);
      expect(item.errorMessage, isNull);
      expect(item.id, 'opencode-call-1');
      expect(item.toolName, 'shell');
    });

    test('maps completed read calls', () {
      final item = mapOpencodeToolCall(
        toolName: 'read_file',
        callId: 'opencode-call-2',
        status: 'complete',
        input: const {'file_path': 'README.md'},
        output: const {'content': 'hello'},
      )!;

      expect(item.status, ToolCallStatus.success);
      expect(item.errorMessage, isNull);
      expect(item.id, 'opencode-call-2');
    });

    test('maps failed calls with required error', () {
      final item = mapOpencodeToolCall(
        toolName: 'shell',
        callId: 'opencode-call-3',
        status: 'error',
        input: const {'command': 'false'},
        output: null,
        error: 'command failed',
      )!;

      expect(item.status, ToolCallStatus.error);
      expect(item.errorMessage, 'command failed');
      expect(item.id, 'opencode-call-3');
    });

    test('maps aborted calls carrying an error as failed', () {
      final item = mapOpencodeToolCall(
        toolName: 'task',
        callId: 'opencode-task-aborted',
        status: 'aborted',
        input: const {'subagent_type': 'explore'},
        output: null,
        error: 'Tool execution aborted',
      )!;

      expect(item.status, ToolCallStatus.error);
      expect(item.errorMessage, 'Tool execution aborted');
    });

    test('maps aborted calls without an error as canceled', () {
      final item = mapOpencodeToolCall(
        toolName: 'task',
        callId: 'opencode-task-canceled',
        status: 'aborted',
      )!;

      expect(item.status, ToolCallStatus.canceled);
      expect(item.errorMessage, isNull);
    });

    test('supplies a default message for a failure with no error payload', () {
      final item = mapOpencodeToolCall(
        toolName: 'shell',
        callId: 'opencode-call-default-error',
        status: 'failed',
      )!;

      expect(item.status, ToolCallStatus.error);
      expect(item.errorMessage, 'Tool call failed');
    });

    test('flattens a structured error payload into a message', () {
      final item = mapOpencodeToolCall(
        toolName: 'shell',
        callId: 'opencode-call-structured-error',
        status: 'error',
        error: const {'name': 'ExitError', 'message': 'exit 1'},
      )!;

      expect(item.errorMessage, '{"name":"ExitError","message":"exit 1"}');
    });

    test('maps unknown tools to unknown detail with raw payloads', () {
      final item = mapOpencodeToolCall(
        toolName: 'my_custom_tool',
        callId: 'opencode-call-4',
        status: 'completed',
        input: const {'foo': 'bar'},
        output: const {'ok': true},
      )!;

      expect(item.status, ToolCallStatus.success);
      expect(item.errorMessage, isNull);
      expect(item.detail.toPaseoJson(), {
        'type': 'unknown',
        'input': {'foo': 'bar'},
        'output': {'ok': true},
      });
    });

    test('does not apply cross-provider speak normalization', () {
      final item = mapOpencodeToolCall(
        toolName: 'paseo_voice.speak',
        callId: 'opencode-call-voice-1',
        status: 'completed',
        input: const {'text': 'Voice response from OpenCode.'},
        output: const {'ok': true},
      )!;

      expect(item.toolName, 'paseo_voice.speak');
      expect(item.detail.toPaseoJson(), {
        'type': 'unknown',
        'input': {'text': 'Voice response from OpenCode.'},
        'output': {'ok': true},
      });
    });

    test('wraps a non-map input in the protocol unknown-detail envelope', () {
      final item = mapOpencodeToolCall(
        toolName: 'weird',
        callId: 'opencode-call-5',
        status: 'completed',
        input: 'raw text',
        output: null,
      )!;

      expect(item.detail.toPaseoJson(), {
        'type': 'unknown',
        'input': {'value': 'raw text'},
        'output': null,
      });
    });

    test('drops tool calls when callId is missing', () {
      expect(
        mapOpencodeToolCall(
          toolName: 'read_file',
          callId: null,
          status: 'completed',
          input: const {'file_path': 'README.md'},
          output: const {'content': 'hello'},
        ),
        isNull,
      );
      expect(mapOpencodeToolCall(toolName: 'read_file', callId: '   '), isNull);
      expect(mapOpencodeToolCall(toolName: 'read_file', callId: ''), isNull);
    });

    test('drops tool calls with an empty tool name', () {
      expect(mapOpencodeToolCall(toolName: '', callId: 'c-1'), isNull);
    });

    test('trims the call id and the tool name', () {
      final item = mapOpencodeToolCall(
        toolName: '  shell  ',
        callId: '  opencode-call-6  ',
      )!;

      expect(item.id, 'opencode-call-6');
      expect(item.toolName, 'shell');
    });

    test('ignores a non-string status and judges by output presence', () {
      expect(
        mapOpencodeToolCall(
          toolName: 'shell',
          callId: 'c-2',
          status: 7,
          output: const {'ok': true},
        )!.status,
        ToolCallStatus.success,
      );
      expect(
        mapOpencodeToolCall(
          toolName: 'shell',
          callId: 'c-3',
          status: 7,
        )!.status,
        ToolCallStatus.running,
      );
    });

    test('passes metadata through only when present', () {
      expect(
        mapOpencodeToolCall(
          toolName: 'shell',
          callId: 'c-4',
          metadata: const {'sessionID': 'ses_1'},
        )!.metadata,
        {'sessionID': 'ses_1'},
      );
      expect(
        mapOpencodeToolCall(toolName: 'shell', callId: 'c-5')!.metadata,
        isEmpty,
      );
      expect(
        mapOpencodeToolCall(
          toolName: 'shell',
          callId: 'c-6',
          status: 'error',
          error: 'boom',
          metadata: const {'sessionID': 'ses_2'},
        )!.metadata,
        {'sessionID': 'ses_2'},
      );
    });

    test(
      'forwards the trimmed name and raw payloads to the detail deriver',
      () {
        final calls = <List<Object?>>[];
        final item = mapOpencodeToolCall(
          toolName: '  read  ',
          callId: 'c-7',
          status: 'completed',
          input: const {'filePath': 'README.md'},
          output: 'file body',
          error: null,
          deriveDetail: (toolName, input, output, error) {
            calls.add([toolName, input, output, error]);
            return const ReadDetail(path: 'README.md', content: 'file body');
          },
        )!;

        expect(calls, [
          [
            'read',
            {'filePath': 'README.md'},
            'file body',
            null,
          ],
        ]);
        expect(item.detail.toPaseoJson(), {
          'type': 'read',
          'filePath': 'README.md',
          'content': 'file body',
        });
      },
    );

    test('the deriver still runs for failed calls and sees the error', () {
      Object? seenError;
      final item = mapOpencodeToolCall(
        toolName: 'task',
        callId: 'c-8',
        status: 'aborted',
        error: 'Tool execution aborted',
        deriveDetail: (toolName, input, output, error) {
          seenError = error;
          return const SubAgentDetail(
            subAgentType: 'explore',
            log: 'Tool execution aborted',
          );
        },
      )!;

      expect(seenError, 'Tool execution aborted');
      expect(item.status, ToolCallStatus.error);
      expect(item.detail.toPaseoJson(), {
        'type': 'sub_agent',
        'subAgentType': 'explore',
        'log': 'Tool execution aborted',
      });
    });
  });
}
