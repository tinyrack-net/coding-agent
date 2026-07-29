import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/schedule_command.dart';
import 'package:test/test.dart';

void main() {
  test(
    'binary exposes schedule and action help',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final results = await Future.wait([
        for (final arguments in const [
          ['schedule', '--help'],
          ['schedule', 'create', '--help'],
          ['schedule', 'update', '--help'],
        ])
          Process.run(Platform.resolvedExecutable, [
            'run',
            'agent_daemon:coding_agent',
            ...arguments,
          ], workingDirectory: packageRoot),
      ]);
      for (final result in results) {
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Usage: coding-agent schedule'));
        expect(result.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('create compiles cadence, provider model, and JSON output', () async {
    Map<String, Object?>? sent;
    var output = '';
    final exitCode = await runScheduleCommand(
      arguments: [
        'create',
        '  review the branch  ',
        '--every',
        '5m',
        '--provider',
        'codex/gpt-5.4',
        '--cwd',
        'C:/repo',
        '--run-now',
        '--json',
      ],
      currentDirectory: 'C:/default',
      request: (request) async {
        sent = request;
        return {
          'requestId': request['requestId'],
          'schedule': _schedule(),
          'error': null,
        };
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect(sent!['prompt'], 'review the branch');
    expect(sent!['cadence'], {'type': 'cron', 'expression': '*/5 * * * *'});
    expect(sent!['target'], {
      'type': 'new-agent',
      'config': {'provider': 'codex', 'cwd': 'C:/repo', 'model': 'gpt-5.4'},
    });
    expect(sent!['runOnCreate'], isTrue);
    expect(jsonDecode(output), {
      'id': 'deadbeef',
      'name': 'Review',
      'cadence': 'cron:*/5 * * * *',
      'target': 'new-agent:codex',
      'status': 'active',
      'nextRunAt': '2026-07-27T00:05:00.000Z',
      'lastRunAt': null,
    });
  });

  test('create accepts Commander long-option equals syntax', () async {
    Map<String, Object?>? sent;
    final exitCode = await runScheduleCommand(
      arguments: [
        'create',
        'review',
        '--cron=0 9 * * *',
        '--timezone=Asia/Seoul',
        '--name=Morning',
        '--provider=codex/gpt-5.4',
        '--mode=full-access',
        '--cwd=C:/remote',
        '--max-runs=3runs',
        '--expires-in=1h',
        '--host=remote:6868',
      ],
      request: (request) async {
        sent = request;
        return {'schedule': _schedule(), 'error': null};
      },
      writeOutput: (_) {},
    );

    expect(exitCode, 0);
    expect(sent, isNotNull);
    expect(sent!['prompt'], 'review');
    expect(sent!['name'], 'Morning');
    expect(sent!['cadence'], {
      'type': 'cron',
      'expression': '0 9 * * *',
      'timezone': 'Asia/Seoul',
    });
    expect(sent!['target'], {
      'type': 'new-agent',
      'config': {
        'provider': 'codex',
        'cwd': 'C:/remote',
        'model': 'gpt-5.4',
        'modeId': 'full-access',
      },
    });
    expect(sent!['maxRuns'], 3);
    expect(sent!['expiresAt'], isA<String>());
  });

  test(
    'option terminator preserves option-like prompts and output mode',
    () async {
      Map<String, Object?>? sent;
      var output = '';
      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            '--every=5m',
            '--provider=codex',
            '--',
            '--json',
          ],
          request: (request) async {
            sent = request;
            return {'schedule': _schedule(), 'error': null};
          },
          writeOutput: (value) => output += value,
        ),
        0,
      );
      expect(sent!['prompt'], '--json');
      expect(output, startsWith('ID'));

      sent = null;
      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            '--every=5m',
            '--provider=codex',
            '--',
            '--help',
          ],
          request: (request) async {
            sent = request;
            return {'schedule': _schedule(), 'error': null};
          },
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent!['prompt'], '--help');
    },
  );

  test(
    'self target skips blank branded ids and rejects an empty scope',
    () async {
      Map<String, Object?>? sent;
      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            'heartbeat',
            '--every',
            '1h',
            '--target',
            'self',
          ],
          environment: const {
            'TINYRACK_AGENT_ID': '   ',
            'PASEO_AGENT_ID': '11111111-1111-4111-8111-111111111111',
          },
          request: (request) async {
            sent = request;
            return {'schedule': _schedule(), 'error': null};
          },
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent!['target'], {
        'type': 'self',
        'agentId': '11111111-1111-4111-8111-111111111111',
      });

      var error = '';
      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            'heartbeat',
            '--every',
            '1h',
            '--target',
            'self',
          ],
          environment: const {'TINYRACK_AGENT_ID': ' ', 'PASEO_AGENT_ID': '\t'},
          request: (_) async =>
              fail('blank self ids must not reach the daemon'),
          writeError: (value) => error += value,
        ),
        1,
      );
      expect(error, contains('--target self requires'));
    },
  );

  test('remote create requires an explicit daemon-side cwd', () async {
    var error = '';
    final exitCode = await runScheduleCommand(
      arguments: [
        'create',
        'review',
        '--every',
        '5m',
        '--provider',
        'codex',
        '--host',
        'remote:6868',
      ],
      request: (_) async => fail('request must not run'),
      writeError: (value) => error += value,
    );

    expect(exitCode, 1);
    expect(error, contains('--cwd is required when --host is specified'));
  });

  test('ls hides existing-agent heartbeat schedules', () async {
    var output = '';
    final exitCode = await runScheduleCommand(
      arguments: ['ls', '--json'],
      request: (request) async => {
        'requestId': request['requestId'],
        'schedules': [
          _schedule(),
          {
            ..._schedule(),
            'id': 'heartbeat',
            'target': {
              'type': 'agent',
              'agentId': '11111111-1111-4111-8111-111111111111',
            },
          },
        ],
        'error': null,
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    final decoded = jsonDecode(output) as List;
    expect(decoded, hasLength(1));
    expect(decoded.single['id'], 'deadbeef');
  });

  test('empty human lists produce no table header', () async {
    var output = '';
    expect(
      await runScheduleCommand(
        arguments: ['ls'],
        request: (_) async => {'schedules': const [], 'error': null},
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, isEmpty);
  });

  test('pause verifies target type before mutating', () async {
    final types = <String>[];
    final exitCode = await runScheduleCommand(
      arguments: ['pause', 'deadbeef', '--json'],
      request: (request) async {
        types.add(request['type']! as String);
        return {
          'requestId': request['requestId'],
          'schedule': _schedule(
            status: request['type'] == 'schedule/pause' ? 'paused' : 'active',
          ),
          'error': null,
        };
      },
      writeOutput: (_) {},
    );

    expect(exitCode, 0);
    expect(types, ['schedule/inspect', 'schedule/pause']);
  });

  test('update rejects conflicting clear and set flags', () async {
    var error = '';
    final exitCode = await runScheduleCommand(
      arguments: ['update', 'deadbeef', '--max-runs', '2', '--no-max-runs'],
      request: (request) async => {
        'requestId': request['requestId'],
        'schedule': _schedule(),
        'error': null,
      },
      writeError: (value) => error += value,
    );

    expect(exitCode, 1);
    expect(error, contains('Use either --max-runs <n> or --no-max-runs'));
  });

  test('delete does not inspect before deleting', () async {
    final types = <String>[];
    final exitCode = await runScheduleCommand(
      arguments: ['delete', 'deadbeef', '--json'],
      request: (request) async {
        types.add(request['type']! as String);
        return {
          'requestId': request['requestId'],
          'scheduleId': request['scheduleId'],
          'error': null,
        };
      },
      writeOutput: (_) {},
    );

    expect(exitCode, 0);
    expect(types, ['schedule/delete']);
  });

  test('human output covers every schedule lifecycle action', () async {
    final types = <String>[];
    Future<Map<String, Object?>> requester(Map<String, Object?> request) async {
      final type = request['type']! as String;
      types.add(type);
      if (type == 'schedule/list') {
        return {
          'requestId': request['requestId'],
          'schedules': [
            _schedule(),
            {
              ..._schedule(),
              'id': 'every',
              'cadence': {'type': 'every', 'everyMs': 3661000},
            },
          ],
          'error': null,
        };
      }
      if (type == 'schedule/logs') {
        return {
          'requestId': request['requestId'],
          'runs': [
            {
              'id': 'run-1',
              'scheduledFor': 'scheduled',
              'startedAt': 'started',
              'endedAt': 'ended',
              'status': 'succeeded',
              'agentId': '11111111-1111-4111-8111-111111111111',
              'output': 'done',
              'error': null,
            },
          ],
          'error': null,
        };
      }
      if (type == 'schedule/delete') {
        return {
          'requestId': request['requestId'],
          'scheduleId': request['scheduleId'],
          'error': null,
        };
      }
      return {
        'requestId': request['requestId'],
        'schedule': _schedule(
          status: type == 'schedule/pause' ? 'paused' : 'active',
        ),
        'error': null,
      };
    }

    for (final arguments in <List<String>>[
      ['ls'],
      ['inspect', 'deadbeef'],
      ['logs', 'deadbeef'],
      ['pause', 'deadbeef'],
      ['resume', 'deadbeef'],
      ['run-once', 'deadbeef'],
      ['delete', 'deadbeef'],
    ]) {
      var output = '';
      expect(
        await runScheduleCommand(
          arguments: arguments,
          request: requester,
          writeOutput: (value) => output += value,
        ),
        0,
      );
      expect(output, isNotEmpty);
    }

    expect(
      types,
      containsAll([
        'schedule/list',
        'schedule/inspect',
        'schedule/logs',
        'schedule/pause',
        'schedule/resume',
        'schedule/run-once',
        'schedule/delete',
      ]),
    );
  });

  test(
    'create supports existing-agent and self compatibility targets',
    () async {
      final sent = <Map<String, Object?>>[];
      Future<Map<String, Object?>> requester(
        Map<String, Object?> request,
      ) async {
        sent.add(request);
        return {
          'requestId': request['requestId'],
          'schedule': _schedule(),
          'error': null,
        };
      }

      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            'review',
            '--cron',
            '0 9 * * *',
            '--timezone',
            'Asia/Seoul',
            '--target',
            '11111111-1111-4111-8111-111111111111',
          ],
          request: requester,
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent.last['target'], {
        'type': 'agent',
        'agentId': '11111111-1111-4111-8111-111111111111',
      });

      expect(
        await runScheduleCommand(
          arguments: [
            'create',
            'heartbeat',
            '--every',
            '1h',
            '--target',
            'self',
          ],
          environment: const {
            'TINYRACK_AGENT_ID': '11111111-1111-4111-8111-111111111111',
          },
          request: requester,
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent.last['target'], {
        'type': 'self',
        'agentId': '11111111-1111-4111-8111-111111111111',
      });
    },
  );

  test('update sends every mutable field and clear operation', () async {
    Map<String, Object?>? update;
    var output = '';
    final exitCode = await runScheduleCommand(
      arguments: [
        'update',
        'deadbeef',
        '--name',
        '',
        '--prompt',
        'next prompt',
        '--cron',
        '0 10 * * *',
        '--timezone',
        'UTC',
        '--provider',
        'codex/gpt-5.4',
        '--mode',
        '',
        '--cwd',
        'C:/next',
        '--no-max-runs',
        '--expires-in',
        '2h30m',
      ],
      request: (request) async {
        if (request['type'] == 'schedule/update') update = request;
        return {
          'requestId': request['requestId'],
          'schedule': _schedule(),
          'error': null,
        };
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect(update, isNotNull);
    expect(update!['name'], isNull);
    expect(update!['prompt'], 'next prompt');
    expect(update!['cadence'], {
      'type': 'cron',
      'expression': '0 10 * * *',
      'timezone': 'UTC',
    });
    expect(update!['newAgentConfig'], {
      'provider': 'codex',
      'model': 'gpt-5.4',
      'modeId': null,
      'cwd': 'C:/next',
    });
    expect(update!['maxRuns'], isNull);
    expect(update!['expiresAt'], isA<String>());
    expect(output, contains('RunCount'));
  });

  test(
    'syntax failures return usage while semantic failures are command errors',
    () async {
      final syntaxCases = <List<String>>[
        const [],
        ['unknown'],
        ['ls', 'extra'],
        ['inspect'],
        ['create', 'x', '--model', 'gpt'],
        ['update', 'id', '--run-now'],
      ];
      for (final arguments in syntaxCases) {
        final code = await runScheduleCommand(
          arguments: arguments,
          request: (_) async => fail('syntax failure must not call daemon'),
          writeError: (_) {},
        );
        expect(code, 64, reason: '$arguments');
      }

      final semanticCases = <List<String>>[
        ['create', ''],
        ['create', 'x', '--every', '7m', '--provider', 'codex'],
        ['create', 'x', '--timezone', 'UTC', '--provider', 'codex'],
        [
          'create',
          'x',
          '--every',
          '5m',
          '--target',
          'agent',
          '--provider',
          'codex',
        ],
        ['update', 'id'],
        ['update', 'id', '--prompt', ''],
        ['update', 'id', '--cwd', ''],
        ['update', 'id', '--max-runs', '0'],
        ['update', 'id', '--expires-in', 'bad'],
        ['update', 'id', '--expires-in', '1h', '--no-expires-in'],
        ['update', 'id', '--cron', '0 9 * * *', '--every', '1h'],
        ['update', 'id', '--timezone', 'UTC'],
      ];
      for (final arguments in semanticCases) {
        final code = await runScheduleCommand(
          arguments: arguments,
          request: (_) async => {'schedule': _schedule(), 'error': null},
          writeError: (_) {},
        );
        expect(code, 1, reason: '$arguments');
      }

      expect(
        await runScheduleCommand(
          arguments: ['ls'],
          request: (_) async => {
            'schedules': const [],
            'error': 'daemon unavailable',
          },
          writeError: (_) {},
        ),
        1,
      );
    },
  );

  test('JSON errors preserve frozen command code and details', () async {
    var error = '';
    final code = await runScheduleCommand(
      arguments: [
        'create',
        'review',
        '--every',
        '7m',
        '--provider',
        'codex',
        '--json',
      ],
      request: (_) async => fail('invalid cadence must not call daemon'),
      writeError: (value) => error += value,
    );

    expect(code, 1);
    expect(jsonDecode(error), {
      'error': {
        'code': 'UNREPRESENTABLE_CADENCE',
        'message': '7m cannot be represented faithfully by five-field cron',
        'details': 'Use --cron for calendar schedules',
      },
    });
  });

  test('semantic validation runs before daemon connection', () async {
    var error = '';
    final code = await runScheduleCommand(
      arguments: ['update', 'deadbeef', '--json'],
      environment: const {'TINYRACK_HOST': '127.0.0.1:1'},
      writeError: (value) => error += value,
    );

    expect(code, 1);
    expect((jsonDecode(error) as Map)['error'], {
      'code': 'NO_UPDATES',
      'message': 'Specify at least one field to update',
    });
  });

  test('cron and timezone flags preserve frozen parser boundaries', () async {
    Map<String, Object?>? sent;
    expect(
      await runScheduleCommand(
        arguments: ['create', 'review', '--cron', '', '--provider', 'codex'],
        request: (request) async {
          sent = request;
          return {'schedule': _schedule(), 'error': null};
        },
        writeOutput: (_) {},
      ),
      0,
    );
    expect(sent!['cadence'], {'type': 'cron', 'expression': ''});

    var error = '';
    expect(
      await runScheduleCommand(
        arguments: [
          'create',
          'review',
          '--cron',
          '0 9 * * *',
          '--timezone',
          '',
          '--provider',
          'codex',
          '--json',
        ],
        request: (_) async => fail('empty timezone must not call daemon'),
        writeError: (value) => error += value,
      ),
      1,
    );
    expect((jsonDecode(error) as Map)['error'], {
      'code': 'INVALID_TIME_ZONE',
      'message': '--timezone cannot be empty',
    });
  });

  test(
    'positive integer flags preserve JavaScript parseInt compatibility',
    () async {
      Map<String, Object?>? update;
      expect(
        await runScheduleCommand(
          arguments: ['update', 'deadbeef', '--max-runs', '2runs'],
          request: (request) async {
            if (request['type'] == 'schedule/update') update = request;
            return {'schedule': _schedule(), 'error': null};
          },
          writeOutput: (_) {},
        ),
        0,
      );
      expect(update!['maxRuns'], 2);
    },
  );

  test('JSON list and logs serialize stable CLI rows', () async {
    var listOutput = '';
    await runScheduleCommand(
      arguments: ['ls', '--json'],
      request: (request) async => {
        'schedules': [_schedule()],
        'error': null,
      },
      writeOutput: (value) => listOutput += value,
    );
    expect((jsonDecode(listOutput) as List).single.keys, {
      'id',
      'name',
      'cadence',
      'target',
      'status',
      'nextRunAt',
      'lastRunAt',
    });

    var logsOutput = '';
    await runScheduleCommand(
      arguments: ['logs', 'deadbeef', '--json'],
      request: (request) async {
        if (request['type'] == 'schedule/inspect') {
          return {'schedule': _schedule(), 'error': null};
        }
        return {
          'runs': [
            {
              'id': 'run-1',
              'scheduledFor': 'ignored',
              'startedAt': 'started',
              'endedAt': 'ignored',
              'status': 'succeeded',
              'agentId': 'abc',
              'output': 'done',
              'error': null,
            },
          ],
          'error': null,
        };
      },
      writeOutput: (value) => logsOutput += value,
    );
    expect((jsonDecode(logsOutput) as List).single, {
      'id': 'run-1',
      'status': 'succeeded',
      'startedAt': 'started',
      'agentId': 'abc',
      'output': 'done',
      'error': null,
    });
  });

  test('help and action-specific option boundaries are exposed', () async {
    for (final arguments in [
      ['--help'],
      ['create', '--help'],
      ['update', '--help'],
      ['run-once', '--help'],
    ]) {
      var output = '';
      expect(
        await runScheduleCommand(
          arguments: arguments,
          request: (_) async => fail('help must not call daemon'),
          writeOutput: (value) => output += value,
        ),
        0,
      );
      expect(output, contains('Usage: coding-agent schedule'));
      if (arguments.first == 'create') {
        expect(output, contains('--every <duration>'));
        expect(output, contains('--cron <expr>'));
        expect(output, contains('(default: UTC)'));
        expect(output, isNot(contains('--target')));
      }
    }
  });
}

Map<String, Object?> _schedule({String status = 'active'}) => {
  'id': 'deadbeef',
  'name': 'Review',
  'prompt': 'review',
  'cadence': {'type': 'cron', 'expression': '*/5 * * * *'},
  'target': {
    'type': 'new-agent',
    'config': {'provider': 'codex', 'cwd': 'C:/repo'},
  },
  'status': status,
  'createdAt': '2026-07-27T00:00:00.000Z',
  'updatedAt': '2026-07-27T00:00:00.000Z',
  'nextRunAt': '2026-07-27T00:05:00.000Z',
  'lastRunAt': null,
  'pausedAt': null,
  'expiresAt': null,
  'maxRuns': null,
  'runs': const [],
};
