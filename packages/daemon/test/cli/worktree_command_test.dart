import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/worktree_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('worktree create input', () {
    test('requires a supported mode', () {
      expect(
        () => _build(['create']),
        throwsA(
          isA<WorktreeCommandException>().having(
            (error) => error.code,
            'code',
            'MISSING_MODE',
          ),
        ),
      );
      expect(
        () => _build(['create', '--mode', 'fork']),
        throwsA(
          isA<WorktreeCommandException>().having(
            (error) => error.code,
            'code',
            'INVALID_MODE',
          ),
        ),
      );
    });

    test('branch-off requires and maps the new branch and base', () {
      expect(
        () => _build(['create', '--mode', 'branch-off']),
        throwsA(
          isA<WorktreeCommandException>().having(
            (error) => error.code,
            'code',
            'MISSING_NEW_BRANCH',
          ),
        ),
      );
      expect(
        _build([
          'create',
          '--mode',
          'branch-off',
          '--new-branch',
          'feature-x',
          '--base',
          'main',
        ]).toJson(),
        {
          'type': 'create_paseo_worktree_request',
          'requestId': 'test',
          'cwd': '/repo',
          'worktreeSlug': 'feature-x',
          'refName': 'main',
          'action': 'branch-off',
        },
      );
    });

    test('checkout branch requires and maps the existing branch', () {
      expect(
        () => _build(['create', '--mode', 'checkout-branch']),
        throwsA(
          isA<WorktreeCommandException>().having(
            (error) => error.code,
            'code',
            'MISSING_BRANCH',
          ),
        ),
      );
      expect(
        _build([
          'create',
          '--mode',
          'checkout-branch',
          '--branch',
          'existing',
        ]).toJson(),
        {
          'type': 'create_paseo_worktree_request',
          'requestId': 'test',
          'cwd': '/repo',
          'refName': 'existing',
          'action': 'checkout',
        },
      );
    });

    test('checkout PR validates a positive integer', () {
      for (final value in ['', '0', '-1', 'abc', '1.5']) {
        expect(
          () =>
              _build(['create', '--mode', 'checkout-pr', '--pr-number', value]),
          throwsA(isA<WorktreeCommandException>()),
        );
      }
      expect(
        _build([
          'create',
          '--mode',
          'checkout-pr',
          '--pr-number',
          '42',
          '--cwd',
          '/other',
        ]).toJson(),
        {
          'type': 'create_paseo_worktree_request',
          'requestId': 'test',
          'cwd': '/other',
          'action': 'checkout',
          'githubPrNumber': 42,
        },
      );
    });
  });

  test('supports shared output aliases and frozen option forms', () async {
    final parsed = WorktreeCliInvocation.parse(const [
      'create',
      '--mode=branch-off',
      '--new-branch=feature-x',
      '--host=ws://127.0.0.1:7777',
      '--format=yaml',
      '--json',
      '--no-color',
    ]);
    expect(parsed.values['--mode'], 'branch-off');
    expect(parsed.values['--new-branch'], 'feature-x');
    expect(parsed.host, 'ws://127.0.0.1:7777');
    expect(parsed.output.format, 'json');
    expect(parsed.output.noColor, isTrue);

    final output = StringBuffer();
    expect(
      await runWorktreeCommand(
        arguments: const ['archive', '-ocli', '--no-headers', '--', '-feature'],
        request: (message) async {
          if (message['type'] == PaseoWorktreeListRequest.type) {
            return {
              'requestId': message['requestId'],
              'worktrees': [
                {
                  'worktreePath': '/managed/-feature',
                  'createdAt': 'now',
                  'branchName': 'feature',
                  'head': null,
                },
              ],
              'error': null,
            };
          }
          return {
            'requestId': message['requestId'],
            'success': true,
            'removedAgents': <String>[],
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), isNot(contains('REMOVED AGENTS')));
    expect(output.toString(), contains('-feature'));
    expect(output.toString(), contains('archived'));
  });

  test('shared yaml renders worktree command errors', () async {
    final error = StringBuffer();
    expect(
      await runWorktreeCommand(
        arguments: const ['archive', 'missing', '--format=yaml'],
        request: (message) async => {
          'requestId': message['requestId'],
          'worktrees': <Object?>[],
          'error': null,
        },
        writeError: error.write,
      ),
      1,
    );
    expect(error.toString(), contains('error:'));
    expect(error.toString(), contains('code: WORKTREE_NOT_FOUND'));
    expect(
      error.toString(),
      contains('message: "Worktree not found: missing"'),
    );
  });

  test('help and binary dispatch expose all worktree commands', () async {
    for (final arguments in const [
      ['--help'],
      ['create', '--help'],
      ['ls', '--help'],
      ['archive', '--help'],
    ]) {
      final output = StringBuffer();
      expect(
        await runWorktreeCommand(
          arguments: arguments,
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('Usage: coding-agent worktree'));
    }
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    final result = await Process.run(Platform.resolvedExecutable, const [
      'run',
      'agent_daemon:coding_agent',
      'worktree',
      '--help',
    ], workingDirectory: packageRoot);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Manage Tinyrack-managed git worktrees'));
    expect(result.stderr, isEmpty);
  });

  test('create sends legacy wire and renders the returned workspace', () async {
    Map<String, Object?>? sent;
    final output = StringBuffer();
    expect(
      await runWorktreeCommand(
        arguments: const [
          'create',
          '--mode',
          'branch-off',
          '--new-branch',
          'feature-x',
          '--json',
        ],
        currentDirectory: '/repo',
        request: (message) async {
          sent = message;
          return {
            'requestId': message['requestId'],
            'workspace': _workspace(
              name: 'feature-x',
              cwd: '/managed/feature-x',
            ),
            'error': null,
            'setupTerminalId': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(sent?['type'], CreatePaseoWorktreeRequest.type);
    expect(sent?['worktreeSlug'], 'feature-x');
    expect(jsonDecode(output.toString()), {
      'name': 'feature-x',
      'branchName': 'feature-x',
      'worktreePath': '/managed/feature-x',
    });
  });

  test('list joins only agents inside the Tinyrack worktree root', () async {
    final separator = p.separator;
    final home = '${separator}home${separator}user';
    final managed =
        '$home${separator}.tinyrack-agent${separator}worktrees${separator}feature';
    final outside = '${separator}tmp${separator}feature';
    final output = StringBuffer();
    final requests = <Map<String, Object?>>[];
    expect(
      await runWorktreeCommand(
        arguments: const ['ls', '--no-headers'],
        environment: {'HOME': home, 'USERPROFILE': home},
        request: (message) async {
          requests.add(message);
          if (message['type'] == FetchAgentsRequest.type) {
            return {
              'requestId': message['requestId'],
              'entries': [
                {
                  'agent': {'id': 'abcdefghi', 'cwd': managed},
                  'project': <String, Object?>{},
                },
                {
                  'agent': {'id': 'outside1', 'cwd': outside},
                  'project': <String, Object?>{},
                },
              ],
              'pageInfo': {
                'nextCursor': null,
                'prevCursor': null,
                'hasMore': false,
              },
            };
          }
          return {
            'requestId': message['requestId'],
            'worktrees': [
              {
                'worktreePath': managed,
                'createdAt': 'now',
                'branchName': 'feature',
                'head': null,
              },
              {
                'worktreePath': outside,
                'createdAt': 'now',
                'branchName': null,
                'head': null,
              },
            ],
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(requests.map((request) => request['type']), [
      FetchAgentsRequest.type,
      PaseoWorktreeListRequest.type,
    ]);
    expect(output.toString(), contains('abcdefg'));
    expect(output.toString(), contains('~'));
    expect(output.toString(), contains('feature'));
    expect(output.toString(), contains(' -'));
    expect(output.toString(), isNot(contains('outside1')));
  });

  test('list follows agent cursor pages and supports output formats', () async {
    var page = 0;
    Future<Map<String, Object?>> request(Map<String, Object?> message) async {
      if (message['type'] == FetchAgentsRequest.type) {
        page++;
        return {
          'requestId': message['requestId'],
          'entries': <Object?>[],
          'pageInfo': {
            'nextCursor': page == 1 ? 'next' : null,
            'prevCursor': null,
            'hasMore': page == 1,
          },
        };
      }
      return {
        'requestId': message['requestId'],
        'worktrees': [
          {
            'worktreePath': '/managed/one',
            'createdAt': 'now',
            'branchName': 'one',
            'head': null,
          },
        ],
        'error': null,
      };
    }

    final jsonOutput = StringBuffer();
    await runWorktreeCommand(
      arguments: const ['ls', '--json'],
      request: request,
      writeOutput: jsonOutput.write,
    );
    expect(page, 2);
    expect(jsonDecode(jsonOutput.toString()), isA<List<dynamic>>());

    page = 0;
    final yamlOutput = StringBuffer();
    await runWorktreeCommand(
      arguments: const ['ls', '--format', 'yaml'],
      request: request,
      writeOutput: yamlOutput.write,
    );
    expect(yamlOutput.toString(), startsWith('- name: one'));

    page = 0;
    final quietOutput = StringBuffer();
    await runWorktreeCommand(
      arguments: const ['ls', '--quiet'],
      request: request,
      writeOutput: quietOutput.write,
    );
    expect(quietOutput.toString(), 'one\n');
  });

  test(
    'archive resolves directory or branch and sends worktree scope',
    () async {
      for (final name in const ['feature-dir', 'feature-branch']) {
        final requests = <Map<String, Object?>>[];
        final output = StringBuffer();
        expect(
          await runWorktreeCommand(
            arguments: ['archive', name, '--json'],
            request: (message) async {
              requests.add(message);
              if (message['type'] == PaseoWorktreeListRequest.type) {
                return {
                  'requestId': message['requestId'],
                  'worktrees': [
                    {
                      'worktreePath': '/managed/feature-dir',
                      'createdAt': 'now',
                      'branchName': 'feature-branch',
                      'head': null,
                    },
                  ],
                  'error': null,
                };
              }
              return {
                'requestId': message['requestId'],
                'success': true,
                'removedAgents': ['agent-1'],
                'error': null,
              };
            },
            writeOutput: output.write,
          ),
          0,
        );
        expect(requests.last['type'], PaseoWorktreeArchiveRequest.type);
        expect(requests.last['worktreePath'], '/managed/feature-dir');
        expect(requests.last['scope'], 'worktree');
        expect(jsonDecode(output.toString()), {
          'name': 'feature-dir',
          'status': 'archived',
          'removedAgents': ['agent-1'],
        });
      }
    },
  );

  test('archive reports not found and daemon checkout errors', () async {
    final notFound = StringBuffer();
    expect(
      await runWorktreeCommand(
        arguments: const ['archive', 'missing', '--json'],
        request: (message) async => {
          'requestId': message['requestId'],
          'worktrees': <Object?>[],
          'error': null,
        },
        writeError: notFound.write,
      ),
      1,
    );
    expect(
      (jsonDecode(notFound.toString())
          as Map<String, dynamic>)['error']['code'],
      'WORKTREE_NOT_FOUND',
    );

    final listError = StringBuffer();
    expect(
      await runWorktreeCommand(
        arguments: const ['ls', '--json'],
        request: (message) async {
          if (message['type'] == FetchAgentsRequest.type) {
            return {
              'requestId': message['requestId'],
              'entries': <Object?>[],
              'pageInfo': {
                'nextCursor': null,
                'prevCursor': null,
                'hasMore': false,
              },
            };
          }
          return {
            'requestId': message['requestId'],
            'worktrees': <Object?>[],
            'error': {'code': 'UNKNOWN', 'message': 'git failed'},
          };
        },
        writeError: listError.write,
      ),
      1,
    );
    expect(
      (jsonDecode(listError.toString())
          as Map<String, dynamic>)['error']['message'],
      'Failed to list worktrees: git failed',
    );
  });
}

CreatePaseoWorktreeRequest _build(List<String> arguments) =>
    buildCreateWorktreeRequest(
      WorktreeCliInvocation.parse(arguments),
      '/repo',
      requestId: 'test',
    );

Map<String, Object?> _workspace({required String name, required String cwd}) =>
    {
      'id': 'workspace-1',
      'projectId': 'project-1',
      'projectDisplayName': 'Project',
      'projectRootPath': '/repo',
      'workspaceDirectory': cwd,
      'projectKind': 'git',
      'workspaceKind': 'worktree',
      'name': name,
      'status': 'done',
      'activityAt': null,
      'scripts': <Object?>[],
      'gitRuntime': null,
    };
