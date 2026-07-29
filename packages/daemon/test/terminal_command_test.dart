import 'dart:convert';

import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:test/test.dart';

void main() {
  test(
    'parser accepts the frozen command surface and rejects invalid forms',
    () {
      final parsed = TerminalCliInvocation.parse([
        'capture',
        'term',
        '--start',
        '-2',
        '--ansi',
        '--json',
      ]);
      expect(parsed.action, 'capture');
      expect(parsed.positionals, ['term']);
      expect(parsed.values['--start'], '-2');
      expect(parsed.flags, containsAll(['--ansi', '--json']));
      expect(parsed.json, isTrue);
      expect(parsed.output.format, 'json');
      expect(
        () => TerminalCliInvocation.parse(const []),
        throwsFormatException,
      );
      expect(() => TerminalCliInvocation.parse(['wat']), throwsFormatException);
      expect(
        () => TerminalCliInvocation.parse(['ls', 'extra']),
        throwsFormatException,
      );
      expect(
        () => TerminalCliInvocation.parse(['create', '--name']),
        throwsFormatException,
      );
      expect(
        () => TerminalCliInvocation.parse(['kill', 't', '--bad']),
        throwsFormatException,
      );
    },
  );

  test('ls emits human table and exact JSON rows', () async {
    final output = StringBuffer();
    final exit = await runTerminalCommand(
      arguments: ['ls', '--all', '--json'],
      request: (message) async {
        expect(message['type'], 'list_terminals_request');
        expect(message, isNot(contains('cwd')));
        return {
          'terminals': [
            {'id': '123456789', 'name': 'Build', 'cwd': '/repo'},
          ],
        };
      },
      writeOutput: output.write,
    );
    expect(exit, 0);
    expect(jsonDecode(output.toString()), [
      {'id': '123456789', 'name': 'Build', 'cwd': '/repo'},
    ]);

    output.clear();
    await runTerminalCommand(
      arguments: ['ls'],
      currentDirectory: '/repo',
      request: (_) async => {
        'cwd': '/repo',
        'terminals': [
          {'id': '123456789', 'name': 'Build'},
        ],
      },
      writeOutput: output.write,
    );
    expect(output.toString(), matches(RegExp(r'12345678  Build +/repo')));
  });

  test('create opens a deduplicated workspace then creates terminal', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    final exit = await runTerminalCommand(
      arguments: ['create', '--cwd', '/repo', '--name', 'Build', '--json'],
      request: (message) async {
        requests.add(message);
        if (message['type'] == 'open_project_request') {
          return {
            'workspace': {'id': 'w1'},
            'error': null,
          };
        }
        return {
          'terminal': {'id': 'terminal-1', 'name': 'Build', 'cwd': '/repo'},
          'error': null,
        };
      },
      writeOutput: output.write,
    );
    expect(exit, 0);
    expect(requests.map((entry) => entry['type']), [
      'open_project_request',
      'create_terminal_request',
    ]);
    expect(requests.last['workspaceId'], 'w1');
    expect(jsonDecode(output.toString())['name'], 'Build');
  });

  test('result actions support frozen shared output options', () async {
    Future<Map<String, Object?>> listRequest(_) async => {
      'terminals': [
        {'id': '123456789', 'name': 'Build', 'cwd': '/repo'},
      ],
    };
    final output = StringBuffer();
    expect(
      await runTerminalCommand(
        arguments: ['ls', '--format=yaml'],
        request: listRequest,
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('id: "123456789"'));
    expect(output.toString(), contains('name: Build'));

    output.clear();
    expect(
      await runTerminalCommand(
        arguments: ['ls', '--quiet'],
        request: listRequest,
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), '123456789\n');

    output.clear();
    expect(
      await runTerminalCommand(
        arguments: ['ls', '--no-headers', '--no-color'],
        request: listRequest,
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), isNot(startsWith('ID')));
    expect(output.toString(), startsWith('12345678'));

    output.clear();
    expect(
      await runTerminalCommand(
        arguments: ['kill', 'Build', '-oyaml'],
        request: (message) async => message['type'] == 'list_terminals_request'
            ? {
                'terminals': [
                  {'id': '123456789', 'name': 'Build'},
                ],
              }
            : {'terminalId': '123456789', 'success': true},
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('terminalId: "123456789"'));
    expect(output.toString(), contains('success: true'));
  });

  test('direct actions retain text or JSON output boundaries', () async {
    Future<Map<String, Object?>> request(message) async {
      if (message['type'] == 'list_terminals_request') {
        return {
          'terminals': [
            {'id': 'abc', 'name': 'Build'},
          ],
        };
      }
      return {
        'terminalId': 'abc',
        'lines': ['one'],
        'totalLines': 1,
      };
    }

    final output = StringBuffer();
    expect(
      await runTerminalCommand(
        arguments: ['capture', 'abc', '--format=yaml', '--quiet'],
        request: request,
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), 'one\n');

    output.clear();
    expect(
      await runTerminalCommand(
        arguments: ['capture', 'abc', '--json', '--no-color'],
        request: request,
        writeOutput: output.write,
      ),
      0,
    );
    expect(jsonDecode(output.toString()), containsPair('lines', ['one']));
  });

  test(
    'capture resolves unique identifiers and supports signed scrollback',
    () async {
      final output = StringBuffer();
      final requests = <Map<String, Object?>>[];
      final exit = await runTerminalCommand(
        arguments: ['capture', 'bui', '-S', '--end', '-1', '--json'],
        request: (message) async {
          requests.add(message);
          if (message['type'] == 'list_terminals_request') {
            return {
              'terminals': [
                {'id': 'abc-123', 'name': 'Build'},
                {'id': 'def-456', 'name': 'Test'},
              ],
            };
          }
          return {
            'terminalId': 'abc-123',
            'lines': ['one', 'two'],
            'totalLines': 2,
          };
        },
        writeOutput: output.write,
      );
      expect(exit, 0);
      expect(requests.last['start'], 0);
      expect(requests.last['end'], -1);
      expect(requests.last['stripAnsi'], isTrue);
      expect(jsonDecode(output.toString())['lines'], ['one', 'two']);
    },
  );

  test('send-keys translates control tokens and literal mode', () async {
    final sent = <Map<String, Object?>>[];
    Future<Map<String, Object?>> lookup(Map<String, Object?> _) async => {
      'terminals': [
        {'id': 'abc', 'name': 'Build'},
      ],
    };
    var exit = await runTerminalCommand(
      arguments: ['send-keys', 'abc', 'C-c', 'Enter', 'Space', 'x', '--json'],
      request: lookup,
      send: (message) async => sent.add(message),
      writeOutput: (_) {},
    );
    expect(exit, 0);
    expect((sent.single['message'] as Map)['data'], '\x03\r x');

    sent.clear();
    exit = await runTerminalCommand(
      arguments: ['send-keys', 'abc', 'Enter', '-l'],
      request: lookup,
      send: (message) async => sent.add(message),
      writeOutput: (_) {},
    );
    expect(exit, 0);
    expect((sent.single['message'] as Map)['data'], 'Enter');
  });

  test(
    'kill resolves case-insensitive exact names and reports result',
    () async {
      final output = StringBuffer();
      final exit = await runTerminalCommand(
        arguments: ['kill', 'BUILD'],
        request: (message) async {
          if (message['type'] == 'list_terminals_request') {
            return {
              'terminals': [
                {'id': 'abc', 'name': 'Build'},
              ],
            };
          }
          return {'terminalId': 'abc', 'success': true};
        },
        writeOutput: output.write,
      );
      expect(exit, 0);
      expect(output.toString(), contains('abc'));
      expect(output.toString(), contains('true'));
    },
  );

  test(
    'identifier resolution follows exact, prefix, name, partial precedence',
    () {
      final terminals = [
        {'id': 'abc-1', 'name': 'Build API'},
        {'id': 'abc-2', 'name': 'Build Web'},
        {'id': 'xyz', 'name': 'Tests'},
      ];
      expect(resolveTerminalIdentifier('xyz', terminals), 'xyz');
      expect(resolveTerminalIdentifier('abc-1', terminals), 'abc-1');
      expect(resolveTerminalIdentifier('abc', terminals), isNull);
      expect(resolveTerminalIdentifier('tests', terminals), 'xyz');
      expect(resolveTerminalIdentifier('web', terminals), 'abc-2');
      expect(resolveTerminalIdentifier('build', terminals), isNull);
      expect(resolveTerminalIdentifier('', terminals), isNull);
    },
  );

  test(
    'command failures return usage or stable terminal error codes',
    () async {
      final errors = StringBuffer();
      expect(
        await runTerminalCommand(
          arguments: ['capture'],
          request: (_) async => {},
          writeError: errors.write,
        ),
        64,
      );
      expect(errors.toString(), contains('Usage: coding-agent terminal'));

      errors.clear();
      expect(
        await runTerminalCommand(
          arguments: ['capture', 'missing'],
          request: (_) async => {'terminals': <Object?>[]},
          writeError: errors.write,
        ),
        1,
      );
      expect(errors.toString(), contains('No terminal found matching'));

      errors.clear();
      expect(
        await runTerminalCommand(
          arguments: ['capture', 'abc', '--start', 'nope'],
          request: (_) async => {
            'terminals': [
              {'id': 'abc', 'name': 'Build'},
            ],
          },
          writeError: errors.write,
        ),
        1,
      );
      expect(errors.toString(), contains('Invalid --start value: nope'));
      expect(errors.toString(), contains('Use an integer line number.'));

      errors.clear();
      expect(
        await runTerminalCommand(
          arguments: ['create'],
          request: (_) async => {'workspace': null, 'error': 'no workspace'},
          writeError: errors.write,
        ),
        1,
      );
      expect(errors.toString(), contains('no workspace'));

      errors.clear();
      expect(
        await runTerminalCommand(
          arguments: ['capture', 'missing', '--json'],
          request: (_) async => {'terminals': <Object?>[]},
          writeError: errors.write,
        ),
        1,
      );
      expect(
        (jsonDecode(errors.toString())['error'] as Map)['code'],
        'TERMINAL_NOT_FOUND',
      );
    },
  );

  test('create reports daemon terminal creation failures', () async {
    final errors = StringBuffer();
    var requestCount = 0;
    final exit = await runTerminalCommand(
      arguments: ['create'],
      request: (_) async {
        requestCount += 1;
        if (requestCount == 1) {
          return {
            'workspace': {'id': 'workspace-1'},
          };
        }
        return {'terminal': null, 'error': 'pty unavailable'};
      },
      writeError: errors.write,
    );

    expect(exit, 1);
    expect(errors.toString(), contains('pty unavailable'));
  });

  test('send-keys reports transport write failures', () async {
    final errors = StringBuffer();
    final exit = await runTerminalCommand(
      arguments: ['send-keys', 'abc', 'Enter'],
      request: (_) async => {
        'terminals': [
          {'id': 'abc', 'name': 'Build'},
        ],
      },
      send: (_) async => throw ArgumentError('write failed'),
      writeError: errors.write,
    );

    expect(exit, 1);
    expect(errors.toString(), contains('write failed'));
  });

  test('rpc request failures use stable error rendering', () async {
    final errors = StringBuffer();
    final exit = await runTerminalCommand(
      arguments: ['ls'],
      request: (_) async => throw StateError('rpc down'),
      writeError: errors.write,
    );

    expect(exit, 1);
    expect(errors.toString(), contains('rpc down'));
  });
}
