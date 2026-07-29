import 'dart:convert';

import 'package:agent_daemon/src/cli/agent_import_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('imports a provider session with cwd and repeated labels', () async {
    Map<String, Object?>? sent;
    var output = '';
    final exitCode = await runAgentImportCommand(
      arguments: [
        ' session-42 ',
        '--provider',
        ' codex ',
        '--cwd',
        ' C:/repo ',
        '--label',
        'team=core',
        '--label',
        'note=a=b',
        '--json',
      ],
      request: (request) async {
        sent = request;
        return _successResponse(request['requestId']! as String);
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect(sent, {
      'type': ImportAgentRequest.type,
      'requestId': isA<String>(),
      'provider': 'codex',
      'sessionId': 'session-42',
      'cwd': 'C:/repo',
      'labels': {'team': 'core', 'note': 'a=b'},
    });
    expect(jsonDecode(output), {
      'agentId': 'agent-1',
      'status': 'created',
      'provider': 'codex',
      'cwd': 'C:/repo',
      'title': 'Imported session',
    });
  });

  test('uses current directory and omits empty labels', () async {
    Map<String, Object?>? sent;
    var output = '';
    final exitCode = await runAgentImportCommand(
      arguments: ['thread-1', '--provider', 'claude'],
      currentDirectory: 'C:/default',
      request: (request) async {
        sent = request;
        return _successResponse(
          request['requestId']! as String,
          provider: 'claude',
          cwd: 'C:/default',
          running: true,
          title: '',
        );
      },
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect(sent, isNot(contains('labels')));
    expect(sent!['cwd'], 'C:/default');
    expect(output, contains('AGENT ID'));
    expect(output, contains('running'));
    expect(output, contains('claude'));
  });

  test('supports yaml quiet and headerless output modes', () async {
    Future<Map<String, Object?>> rpc(Map<String, Object?> request) async =>
        _successResponse(request['requestId']! as String);

    var yaml = '';
    expect(
      await runAgentImportCommand(
        arguments: ['id', '--provider', 'codex', '--format', 'yaml'],
        currentDirectory: 'C:/repo',
        request: rpc,
        writeOutput: (value) => yaml += value,
      ),
      0,
    );
    expect(yaml, contains('agentId: agent-1'));

    var quiet = '';
    expect(
      await runAgentImportCommand(
        arguments: ['id', '--provider', 'codex', '--quiet'],
        currentDirectory: 'C:/repo',
        request: rpc,
        writeOutput: (value) => quiet += value,
      ),
      0,
    );
    expect(quiet, 'agent-1\n');

    var table = '';
    expect(
      await runAgentImportCommand(
        arguments: ['id', '--provider', 'codex', '--no-headers', '--no-color'],
        currentDirectory: 'C:/repo',
        request: rpc,
        writeOutput: (value) => table += value,
      ),
      0,
    );
    expect(table, isNot(contains('AGENT ID')));
    expect(table, contains('agent-1'));
  });

  test('supports frozen shared output aliases and option forms', () async {
    final parsed = AgentImportCliInvocation.parse(const [
      '--provider= codex ',
      '--cwd= C:/repo ',
      '--label=team=core',
      '--host=ws://127.0.0.1:7777',
      '--format=yaml',
      '--json',
      '--no-color',
      'session-1',
    ]);
    expect(parsed.provider, 'codex');
    expect(parsed.cwd, 'C:/repo');
    expect(parsed.labels, {'team': 'core'});
    expect(parsed.host, 'ws://127.0.0.1:7777');
    expect(parsed.output.format, 'json');
    expect(parsed.output.noColor, isTrue);

    var output = '';
    expect(
      await runAgentImportCommand(
        arguments: const [
          '--provider',
          'codex',
          '-ocli',
          '--no-headers',
          '--',
          '-session-id',
        ],
        currentDirectory: 'C:/repo',
        request: (request) async =>
            _successResponse(request['requestId']! as String),
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, contains('agent-1'));
    expect(output, isNot(contains('AGENT ID')));
  });

  test('reports permission-blocked imported sessions as running', () async {
    var output = '';
    final exitCode = await runAgentImportCommand(
      arguments: ['id', '--provider', 'codex', '--json'],
      currentDirectory: 'C:/repo',
      request: (request) async => _successResponse(
        request['requestId']! as String,
        awaitingPermission: true,
      ),
      writeOutput: (value) => output += value,
    );

    expect(exitCode, 0);
    expect((jsonDecode(output) as Map)['status'], 'running');
  });

  test(
    'rejects parser-level malformed arguments without calling daemon',
    () async {
      for (final arguments in <List<String>>[
        ['id', '--provider'],
        ['id', '--provider', 'codex', '--format', 'toml'],
        ['id', '--provider', 'codex', '--unknown'],
        ['id', 'second', '--provider', 'codex'],
      ]) {
        var error = '';
        final exitCode = await runAgentImportCommand(
          arguments: arguments,
          request: (_) async => fail('request must not run for $arguments'),
          writeError: (value) => error += value,
        );
        expect(exitCode, 64, reason: '$arguments');
        expect(error, contains('Usage: coding-agent import'));
      }
    },
  );

  test('returns frozen command errors for invalid import values', () async {
    for (final testCase in <(List<String>, String)>[
      ([], 'MISSING_SESSION_ID'),
      (['id'], 'MISSING_PROVIDER'),
      (['id', '--provider', ' '], 'MISSING_PROVIDER'),
      (['id', '--provider', 'codex', '--cwd', ' '], 'INVALID_CWD'),
      (
        ['id', '--provider', 'codex', '--label', 'missing-equals'],
        'INVALID_LABEL',
      ),
      (['id', '--provider', 'codex', '--label', '=value'], 'INVALID_LABEL'),
    ]) {
      var error = '';
      final exitCode = await runAgentImportCommand(
        arguments: [...testCase.$1, '--json'],
        request: (_) async => fail('request must not run for ${testCase.$1}'),
        writeError: (value) => error += value,
      );
      expect(exitCode, 1, reason: '${testCase.$1}');
      expect(
        (jsonDecode(error) as Map)['error'],
        containsPair('code', testCase.$2),
      );
    }
  });

  test('rejects an empty invoking directory when cwd is omitted', () async {
    var error = '';
    expect(
      await runAgentImportCommand(
        arguments: const ['id', '--provider', 'codex', '--json'],
        currentDirectory: '  ',
        environment: const {'TINYRACK_LISTEN': '127.0.0.1:1'},
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(
      (jsonDecode(error) as Map)['error'],
      containsPair('code', 'INVALID_CWD'),
    );
  });

  test('renders structured import failure in json mode', () async {
    var error = '';
    final exitCode = await runAgentImportCommand(
      arguments: ['id', '--provider', 'codex', '--json'],
      currentDirectory: 'C:/repo',
      request: (request) async => {
        'type': 'status',
        'payload': {
          'requestId': request['requestId'],
          'status': 'agent_create_failed',
          'error': 'session not found',
        },
      },
      writeError: (value) => error += value,
    );

    expect(exitCode, 1);
    expect(jsonDecode(error), {
      'error': {
        'code': 'AGENT_IMPORT_FAILED',
        'message': 'Failed to import agent: session not found',
      },
    });
  });

  test('renders structured command failures in yaml mode', () async {
    var error = '';
    final exitCode = await runAgentImportCommand(
      arguments: ['id', '--provider', 'codex', '--format', 'yaml'],
      request: (request) async => {
        'type': 'status',
        'payload': {
          'requestId': request['requestId'],
          'status': 'agent_create_failed',
          'error': 'session: missing',
        },
      },
      writeError: (value) => error += value,
    );

    expect(exitCode, 1);
    expect(error, contains('code: AGENT_IMPORT_FAILED'));
    expect(
      error,
      contains('message: "Failed to import agent: session: missing"'),
    );
  });

  test('wraps unexpected protocol failures with stable code', () async {
    var error = '';
    final exitCode = await runAgentImportCommand(
      arguments: ['id', '--provider', 'codex'],
      request: (_) async => throw StateError('socket closed'),
      writeError: (value) => error += value,
    );

    expect(exitCode, 1);
    expect(error, contains('Error: Failed to import agent: socket closed'));
  });
}

Map<String, Object?> _successResponse(
  String requestId, {
  String provider = 'codex',
  String cwd = 'C:/repo',
  bool running = false,
  bool awaitingPermission = false,
  String title = 'Imported session',
}) {
  final agent = AgentSummary(
    agentId: 'agent-1',
    title: title,
    cwd: cwd,
    provider: provider,
    model: 'model',
    mode: AgentMode.normal,
    runState: awaitingPermission
        ? AgentRunState.awaitingPermission
        : running
        ? AgentRunState.running
        : AgentRunState.idle,
    createdAtMs: 1,
  );
  return {
    'type': 'status',
    'payload': {
      'requestId': requestId,
      'status': 'agent_resumed',
      'agentId': agent.agentId,
      'timelineSize': 2,
      'agent': PaseoAgentSnapshotCodec.encode(agent),
    },
  };
}
