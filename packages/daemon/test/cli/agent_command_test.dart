import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'help, nested commands, and top-level aliases are exposed',
    () async {
      for (final arguments in const [
        ['--help'],
        ['ls', '--help'],
        ['inspect', '--help'],
        ['mode', '--help'],
        ['stop', '--help'],
        ['send', '--help'],
        ['wait', '--help'],
        ['archive', '--help'],
        ['delete', '--help'],
        ['detach', '--help'],
        ['reload', '--help'],
        ['update', '--help'],
      ]) {
        final output = StringBuffer();
        expect(
          await runAgentCommand(
            arguments: arguments,
            writeOutput: output.write,
          ),
          0,
        );
        expect(output.toString(), contains('Usage: coding-agent agent'));
      }

      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      const binaryArguments = [
        ['agent', 'ls', '--help'],
        ['agent', 'inspect', '--help'],
        ['agent', 'mode', '--help'],
        ['agent', 'stop', '--help'],
        ['agent', 'send', '--help'],
        ['agent', 'wait', '--help'],
        ['agent', 'archive', '--help'],
        ['agent', 'delete', '--help'],
        ['agent', 'detach', '--help'],
        ['agent', 'reload', '--help'],
        ['agent', 'update', '--help'],
        ['ls', '--help'],
        ['inspect', '--help'],
        ['stop', '--help'],
        ['send', '--help'],
        ['wait', '--help'],
        ['archive', '--help'],
        ['delete', '--help'],
      ];
      final results = await Future.wait([
        for (final arguments in binaryArguments)
          Process.run(Platform.resolvedExecutable, [
            'run',
            'agent_daemon:coding_agent',
            ...arguments,
          ], workingDirectory: packageRoot),
      ]);
      for (var index = 0; index < binaryArguments.length; index++) {
        final arguments = binaryArguments[index];
        final result = results[index];
        expect(result.exitCode, 0, reason: '$arguments');
        expect(result.stdout, contains('Usage: coding-agent agent'));
        expect(result.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

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

  test('send preserves prompt text and supports no-wait output', () async {
    Map<String, Object?>? sent;
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const [
          'send',
          'agent-prefix',
          '  keep surrounding whitespace  ',
          '--no-wait',
          '--json',
        ],
        request: (message) async {
          sent = message;
          return {
            'requestId': message['requestId'],
            'agentId': 'agent-canonical',
            'accepted': true,
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(sent, {
      'type': 'send_agent_message_request',
      'requestId': isA<String>(),
      'agentId': 'agent-prefix',
      'text': '  keep surrounding whitespace  ',
      'messageId': matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
          r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    });
    expect(jsonDecode(output.toString()), {
      'agentId': 'agent-prefix',
      'status': 'sent',
      'message': 'Message sent, not waiting for completion',
    });
  });

  test('send waits and maps every frozen finish status', () async {
    for (final entry in const [
      (
        wire: 'idle',
        cli: 'completed',
        message: 'Agent completed processing the message',
        error: null,
      ),
      (
        wire: 'permission',
        cli: 'permission',
        message: 'Agent is waiting for permission',
        error: null,
      ),
      (
        wire: 'timeout',
        cli: 'timeout',
        message: 'Timed out waiting for agent to finish',
        error: null,
      ),
      (
        wire: 'error',
        cli: 'error',
        message: 'provider exploded',
        error: 'provider exploded',
      ),
    ]) {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['send', 'agent-pre', '--prompt', 'hello', '--json'],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'send_agent_message_request') {
              return {
                'requestId': message['requestId'],
                'agentId': 'agent-canonical',
                'accepted': true,
                'error': null,
              };
            }
            return {
              'requestId': message['requestId'],
              'agentId': 'agent-canonical',
              'status': entry.wire,
              'final': _snapshot(id: 'agent-canonical'),
              'error': entry.error,
              'lastMessage': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent.map((message) => message['type']), [
        'send_agent_message_request',
        'wait_for_finish_request',
      ]);
      expect(sent.last, {
        'type': 'wait_for_finish_request',
        'requestId': isA<String>(),
        'agentId': 'agent-pre',
        'timeoutMs': 600000,
      });
      expect(jsonDecode(output.toString()), {
        'agentId': 'agent-canonical',
        'status': entry.cli,
        'message': entry.message,
      });
    }
  });

  test('send reads UTF-8 prompt files and repeated images', () async {
    final temp = await Directory.systemTemp.createTemp('coding-agent-send-');
    addTearDown(() => temp.delete(recursive: true));
    final prompt = File('${temp.path}${Platform.pathSeparator}prompt.txt');
    final png = File('${temp.path}${Platform.pathSeparator}first.png');
    final unknown = File('${temp.path}${Platform.pathSeparator}second.bin');
    await prompt.writeAsString('파일 프롬프트\n', encoding: utf8);
    await png.writeAsBytes([1, 2, 3]);
    await unknown.writeAsBytes([4, 5]);

    Map<String, Object?>? sent;
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: [
          'send',
          'agent',
          '--prompt-file',
          prompt.path,
          '--image',
          png.path,
          '--image',
          unknown.path,
          '--no-wait',
          '--quiet',
        ],
        request: (message) async {
          sent = message;
          return {
            'requestId': message['requestId'],
            'agentId': 'agent',
            'accepted': true,
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(sent?['text'], '파일 프롬프트\n');
    expect(sent?['images'], [
      {
        'data': base64Encode([1, 2, 3]),
        'mimeType': 'image/png',
      },
      {
        'data': base64Encode([4, 5]),
        'mimeType': 'image/jpeg',
      },
    ]);
    expect(output.toString(), 'agent\n');
  });

  test(
    'send input and transport failures preserve frozen error codes',
    () async {
      Future<void> expectError(
        List<String> arguments,
        String code, {
        AgentRpcRequester? request,
      }) async {
        final error = StringBuffer();
        expect(
          await runAgentCommand(
            arguments: [...arguments, '--json'],
            request: request,
            writeError: error.write,
          ),
          1,
        );
        expect(
          (jsonDecode(error.toString())
              as Map<String, dynamic>)['error']['code'],
          code,
        );
      }

      await expectError(['send', 'agent'], 'MISSING_PROMPT');
      await expectError(['send'], 'MISSING_AGENT_ID');
      await expectError([
        'send',
        'agent',
        'arg',
        '--prompt',
        'option',
      ], 'CONFLICTING_PROMPT_INPUT');
      await expectError([
        'send',
        'agent',
        '--prompt-file',
        'definitely-missing.txt',
      ], 'PROMPT_FILE_READ_ERROR');
      await expectError(
        ['send', 'agent', 'prompt', '--image', 'definitely-missing.png'],
        'IMAGE_READ_ERROR',
        request: (_) async => throw StateError('must not connect'),
      );
      await expectError(
        ['send', 'agent', 'prompt'],
        'SEND_FAILED',
        request: (_) async => throw StateError('socket closed'),
      );
      await expectError(
        ['send', 'agent', 'prompt'],
        'SEND_FAILED',
        request: (message) async => {
          'requestId': message['requestId'],
          'agentId': 'agent',
          'accepted': false,
          'error': 'agent is gone',
        },
      );
    },
  );

  test('wait defaults to no limit and appends five recent items', () async {
    final sent = <Map<String, Object?>>[];
    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: const ['wait', 'agent-pre', '--json'],
        request: (message) async {
          sent.add(message);
          if (message['type'] == 'wait_for_finish_request') {
            return {
              'requestId': message['requestId'],
              'status': 'idle',
              'final': _snapshot(id: 'agent-canonical'),
              'error': null,
              'lastMessage': 'done',
            };
          }
          return _timelinePayload(message, [
            for (var index = 0; index < 6; index++)
              UserMessageItem(id: 'user-$index', text: 'activity $index'),
          ]);
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(sent.first, {
      'type': 'wait_for_finish_request',
      'requestId': isA<String>(),
      'agentId': 'agent-pre',
    });
    expect(sent.last, {
      'type': 'fetch_agent_timeline_request',
      'agentId': 'agent-canonical',
      'requestId': isA<String>(),
      'direction': 'tail',
      'limit': 0,
      'projection': 'projected',
    });
    final result = jsonDecode(output.toString()) as Map<String, dynamic>;
    expect(result['agentId'], 'agent-canonical');
    expect(result['status'], 'idle');
    expect(
      result['message'],
      startsWith('Agent is idle.\nLast 5 activity items:'),
    );
    expect(result['message'], isNot(contains('activity 0')));
    for (var index = 1; index < 6; index++) {
      expect(result['message'], contains('[User] activity $index'));
    }
  });

  test('wait parses frozen durations and explains finite timeout', () async {
    for (final entry in const [
      (input: '1', milliseconds: 1000, label: '1 second'),
      (input: '30s', milliseconds: 30000, label: '30 seconds'),
      (input: '2h30m', milliseconds: 9000000, label: '9000 seconds'),
      (input: '1d', milliseconds: 86400000, label: '86400 seconds'),
    ]) {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: ['wait', 'agent', '--timeout', entry.input, '--json'],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'wait_for_finish_request') {
              return {
                'requestId': message['requestId'],
                'status': 'timeout',
                'final': _snapshot(id: 'agent-full', status: 'running'),
                'error': null,
                'lastMessage': null,
              };
            }
            throw StateError('activity unavailable');
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent.first['timeoutMs'], entry.milliseconds);
      expect(jsonDecode(output.toString()), {
        'agentId': 'agent-full',
        'status': 'timeout',
        'message':
            'Agent did not finish within ${entry.label}. '
            'Run `coding-agent wait agent-full` again to keep waiting.',
      });
    }
  });

  test('wait maps permission and error without fetching activity', () async {
    for (final entry in const [
      (
        wire: 'permission',
        status: 'permission',
        message: 'Agent is waiting for permission: tool',
        error: null,
      ),
      (
        wire: 'error',
        status: 'error',
        message: 'provider exploded',
        error: 'provider exploded',
      ),
    ]) {
      var requestCount = 0;
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['wait', 'agent', '--quiet'],
          request: (message) async {
            requestCount++;
            return {
              'requestId': message['requestId'],
              'status': entry.wire,
              'final': _snapshot(
                id: 'agent-full',
                status: entry.wire == 'permission' ? 'running' : 'error',
                pendingPermissions: entry.wire == 'permission'
                    ? const [
                        {
                          'id': 'permission',
                          'provider': 'codex',
                          'name': 'Bash',
                          'kind': 'tool',
                          'detail': {
                            'type': 'plain_text',
                            'label': 'Command',
                            'text': 'git status',
                          },
                        },
                      ]
                    : null,
              ),
              'error': entry.error,
              'lastMessage': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(requestCount, 1);
      expect(output.toString(), 'agent-full\n');

      final structured = StringBuffer();
      await runAgentCommand(
        arguments: const ['wait', 'agent', '--json'],
        request: (message) async => {
          'requestId': message['requestId'],
          'status': entry.wire,
          'final': _snapshot(
            id: 'agent-full',
            status: entry.wire == 'permission' ? 'running' : 'error',
            pendingPermissions: entry.wire == 'permission'
                ? const [
                    {
                      'id': 'permission',
                      'provider': 'codex',
                      'name': 'Bash',
                      'kind': 'tool',
                      'detail': {
                        'type': 'plain_text',
                        'label': 'Command',
                        'text': 'git status',
                      },
                    },
                  ]
                : null,
          ),
          'error': entry.error,
          'lastMessage': null,
        },
        writeOutput: structured.write,
      );
      expect(jsonDecode(structured.toString()), {
        'agentId': 'agent-full',
        'status': entry.status,
        'message': entry.message,
      });
    }
  });

  test('wait validation and transport failures preserve error codes', () async {
    Future<Map<String, dynamic>> fail(
      List<String> arguments, {
      AgentRpcRequester? request,
    }) async {
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: request,
          writeError: error.write,
        ),
        1,
      );
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    expect((await fail(['wait']))['code'], 'MISSING_AGENT_ID');
    for (final timeout in const ['0', '0s', '-1', '1.5s', '1M']) {
      final error = await fail(['wait', 'agent', '--timeout', timeout]);
      expect(error['code'], 'INVALID_TIMEOUT', reason: timeout);
      expect(error['message'], 'Invalid timeout value');
    }
    final failed = await fail([
      'wait',
      'agent',
    ], request: (_) async => throw StateError('socket closed'));
    expect(failed['code'], 'WAIT_FAILED');
    expect(failed['message'], contains('socket closed'));
  });

  test('archive resolves frozen id, prefix, and title precedence', () async {
    final agents = [
      _entry(_snapshot(id: 'alpha-first', title: 'Workspace Builder')),
      _entry(_snapshot(id: 'alpha-second', title: 'Other Agent')),
      _entry(_snapshot(id: 'beta-agent', title: 'Unique Dashboard')),
    ];
    for (final entry in const [
      (query: 'beta-agent', expected: 'beta-agent'),
      (query: 'beta', expected: 'beta-agent'),
      (query: 'workspace builder', expected: 'alpha-first'),
      (query: 'dashboard', expected: 'beta-agent'),
      (query: 'alpha', expected: 'alpha-first'),
    ]) {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: ['archive', entry.query, '--json'],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'fetch_agents_request') {
              return _listPayload(agents);
            }
            return {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
              'archivedAt': '2026-07-29T12:34:56.000Z',
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent.first, {
        'type': 'fetch_agents_request',
        'requestId': isA<String>(),
        'filter': {'includeArchived': true},
      });
      expect(sent.last, {
        'type': 'archive_agent_request',
        'requestId': isA<String>(),
        'agentId': entry.expected,
      });
      expect(jsonDecode(output.toString()), {
        'agentId': entry.expected,
        'status': 'archived',
        'archivedAt': '2026-07-29T12:34:56.000Z',
      });
    }
  });

  test('archive supports table, yaml, and quiet output', () async {
    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        message['type'] == 'fetch_agents_request'
        ? _listPayload([_entry(_snapshot(id: 'agent-full'))])
        : {
            'requestId': message['requestId'],
            'agentId': message['agentId'],
            'archivedAt': '2026-07-29T12:34:56.000Z',
          };

    final table = StringBuffer();
    await runAgentCommand(
      arguments: const ['archive', 'agent'],
      request: request,
      writeOutput: table.write,
    );
    expect(table.toString(), startsWith('AGENT ID'));
    expect(table.toString(), contains('ARCHIVED AT'));
    expect(table.toString(), contains('2026-07-29T12:34:56.000Z'));

    final yaml = StringBuffer();
    await runAgentCommand(
      arguments: const ['archive', 'agent', '--format', 'yaml'],
      request: request,
      writeOutput: yaml.write,
    );
    expect(yaml.toString(), contains('status: archived'));

    final quiet = StringBuffer();
    await runAgentCommand(
      arguments: const ['archive', 'agent', '--quiet'],
      request: request,
      writeOutput: quiet.write,
    );
    expect(quiet.toString(), 'agent-full\n');
  });

  test(
    'archive enforces archived and running guards before mutation',
    () async {
      Future<Map<String, dynamic>> run(
        Map<String, Object?> agent, {
        bool force = false,
      }) async {
        var archiveCalled = false;
        final error = StringBuffer();
        expect(
          await runAgentCommand(
            arguments: [
              'archive',
              '${agent['id']}',
              if (force) '--force',
              '--json',
            ],
            request: (message) async {
              if (message['type'] == 'fetch_agents_request') {
                return _listPayload([_entry(agent)]);
              }
              archiveCalled = true;
              return {
                'requestId': message['requestId'],
                'agentId': message['agentId'],
                'archivedAt': '2026-07-29T12:34:56.000Z',
              };
            },
            writeOutput: (_) {},
            writeError: error.write,
          ),
          force ? 0 : 1,
        );
        expect(archiveCalled, force);
        return error.isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
                  as Map<String, dynamic>;
      }

      final archived = await run(
        _snapshot(
          id: 'archived-agent',
          status: 'closed',
          archivedAt: '2026-07-28T00:00:00.000Z',
        ),
      );
      expect(archived['code'], 'AGENT_ALREADY_ARCHIVED');
      expect(archived['details'], contains('2026-07-28'));

      final running = await run(
        _snapshot(id: 'running-agent', status: 'running'),
      );
      expect(running['code'], 'AGENT_RUNNING');
      expect(running['details'], contains('--force'));

      await run(_snapshot(id: 'forced-agent', status: 'running'), force: true);
    },
  );

  test('archive failures preserve frozen structured errors', () async {
    Future<Map<String, dynamic>> fail(
      List<String> arguments,
      AgentRpcRequester request,
    ) async {
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: request,
          writeError: error.write,
        ),
        1,
      );
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    final missingId = await fail(['archive'], (_) async => const {});
    expect(missingId['code'], 'MISSING_AGENT_ID');

    final notFound = await fail([
      'archive',
      'missing',
    ], (_) async => _listPayload([]));
    expect(notFound['code'], 'AGENT_NOT_FOUND');
    expect(notFound['details'], contains('coding-agent ls'));

    final listFailure = await fail([
      'archive',
      'agent',
    ], (_) async => throw StateError('socket closed'));
    expect(listFailure['code'], 'ARCHIVE_FAILED');
    expect(listFailure['message'], contains('socket closed'));

    final archiveFailure = await fail(
      ['archive', 'agent'],
      (message) async => message['type'] == 'fetch_agents_request'
          ? _listPayload([_entry(_snapshot(id: 'agent'))])
          : throw StateError('archive refused'),
    );
    expect(archiveFailure['code'], 'ARCHIVE_FAILED');
    expect(archiveFailure['message'], contains('archive refused'));
  });

  test(
    'delete --all skips archived agents, isolates failures, and keeps going',
    () async {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      final warnings = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['delete', '--all', '--json'],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'fetch_agents_request') {
              return _listPayload([
                _entry(_snapshot(id: 'running-agent', status: 'running')),
                _entry(_snapshot(id: 'idle-failure')),
                _entry(
                  _snapshot(
                    id: 'archived-agent',
                    status: 'closed',
                    archivedAt: '2026-07-29T00:00:00Z',
                  ),
                ),
              ]);
            }
            if (message['type'] == 'cancel_agent_request') {
              throw StateError('cancel transport failed');
            }
            if (message['agentId'] == 'idle-failure') {
              throw StateError('delete refused');
            }
            return {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
            };
          },
          writeOutput: output.write,
          writeError: warnings.write,
        ),
        0,
      );
      expect(
        sent.where((message) => message['type'] == 'delete_agent_request'),
        hasLength(2),
      );
      expect(
        sent
            .where((message) => message['type'] == 'delete_agent_request')
            .map((message) => message['agentId']),
        unorderedEquals(['running-agent', 'idle-failure']),
      );
      expect(jsonDecode(output.toString()), {
        'deletedCount': 1,
        'agentIds': ['running-agent'],
      });
      expect(
        warnings.toString(),
        'Warning: Failed to delete agent idle-fa: delete refused\n',
      );
    },
  );

  test(
    'delete exact id permits archived agent and supports quiet output',
    () async {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['delete', 'arch', '--quiet'],
          request: (message) async {
            sent.add(message);
            return switch (message['type']) {
              'fetch_agents_request' => _listPayload([]),
              'fetch_agent_request' => {
                'requestId': message['requestId'],
                'agent': _snapshot(
                  id: 'archived-agent',
                  status: 'closed',
                  archivedAt: '2026-07-29T00:00:00Z',
                ),
                'project': null,
                'error': null,
              },
              'delete_agent_request' => {
                'requestId': message['requestId'],
                'agentId': message['agentId'],
              },
              _ => throw StateError('unexpected request'),
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent.map((message) => message['type']), [
        'fetch_agents_request',
        'fetch_agent_request',
        'delete_agent_request',
      ]);
      expect(sent.last['agentId'], 'archived-agent');
      expect(output.toString(), 'archived-agent\n');
    },
  );

  test(
    'delete missing target and outer failures preserve structured codes',
    () async {
      final missing = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['delete', '--json'],
          request: (_) async => throw StateError('must not connect'),
          writeError: missing.write,
        ),
        1,
      );
      expect(
        (jsonDecode(missing.toString())
            as Map<String, dynamic>)['error']['code'],
        'MISSING_ARGUMENT',
      );

      final failed = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['delete', '--all', '--json'],
          request: (_) async => throw StateError('socket closed'),
          writeError: failed.write,
        ),
        1,
      );
      expect(
        (jsonDecode(failed.toString())
            as Map<String, dynamic>)['error']['code'],
        'DELETE_AGENT_FAILED',
      );
    },
  );

  test(
    'delete --cwd matches descendants and supports yaml/table output',
    () async {
      final deleted = <String>[];
      Future<Map<String, Object?>> request(Map<String, Object?> message) async {
        if (message['type'] == 'fetch_agents_request') {
          return _listPayload([
            _entry(_snapshot(id: 'same', cwd: r'C:\Repo')),
            _entry(_snapshot(id: 'child', cwd: 'c:/repo/packages/app')),
            _entry(_snapshot(id: 'sibling', cwd: r'C:\Repository')),
            _entry(
              _snapshot(
                id: 'archived',
                status: 'closed',
                cwd: r'C:\Repo\old',
                archivedAt: '2026-07-29T00:00:00Z',
              ),
            ),
          ]);
        }
        deleted.add(message['agentId']! as String);
        return {
          'requestId': message['requestId'],
          'agentId': message['agentId'],
        };
      }

      final yaml = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const ['delete', '--cwd', r'C:\Repo', '--format', 'yaml'],
          request: request,
          writeOutput: yaml.write,
        ),
        0,
      );
      expect(deleted, unorderedEquals(['same', 'child']));
      expect(yaml.toString(), contains('deletedCount: 2'));
      expect(yaml.toString(), contains('- same'));
      expect(yaml.toString(), contains('- child'));

      deleted.clear();
      final table = StringBuffer();
      await runAgentCommand(
        arguments: const ['delete', '--cwd', r'C:\Repo'],
        request: request,
        writeOutput: table.write,
      );
      expect(deleted, unorderedEquals(['same', 'child']));
      expect(table.toString(), startsWith('DELETED'));
      expect(table.toString(), contains('2'));
    },
  );

  test('detach resolves frozen id, prefix, and title precedence', () async {
    final agents = [
      _entry(_snapshot(id: 'alpha-first', title: 'Workspace Builder')),
      _entry(_snapshot(id: 'alpha-second', title: 'Other Agent')),
      _entry(_snapshot(id: 'beta-agent', title: 'Unique Dashboard')),
    ];
    for (final entry in const [
      (query: 'beta-agent', expected: 'beta-agent'),
      (query: 'beta', expected: 'beta-agent'),
      (query: 'workspace builder', expected: 'alpha-first'),
      (query: 'dashboard', expected: 'beta-agent'),
      (query: 'alpha', expected: 'alpha-first'),
    ]) {
      final sent = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: ['detach', entry.query, '--json'],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'fetch_agents_request') {
              return _listPayload(agents);
            }
            return {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
              'accepted': true,
              'error': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent.first, {
        'type': 'fetch_agents_request',
        'requestId': isA<String>(),
        'filter': {'includeArchived': true},
      });
      expect(sent.last, {
        'type': 'agent.detach.request',
        'requestId': isA<String>(),
        'agentId': entry.expected,
      });
      expect(jsonDecode(output.toString()), {
        'agentId': entry.expected,
        'status': 'detached',
      });
    }
  });

  test('detach supports table, yaml, and quiet output', () async {
    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        message['type'] == 'fetch_agents_request'
        ? _listPayload([_entry(_snapshot(id: 'child-agent'))])
        : {
            'requestId': message['requestId'],
            'agentId': message['agentId'],
            'accepted': true,
            'error': null,
          };

    final table = StringBuffer();
    await runAgentCommand(
      arguments: const ['detach', 'child'],
      request: request,
      writeOutput: table.write,
    );
    expect(table.toString(), startsWith('AGENT ID'));
    expect(table.toString(), contains('detached'));

    final yaml = StringBuffer();
    await runAgentCommand(
      arguments: const ['detach', 'child', '--format', 'yaml'],
      request: request,
      writeOutput: yaml.write,
    );
    expect(yaml.toString(), contains('status: detached'));

    final quiet = StringBuffer();
    await runAgentCommand(
      arguments: const ['detach', 'child', '--quiet'],
      request: request,
      writeOutput: quiet.write,
    );
    expect(quiet.toString(), 'child-agent\n');
  });

  test('detach preserves frozen structured and unknown errors', () async {
    Future<Map<String, dynamic>> fail(
      List<String> arguments,
      AgentRpcRequester request,
    ) async {
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: request,
          writeError: error.write,
        ),
        1,
      );
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    expect(
      (await fail(['detach'], (_) async => const {}))['code'],
      'MISSING_AGENT_ID',
    );
    final notFound = await fail([
      'detach',
      'missing',
    ], (_) async => _listPayload([]));
    expect(notFound['code'], 'AGENT_NOT_FOUND');

    final rejected = await fail(
      ['detach', 'child'],
      (message) async => message['type'] == 'fetch_agents_request'
          ? _listPayload([_entry(_snapshot(id: 'child-agent'))])
          : {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
              'accepted': false,
              'error': 'detach refused',
            },
    );
    expect(rejected['code'], 'UNKNOWN_ERROR');
    expect(rejected['message'], 'detach refused');
  });

  test(
    'reload resolves frozen identifiers and projects timeline size',
    () async {
      final agents = [
        _entry(_snapshot(id: 'alpha-first', title: 'Workspace Builder')),
        _entry(_snapshot(id: 'alpha-second', title: 'Other Agent')),
        _entry(_snapshot(id: 'beta-agent', title: 'Unique Dashboard')),
      ];
      for (final entry in const [
        (query: 'beta-agent', expected: 'beta-agent'),
        (query: 'beta', expected: 'beta-agent'),
        (query: 'workspace builder', expected: 'alpha-first'),
        (query: 'dashboard', expected: 'beta-agent'),
        (query: 'alpha', expected: 'alpha-first'),
      ]) {
        final sent = <Map<String, Object?>>[];
        final output = StringBuffer();
        expect(
          await runAgentCommand(
            arguments: ['reload', entry.query, '--json'],
            request: (message) async {
              sent.add(message);
              if (message['type'] == 'fetch_agents_request') {
                return _listPayload(agents);
              }
              return {
                'status': 'agent_refreshed',
                'requestId': message['requestId'],
                'agentId': message['agentId'],
                'timelineSize': 3,
              };
            },
            writeOutput: output.write,
          ),
          0,
        );
        expect(sent.last, {
          'type': 'refresh_agent_request',
          'requestId': isA<String>(),
          'agentId': entry.expected,
        });
        expect(jsonDecode(output.toString()), {
          'agentId': entry.expected,
          'status': 'reloaded',
          'timelineSize': 3,
        });
      }
    },
  );

  test(
    'reload supports table, yaml, quiet, and absent timeline size',
    () async {
      Future<Map<String, Object?>> request(
        Map<String, Object?> message,
      ) async => message['type'] == 'fetch_agents_request'
          ? _listPayload([_entry(_snapshot(id: 'agent-full'))])
          : {
              'status': 'agent_refreshed',
              'requestId': message['requestId'],
              'agentId': message['agentId'],
            };

      final table = StringBuffer();
      await runAgentCommand(
        arguments: const ['reload', 'agent'],
        request: request,
        writeOutput: table.write,
      );
      expect(table.toString(), startsWith('AGENT ID'));
      expect(table.toString(), contains('TIMELINE'));
      expect(table.toString(), contains('reloaded'));

      final yaml = StringBuffer();
      await runAgentCommand(
        arguments: const ['reload', 'agent', '--format', 'yaml'],
        request: request,
        writeOutput: yaml.write,
      );
      expect(yaml.toString(), contains('timelineSize: 0'));

      final quiet = StringBuffer();
      await runAgentCommand(
        arguments: const ['reload', 'agent', '--quiet'],
        request: request,
        writeOutput: quiet.write,
      );
      expect(quiet.toString(), 'agent-full\n');
    },
  );

  test('reload preserves frozen structured errors', () async {
    Future<Map<String, dynamic>> fail(
      List<String> arguments,
      AgentRpcRequester request,
    ) async {
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: request,
          writeError: error.write,
        ),
        1,
      );
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    expect(
      (await fail(['reload'], (_) async => const {}))['code'],
      'MISSING_AGENT_ID',
    );
    final notFound = await fail([
      'reload',
      'missing',
    ], (_) async => _listPayload([]));
    expect(notFound['code'], 'AGENT_NOT_FOUND');
    expect(notFound['details'], contains('coding-agent ls'));

    final failed = await fail(
      ['reload', 'agent'],
      (message) async => message['type'] == 'fetch_agents_request'
          ? _listPayload([_entry(_snapshot(id: 'agent-full'))])
          : throw StateError('provider unavailable'),
    );
    expect(failed['code'], 'RELOAD_FAILED');
    expect(failed['message'], contains('provider unavailable'));
  });

  test('update validates frozen options before connecting', () async {
    Future<Map<String, dynamic>> fail(List<String> arguments) async {
      var requested = false;
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: (_) async {
            requested = true;
            return const {};
          },
          writeError: error.write,
        ),
        1,
      );
      expect(requested, isFalse);
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    expect((await fail(['update']))['code'], 'MISSING_AGENT_ID');
    expect(
      (await fail(['update', 'agent', '--name', '   ']))['code'],
      'INVALID_NAME',
    );
    expect(
      (await fail(['update', 'agent', '--label', 'broken']))['code'],
      'INVALID_LABEL',
    );
    expect(
      (await fail(['update', 'agent', '--label', '=value']))['code'],
      'INVALID_LABEL',
    );
    expect(
      (await fail(['update', 'agent', '--label', ' , ']))['code'],
      'NO_CHANGES_PROVIDED',
    );
  });

  test(
    'update resolves, patches, refetches, and renders frozen output',
    () async {
      final sent = <Map<String, Object?>>[];
      var fetchCount = 0;
      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: const [
            'update',
            'agent-prefix',
            '--name',
            '  Renamed Agent  ',
            '--label',
            'owner=first,empty=',
            '--label',
            'owner=last,note=a=b',
            '--json',
          ],
          request: (message) async {
            sent.add(message);
            if (message['type'] == 'fetch_agent_request') {
              fetchCount++;
              return {
                'requestId': message['requestId'],
                'agent': _snapshot(
                  id: 'agent-full-id',
                  title: fetchCount == 1 ? 'Before' : 'Renamed Agent',
                  labels: fetchCount == 1
                      ? const {}
                      : const {'owner': 'last', 'empty': '', 'note': 'a=b'},
                ),
                'project': null,
                'error': null,
              };
            }
            return {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
              'accepted': true,
              'error': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent[0]['agentId'], 'agent-prefix');
      expect(sent[1], {
        'type': 'update_agent_request',
        'agentId': 'agent-full-id',
        'name': 'Renamed Agent',
        'labels': {'owner': 'last', 'empty': '', 'note': 'a=b'},
        'requestId': isA<String>(),
      });
      expect(sent[2]['agentId'], 'agent-full-id');
      expect(jsonDecode(output.toString()), {
        'agentId': 'agent-full-id',
        'name': 'Renamed Agent',
        'labels': 'owner=last,empty=,note=a=b',
      });
    },
  );

  test('update preserves frozen not-found and failure errors', () async {
    Future<Map<String, dynamic>> fail(
      List<String> arguments,
      AgentRpcRequester request,
    ) async {
      final error = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [...arguments, '--json'],
          request: request,
          writeError: error.write,
        ),
        1,
      );
      return (jsonDecode(error.toString()) as Map<String, dynamic>)['error']
          as Map<String, dynamic>;
    }

    final notFound = await fail(
      ['update', 'missing', '--name', 'Name'],
      (message) async => {
        'requestId': message['requestId'],
        'agent': null,
        'project': null,
        'error': null,
      },
    );
    expect(notFound['code'], 'AGENT_NOT_FOUND');
    expect(notFound['details'], contains('coding-agent ls'));

    final rejected = await fail(
      ['update', 'agent', '--label', 'key=value'],
      (message) async => message['type'] == 'fetch_agent_request'
          ? {
              'requestId': message['requestId'],
              'agent': _snapshot(id: 'agent-full'),
              'project': null,
              'error': null,
            }
          : {
              'requestId': message['requestId'],
              'agentId': message['agentId'],
              'accepted': false,
              'error': 'update refused',
            },
    );
    expect(rejected['code'], 'UPDATE_FAILED');
    expect(rejected['message'], contains('update refused'));
  });

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
      ['send', 'one', 'two', 'three'],
      ['send', 'one', 'prompt', '--no-wait=false'],
      ['send', 'one', 'prompt', '--image'],
      ['wait', 'one', 'two'],
      ['wait', 'one', '--timeout'],
      ['send', 'one', 'prompt', '--timeout', '1s'],
      ['archive', 'one', 'two'],
      ['archive', 'one', '--force=false'],
      ['delete', 'one', 'two'],
      ['delete', '--cwd'],
      ['detach', 'one', 'two'],
      ['reload', 'one', 'two'],
      ['update', 'one', 'two'],
      ['update', 'one', '--name'],
      ['update', 'one', '--label'],
      ['wait', 'one', '--force'],
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

Map<String, Object?> _timelinePayload(
  Map<String, Object?> request,
  List<TimelineItem> items,
) => {
  'requestId': request['requestId'],
  'agentId': request['agentId'],
  'agent': _snapshot(id: '${request['agentId']}'),
  'direction': 'tail',
  'projection': 'projected',
  'epoch': '1',
  'reset': false,
  'staleCursor': false,
  'gap': false,
  'window': {'minSeq': 1, 'maxSeq': items.length, 'nextSeq': items.length + 1},
  'startCursor': items.isEmpty ? null : {'epoch': '1', 'seq': 1},
  'endCursor': items.isEmpty ? null : {'epoch': '1', 'seq': items.length},
  'hasOlder': false,
  'hasNewer': false,
  'entries': [
    for (var index = 0; index < items.length; index++)
      {
        'provider': 'codex',
        'item': PaseoTimelineCodec.encode(items[index]),
        'timestamp': '2026-07-29T00:00:0${index}Z',
        'seqStart': index + 1,
        'seqEnd': index + 1,
        'sourceSeqRanges': [
          {'startSeq': index + 1, 'endSeq': index + 1},
        ],
        'collapsed': <Object?>[],
      },
  ],
  'error': null,
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
