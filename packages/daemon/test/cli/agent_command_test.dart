import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:test/test.dart';

void main() {
  test('help, nested commands, and top-level aliases are exposed', () async {
    for (final arguments in const [
      ['--help'],
      ['ls', '--help'],
      ['inspect', '--help'],
      ['mode', '--help'],
      ['stop', '--help'],
    ]) {
      final output = StringBuffer();
      expect(
        await runAgentCommand(arguments: arguments, writeOutput: output.write),
        0,
      );
      expect(output.toString(), contains('Usage: coding-agent agent'));
    }

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    for (final arguments in const [
      ['agent', 'ls', '--help'],
      ['agent', 'inspect', '--help'],
      ['agent', 'mode', '--help'],
      ['agent', 'stop', '--help'],
      ['ls', '--help'],
      ['inspect', '--help'],
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'agent_daemon:coding_agent',
        ...arguments,
      ], workingDirectory: packageRoot);
      expect(result.exitCode, 0, reason: '$arguments');
      expect(result.stdout, contains('Usage: coding-agent agent'));
      expect(result.stderr, isEmpty);
    }
  });

  test('ls builds frozen active-scope filter combinations', () async {
    Future<Map<String, Object?>> capture(
      List<String> arguments,
      Map<String, Object?> expected,
    ) async {
      Map<String, Object?>? sent;
      expect(
        await runAgentCommand(
          arguments: arguments,
          request: (message) async {
            sent = message;
            return _listPayload([]);
          },
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent, expected);
      return sent!;
    }

    await capture(
      ['ls'],
      {
        'type': 'fetch_agents_request',
        'requestId': isA<String>(),
        'scope': 'active',
      },
    );
    await capture(
      ['ls', '-a'],
      {
        'type': 'fetch_agents_request',
        'requestId': isA<String>(),
        'scope': 'active',
        'filter': {'includeArchived': true},
      },
    );
    await capture(
      ['ls', '-g'],
      {'type': 'fetch_agents_request', 'requestId': isA<String>()},
    );
    await capture(
      [
        'ls',
        '-ag',
        '--label',
        'surface=workspace',
        '--label',
        'owner=a=b',
        '--label',
        'ignored',
        '--thinking',
        ' medium ',
      ],
      {
        'type': 'fetch_agents_request',
        'requestId': isA<String>(),
        'filter': {
          'labels': {'surface': 'workspace', 'owner': 'a=b'},
          'includeArchived': true,
          'thinkingOptionId': 'medium',
        },
      },
    );
  });

  test('ls filters, sorts, and renders frozen display fields', () async {
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['ls', '--label', 'surface=workspace', '--json'],
        environment: const {'HOME': r'C:\Users\tester'},
        now: () => DateTime.parse('2026-07-29T12:00:00Z'),
        request: (_) async => _listPayload([
          _entry(
            _snapshot(
              id: 'error-newest',
              title: null,
              status: 'error',
              createdAt: '2026-07-29T11:59:30Z',
              labels: const {'surface': 'workspace'},
            ),
          ),
          _entry(
            _snapshot(
              id: 'idle-older',
              status: 'idle',
              createdAt: '2026-07-29T10:00:00Z',
              model: 'ignored',
              runtimeModel: ' default ',
              labels: const {'surface': 'workspace'},
            ),
          ),
          _entry(
            _snapshot(
              id: 'running-newer',
              status: 'running',
              createdAt: '2026-07-29T11:30:00Z',
              runtimeModel: ' gpt-5.4 ',
              thinking: 'high',
              cwd: r'C:\Users\tester\repo',
              labels: const {'surface': 'workspace'},
            ),
          ),
          _entry(
            _snapshot(
              id: 'running-old',
              status: 'running',
              createdAt: '2026-07-28T12:00:00Z',
              labels: const {'surface': 'workspace'},
            ),
          ),
          _entry(
            _snapshot(
              id: 'archived-hidden',
              status: 'closed',
              createdAt: '2026-07-29T11:59:59Z',
              archivedAt: '2026-07-29T12:00:00Z',
              labels: const {'surface': 'workspace'},
            ),
          ),
          _entry(
            _snapshot(
              id: 'other-label',
              status: 'running',
              createdAt: '2026-07-29T11:59:59Z',
              labels: const {'surface': 'other'},
            ),
          ),
        ]),
        writeOutput: output.write,
      ),
      0,
    );
    final rows = (jsonDecode(output.toString()) as List).cast<Map>();
    expect(rows.map((row) => row['id']), [
      'running-newer',
      'running-old',
      'idle-older',
      'error-newest',
    ]);
    expect(rows.first, {
      'id': 'running-newer',
      'shortId': 'running',
      'name': 'Agent',
      'provider': 'codex/gpt-5.4',
      'thinking': 'high',
      'status': 'running',
      'cwd': r'~\repo',
      'created': '30 minutes ago',
    });
    expect(rows[2]['provider'], 'codex/ignored');
    expect(rows[3]['name'], '-');
    expect(rows[3]['created'], 'just now');
    expect(rows[1]['created'], '1 days ago');
  });

  test(
    'ls supports table yaml quiet and explicit archived inclusion',
    () async {
      Future<Map<String, Object?>> request(_) async => _listPayload([
        _entry(
          _snapshot(
            id: 'agent-123456',
            archivedAt: '2026-07-29T00:00:00Z',
            status: 'closed',
          ),
        ),
      ]);

      final hidden = StringBuffer();
      await runAgentCommand(
        arguments: const ['ls', '--no-headers'],
        request: request,
        writeOutput: hidden.write,
      );
      expect(hidden, isEmpty);

      final table = StringBuffer();
      await runAgentCommand(
        arguments: const ['ls', '--all'],
        request: request,
        writeOutput: table.write,
      );
      expect(table.toString(), contains('AGENT ID'));
      expect(table.toString(), contains('agent-1'));

      final yaml = StringBuffer();
      await runAgentCommand(
        arguments: const ['ls', '--all', '--format', 'yaml'],
        request: request,
        writeOutput: yaml.write,
      );
      expect(yaml.toString(), startsWith('- id: agent-123456'));

      final quiet = StringBuffer();
      await runAgentCommand(
        arguments: const ['ls', '--all', '--quiet'],
        request: request,
        writeOutput: quiet.write,
      );
      expect(quiet.toString(), 'agent-1\n');
    },
  );

  test(
    'inspect sends prefix and renders complete structured snapshot',
    () async {
      Map<String, Object?>? sent;
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['inspect', 'agent-pre', '--json'],
          request: (message) async {
            sent = message;
            return {
              'requestId': message['requestId'],
              'agent': _snapshot(
                id: 'agent-precise',
                title: 'Detailed',
                status: 'running',
                model: 'fallback',
                runtimeModel: 'gpt-5.4',
                thinking: 'xhigh',
                currentModeId: 'full-access',
                archivedAt: '2026-07-29T13:00:00Z',
                labels: const {
                  'paseo.worktree': 'gentle-otter',
                  'paseo.parent-agent-id': 'parent-1',
                },
                lastUsage: const {
                  'inputTokens': 10,
                  'outputTokens': 20,
                  'cachedInputTokens': 5,
                  'totalCostUsd': 0.0042,
                },
                capabilities: const {
                  'supportsStreaming': true,
                  'supportsSessionPersistence': true,
                  'supportsDynamicModes': false,
                  'supportsMcpServers': true,
                },
                availableModes: const [
                  {'id': 'plan', 'label': 'Plan'},
                  {'id': 'full-access', 'label': 'Full access'},
                ],
                pendingPermissions: const [
                  {'id': 'permission-1', 'name': 'Bash'},
                  {'id': 'permission-2', 'name': null},
                ],
              ),
              'project': null,
              'error': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent?['type'], 'fetch_agent_request');
      expect(sent?['agentId'], 'agent-pre');
      final data = jsonDecode(output.toString()) as Map<String, dynamic>;
      expect(data['Id'], 'agent-precise');
      expect(data['Model'], 'gpt-5.4');
      expect(data['Archived'], isTrue);
      expect(data['LastUsage'], {
        'InputTokens': 10,
        'OutputTokens': 20,
        'CachedTokens': 5,
        'CostUsd': 0.0042,
      });
      expect(data['Capabilities']['McpServers'], isTrue);
      expect(data['AvailableModes'], [
        {'id': 'plan', 'label': 'Plan'},
        {'id': 'full-access', 'label': 'Full access'},
      ]);
      expect(data['PendingPermissions'], [
        {'id': 'permission-1', 'tool': 'Bash'},
        {'id': 'permission-2', 'tool': 'unknown'},
      ]);
      expect(data['Worktree'], 'gentle-otter');
      expect(data['ParentAgentId'], 'parent-1');
    },
  );

  test('inspect table formats nested fields and path', () async {
    final output = StringBuffer();
    await runAgentCommand(
      arguments: const ['inspect', 'agent'],
      environment: const {'HOME': '/home/tester'},
      request: (message) async => {
        'requestId': message['requestId'],
        'agent': _snapshot(
          id: 'agent',
          cwd: '/home/tester/repo',
          lastUsage: const {'totalCostUsd': 1.25},
          capabilities: const {},
          availableModes: const [],
          pendingPermissions: const [],
        ),
        'project': null,
        'error': null,
      },
      writeOutput: output.write,
    );
    expect(output.toString(), contains('Cwd'));
    expect(output.toString(), contains('~/repo'));
    expect(output.toString(), contains(r'CostUsd: $1.25'));
    expect(output.toString(), contains('PendingPermissions'));
    expect(output.toString(), contains('[]'));
    expect(output.toString(), contains('ParentAgentId'));
  });

  test(
    'inspect not-found and transport failures preserve stable errors',
    () async {
      final notFound = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['inspect', 'missing', '--json'],
          request: (message) async => {
            'requestId': message['requestId'],
            'agent': null,
            'project': null,
            'error': null,
          },
          writeError: notFound.write,
        ),
        1,
      );
      final missing = jsonDecode(notFound.toString()) as Map<String, dynamic>;
      expect(missing['error']['code'], 'AGENT_NOT_FOUND');
      expect(missing['error']['details'], contains('coding-agent ls'));

      final serverError = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['inspect', 'ambiguous', '--json'],
          request: (message) async => {
            'requestId': message['requestId'],
            'agent': null,
            'project': null,
            'error': 'Agent identifier is ambiguous',
          },
          writeError: serverError.write,
        ),
        1,
      );
      final ambiguous =
          jsonDecode(serverError.toString()) as Map<String, dynamic>;
      expect(ambiguous['error']['code'], 'INSPECT_FAILED');
      expect(ambiguous['error']['message'], contains('ambiguous'));

      final failed = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['inspect', 'agent', '--format', 'yaml'],
          request: (_) async => throw StateError('socket closed'),
          writeError: failed.write,
        ),
        1,
      );
      expect(failed.toString(), contains('code: INSPECT_FAILED'));
      expect(failed.toString(), contains('socket closed'));
    },
  );

  test(
    'mode --list resolves the agent and renders the frozen catalog',
    () async {
      Map<String, Object?>? sent;
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const [
            'mode',
            '--list',
            'agent-pre',
            '--json',
            '--format',
            'yaml',
          ],
          request: (message) async {
            sent = message;
            return {
              'requestId': message['requestId'],
              'agent': _snapshot(
                id: 'agent-precise',
                currentModeId: 'plan',
                availableModes: const [
                  {
                    'id': 'plan',
                    'label': 'Plan',
                    'description': 'Plan before editing',
                  },
                  {'id': 'full-access', 'label': 'Full access'},
                ],
              ),
              'project': null,
              'error': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent, {
        'type': 'fetch_agent_request',
        'requestId': isA<String>(),
        'agentId': 'agent-pre',
      });
      expect(jsonDecode(output.toString()), [
        {'id': 'plan', 'label': 'Plan', 'description': 'Plan before editing'},
        {'id': 'full-access', 'label': 'Full access'},
      ]);

      Future<Map<String, Object?>> request(message) async => {
        'requestId': message['requestId'],
        'agent': _snapshot(
          id: 'agent-precise',
          availableModes: const [
            {'id': 'plan', 'label': 'Plan', 'description': 'Plan first'},
          ],
        ),
        'project': null,
        'error': null,
      };
      final table = StringBuffer();
      await runAgentCommand(
        arguments: const [
          'mode',
          'agent-pre',
          '--list',
          '--format',
          'CLI',
          '--no-headers',
        ],
        request: request,
        writeOutput: table.write,
      );
      expect(table.toString(), isNot(contains('MODE')));
      expect(table.toString(), contains('Plan first'));
      expect(table.toString(), endsWith(' ' * 30 + '\n'));

      final quiet = StringBuffer();
      await runAgentCommand(
        arguments: const ['mode', '--list', 'agent-pre', '--quiet'],
        request: request,
        writeOutput: quiet.write,
      );
      expect(quiet.toString(), 'plan\n');

      final yaml = StringBuffer();
      await runAgentCommand(
        arguments: const ['mode', '--list', 'agent-pre', '-o', 'yaml'],
        request: request,
        writeOutput: yaml.write,
      );
      expect(yaml.toString(), startsWith('- id: plan'));
    },
  );

  test(
    'mode set trims input, uses canonical id, and renders all outputs',
    () async {
      final sent = <Map<String, Object?>>[];
      Future<Map<String, Object?>> request(Map<String, Object?> message) async {
        sent.add(message);
        if (message['type'] == 'fetch_agent_request') {
          return {
            'requestId': message['requestId'],
            'agent': _snapshot(id: 'agent-precise'),
            'project': null,
            'error': null,
          };
        }
        expect(message['type'], 'set_agent_mode_request');
        return {
          'requestId': message['requestId'],
          'agentId': message['agentId'],
          'accepted': true,
          'error': null,
          'notice': {'type': 'info', 'message': 'mode changed'},
        };
      }

      final json = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['mode', 'agent-pre', ' full-access ', '--json'],
          request: request,
          writeOutput: json.write,
        ),
        0,
      );
      expect(sent[1], {
        'type': 'set_agent_mode_request',
        'agentId': 'agent-precise',
        'modeId': 'full-access',
        'requestId': isA<String>(),
      });
      expect(jsonDecode(json.toString()), {
        'agentId': 'agent-p',
        'mode': 'full-access',
      });

      final table = StringBuffer();
      await runAgentCommand(
        arguments: const ['mode', 'agent-pre', 'plan'],
        request: request,
        writeOutput: table.write,
      );
      expect(table.toString(), contains('AGENT ID'));
      expect(table.toString(), contains('agent-p'));
      expect(table.toString(), contains('plan'));

      final quiet = StringBuffer();
      await runAgentCommand(
        arguments: const ['mode', 'agent-pre', 'plan', '--quiet'],
        request: request,
        writeOutput: quiet.write,
      );
      expect(quiet.toString(), 'agent-p\n');
    },
  );

  test('mode preserves frozen validation and operation errors', () async {
    var requested = false;
    final missingMode = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['mode', 'agent', '--json'],
        request: (_) async {
          requested = true;
          return const {};
        },
        writeError: missingMode.write,
      ),
      1,
    );
    expect(requested, isFalse);
    expect(
      (jsonDecode(missingMode.toString())
          as Map<String, dynamic>)['error']['code'],
      'MISSING_ARGUMENT',
    );

    final notFound = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['mode', '--list', 'missing'],
        request: (message) async => {
          'requestId': message['requestId'],
          'agent': null,
          'project': null,
          'error': null,
        },
        writeError: notFound.write,
      ),
      1,
    );
    expect(notFound.toString(), contains('No agent found matching: missing'));
    expect(notFound.toString(), contains('coding-agent ls'));

    final fetchFailed = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['mode', '--list', 'ambiguous', '--json'],
        request: (message) async => {
          'requestId': message['requestId'],
          'agent': null,
          'project': null,
          'error': 'Agent identifier is ambiguous',
        },
        writeError: fetchFailed.write,
      ),
      1,
    );
    expect(fetchFailed.toString(), contains('MODE_OPERATION_FAILED'));
    expect(fetchFailed.toString(), contains('Failed to list modes'));

    final rejected = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['mode', 'agent', 'unknown', '--json'],
        request: (message) async {
          if (message['type'] == 'fetch_agent_request') {
            return {
              'requestId': message['requestId'],
              'agent': _snapshot(id: 'agent-precise'),
              'project': null,
              'error': null,
            };
          }
          return {
            'requestId': message['requestId'],
            'agentId': message['agentId'],
            'accepted': false,
            'error': 'Unknown mode: unknown',
          };
        },
        writeError: rejected.write,
      ),
      1,
    );
    final rejectedError =
        (jsonDecode(rejected.toString()) as Map<String, dynamic>)['error'];
    expect(rejectedError['code'], 'MODE_OPERATION_FAILED');
    expect(rejectedError['message'], contains('Unknown mode: unknown'));
  });

  test('stop --all interrupts only running non-archived agents', () async {
    final sent = <Map<String, Object?>>[];
    final warnings = StringBuffer();
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['stop', '--all', '--json'],
        request: (message) async {
          sent.add(message);
          if (message['type'] == 'fetch_agents_request') {
            return _listPayload([
              _entry(_snapshot(id: 'running-success', status: 'running')),
              _entry(_snapshot(id: 'running-failure', status: 'running')),
              _entry(_snapshot(id: 'idle-agent', status: 'idle')),
              _entry(
                _snapshot(
                  id: 'archived-agent',
                  status: 'closed',
                  archivedAt: '2026-07-29T00:00:00Z',
                ),
              ),
            ]);
          }
          final id = message['agentId'] as String;
          return {
            'requestId': message['requestId'],
            'agentId': id,
            'agent': _snapshot(id: id, status: 'idle'),
            'error': id == 'running-failure' ? 'provider refused' : null,
          };
        },
        writeOutput: output.write,
        writeError: warnings.write,
      ),
      0,
    );
    expect(sent.first, {
      'type': 'fetch_agents_request',
      'requestId': isA<String>(),
      'filter': {'includeArchived': true},
    });
    expect(
      sent.where((message) => message['type'] == 'cancel_agent_request'),
      hasLength(2),
    );
    expect(jsonDecode(output.toString()), {
      'stoppedCount': 1,
      'agentIds': ['running-success'],
    });
    expect(
      warnings.toString(),
      'Warning: Failed to stop agent running: provider refused\n',
    );
  });

  test(
    'stop resolves a specific agent and supports quiet/table output',
    () async {
      final sent = <Map<String, Object?>>[];
      Future<Map<String, Object?>> request(Map<String, Object?> message) async {
        sent.add(message);
        return switch (message['type']) {
          'fetch_agents_request' => _listPayload([]),
          'fetch_agent_request' => {
            'requestId': message['requestId'],
            'agent': _snapshot(id: 'agent-precise', status: 'running'),
            'project': null,
            'error': null,
          },
          'cancel_agent_request' => {
            'requestId': message['requestId'],
            'agentId': message['agentId'],
            'agent': _snapshot(id: 'agent-precise', status: 'idle'),
            'error': null,
          },
          _ => throw StateError('unexpected request'),
        };
      }

      final quiet = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['stop', 'agent-pre', '--quiet'],
          request: request,
          writeOutput: quiet.write,
        ),
        0,
      );
      expect(sent.map((message) => message['type']), [
        'fetch_agents_request',
        'fetch_agent_request',
        'cancel_agent_request',
      ]);
      expect(sent[1]['agentId'], 'agent-pre');
      expect(sent[2]['agentId'], 'agent-precise');
      expect(quiet.toString(), 'agent-precise\n');

      final table = StringBuffer();
      await runAgentCommand(
        arguments: const ['stop', 'agent-pre'],
        request: request,
        writeOutput: table.write,
      );
      expect(table.toString(), startsWith('INTERRUPTED'));
      expect(table.toString(), contains('1'));
    },
  );

  test('stop --cwd uses frozen mixed-separator descendant matching', () async {
    final cancelled = <String>[];
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['stop', '--cwd', r'C:\Repo', '--format', 'yaml'],
        request: (message) async {
          if (message['type'] == 'fetch_agents_request') {
            return _listPayload([
              _entry(
                _snapshot(id: 'same', status: 'running', cwd: r'c:\repo\\'),
              ),
              _entry(
                _snapshot(
                  id: 'child',
                  status: 'running',
                  cwd: 'C:/REPO/packages/app',
                ),
              ),
              _entry(
                _snapshot(
                  id: 'sibling-prefix',
                  status: 'running',
                  cwd: r'C:\repository',
                ),
              ),
              _entry(
                _snapshot(
                  id: 'archived-child',
                  status: 'closed',
                  cwd: r'C:\repo\old',
                  archivedAt: '2026-07-29T00:00:00Z',
                ),
              ),
            ]);
          }
          final id = message['agentId'] as String;
          cancelled.add(id);
          return {
            'requestId': message['requestId'],
            'agentId': id,
            'agent': _snapshot(id: id, status: 'idle'),
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(cancelled, ['same', 'child']);
    expect(output.toString(), contains('stoppedCount: 2'));
    expect(output.toString(), contains('- same'));
    expect(output.toString(), contains('- child'));
  });

  test(
    'stop idle, missing, and operation failures preserve contracts',
    () async {
      var requested = false;
      final missing = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['stop', '--json'],
          request: (_) async {
            requested = true;
            return const {};
          },
          writeError: missing.write,
        ),
        1,
      );
      expect(requested, isFalse);
      expect(
        (jsonDecode(missing.toString())
            as Map<String, dynamic>)['error']['code'],
        'MISSING_ARGUMENT',
      );

      final notFound = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['stop', 'missing', '--json'],
          request: (message) async => message['type'] == 'fetch_agents_request'
              ? _listPayload([])
              : {
                  'requestId': message['requestId'],
                  'agent': null,
                  'project': null,
                  'error': null,
                },
          writeError: notFound.write,
        ),
        1,
      );
      expect(notFound.toString(), contains('AGENT_NOT_FOUND'));

      var cancelCalled = false;
      final idle = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['stop', 'idle'],
          request: (message) async {
            if (message['type'] == 'fetch_agents_request') {
              return _listPayload([]);
            }
            if (message['type'] == 'fetch_agent_request') {
              return {
                'requestId': message['requestId'],
                'agent': _snapshot(id: 'idle', status: 'idle'),
                'project': null,
                'error': null,
              };
            }
            cancelCalled = true;
            return const {};
          },
          writeOutput: idle.write,
        ),
        0,
      );
      expect(cancelCalled, isFalse);
      expect(idle.toString(), contains('0'));

      final failed = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['stop', '--all', '--json'],
          request: (_) async => throw StateError('socket closed'),
          writeError: failed.write,
        ),
        1,
      );
      final error =
          (jsonDecode(failed.toString()) as Map<String, dynamic>)['error'];
      expect(error['code'], 'STOP_AGENT_FAILED');
      expect(error['message'], contains('socket closed'));
    },
  );

  test('parser and invalid thinking errors are deterministic', () async {
    for (final arguments in const [
      <String>[],
      ['unknown'],
      ['ls', 'extra'],
      ['inspect'],
      ['inspect', 'one', 'two'],
      ['inspect', 'one', '--all'],
      ['mode'],
      ['mode', 'one', 'two', 'three'],
      ['mode', 'one', 'plan', '--list', 'extra'],
      ['stop', 'one', 'two'],
      ['stop', '--cwd'],
      ['stop', '--all', '-a'],
      ['ls', '--list'],
      ['ls', '--format', 'xml'],
    ]) {
      final error = StringBuffer();
      expect(
        await runAgentCommand(arguments: arguments, writeError: error.write),
        64,
      );
      expect(error.toString(), contains('Usage: coding-agent agent'));
    }

    final thinking = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['ls', '--thinking', '', '--json'],
        writeError: thinking.write,
      ),
      1,
    );
    expect(
      (jsonDecode(thinking.toString())
          as Map<String, dynamic>)['error']['code'],
      'LIST_AGENTS_FAILED',
    );
    expect(thinking.toString(), contains('[object Object]'));
  });
}

Map<String, Object?> _listPayload(List<Map<String, Object?>> entries) => {
  'requestId': 'request',
  'entries': entries,
  'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
};

Map<String, Object?> _entry(Map<String, Object?> agent) => {
  'agent': agent,
  'project': const <String, Object?>{},
};

Map<String, Object?> _snapshot({
  required String id,
  String? title = 'Agent',
  String status = 'idle',
  String createdAt = '2026-07-29T11:00:00Z',
  String? updatedAt,
  String provider = 'codex',
  String model = 'default',
  String? runtimeModel,
  String? thinking,
  String cwd = '/repo',
  String? currentModeId,
  String? archivedAt,
  Map<String, String> labels = const {},
  Map<String, Object?>? lastUsage,
  Map<String, bool>? capabilities,
  List<Map<String, Object?>>? availableModes,
  List<Map<String, Object?>>? pendingPermissions,
}) => {
  'id': id,
  'provider': provider,
  'cwd': cwd,
  'model': model,
  'thinkingOptionId': thinking,
  'effectiveThinkingOptionId': thinking,
  'createdAt': createdAt,
  'updatedAt': updatedAt ?? createdAt,
  'lastUserMessageAt': null,
  'status': status,
  'capabilities':
      capabilities ??
      const {
        'supportsStreaming': false,
        'supportsSessionPersistence': true,
        'supportsDynamicModes': false,
        'supportsMcpServers': false,
      },
  'currentModeId': currentModeId,
  'availableModes':
      availableModes ??
      const [
        {'id': 'normal', 'label': 'Normal'},
      ],
  'pendingPermissions': pendingPermissions ?? const <Map<String, Object?>>[],
  'persistence': null,
  'runtimeInfo': {
    'provider': provider,
    'sessionId': null,
    'model': runtimeModel,
    'thinkingOptionId': thinking,
    'modeId': currentModeId,
  },
  if (lastUsage != null) 'lastUsage': lastUsage,
  'title': title,
  'labels': labels,
  'requiresAttention': false,
  'attentionReason': null,
  'attentionTimestamp': null,
  'archivedAt': archivedAt,
  'providerUnavailable': false,
};
