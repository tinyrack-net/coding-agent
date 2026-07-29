import 'dart:convert';

import 'package:agent_daemon/src/cli/clone_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('clones shorthand through the daemon and renders json', () async {
    final client = _FakeCloneClient();
    var output = '';

    final exitCode = await runCloneCommand(
      arguments: [
        'owner/repo',
        '--dir',
        ' C:/src ',
        '--protocol',
        'ssh',
        '--host',
        'remote:6868',
        '--json',
      ],
      environment: const {},
      connect: ({required host, required environment}) async {
        expect(host, 'remote:6868');
        return client;
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect(client.closed, isTrue);
    expect(client.timeout, cloneCommandTimeout);
    expect(client.sentRequest, {
      'type': ProjectGithubCloneRequest.type,
      'repo': 'owner/repo',
      'cloneProtocol': 'ssh',
      'targetDirectory': 'C:/src',
      'requestId': isA<String>(),
    });
    expect(jsonDecode(output), {
      'repo': 'owner/repo',
      'checkoutPath': 'C:/src/repo',
      'projectId': 'project-1',
      'projectName': 'repo',
    });
  });

  test('complete remotes do not require an explicit protocol', () async {
    final client = _FakeCloneClient();
    var output = '';

    expect(
      await runCloneCommand(
        arguments: [
          'https://github.com/owner/repo.git',
          '--dir',
          'C:/src',
          '--protocol',
          'ssh',
          '--no-headers',
        ],
        connect: ({required host, required environment}) async => client,
        writeOutput: (value) => output += value,
      ),
      0,
    );

    expect(client.sentRequest, isNot(contains('cloneProtocol')));
    expect(output, isNot(contains('REPO')));
    expect(output, contains('repo'));
  });

  test('supports quiet and yaml output', () async {
    for (final testCase in <(List<String>, Matcher)>[
      (
        ['owner/repo', '--dir', 'C:/src', '--protocol', 'https', '--quiet'],
        equals('project-1\n'),
      ),
      (
        [
          'owner/repo',
          '--dir',
          'C:/src',
          '--protocol',
          'https',
          '--format',
          'yaml',
        ],
        contains('projectId: "project-1"'),
      ),
    ]) {
      var output = '';
      expect(
        await runCloneCommand(
          arguments: testCase.$1,
          connect: ({required host, required environment}) async =>
              _FakeCloneClient(),
          writeOutput: (value) => output += value,
        ),
        0,
      );
      expect(output, testCase.$2);
    }
  });

  test('rejects malformed options before connecting', () async {
    for (final arguments in <List<String>>[
      [],
      ['one', 'two', '--dir', 'C:/src'],
      ['owner/repo', '--protocol', 'https'],
      ['owner/repo', '--dir', 'C:/src'],
      ['owner/repo', '--dir', 'C:/src', '--protocol', 'git'],
      ['owner/repo', '--dir', 'C:/src', '--format', 'toml'],
      ['owner/repo', '--dir', 'C:/src', '--unknown'],
    ]) {
      var error = '';
      final exitCode = await runCloneCommand(
        arguments: [...arguments, '--json'],
        connect: ({required host, required environment}) async =>
            fail('must not connect for $arguments'),
        writeError: (value) => error += value,
      );
      expect(exitCode, anyOf(1, 64), reason: '$arguments');
      expect(error, isNotEmpty, reason: '$arguments');
    }
  });

  test('reports unsupported hosts and daemon clone failures', () async {
    final unsupported = _FakeCloneClient(
      serverInfo: _serverInfo(features: const {}),
    );
    var unsupportedError = '';
    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          'C:/src',
          '--protocol',
          'https',
          '--json',
        ],
        connect: ({required host, required environment}) async => unsupported,
        writeError: (value) => unsupportedError += value,
      ),
      1,
    );
    expect(
      (jsonDecode(unsupportedError) as Map)['error'],
      containsPair('code', 'UNSUPPORTED_BY_HOST'),
    );
    expect(unsupported.closed, isTrue);

    final failed = _FakeCloneClient(error: 'clone rejected');
    var failedError = '';
    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          'C:/src',
          '--protocol',
          'https',
          '--json',
        ],
        connect: ({required host, required environment}) async => failed,
        writeError: (value) => failedError += value,
      ),
      1,
    );
    expect(
      (jsonDecode(failedError) as Map)['error'],
      containsPair('code', 'CLONE_FAILED'),
    );
  });

  test('help and connection failures are stable', () async {
    var help = '';
    expect(
      await runCloneCommand(
        arguments: ['--help'],
        connect: ({required host, required environment}) async =>
            fail('help must not connect'),
        writeOutput: (value) => help += value,
      ),
      0,
    );
    expect(help, contains('coding-agent clone'));

    var error = '';
    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          'C:/src',
          '--protocol',
          'https',
          '--json',
        ],
        environment: const {},
        connect: ({required host, required environment}) async =>
            throw StateError('refused'),
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(
      (jsonDecode(error) as Map)['error'],
      containsPair('code', 'DAEMON_NOT_RUNNING'),
    );

    expect(
      await runCloneCommand(
        arguments: [
          'owner/repo',
          '--dir',
          'C:/src',
          '--protocol',
          'https',
          '--quiet',
        ],
        connect: ({required host, required environment}) async =>
            _FakeCloneClient(closeThrows: true),
        writeOutput: (_) {},
      ),
      0,
    );
  });
}

final class _FakeCloneClient implements CloneDaemonClient {
  _FakeCloneClient({
    ServerInfoStatus? serverInfo,
    this.error,
    this.closeThrows = false,
  }) : serverInfo =
           serverInfo ??
           _serverInfo(features: const {'projectGithubClone': true});

  @override
  final ServerInfoStatus serverInfo;
  final String? error;
  final bool closeThrows;
  Map<String, Object?>? sentRequest;
  Duration? timeout;
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) async {
    sentRequest = request;
    this.timeout = timeout;
    return {
      'requestId': request['requestId'],
      'repo': request['repo'],
      'checkoutPath': error == null ? 'C:/src/repo' : null,
      'project': error == null
          ? const WorkspaceProjectDescriptor(
              projectId: 'project-1',
              projectDisplayName: 'repo',
              projectRootPath: 'C:/src/repo',
              projectKind: WorkspaceProjectKind.git,
            ).toJson()
          : null,
      'error': error,
    };
  }

  @override
  Future<void> close() async {
    closed = true;
    if (closeThrows) throw StateError('already closed');
  }
}

ServerInfoStatus _serverInfo({required Map<String, bool> features}) =>
    ServerInfoStatus(
      serverId: 'server',
      hostname: 'host',
      version: '0.2.0',
      desktopManaged: false,
      features: features,
    );
