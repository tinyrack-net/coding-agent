import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/workspace_command.dart';
import 'package:test/test.dart';

void main() {
  group('workspace create source', () {
    test('maps local isolation to a directory workspace', () {
      expect(
        _source([
          'create',
          '--isolation',
          'local',
          '--path',
          '/tmp/project',
          '--project',
          'project-1',
        ]),
        {'kind': 'directory', 'path': '/tmp/project', 'projectId': 'project-1'},
      );
    });

    test('keeps branch names separate from managed worktree slugs', () {
      expect(
        _source([
          'create',
          '--isolation',
          'worktree',
          '--path',
          '/tmp/project',
          '--mode',
          'branch-off',
          '--new-branch',
          'feature/auth',
          '--worktree-slug',
          'feature-auth',
          '--base',
          'main',
        ]),
        {
          'kind': 'worktree',
          'cwd': '/tmp/project',
          'action': 'branch-off',
          'branchName': 'feature/auth',
          'worktreeSlug': 'feature-auth',
          'baseBranch': 'main',
        },
      );
    });

    test('uses a project without capturing the ambient directory', () {
      expect(
        _source([
          'create',
          '--isolation',
          'worktree',
          '--project',
          'project-1',
          '--new-branch',
          'fix-x',
        ]),
        {
          'kind': 'worktree',
          'projectId': 'project-1',
          'action': 'branch-off',
          'branchName': 'fix-x',
        },
      );
    });

    test('checks out an existing branch', () {
      expect(
        _source([
          'create',
          '--isolation',
          'worktree',
          '--mode',
          'checkout-branch',
          '--branch',
          'existing-work',
          '--worktree-slug',
          'existing-work-copy',
        ]),
        {
          'kind': 'worktree',
          'cwd': '/current',
          'action': 'checkout',
          'refName': 'existing-work',
          'worktreeSlug': 'existing-work-copy',
        },
      );
    });

    test('checks out a change request with optional forge', () {
      expect(
        _source([
          'create',
          '--isolation',
          'worktree',
          '--mode',
          'checkout-pr',
          '--pr-number',
          '42',
          '--forge',
          'gitlab',
        ]),
        {
          'kind': 'worktree',
          'cwd': '/current',
          'action': 'checkout',
          'checkoutSource': {
            'kind': 'change_request',
            'forge': 'gitlab',
            'number': 42,
          },
        },
      );
      expect(
        (_source([
              'create',
              '--isolation',
              'worktree',
              '--mode',
              'checkout-pr',
              '--pr-number',
              '42',
            ])['checkoutSource']
            as Map<String, Object?>),
        {'kind': 'change_request', 'number': 42},
      );
    });

    test('rejects invalid isolation and mode-specific combinations', () {
      expect(
        () => _source(['create', '--isolation', 'container']),
        throwsFormatException,
      );
      expect(
        () =>
            _source(['create', '--isolation', 'local', '--mode', 'branch-off']),
        throwsFormatException,
      );
      expect(
        () => _source([
          'create',
          '--isolation',
          'worktree',
          '--mode',
          'checkout-branch',
        ]),
        throwsFormatException,
      );
      expect(
        () => _source([
          'create',
          '--isolation',
          'worktree',
          '--mode',
          'checkout-pr',
          '--pr-number',
          '0',
        ]),
        throwsFormatException,
      );
      expect(
        () => _source([
          'create',
          '--isolation',
          'worktree',
          '--mode',
          'checkout-pr',
          '--pr-number',
          '1.5',
        ]),
        throwsFormatException,
      );
    });
  });

  test('help and binary dispatch expose all workspace commands', () async {
    for (final arguments in const [
      ['--help'],
      ['create', '--help'],
      ['ls', '--help'],
      ['archive', '--help'],
    ]) {
      final output = StringBuffer();
      expect(
        await runWorkspaceCommand(
          arguments: arguments,
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('Usage: coding-agent workspace'));
    }

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    final result = await Process.run(Platform.resolvedExecutable, const [
      'run',
      'agent_daemon:coding_agent',
      'workspace',
      '--help',
    ], workingDirectory: packageRoot);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Manage workspaces'));
    expect(result.stdout, contains('archive'));
    expect(result.stderr, isEmpty);
  });

  test('create sends frozen request and renders a single row', () async {
    Map<String, Object?>? sent;
    final output = StringBuffer();
    final exitCode = await runWorkspaceCommand(
      arguments: const [
        'create',
        '--isolation',
        'worktree',
        '--new-branch',
        'feature/auth',
        '--title',
        'Authentication',
        '--json',
      ],
      currentDirectory: '/repo',
      request: (message) async {
        sent = message;
        return {
          'requestId': message['requestId'],
          'workspace': _workspace(
            id: 'workspace-1',
            kind: 'worktree',
            name: 'feature/auth',
            cwd: '/managed/feature-auth',
          ),
          'setupTerminalId': null,
          'error': null,
        };
      },
      writeOutput: output.write,
    );

    expect(exitCode, 0);
    expect(sent?['type'], 'workspace.create.request');
    expect(sent?['title'], 'Authentication');
    expect(sent?['source'], {
      'kind': 'worktree',
      'cwd': '/repo',
      'action': 'branch-off',
      'branchName': 'feature/auth',
    });
    expect(jsonDecode(output.toString()), {
      'workspaceId': 'workspace-1',
      'project': 'Example',
      'name': 'feature/auth',
      'isolation': 'worktree',
      'cwd': '/managed/feature-auth',
    });
  });

  test('ls follows every 200-row cursor page in response order', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    expect(
      await runWorkspaceCommand(
        arguments: const ['ls', '--no-headers'],
        request: (message) async {
          requests.add(message);
          final cursor =
              (message['page'] as Map<String, Object?>?)?['cursor'] as String?;
          if (cursor == null) {
            return {
              'requestId': message['requestId'],
              'entries': [_workspace(id: 'w1', kind: 'directory', name: 'one')],
              'emptyProjects': <Object?>[],
              'pageInfo': {
                'nextCursor': 'next',
                'prevCursor': null,
                'hasMore': true,
              },
            };
          }
          return {
            'requestId': message['requestId'],
            'entries': [_workspace(id: 'w2', kind: 'worktree', name: 'two')],
            'emptyProjects': <Object?>[],
            'pageInfo': {
              'nextCursor': null,
              'prevCursor': 'prev',
              'hasMore': false,
            },
          };
        },
        writeOutput: output.write,
      ),
      0,
    );

    expect(requests, hasLength(2));
    expect(requests.first['type'], 'fetch_workspaces_request');
    expect(requests.first['page'], {'limit': 200});
    expect(requests.last['page'], {'limit': 200, 'cursor': 'next'});
    expect(
      output.toString().indexOf('w1'),
      lessThan(output.toString().indexOf('w2')),
    );
    expect(output.toString(), contains('local'));
    expect(output.toString(), contains('worktree'));
  });

  test('ls supports json yaml quiet and empty table output', () async {
    Future<Map<String, Object?>> request(
      Map<String, Object?> message,
    ) async => {
      'requestId': message['requestId'],
      'entries': [_workspace(id: 'workspace-1', name: 'first')],
      'emptyProjects': <Object?>[],
      'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
    };

    final jsonOutput = StringBuffer();
    await runWorkspaceCommand(
      arguments: const ['ls', '--json'],
      request: request,
      writeOutput: jsonOutput.write,
    );
    expect(jsonDecode(jsonOutput.toString()), isA<List<dynamic>>());

    final yamlOutput = StringBuffer();
    await runWorkspaceCommand(
      arguments: const ['ls', '--format', 'yaml'],
      request: request,
      writeOutput: yamlOutput.write,
    );
    expect(yamlOutput.toString(), startsWith('- workspaceId: workspace-1'));

    final quietOutput = StringBuffer();
    await runWorkspaceCommand(
      arguments: const ['ls', '--quiet'],
      request: request,
      writeOutput: quietOutput.write,
    );
    expect(quietOutput.toString(), 'workspace-1\n');

    final emptyOutput = StringBuffer();
    await runWorkspaceCommand(
      arguments: const ['ls', '--no-headers'],
      request: (message) async => {
        'requestId': message['requestId'],
        'entries': <Object?>[],
        'emptyProjects': <Object?>[],
        'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
      },
      writeOutput: emptyOutput.write,
    );
    expect(emptyOutput, isEmpty);
  });

  test('archive requires timestamp and renders the frozen result', () async {
    Map<String, Object?>? sent;
    final output = StringBuffer();
    expect(
      await runWorkspaceCommand(
        arguments: const ['archive', 'workspace-1', '--json'],
        request: (message) async {
          sent = message;
          return {
            'requestId': message['requestId'],
            'workspaceId': 'workspace-1',
            'archivedAt': '2026-07-29T00:00:00.000Z',
            'error': null,
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(sent?['type'], 'archive_workspace_request');
    expect(sent?['workspaceId'], 'workspace-1');
    expect(jsonDecode(output.toString()), {
      'workspaceId': 'workspace-1',
      'status': 'archived',
      'archivedAt': '2026-07-29T00:00:00.000Z',
    });

    final error = StringBuffer();
    expect(
      await runWorkspaceCommand(
        arguments: const ['archive', 'workspace-1', '--json'],
        request: (message) async => {
          'requestId': message['requestId'],
          'workspaceId': 'workspace-1',
          'archivedAt': null,
          'error': null,
        },
        writeError: error.write,
      ),
      1,
    );
    expect(
      (jsonDecode(error.toString()) as Map<String, dynamic>)['error']['code'],
      'WORKSPACE_ARCHIVE_FAILED',
    );
  });

  test('parser and daemon failures use stable exit codes', () async {
    final usageError = StringBuffer();
    expect(
      await runWorkspaceCommand(
        arguments: const ['create'],
        writeError: usageError.write,
      ),
      64,
    );
    expect(usageError.toString(), contains('--isolation is required'));

    final commandError = StringBuffer();
    expect(
      await runWorkspaceCommand(
        arguments: const [
          'create',
          '--isolation',
          'local',
          '--mode',
          'branch-off',
          '--json',
        ],
        request: (_) async => throw StateError('must not send'),
        writeError: commandError.write,
      ),
      1,
    );
    final payload = jsonDecode(commandError.toString()) as Map<String, dynamic>;
    expect(payload['error']['code'], 'WORKSPACE_CREATE_FAILED');
    expect(
      payload['error']['message'],
      'Worktree options require --isolation worktree',
    );
  });
}

Map<String, Object?> _source(List<String> arguments) =>
    buildWorkspaceCreateSource(
      WorkspaceCliInvocation.parse(arguments),
      '/current',
    );

Map<String, Object?> _workspace({
  required String id,
  String kind = 'directory',
  String name = 'workspace',
  String cwd = '/repo',
}) => {
  'id': id,
  'projectId': 'project-1',
  'projectDisplayName': 'Example',
  'projectRootPath': '/repo',
  'workspaceDirectory': cwd,
  'projectKind': 'git',
  'workspaceKind': kind,
  'name': name,
  'status': 'done',
  'activityAt': null,
  'scripts': <Object?>[],
  'gitRuntime': null,
};
