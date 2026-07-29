import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/agent_run_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'top-level and nested binary run aliases are exposed',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final results = await Future.wait([
        for (final arguments in const [
          ['run', '--help'],
          ['agent', 'run', '--help'],
        ])
          Process.run(Platform.resolvedExecutable, [
            'run',
            'agent_daemon:coding_agent',
            ...arguments,
          ], workingDirectory: packageRoot),
      ]);
      for (final result in results) {
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Usage: coding-agent run'));
        expect(result.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('foreground run creates local workspace, agent, and waits', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    final errors = StringBuffer();
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'codex/gpt-5.4',
        '--thinking',
        'high',
        '--mode',
        'full-access',
        '--title',
        'Ship it',
        '--env',
        'A=1',
        '--label',
        'team=core',
        '--json',
        'Implement this',
      ],
      currentDirectory: r'C:\repo',
      environment: const {},
      request: (request) async {
        requests.add(request);
        return switch (request['type']) {
          'workspace.create.request' => _workspaceCreatePayload(
            request['requestId']! as String,
          ),
          CreateAgentRequest.type => _createdPayload(
            request['requestId']! as String,
            status: 'running',
          ),
          WaitForFinishRequest.type => _waitPayload(
            request['requestId']! as String,
            status: 'idle',
            finalAgent: _snapshot(status: 'idle'),
            lastMessage: 'Done',
          ),
          _ => throw StateError('Unexpected request: $request'),
        };
      },
      writeOutput: output.write,
      writeError: errors.write,
    );

    expect(code, 0);
    expect(jsonDecode(output.toString()), {
      'agentId': 'agent-1',
      'status': 'completed',
      'provider': 'codex',
      'cwd': r'C:\repo',
      'title': 'Ship it',
    });
    expect(
      errors.toString(),
      contains('Created workspace workspace-1 - repo (main)'),
    );
    expect(requests.map((entry) => entry['type']), [
      'workspace.create.request',
      CreateAgentRequest.type,
      WaitForFinishRequest.type,
    ]);
    final workspace = requests[0];
    expect(workspace['source'], {'kind': 'directory', 'path': r'C:\repo'});
    final create = CreateAgentRequest.fromJson(requests[1]);
    expect(create.config.provider, 'codex');
    expect(create.config.model, 'gpt-5.4');
    expect(create.config.thinkingOptionId, 'high');
    expect(create.config.modeId, 'full-access');
    expect(create.config.title, 'Ship it');
    expect(create.workspaceId, 'workspace-1');
    expect(create.initialPrompt, 'Implement this');
    expect(create.env, {'A': '1'});
    expect(create.labels, {'team': 'core'});
    expect((requests[2]['timeoutMs']), isNull);
  });

  test('background legacy detach returns without waiting', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'claude',
        '--detach',
        '--quiet',
        'Keep working',
      ],
      currentDirectory: '/repo',
      environment: const {},
      request: (request) async {
        requests.add(request);
        return switch (request['type']) {
          'workspace.create.request' => _workspaceCreatePayload(
            request['requestId']! as String,
            cwd: '/repo',
          ),
          CreateAgentRequest.type => _createdPayload(
            request['requestId']! as String,
            cwd: '/repo',
            provider: 'claude',
            status: 'running',
          ),
          _ => throw StateError('Unexpected request: $request'),
        };
      },
      writeOutput: output.write,
      writeError: (_) {},
    );

    expect(code, 0);
    expect(output.toString(), 'agent-1\n');
    expect(
      requests.where((entry) => entry['type'] == WaitForFinishRequest.type),
      isEmpty,
    );
  });

  test('shared output aliases and frozen option forms are supported', () async {
    final parsed = AgentRunInvocation.parse(const [
      '--provider=codex',
      '--image=first.png',
      '--env=A=1',
      '--label=team=core',
      '--host=ws://127.0.0.1:7777',
      '--format=yaml',
      '--json',
      '--no-color',
      '--',
      '-prompt',
    ]);
    expect(parsed.prompt, '-prompt');
    expect(parsed.provider, 'codex');
    expect(parsed.images, ['first.png']);
    expect(parsed.env, ['A=1']);
    expect(parsed.labels, ['team=core']);
    expect(parsed.host, 'ws://127.0.0.1:7777');
    expect(parsed.output.format, 'json');
    expect(parsed.output.noColor, isTrue);

    Future<Map<String, Object?>> create(Map<String, Object?> request) async =>
        _createdPayload(request['requestId']! as String, cwd: '/repo');

    final table = StringBuffer();
    expect(
      await runAgentRunCommand(
        arguments: const [
          '--provider',
          'codex',
          '--background',
          '-ocli',
          '--no-headers',
          'task',
        ],
        currentDirectory: '/repo',
        environment: const {'PASEO_AGENT_ID': 'parent'},
        request: create,
        writeOutput: table.write,
        writeError: (_) {},
      ),
      0,
    );
    expect(table.toString(), contains('agent-1'));
    expect(table.toString(), isNot(contains('AGENT ID')));

    final yaml = StringBuffer();
    expect(
      await runAgentRunCommand(
        arguments: const [
          '--provider',
          'codex',
          '--background',
          '--format=yaml',
          'task',
        ],
        currentDirectory: '/repo',
        environment: const {'PASEO_AGENT_ID': 'parent'},
        request: create,
        writeOutput: yaml.write,
        writeError: (_) {},
      ),
      0,
    );
    expect(yaml.toString(), contains('agentId: agent-1'));
    expect(yaml.toString(), contains('status: running'));
  });

  test(
    'shared yaml renders command errors recovered before invocation',
    () async {
      final error = StringBuffer();
      expect(
        await runAgentRunCommand(
          arguments: const ['--provider', 'codex', '--format=yaml'],
          environment: const {},
          request: (_) async => fail('request must not run'),
          writeOutput: (_) {},
          writeError: error.write,
        ),
        1,
      );
      expect(error.toString(), contains('error:'));
      expect(error.toString(), contains('code: MISSING_PROMPT'));
      expect(error.toString(), contains('message: A prompt is required'));
    },
  );

  test(
    'caller agent takes workspace precedence without lookup or mint',
    () async {
      final requests = <Map<String, Object?>>[];
      final output = StringBuffer();
      final code = await runAgentRunCommand(
        arguments: const [
          '--provider',
          'codex',
          '--background',
          '--json',
          'Child task',
        ],
        currentDirectory: '/caller-cwd',
        environment: const {
          'PASEO_AGENT_ID': ' parent-agent ',
          'PASEO_WORKSPACE_ID': 'ambient-workspace',
        },
        request: (request) async {
          requests.add(request);
          if (request['type'] == CreateAgentRequest.type) {
            return _createdPayload(request['requestId']! as String);
          }
          throw StateError('Unexpected request: $request');
        },
        writeOutput: output.write,
        writeError: (_) {},
      );

      expect(code, 0);
      final create = CreateAgentRequest.fromJson(requests.single);
      expect(create.callerAgentId, 'parent-agent');
      expect(create.workspaceId, isNull);
      expect(create.config.cwd, '/caller-cwd');
    },
  );

  test('explicit workspace replaces stale cwd without minting', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    final errors = StringBuffer();
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'codex',
        '--workspace',
        'workspace-1',
        '--background',
        '--json',
        'Use existing',
      ],
      currentDirectory: '/stale-client-cwd',
      environment: const {},
      request: (request) async {
        requests.add(request);
        return switch (request['type']) {
          'fetch_workspaces_request' => _workspaceFetchPayload(
            request['requestId']! as String,
            cwd: '/authoritative-workspace',
          ),
          CreateAgentRequest.type => _createdPayload(
            request['requestId']! as String,
            cwd: '/authoritative-workspace',
          ),
          _ => throw StateError('Unexpected request: $request'),
        };
      },
      writeOutput: output.write,
      writeError: errors.write,
    );

    expect(code, 0);
    expect(errors.toString(), 'Using workspace workspace-1\n');
    expect(requests.map((entry) => entry['type']), [
      'fetch_workspaces_request',
      CreateAgentRequest.type,
    ]);
    final create = CreateAgentRequest.fromJson(requests.last);
    expect(create.workspaceId, 'workspace-1');
    expect(create.config.cwd, '/authoritative-workspace');
  });

  test('worktree checkout-pr options use frozen workspace source', () async {
    final requests = <Map<String, Object?>>[];
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'codex',
        '--new-workspace',
        'worktree',
        '--worktree-mode',
        'checkout-pr',
        '--worktree-slug',
        'review-42',
        '--pr-number',
        '42',
        '--forge',
        'gitlab',
        '--background',
        'Review change',
      ],
      currentDirectory: '/repo',
      environment: const {},
      request: (request) async {
        requests.add(request);
        return switch (request['type']) {
          'workspace.create.request' => _workspaceCreatePayload(
            request['requestId']! as String,
            cwd: '/worktrees/review-42',
          ),
          CreateAgentRequest.type => _createdPayload(
            request['requestId']! as String,
            cwd: '/worktrees/review-42',
          ),
          _ => throw StateError('Unexpected request: $request'),
        };
      },
      writeOutput: (_) {},
      writeError: (_) {},
    );

    expect(code, 0);
    expect(requests.first['source'], {
      'kind': 'worktree',
      'cwd': '/repo',
      'worktreeSlug': 'review-42',
      'action': 'checkout',
      'checkoutSource': {
        'kind': 'change_request',
        'forge': 'gitlab',
        'number': 42,
      },
    });
  });

  test('images are loaded with MIME type and repeatable order', () async {
    final requests = <Map<String, Object?>>[];
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'codex',
        '--image',
        'first.png',
        '--image',
        'second.webp',
        '--background',
        'Inspect images',
      ],
      currentDirectory: '/repo',
      environment: const {'PASEO_AGENT_ID': 'parent'},
      readFile: (path) => path.endsWith('first.png') ? [1, 2] : [3, 4],
      request: (request) async {
        requests.add(request);
        return _createdPayload(request['requestId']! as String, cwd: '/repo');
      },
      writeOutput: (_) {},
      writeError: (_) {},
    );

    expect(code, 0);
    final create = CreateAgentRequest.fromJson(requests.single);
    expect(create.images.map((image) => image.mimeType), [
      'image/png',
      'image/webp',
    ]);
    expect(create.images.map((image) => image.data), ['AQI=', 'AwQ=']);
  });

  test('structured output retries the same agent and forces JSON', () async {
    final requests = <Map<String, Object?>>[];
    var waits = 0;
    final output = StringBuffer();
    final code = await runAgentRunCommand(
      arguments: const [
        '--provider',
        'codex',
        '--output-schema',
        '{"type":"object","required":["answer"],'
            '"properties":{"answer":{"type":"string"}}}',
        '--quiet',
        'Return an answer',
      ],
      currentDirectory: '/repo',
      environment: const {'PASEO_AGENT_ID': 'parent'},
      request: (request) async {
        requests.add(request);
        return switch (request['type']) {
          CreateAgentRequest.type => _createdPayload(
            request['requestId']! as String,
            cwd: '/repo',
          ),
          WaitForFinishRequest.type => _waitPayload(
            request['requestId']! as String,
            status: 'idle',
            finalAgent: _snapshot(cwd: '/repo', status: 'idle'),
            lastMessage: waits++ == 0 ? '{"wrong":true}' : '{"answer":"yes"}',
          ),
          SendAgentMessageRequest.type => {
            'requestId': request['requestId'],
            'agentId': 'agent-1',
            'accepted': true,
            'error': null,
          },
          _ => throw StateError('Unexpected request: $request'),
        };
      },
      writeOutput: output.write,
      writeError: (_) {},
    );

    expect(code, 0);
    expect(jsonDecode(output.toString()), {'answer': 'yes'});
    expect(
      requests.where((entry) => entry['type'] == CreateAgentRequest.type),
      hasLength(1),
    );
    expect(
      requests.where((entry) => entry['type'] == SendAgentMessageRequest.type),
      hasLength(1),
    );
    final retry = requests.firstWhere(
      (entry) => entry['type'] == SendAgentMessageRequest.type,
    );
    expect(
      retry['text'],
      contains('Previous response was invalid with validation errors:'),
    );
  });

  test(
    'frozen validation failures are structured and do not call daemon',
    () async {
      Future<void> expectFailure(
        List<String> arguments,
        String code,
        String message,
      ) async {
        final errors = StringBuffer();
        final exitCode = await runAgentRunCommand(
          arguments: [...arguments, '--json'],
          currentDirectory: '/repo',
          environment: const {},
          request: (_) => throw StateError('must not connect'),
          writeOutput: (_) {},
          writeError: errors.write,
        );
        expect(exitCode, 1);
        final error = (jsonDecode(errors.toString()) as Map)['error'] as Map;
        expect(error['code'], code);
        expect(error['message'], message);
      }

      await expectFailure(
        const ['--provider', 'codex', '--new-workspace', 'remote', 'task'],
        'INVALID_OPTIONS',
        'Unsupported new workspace kind: remote',
      );
      await expectFailure(
        const [
          '--provider',
          'codex',
          '--background',
          '--output-schema',
          '{}',
          'task',
        ],
        'INVALID_OPTIONS',
        '--output-schema cannot be used with --background',
      );
      await expectFailure(
        const ['--provider', 'codex', '--wait-timeout', '0s', 'task'],
        'INVALID_TIMEOUT',
        'Invalid wait timeout value',
      );
      await expectFailure(
        const ['--provider', 'codex', '--label', 'invalid', 'task'],
        'INVALID_LABEL',
        'Invalid label format: invalid',
      );
    },
  );

  test('missing prompt preserves Paseo command error', () async {
    final errors = StringBuffer();
    final code = await runAgentRunCommand(
      arguments: const ['--provider', 'codex', '--json'],
      environment: const {},
      request: (_) => throw StateError('must not connect'),
      writeOutput: (_) {},
      writeError: errors.write,
    );

    expect(code, 1);
    expect((jsonDecode(errors.toString()) as Map)['error'], {
      'code': 'MISSING_PROMPT',
      'message': 'A prompt is required',
      'details': 'Usage: paseo agent run [options] <prompt>',
    });
  });
}

Map<String, Object?> _createdPayload(
  String requestId, {
  String cwd = r'C:\repo',
  String provider = 'codex',
  String status = 'running',
}) => {
  'status': 'agent_created',
  'agentId': 'agent-1',
  'requestId': requestId,
  'agent': _snapshot(cwd: cwd, provider: provider, status: status),
};

Map<String, Object?> _waitPayload(
  String requestId, {
  required String status,
  required Map<String, Object?>? finalAgent,
  required String? lastMessage,
}) => {
  'requestId': requestId,
  'status': status,
  'final': finalAgent,
  'error': null,
  'lastMessage': lastMessage,
};

Map<String, Object?> _snapshot({
  String cwd = r'C:\repo',
  String provider = 'codex',
  String status = 'running',
}) => {
  'id': 'agent-1',
  'provider': provider,
  'cwd': cwd,
  'model': 'gpt-5.4',
  'createdAt': '2026-07-29T00:00:00.000Z',
  'updatedAt': '2026-07-29T00:00:01.000Z',
  'status': status,
  'pendingPermissions': const [],
  'title': 'Ship it',
  'labels': const <String, String>{},
};

Map<String, Object?> _workspaceCreatePayload(
  String requestId, {
  String cwd = r'C:\repo',
}) => {
  'requestId': requestId,
  'workspace': {
    'id': 'workspace-1',
    'projectId': 'project-1',
    'projectDisplayName': 'repo',
    'projectRootPath': cwd,
    'workspaceDirectory': cwd,
    'projectKind': 'git',
    'workspaceKind': 'local_checkout',
    'name': 'repo',
    'status': 'done',
    'activityAt': '2026-07-29T00:00:00.000Z',
    'scripts': const [],
    'gitRuntime': {'currentBranch': 'main'},
  },
  'setupTerminalId': null,
  'error': null,
};

Map<String, Object?> _workspaceFetchPayload(
  String requestId, {
  required String cwd,
}) => {
  'requestId': requestId,
  'entries': [
    (_workspaceCreatePayload(requestId, cwd: cwd)['workspace']! as Map)
        .cast<String, Object?>(),
  ],
  'emptyProjects': const [],
  'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
};
