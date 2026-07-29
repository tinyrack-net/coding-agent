import 'dart:convert';

import 'package:agent_daemon/src/cli/loop_command.dart';
import 'package:test/test.dart';

void main() {
  group('runLoopCommand', () {
    test(
      'run maps every frozen option and provider/model precedence',
      () async {
        Map<String, Object?>? sent;
        final output = StringBuffer();

        final code = await runLoopCommand(
          arguments: [
            'run',
            'fix everything',
            '--provider',
            'opencode/hy3-preview-free',
            '--model',
            'explicit-model',
            '--mode',
            'build',
            '--verify-provider',
            'codex/gpt-5.4',
            '--verify-model',
            'gpt-5.4-mini',
            '--verify-mode',
            'read-only',
            '--verify',
            'review',
            '--verify-check',
            'dart analyze',
            '--verify-check=flutter test',
            '--archive',
            '--name',
            'green',
            '--sleep',
            '2m30s',
            '--max-iterations',
            '4',
            '--max-time',
            '1h',
            '--json',
          ],
          currentDirectory: r'C:\repo',
          request: (request) async {
            sent = request;
            return {'loop': _loop(), 'error': null};
          },
          writeOutput: output.write,
        );

        expect(code, 0);
        expect(sent, {
          'type': 'loop/run',
          'requestId': isA<String>(),
          'prompt': 'fix everything',
          'cwd': r'C:\repo',
          'provider': 'opencode',
          'model': 'explicit-model',
          'modeId': 'build',
          'verifierProvider': 'codex',
          'verifierModel': 'gpt-5.4-mini',
          'verifierModeId': 'read-only',
          'verifyPrompt': 'review',
          'verifyChecks': ['dart analyze', 'flutter test'],
          'archive': true,
          'name': 'green',
          'sleepMs': 150000,
          'maxIterations': 4,
          'maxTimeMs': 3600000,
        });
        final json = jsonDecode(output.toString()) as Map;
        expect(json, {
          'id': 'abcd1234',
          'status': 'running',
          'name': 'green',
          'cwd': r'C:\repo',
        });
      },
    );

    test('ls renders exact six-column schema and JSON rows', () async {
      final human = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['ls'],
          request: (_) async => {
            'loops': [_listItem()],
            'error': null,
          },
          writeOutput: human.write,
        ),
        0,
      );
      expect(
        human.toString().split('\n').first.trim().split(RegExp(r'\s{2,}')),
        ['LOOP ID', 'NAME', 'STATUS', 'ITER', 'CWD', 'UPDATED'],
      );
      expect(human.toString(), contains('abcd1234'));

      final json = StringBuffer();
      await runLoopCommand(
        arguments: const ['ls', '--json'],
        request: (_) async => {
          'loops': [_listItem()],
          'error': null,
        },
        writeOutput: json.write,
      );
      expect(jsonDecode(json.toString()), [
        {
          'id': 'abcd1234',
          'name': 'green',
          'status': 'running',
          'activeIteration': '1',
          'cwd': r'C:\repo',
          'updated': '2026-07-30T00:00:01.000Z',
        },
      ]);
    });

    test('inspect returns full JSON and human iteration summaries', () async {
      final json = StringBuffer();
      await runLoopCommand(
        arguments: const ['inspect', 'abcd', '--json'],
        request: (request) async {
          expect(request['type'], 'loop/inspect');
          expect(request['id'], 'abcd');
          return {'loop': _loop(withIteration: true), 'error': null};
        },
        writeOutput: json.write,
      );
      expect((jsonDecode(json.toString()) as Map)['verifyChecks'], [
        'dart test',
      ]);

      final human = StringBuffer();
      await runLoopCommand(
        arguments: const ['inspect', 'abcd'],
        request: (_) async => {
          'loop': _loop(withIteration: true),
          'error': null,
        },
        writeOutput: human.write,
      );
      expect(human.toString(), contains('Iterations'));
      expect(
        human.toString(),
        contains('#1 failed worker=worker-1 reason=check failed'),
      );
    });

    test(
      'logs polls by cursor, streams entries, and stops at terminal state',
      () async {
        final requests = <Map<String, Object?>>[];
        final output = StringBuffer();
        var call = 0;
        var delays = 0;

        final code = await runLoopCommand(
          arguments: const ['logs', 'abcd', '--poll-interval', '25'],
          request: (request) async {
            requests.add(request);
            call++;
            return {
              'loop': _loop(status: call == 1 ? 'running' : 'succeeded'),
              'entries': [
                {
                  'seq': call,
                  'timestamp': '2026-07-30T00:00:0$call.000Z',
                  'iteration': call,
                  'source': call == 1 ? 'worker' : 'loop',
                  'level': call == 1 ? 'info' : 'error',
                  'text': call == 1 ? 'working' : 'done',
                },
              ],
              'nextCursor': call,
              'error': null,
            };
          },
          delay: (duration) async {
            expect(duration, const Duration(milliseconds: 25));
            delays++;
          },
          writeOutput: output.write,
        );

        expect(code, 0);
        expect(delays, 1);
        expect(requests.map((request) => request['afterSeq']), [0, 1]);
        expect(output.toString(), contains('worker iteration=1\nworking'));
        expect(output.toString(), contains('loop iteration=2 ERROR\ndone'));
      },
    );

    test('stop emits frozen row schema', () async {
      final output = StringBuffer();
      final code = await runLoopCommand(
        arguments: const ['stop', 'abcd'],
        request: (request) async {
          expect(request['type'], 'loop/stop');
          return {
            'loop': _loop(status: 'stopped')..['activeIteration'] = null,
            'error': null,
          };
        },
        writeOutput: output.write,
      );

      expect(code, 0);
      expect(
        output.toString().split('\n').first.trim().split(RegExp(r'\s{2,}')),
        ['LOOP ID', 'STATUS', 'ITER'],
      );
      expect(output.toString(), contains('stopped'));
    });

    test('supports frozen yaml quiet header and format precedence', () async {
      Future<Map<String, Object?>> request(Map<String, Object?> request) async {
        return switch (request['type']) {
          'loop/list' => {
            'loops': [_listItem()],
            'error': null,
          },
          'loop/inspect' => {'loop': _loop(withIteration: true), 'error': null},
          'loop/stop' => {'loop': _loop(status: 'stopped'), 'error': null},
          _ => {'loop': _loop(), 'error': null},
        };
      }

      final inspectYaml = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['inspect', 'abcd', '--format', 'yaml'],
          request: request,
          writeOutput: inspectYaml.write,
        ),
        0,
      );
      expect(inspectYaml.toString(), startsWith('id: abcd1234\n'));
      expect(inspectYaml.toString(), contains('iterations:\n'));
      expect(inspectYaml.toString(), isNot(contains('key: Id')));

      final quiet = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['ls', '--quiet'],
          request: request,
          writeOutput: quiet.write,
        ),
        0,
      );
      expect(quiet.toString(), 'abcd1234\n');

      final noHeaders = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['stop', 'abcd', '--no-headers', '--no-color'],
          request: request,
          writeOutput: noHeaders.write,
        ),
        0,
      );
      expect(noHeaders.toString(), isNot(contains('LOOP ID')));
      expect(noHeaders.toString(), contains('stopped'));

      final jsonWins = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['run', 'go', '--format=yaml', '--json'],
          request: request,
          writeOutput: jsonWins.write,
        ),
        0,
      );
      expect(jsonDecode(jsonWins.toString()), isA<Map>());
    });

    test('preserves frozen raw action errors in YAML', () async {
      final error = StringBuffer();
      final code = await runLoopCommand(
        arguments: const ['inspect', 'missing', '-oyaml'],
        request: (_) async => {'loop': null, 'error': 'Loop not found'},
        writeError: error.write,
      );

      expect(code, 1);
      expect(
        error.toString(),
        startsWith('error:\n  code: LOOP_INSPECT_FAILED\n'),
      );
      expect(error.toString(), contains('message: Loop not found\n'));
      expect(error.toString(), isNot(contains('Failed to inspect loop')));
    });

    test('accepts frozen empty prompt and verify-check values', () async {
      Map<String, Object?>? sent;
      expect(
        await runLoopCommand(
          arguments: const ['run', '', '--verify-check', '', '--quiet'],
          request: (request) async {
            sent = request;
            return {'loop': _loop(), 'error': null};
          },
          writeOutput: (_) {},
        ),
        0,
      );
      expect(sent!['prompt'], '');
      expect(sent!['verifyChecks'], ['']);
    });

    test('keeps logs streaming-only and rejects invalid formats', () async {
      for (final arguments in const [
        ['logs', 'abcd', '--json'],
        ['logs', 'abcd', '--quiet'],
        ['logs', 'abcd', '--format', 'yaml'],
        ['ls', '--format'],
        ['ls', '--format', 'xml'],
        ['stop', 'abcd', '-oxml'],
      ]) {
        expect(
          await runLoopCommand(
            arguments: arguments,
            request: (_) async => fail('syntax failure must not call daemon'),
            writeError: (_) {},
          ),
          64,
          reason: '$arguments',
        );
      }
    });

    test(
      'validates options before transport and returns stable error codes',
      () async {
        for (final testCase in [
          (
            args: ['run', 'go', '--max-iterations', '0'],
            code: 'INVALID_MAX_ITERATIONS',
          ),
          (args: ['run', 'go', '--verify', ' '], code: 'INVALID_VERIFY_PROMPT'),
          (
            args: ['logs', 'x', '--poll-interval', '0'],
            code: 'INVALID_POLL_INTERVAL',
          ),
        ]) {
          final error = StringBuffer();
          var called = false;
          final code = await runLoopCommand(
            arguments: [...testCase.args, '--json'],
            request: (_) async {
              called = true;
              return {};
            },
            writeError: error.write,
          );
          expect(code, testCase.args.first == 'logs' ? 64 : 1);
          if (testCase.args.first != 'logs') {
            expect(
              (jsonDecode(error.toString()) as Map)['error']['code'],
              testCase.code,
            );
          }
          expect(called, isFalse);
        }
      },
    );

    test('matches JavaScript parseInt option semantics', () async {
      Map<String, Object?>? sent;
      final output = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const [
            'run',
            '  preserve prompt whitespace  ',
            '--max-iterations',
            '3iterations',
            '--verify-check',
            'ok',
            '--json',
          ],
          currentDirectory: '.',
          request: (request) async {
            sent = request;
            return {'loop': _loop(), 'error': null};
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(sent!['prompt'], '  preserve prompt whitespace  ');
      expect(sent!['maxIterations'], 3);
    });

    test('contains daemon errors and help/usage behavior', () async {
      final error = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['inspect', 'missing', '--json'],
          request: (_) async => {'loop': null, 'error': 'Loop not found'},
          writeError: error.write,
        ),
        1,
      );
      expect(
        (jsonDecode(error.toString()) as Map)['error']['code'],
        'LOOP_INSPECT_FAILED',
      );

      final help = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['run', '--help'],
          writeOutput: help.write,
        ),
        0,
      );
      expect(help.toString(), contains('--verify-check <command>'));

      final usage = StringBuffer();
      expect(
        await runLoopCommand(
          arguments: const ['unknown'],
          writeError: usage.write,
        ),
        64,
      );
      expect(usage.toString(), contains('Unknown loop action'));
    });
  });

  test('parseLoopDuration supports Paseo compound durations', () {
    expect(parseLoopDuration('1h30m5s'), 5405000);
    expect(parseLoopDuration('15'), 15000);
    expect(
      () => parseLoopDuration('500ms'),
      throwsA(isA<LoopCommandException>()),
    );
    expect(
      () => parseLoopDuration('tomorrow'),
      throwsA(isA<LoopCommandException>()),
    );
  });
}

Map<String, Object?> _listItem() => {
  'id': 'abcd1234',
  'name': 'green',
  'status': 'running',
  'cwd': r'C:\repo',
  'createdAt': '2026-07-30T00:00:00.000Z',
  'updatedAt': '2026-07-30T00:00:01.000Z',
  'activeIteration': 1,
};

Map<String, Object?> _loop({
  String status = 'running',
  bool withIteration = false,
}) => {
  'id': 'abcd1234',
  'name': 'green',
  'prompt': 'fix everything',
  'cwd': r'C:\repo',
  'provider': 'codex',
  'model': 'gpt-5.4',
  'modeId': 'full-access',
  'workerProvider': null,
  'workerModel': null,
  'verifierProvider': null,
  'verifierModel': null,
  'verifierModeId': null,
  'verifyPrompt': null,
  'verifyChecks': ['dart test'],
  'archive': false,
  'sleepMs': 0,
  'maxIterations': null,
  'maxTimeMs': null,
  'status': status,
  'createdAt': '2026-07-30T00:00:00.000Z',
  'updatedAt': '2026-07-30T00:00:01.000Z',
  'startedAt': '2026-07-30T00:00:00.000Z',
  'completedAt': null,
  'stopRequestedAt': null,
  'iterations': withIteration
      ? [
          {
            'index': 1,
            'workerAgentId': 'worker-1',
            'workerStartedAt': '2026-07-30T00:00:00.000Z',
            'workerCompletedAt': '2026-07-30T00:00:01.000Z',
            'verifierAgentId': null,
            'status': 'failed',
            'workerOutcome': 'completed',
            'failureReason': 'check failed',
            'verifyChecks': <Object?>[],
            'verifyPrompt': null,
          },
        ]
      : <Object?>[],
  'logs': <Object?>[],
  'nextLogSeq': 1,
  'activeIteration': 1,
  'activeWorkerAgentId': null,
  'activeVerifierAgentId': null,
};
