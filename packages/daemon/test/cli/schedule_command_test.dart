import 'dart:convert';

import 'package:agent_daemon/src/cli/schedule_command.dart';
import 'package:test/test.dart';

void main() {
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
    expect(jsonDecode(output), containsPair('id', 'deadbeef'));
  });

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

    expect(exitCode, 64);
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

    expect(exitCode, 64);
    expect(error, contains('Use either --max-runs or --no-max-runs'));
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
    'validation and daemon payload failures return stable exit codes',
    () async {
      final cases = <List<String>>[
        const [],
        ['unknown'],
        ['ls', 'extra'],
        ['inspect'],
        ['create', ''],
        ['create', 'x', '--every', '7m', '--provider', 'codex'],
        ['create', 'x', '--timezone', 'UTC', '--provider', 'codex'],
        ['create', 'x', '--every', '5m', '--provider', 'codex', '--model'],
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
      for (final arguments in cases) {
        final code = await runScheduleCommand(
          arguments: arguments,
          request: (_) async => {'schedule': _schedule(), 'error': null},
          writeError: (_) {},
        );
        expect(code, 64, reason: '$arguments');
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
