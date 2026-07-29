import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/heartbeat_command.dart';
import 'package:test/test.dart';

const _agentId = '11111111-1111-4111-8111-111111111111';
const _otherAgentId = '22222222-2222-4222-8222-222222222222';

void main() {
  test(
    'binary exposes frozen heartbeat command help',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final results = await Future.wait([
        for (final arguments in const [
          ['heartbeat', '--help'],
          ['heartbeat', 'create', '--help'],
          ['heartbeat', 'update', '--help'],
          ['heartbeat', 'delete', '--help'],
        ])
          Process.run(Platform.resolvedExecutable, [
            'run',
            'agent_daemon:coding_agent',
            ...arguments,
          ], workingDirectory: packageRoot),
      ]);

      for (final result in results) {
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Usage: coding-agent heartbeat'));
        expect(result.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'create sends the frozen agent-target payload and stable JSON row',
    () async {
      Map<String, Object?>? sent;
      var output = '';
      final code = await runHeartbeatCommand(
        arguments: [
          'create',
          '  check the build  ',
          '--cron=0 9 * * *',
          '--timezone=Asia/Seoul',
          '--name=Morning',
          '--max-runs=3runs',
          '--expires-in=1h',
          '--host=remote.example:6767',
          '--json',
        ],
        environment: const {'TINYRACK_AGENT_ID': ' $_agentId '},
        now: () => DateTime.utc(2026, 7, 30),
        request: (request) async {
          sent = request;
          return {'schedule': _schedule(), 'error': null};
        },
        writeOutput: (value) => output += value,
      );

      expect(code, 0);
      expect(sent, {
        'type': 'schedule/create',
        'requestId': startsWith('heartbeat_'),
        'prompt': 'check the build',
        'cadence': {
          'type': 'cron',
          'expression': '0 9 * * *',
          'timezone': 'Asia/Seoul',
        },
        'target': {'type': 'agent', 'agentId': _agentId},
        'name': 'Morning',
        'maxRuns': 3,
        'expiresAt': '2026-07-30T01:00:00.000Z',
      });
      expect(jsonDecode(output), {
        'id': 'heartbeat-1',
        'name': 'Morning',
        'cadence': 'cron:0 9 * * * (Asia/Seoul)',
        'target': 'agent:1111111',
        'status': 'active',
        'nextRunAt': '2026-07-31T00:00:00.000Z',
        'lastRunAt': null,
      });
    },
  );

  test('update verifies ownership before changing only cadence', () async {
    final requests = <Map<String, Object?>>[];
    var output = '';
    final code = await runHeartbeatCommand(
      arguments: [
        'update',
        'heartbeat-1',
        '--cron',
        '*/15 * * * *',
        '--timezone',
        ' UTC ',
      ],
      environment: const {'PASEO_AGENT_ID': _agentId},
      request: (request) async {
        requests.add(request);
        return request['type'] == 'schedule/inspect'
            ? {'schedule': _schedule(), 'error': null}
            : {'schedule': _schedule(), 'error': null};
      },
      writeOutput: (value) => output += value,
    );

    expect(code, 0);
    expect(requests, hasLength(2));
    expect(requests.first, {
      'type': 'schedule/inspect',
      'requestId': startsWith('heartbeat_'),
      'scheduleId': 'heartbeat-1',
    });
    expect(requests.last, {
      'type': 'schedule/update',
      'requestId': startsWith('heartbeat_'),
      'scheduleId': 'heartbeat-1',
      'cadence': {
        'type': 'cron',
        'expression': '*/15 * * * *',
        'timezone': 'UTC',
      },
    });
    expect(output, startsWith('ID'));
    expect(output, contains('agent:1111111'));
  });

  test('delete enforces caller ownership and returns the frozen row', () async {
    final requests = <Map<String, Object?>>[];
    var error = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['delete', 'heartbeat-1', '--json'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: (request) async {
          requests.add(request);
          return {'schedule': _schedule(agentId: _otherAgentId), 'error': null};
        },
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(requests, hasLength(1));
    expect((jsonDecode(error) as Map)['error'], {
      'code': 'HEARTBEAT_DELETE_FAILED',
      'message':
          'Failed to delete heartbeat: Heartbeat heartbeat-1 does not belong '
          'to agent $_agentId',
    });

    requests.clear();
    var output = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['delete', 'heartbeat-1', '--json'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: (request) async {
          requests.add(request);
          return request['type'] == 'schedule/inspect'
              ? {'schedule': _schedule(), 'error': null}
              : {'scheduleId': 'heartbeat-1', 'error': null};
        },
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(requests.map((request) => request['type']), [
      'schedule/inspect',
      'schedule/delete',
    ]);
    expect(jsonDecode(output), {'id': 'heartbeat-1', 'status': 'deleted'});
  });

  test('caller and cron guards run before daemon requests', () async {
    var calls = 0;
    var error = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['create', 'prompt', '--cron', '* * * * *', '--json'],
        environment: const {},
        request: (_) async {
          calls++;
          return const {};
        },
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(calls, 0);
    expect((jsonDecode(error) as Map)['error'], {
      'code': 'UNKNOWN_ERROR',
      'message': 'Heartbeat commands must run inside a Tinyrack agent',
    });

    error = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['update', 'heartbeat-1', '--cron=', '--json'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: (_) async {
          calls++;
          return const {};
        },
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(calls, 0);
    expect((jsonDecode(error) as Map)['error'], {
      'code': 'UNKNOWN_ERROR',
      'message': '--cron is required',
    });
  });

  test(
    'create matches parseInt, duration, and action error boundaries',
    () async {
      for (final maxRuns in ['0', '-1', 'safe?', '9007199254740992']) {
        var error = '';
        expect(
          await runHeartbeatCommand(
            arguments: [
              'create',
              'prompt',
              '--cron',
              '* * * * *',
              '--max-runs',
              maxRuns,
              '--json',
            ],
            environment: const {'TINYRACK_AGENT_ID': _agentId},
            request: (_) async => fail('invalid max-runs must not reach RPC'),
            writeError: (value) => error += value,
          ),
          1,
        );
        expect(
          (jsonDecode(error) as Map)['error'],
          containsPair('code', 'HEARTBEAT_CREATE_FAILED'),
        );
      }

      var error = '';
      expect(
        await runHeartbeatCommand(
          arguments: [
            'create',
            'prompt',
            '--cron',
            '* * * * *',
            '--expires-in',
            'soon',
            '--json',
          ],
          environment: const {'TINYRACK_AGENT_ID': _agentId},
          request: (_) async => fail('invalid duration must not reach RPC'),
          writeError: (value) => error += value,
        ),
        1,
      );
      expect((jsonDecode(error) as Map)['error'], {
        'code': 'HEARTBEAT_CREATE_FAILED',
        'message':
            'Failed to create heartbeat: Invalid duration format: soon. '
            'Use formats like: 5m, 30s, 1h, 2h30m, 1d',
      });
    },
  );

  test('syntax and option boundaries match the three frozen actions', () async {
    for (final arguments in const [
      <String>[],
      ['future'],
      ['create', 'prompt', '--cron', '* * * * *', '--unknown'],
      ['create', 'prompt', '--cron', '* * * * *', '--format', 'xml'],
      ['create', 'prompt', '--cron', '* * * * *', '--format'],
      ['update', 'id', '--name', 'not-supported'],
      ['delete', 'id', '--cron', '* * * * *'],
      ['delete'],
    ]) {
      var error = '';
      expect(
        await runHeartbeatCommand(
          arguments: arguments,
          environment: const {'TINYRACK_AGENT_ID': _agentId},
          request: (_) async => fail('syntax errors must not reach RPC'),
          writeError: (value) => error += value,
        ),
        64,
        reason: '$arguments',
      );
      expect(error, contains('Usage: coding-agent heartbeat'));
    }
  });

  test('heartbeat supports frozen yaml quiet and table options', () async {
    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        switch (message['type']) {
          'schedule/inspect' => {'schedule': _schedule(), 'error': null},
          'schedule/delete' => {'scheduleId': 'heartbeat-1', 'error': null},
          _ => {'schedule': _schedule(), 'error': null},
        };

    var output = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['create', 'prompt', '--cron', '* * * * *', '--format=yaml'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: request,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, startsWith('id: heartbeat-1\n'));
    expect(output, contains('target: "agent:1111111"'));
    expect(output, contains('lastRunAt: null'));

    output = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['update', 'heartbeat-1', '--cron', '* * * * *', '-q'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: request,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, 'heartbeat-1\n');

    output = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['delete', 'heartbeat-1', '--quiet'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: request,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, 'heartbeat-1\n');

    output = '';
    expect(
      await runHeartbeatCommand(
        arguments: [
          'create',
          'prompt',
          '--cron',
          '* * * * *',
          '--no-headers',
          '--no-color',
        ],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: request,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, isNot(contains('NEXT RUN')));
    expect(output, contains('heartbeat-1'));

    output = '';
    expect(
      await runHeartbeatCommand(
        arguments: [
          'create',
          'prompt',
          '--cron',
          '* * * * *',
          '--json',
          '--format',
          'yaml',
        ],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: request,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(jsonDecode(output), isA<Map<String, dynamic>>());
  });

  test('heartbeat renders runtime errors in YAML', () async {
    var error = '';
    expect(
      await runHeartbeatCommand(
        arguments: ['delete', 'heartbeat-1', '-oyaml'],
        environment: const {'TINYRACK_AGENT_ID': _agentId},
        request: (_) async => {
          'schedule': _schedule(agentId: _otherAgentId),
          'error': null,
        },
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(error, startsWith('error:\n'));
    expect(error, contains('code: HEARTBEAT_DELETE_FAILED'));
    expect(error, contains('does not belong to agent'));
  });
}

Map<String, Object?> _schedule({String agentId = _agentId}) => {
  'id': 'heartbeat-1',
  'name': 'Morning',
  'prompt': 'check the build',
  'cadence': {
    'type': 'cron',
    'expression': '0 9 * * *',
    'timezone': 'Asia/Seoul',
  },
  'target': {'type': 'agent', 'agentId': agentId},
  'status': 'active',
  'createdAt': '2026-07-30T00:00:00.000Z',
  'updatedAt': '2026-07-30T00:00:00.000Z',
  'nextRunAt': '2026-07-31T00:00:00.000Z',
  'lastRunAt': null,
  'pausedAt': null,
  'expiresAt': null,
  'maxRuns': null,
  'runs': const [],
};
