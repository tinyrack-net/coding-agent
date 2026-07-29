import 'dart:convert';

import 'package:agent_daemon/src/cli/permit_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('ls collects pending permissions with frozen projections', () async {
    final client = _FakePermitClient(
      agents: [
        _agent(
          'agent-123456789',
          permissions: const [
            {
              'id': 'permission-123456',
              'name': 'Bash',
              'description': 'Run tests',
            },
          ],
        ),
        _agent('agent-empty'),
      ],
    );
    final output = StringBuffer();

    expect(
      await runPermitCommand(
        arguments: const ['ls', '--json'],
        connect: _connector(client),
        writeOutput: output.write,
      ),
      0,
    );
    expect(jsonDecode(output.toString()), [
      {
        'id': 'permissi',
        'agentId': 'agent-123456789',
        'agentShortId': 'agent-1',
        'name': 'Bash',
        'description': 'Run tests',
      },
    ]);
    expect(client.requests.single['type'], FetchAgentsRequest.type);
    expect(
      (client.requests.single['filter'] as Map)['includeArchived'],
      isTrue,
    );
    expect(client.closed, isTrue);
  });

  test('ls table, quiet, yaml, and empty output modes are stable', () async {
    final tableClient = _FakePermitClient(
      agents: [
        _agent(
          'agent-1',
          permissions: const [
            {'id': 'permission-1', 'name': 'Edit'},
          ],
        ),
      ],
    );
    final table = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['ls'],
        connect: _connector(tableClient),
        writeOutput: table.write,
      ),
      0,
    );
    expect(table.toString(), contains('AGENT'));
    expect(table.toString(), contains('REQ_ID'));
    expect(table.toString(), contains('Edit'));
    expect(table.toString(), contains('-'));

    final quiet = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['ls', '--quiet'],
        connect: _connector(
          _FakePermitClient(
            agents: [
              _agent(
                'agent-1',
                permissions: const [
                  {'id': 'permission-1', 'name': 'Edit'},
                ],
              ),
            ],
          ),
        ),
        writeOutput: quiet.write,
      ),
      0,
    );
    expect(quiet.toString(), 'permissi\n');

    final yaml = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['ls', '--format', 'yaml'],
        connect: _connector(_FakePermitClient(agents: const [])),
        writeOutput: yaml.write,
      ),
      0,
    );
    expect(yaml.toString(), '[]\n');
  });

  test(
    'shared output aliases, precedence, and headers match frozen CLI',
    () async {
      _FakePermitClient client() => _FakePermitClient(
        agents: [
          _agent(
            'agent-123456',
            permissions: const [
              {'id': 'permission-1', 'name': 'Edit'},
            ],
          ),
        ],
      );

      final yaml = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: const ['ls', '-oyaml'],
          connect: _connector(client()),
          writeOutput: yaml.write,
        ),
        0,
      );
      expect(yaml.toString(), contains('- id: permissi'));

      final json = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: const ['ls', '--format=yaml', '--json'],
          connect: _connector(client()),
          writeOutput: json.write,
        ),
        0,
      );
      expect(jsonDecode(json.toString()), isA<List<Object?>>());

      final table = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: const ['ls', '--no-headers', '--no-color'],
          connect: _connector(client()),
          writeOutput: table.write,
        ),
        0,
      );
      expect(table.toString(), isNot(startsWith('AGENT')));
      expect(table.toString(), startsWith('agent-1'));
    },
  );

  test('allow defaults to every request and forwards modified input', () async {
    final client = _FakePermitClient(
      fetchedAgent: _agent(
        'agent-123456789',
        permissions: const [
          {'id': 'permission-one', 'name': 'Bash'},
          {'id': 'permission-two', 'name': 'Write'},
        ],
      ),
    );
    final output = StringBuffer();

    expect(
      await runPermitCommand(
        arguments: const [
          'allow',
          'agent-1',
          '--input',
          '{"command":"dart test"}',
          '--json',
        ],
        connect: _connector(client),
        writeOutput: output.write,
      ),
      0,
    );
    expect((jsonDecode(output.toString()) as List), hasLength(2));
    expect(client.sent, hasLength(2));
    for (final message in client.sent) {
      final decoded = AgentPermissionResponseMessage.fromJson(message);
      expect(decoded.agentId, 'agent-123456789');
      expect(decoded.response.behavior, AgentPermissionBehavior.allow);
      expect(decoded.response.updatedInput, {'command': 'dart test'});
    }
  });

  test('allow resolves a permission ID prefix', () async {
    final client = _FakePermitClient(
      fetchedAgent: _agent(
        'agent-1',
        permissions: const [
          {'id': 'abc12345-full', 'name': 'Read'},
          {'id': 'def67890-full', 'name': 'Write'},
        ],
      ),
    );
    final output = StringBuffer();

    expect(
      await runPermitCommand(
        arguments: const ['allow', 'agent', 'def6', '--json'],
        connect: _connector(client),
        writeOutput: output.write,
      ),
      0,
    );
    expect(client.sent, hasLength(1));
    expect(client.sent.single['requestId'], 'def67890-full');
    expect(jsonDecode(output.toString()), [
      {
        'requestId': 'def67890',
        'agentId': 'agent-1',
        'agentShortId': 'agent-1',
        'name': 'Write',
        'result': 'allowed',
      },
    ]);
  });

  test('deny forwards reason and interrupt and supports all', () async {
    final client = _FakePermitClient(
      fetchedAgent: _agent(
        'agent-123456',
        permissions: const [
          {'id': 'permission-one', 'name': 'Bash'},
          {'id': 'permission-two', 'name': 'Write'},
        ],
      ),
    );
    final output = StringBuffer();

    expect(
      await runPermitCommand(
        arguments: const [
          'deny',
          'agent',
          '--all',
          '--message',
          'Not safe',
          '--interrupt',
          '--json',
        ],
        connect: _connector(client),
        writeOutput: output.write,
      ),
      0,
    );
    expect(client.sent, hasLength(2));
    for (final message in client.sent) {
      final decoded = AgentPermissionResponseMessage.fromJson(message);
      expect(decoded.response.behavior, AgentPermissionBehavior.deny);
      expect(decoded.response.message, 'Not safe');
      expect(decoded.response.interrupt, isTrue);
    }
    expect(
      (jsonDecode(output.toString()) as List).map(
        (row) => (row as Map)['result'],
      ),
      everyElement('denied'),
    );
  });

  test('validation failures occur before a daemon connection', () async {
    for (final testCase in <(List<String>, String, int)>[
      (
        const ['deny', 'agent'],
        'Request ID is required unless --all is specified',
        1,
      ),
      (
        const ['allow', 'agent', '--input', '{bad'],
        'Invalid JSON for --input',
        1,
      ),
      (
        const ['allow', 'agent', '--input', '[]'],
        'JSON value must be an object',
        1,
      ),
      (const ['ls', 'extra'], 'permit ls does not accept arguments', 64),
      (const ['unknown'], 'Unknown permit action', 64),
    ]) {
      var connected = false;
      final errors = StringBuffer();
      final exit = await runPermitCommand(
        arguments: testCase.$1,
        connect:
            ({
              required String? host,
              required Map<String, String> environment,
            }) async {
              connected = true;
              return _FakePermitClient();
            },
        writeError: errors.write,
      );
      expect(exit, testCase.$3);
      expect(errors.toString(), contains(testCase.$2));
      expect(connected, isFalse);
    }
  });

  test('pre-connect validation errors honor structured output', () async {
    final errors = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['allow', 'agent', '--input', '{bad', '--format=yaml'],
        connect:
            ({
              required String? host,
              required Map<String, String> environment,
            }) async => fail('validation must not connect'),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('code: INVALID_JSON'));
    expect(errors.toString(), contains('message: "Invalid JSON for --input:'));
  });

  test('agent and permission lookup errors use frozen codes', () async {
    final cases = <(_FakePermitClient, List<String>, String)>[
      (
        _FakePermitClient(fetchedAgent: null),
        const ['allow', 'missing', '--json'],
        'AGENT_NOT_FOUND',
      ),
      (
        _FakePermitClient(fetchedAgent: _agent('agent')),
        const ['allow', 'agent', '--json'],
        'NO_PENDING_PERMISSIONS',
      ),
      (
        _FakePermitClient(
          fetchedAgent: _agent(
            'agent',
            permissions: const [
              {'id': 'available-id', 'name': 'Bash'},
            ],
          ),
        ),
        const ['allow', 'agent', 'missing', '--json'],
        'PERMISSION_NOT_FOUND',
      ),
    ];
    for (final testCase in cases) {
      final errors = StringBuffer();
      expect(
        await runPermitCommand(
          arguments: testCase.$2,
          connect: _connector(testCase.$1),
          writeError: errors.write,
        ),
        1,
      );
      expect(
        (jsonDecode(errors.toString()) as Map)['error']['code'],
        testCase.$3,
      );
    }
  });

  test('connection and malformed daemon failures are rendered', () async {
    final connectErrors = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['ls', '--host', '127.0.0.1:1', '--json'],
        environment: const {},
        connect:
            ({
              required String? host,
              required Map<String, String> environment,
            }) => throw StateError('refused'),
        writeError: connectErrors.write,
      ),
      1,
    );
    expect(
      (jsonDecode(connectErrors.toString()) as Map)['error']['code'],
      'DAEMON_NOT_RUNNING',
    );

    final malformed = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['ls', '--json'],
        connect: _connector(_FakePermitClient(malformedList: true)),
        writeError: malformed.write,
      ),
      1,
    );
    expect(
      (jsonDecode(malformed.toString()) as Map)['error']['code'],
      'LIST_PERMISSIONS_FAILED',
    );
  });

  test('help is available without connecting', () async {
    final output = StringBuffer();
    expect(
      await runPermitCommand(
        arguments: const ['allow', '--help'],
        connect:
            ({
              required String? host,
              required Map<String, String> environment,
            }) => throw StateError('must not connect'),
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('permit allow'));
  });
}

PermitClientConnector _connector(_FakePermitClient client) =>
    ({required String? host, required Map<String, String> environment}) async =>
        client;

Map<String, Object?> _agent(
  String id, {
  List<Map<String, Object?>> permissions = const [],
}) => {'id': id, 'pendingPermissions': permissions};

final class _FakePermitClient implements PermitDaemonClient {
  _FakePermitClient({
    this.agents = const [],
    this.fetchedAgent,
    this.malformedList = false,
  });

  final List<Map<String, Object?>> agents;
  final Map<String, Object?>? fetchedAgent;
  final bool malformedList;
  final requests = <Map<String, Object?>>[];
  final sent = <Map<String, Object?>>[];
  bool closed = false;

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    requests.add(request);
    return switch (request['type']) {
      FetchAgentsRequest.type =>
        malformedList
            ? const {'entries': 'bad'}
            : {
                'entries': [
                  for (final agent in agents)
                    {'agent': agent, 'project': const {}},
                ],
              },
      FetchAgentRequest.type => {
        'agent': fetchedAgent,
        'project': null,
        'error': fetchedAgent == null ? 'not found' : null,
      },
      _ => throw StateError('Unexpected request: ${request['type']}'),
    };
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
