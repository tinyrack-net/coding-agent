import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/script_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('help and binary dispatch expose every script command', () async {
    for (final arguments in const [
      ['--help'],
      ['ls', '--help'],
      ['start', '--help'],
      ['stop', '--help'],
    ]) {
      final output = StringBuffer();
      expect(
        await runScriptCommand(arguments: arguments, writeOutput: output.write),
        0,
      );
      expect(output.toString(), contains('Usage: coding-agent script'));
    }

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    final result = await Process.run(Platform.resolvedExecutable, const [
      'run',
      'agent_daemon:coding_agent',
      'script',
      '--help',
    ], workingDirectory: packageRoot);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Manage configured workspace scripts'));
    expect(result.stdout, contains('start'));
    expect(result.stderr, isEmpty);
  });

  test(
    '--workspace takes precedence and ls sends the frozen request',
    () async {
      final requests = <Map<String, Object?>>[];
      final output = StringBuffer();
      expect(
        await runScriptCommand(
          arguments: const [
            'ls',
            '--workspace',
            'workspace-1',
            '--cwd',
            'ignored',
            '--json',
          ],
          currentDirectory: p.join('C:', 'repo'),
          request: (message) async {
            requests.add(message);
            return {
              'requestId': message['requestId'],
              'workspaceId': 'workspace-1',
              'scripts': [_script()],
              'error': null,
            };
          },
          writeOutput: output.write,
        ),
        0,
      );
      expect(requests, hasLength(1));
      expect(requests.single['type'], 'workspace.script.list.request');
      expect(requests.single['workspaceId'], 'workspace-1');
      final result = jsonDecode(output.toString()) as List<dynamic>;
      expect(result.single['scriptName'], 'dev');
      expect(result.single['lifecycle'], 'running');
    },
  );

  test(
    'cwd resolution requests one 200-entry page and normalizes paths',
    () async {
      final requests = <Map<String, Object?>>[];
      expect(
        await runScriptCommand(
          arguments: const ['ls', '--cwd', 'nested', '--no-headers'],
          currentDirectory: p.join('C:', 'repo'),
          request: (message) async {
            requests.add(message);
            if (message['type'] == 'fetch_workspaces_request') {
              return {
                'requestId': message['requestId'],
                'entries': [
                  _workspace(
                    id: 'workspace-1',
                    directory: p.join('C:', 'repo', 'other', '..', 'nested'),
                  ),
                ],
                'emptyProjects': <Object?>[],
                'pageInfo': {
                  'nextCursor': 'ignored-by-frozen-cli',
                  'prevCursor': null,
                  'hasMore': true,
                },
              };
            }
            return {
              'requestId': message['requestId'],
              'workspaceId': 'workspace-1',
              'scripts': <Object?>[],
              'error': null,
            };
          },
        ),
        0,
      );
      expect(requests, hasLength(2));
      expect(requests.first['type'], 'fetch_workspaces_request');
      expect(requests.first['page'], {'limit': 200});
      expect(requests.last['workspaceId'], 'workspace-1');
    },
  );

  test('cwd resolution reports missing and ambiguous workspaces', () async {
    Future<Map<String, Object?>> noMatches(
      Map<String, Object?> message,
    ) async => {
      'requestId': message['requestId'],
      'entries': <Object?>[],
      'emptyProjects': <Object?>[],
      'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
    };
    final missing = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const ['ls', '--json'],
        currentDirectory: p.join('C:', 'missing'),
        request: noMatches,
        writeError: missing.write,
      ),
      1,
    );
    expect(
      (jsonDecode(missing.toString()) as Map<String, dynamic>)['error']['code'],
      'WORKSPACE_NOT_FOUND',
    );

    final ambiguous = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const ['ls', '--json'],
        currentDirectory: p.join('C:', 'repo'),
        request: (message) async => {
          'requestId': message['requestId'],
          'entries': [
            _workspace(id: 'one', directory: p.join('C:', 'repo')),
            _workspace(id: 'two', directory: p.join('C:', 'repo')),
          ],
          'emptyProjects': <Object?>[],
          'pageInfo': {
            'nextCursor': null,
            'prevCursor': null,
            'hasMore': false,
          },
        },
        writeError: ambiguous.write,
      ),
      1,
    );
    final payload = jsonDecode(ambiguous.toString()) as Map<String, dynamic>;
    expect(payload['error']['code'], 'WORKSPACE_AMBIGUOUS');
    expect(payload['error']['details'], contains('--workspace'));
  });

  test(
    'start and stop require metadata and preserve operation errors',
    () async {
      for (final action in const ['start', 'stop']) {
        Map<String, Object?>? sent;
        final output = StringBuffer();
        expect(
          await runScriptCommand(
            arguments: [action, 'dev', '--workspace', 'workspace-1', '--json'],
            request: (message) async {
              sent = message;
              return {
                'requestId': message['requestId'],
                'workspaceId': 'workspace-1',
                'scriptName': 'dev',
                'script': _script(
                  lifecycle: action == 'start' ? 'running' : 'stopped',
                ),
                'error': null,
              };
            },
            writeOutput: output.write,
          ),
          0,
        );
        expect(sent?['type'], 'workspace.script.$action.request');
        expect(sent?['scriptName'], 'dev');
        expect(
          (jsonDecode(output.toString()) as Map<String, dynamic>)['lifecycle'],
          action == 'start' ? 'running' : 'stopped',
        );
      }

      final missing = StringBuffer();
      expect(
        await runScriptCommand(
          arguments: const [
            'start',
            'dev',
            '--workspace',
            'workspace-1',
            '--json',
          ],
          request: (message) async => {
            'requestId': message['requestId'],
            'workspaceId': 'workspace-1',
            'scriptName': 'dev',
            'script': null,
            'error': null,
          },
          writeError: missing.write,
        ),
        1,
      );
      expect(
        (jsonDecode(missing.toString())
            as Map<String, dynamic>)['error']['code'],
        'WORKSPACE_SCRIPT_START_FAILED',
      );

      final daemonError = StringBuffer();
      await runScriptCommand(
        arguments: const [
          'stop',
          'dev',
          '--workspace',
          'workspace-1',
          '--json',
        ],
        request: (message) async => {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'scriptName': 'dev',
          'script': null,
          'error': 'not running',
        },
        writeError: daemonError.write,
      );
      expect(
        (jsonDecode(daemonError.toString())
            as Map<String, dynamic>)['error']['message'],
        'not running',
      );

      final resolutionError = StringBuffer();
      await runScriptCommand(
        arguments: const ['start', 'dev', '--json'],
        request: (_) async => throw StateError('workspace lookup failed'),
        writeError: resolutionError.write,
      );
      expect(
        (jsonDecode(resolutionError.toString())
            as Map<String, dynamic>)['error']['code'],
        'WORKSPACE_SCRIPT_START_FAILED',
      );
    },
  );

  test('list supports table yaml quiet and empty output', () async {
    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'scripts': [_script()],
          'error': null,
        };
    final table = StringBuffer();
    await runScriptCommand(
      arguments: const ['ls', '--workspace', 'workspace-1'],
      request: request,
      writeOutput: table.write,
    );
    expect(table.toString(), contains('PROXY URL'));
    expect(table.toString(), contains('dev'));

    final yaml = StringBuffer();
    await runScriptCommand(
      arguments: const ['ls', '--workspace', 'workspace-1', '--format', 'yaml'],
      request: request,
      writeOutput: yaml.write,
    );
    expect(yaml.toString(), startsWith('- scriptName: dev'));

    final quiet = StringBuffer();
    await runScriptCommand(
      arguments: const ['ls', '--workspace', 'workspace-1', '--quiet'],
      request: request,
      writeOutput: quiet.write,
    );
    expect(quiet.toString(), 'dev\n');

    final empty = StringBuffer();
    await runScriptCommand(
      arguments: const ['ls', '--workspace', 'workspace-1', '--no-headers'],
      request: (message) async => {
        'requestId': message['requestId'],
        'workspaceId': 'workspace-1',
        'scripts': <Object?>[],
        'error': null,
      },
      writeOutput: empty.write,
    );
    expect(empty, isEmpty);
  });

  test('shared output aliases and JSON precedence match frozen CLI', () async {
    final parsed = ScriptCliInvocation.parse(const [
      'ls',
      '--format=yaml',
      '--json',
      '--no-color',
    ]);
    expect(parsed.output.format, 'json');
    expect(parsed.output.noColor, isTrue);

    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'scripts': [_script()],
          'error': null,
        };
    final yaml = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const ['ls', '--workspace=workspace-1', '-oyaml'],
        request: request,
        writeOutput: yaml.write,
      ),
      0,
    );
    expect(yaml.toString(), startsWith('- scriptName: dev'));

    final single = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const [
          'start',
          'dev',
          '--workspace=workspace-1',
          '--format=yaml',
        ],
        request: (message) async => {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'scriptName': 'dev',
          'script': _script(),
          'error': null,
        },
        writeOutput: single.write,
      ),
      0,
    );
    expect(single.toString(), startsWith('scriptName: dev'));
  });

  test('script failures honor YAML output', () async {
    final error = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const ['ls', '--workspace', 'workspace-1', '--format=yaml'],
        request: (_) async => throw StateError('offline'),
        writeError: error.write,
      ),
      1,
    );
    expect(error.toString(), contains('code: WORKSPACE_SCRIPT_LIST_FAILED'));
    expect(
      error.toString(),
      contains('message: "Failed to list workspace scripts: offline"'),
    );
  });

  test('list rejects malformed script entries at the CLI boundary', () async {
    final error = StringBuffer();
    expect(
      await runScriptCommand(
        arguments: const ['ls', '--workspace', 'workspace-1', '--json'],
        request: (message) async => {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'scripts': ['invalid'],
          'error': null,
        },
        writeError: error.write,
      ),
      1,
    );
    expect(
      (jsonDecode(error.toString()) as Map<String, dynamic>)['error']['code'],
      'WORKSPACE_SCRIPT_LIST_FAILED',
    );
  });

  test('parser failures use usage exit code', () async {
    for (final arguments in const [
      <String>[],
      ['unknown'],
      ['ls', 'extra'],
      ['start'],
      ['stop', 'one', 'two'],
      ['ls', '--format', 'xml'],
      ['ls', '--unknown'],
    ]) {
      final error = StringBuffer();
      expect(
        await runScriptCommand(arguments: arguments, writeError: error.write),
        64,
      );
      expect(error.toString(), contains('Usage: coding-agent script'));
    }
  });
}

Map<String, Object?> _script({String lifecycle = 'running'}) => {
  'scriptName': 'dev',
  'type': 'service',
  'hostname': 'dev--workspace.localhost',
  'port': 3000,
  'localProxyUrl': 'http://dev--workspace.localhost:6868',
  'publicProxyUrl': null,
  'proxyUrl': 'http://dev--workspace.localhost:6868',
  'lifecycle': lifecycle,
  'health': lifecycle == 'running' ? 'healthy' : null,
  'exitCode': lifecycle == 'running' ? null : 0,
  'terminalId': lifecycle == 'running' ? 'terminal-1' : null,
};

Map<String, Object?> _workspace({
  required String id,
  required String directory,
}) => {'id': id, 'workspaceDirectory': directory};
