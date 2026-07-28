import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('client capabilities match the frozen wire values', () {
    expect(ClientCapabilities.all, {
      'selective_agent_timeline',
      'reasoning_merge_enum',
      'custom_mode_icons',
      'terminal_reflowable_snapshot',
      'provider_subagents',
      'project_updates',
      'browser_host',
    });
  });

  test('direct TCP host connections default TLS to false', () {
    final connection = DirectTcpHostConnection.fromJson(const {
      'id': 'host-1',
      'type': 'directTcp',
      'endpoint': 'localhost:6767',
    });
    expect(connection.useTls, isFalse);
    expect(connection.password, isNull);
    expect(connection.toJson()['type'], 'directTcp');
  });

  test(
    'direct TCP connections preserve optional fields and validate types',
    () {
      final connection = DirectTcpHostConnection.fromJson(const {
        'id': 'host-1',
        'type': 'directTcp',
        'endpoint': 'example.com:443',
        'useTls': true,
        'password': 'secret',
      });
      expect(connection.toJson(), {
        'id': 'host-1',
        'type': 'directTcp',
        'endpoint': 'example.com:443',
        'useTls': true,
        'password': 'secret',
      });

      for (final json in const [
        {'id': 1, 'type': 'directTcp', 'endpoint': 'localhost:6767'},
        {'id': 'x', 'type': 'relay', 'endpoint': 'localhost:6767'},
        {'id': 'x', 'type': 'directTcp', 'endpoint': 1},
        {
          'id': 'x',
          'type': 'directTcp',
          'endpoint': 'localhost:6767',
          'useTls': 'yes',
        },
        {
          'id': 'x',
          'type': 'directTcp',
          'endpoint': 'localhost:6767',
          'password': 1,
        },
      ]) {
        expect(
          () => DirectTcpHostConnection.fromJson(json),
          throwsFormatException,
        );
      }
    },
  );

  test('all Paseo host connection variants round-trip', () {
    for (final json in const <Map<String, Object?>>[
      {
        'id': 'socket:/tmp/paseo.sock',
        'type': 'directSocket',
        'path': '/tmp/paseo.sock',
      },
      {
        'id': r'pipe:\\.\pipe\paseo',
        'type': 'directPipe',
        'path': r'\\.\pipe\paseo',
      },
      {
        'id': 'relay:wss:relay.example.com:443',
        'type': 'relay',
        'relayEndpoint': 'relay.example.com:443',
        'useTls': true,
        'daemonPublicKeyB64': 'public-key',
      },
    ]) {
      expect(HostConnection.fromJson(json).toJson(), json);
    }
  });

  test('host profiles preserve the frozen Paseo registry shape', () {
    const json = <String, Object?>{
      'serverId': 'server-1',
      'label': 'My workstation',
      'lifecycle': <String, Object?>{},
      'connections': [
        {
          'id': 'direct:localhost:6767',
          'type': 'directTcp',
          'endpoint': 'localhost:6767',
          'useTls': false,
        },
      ],
      'preferredConnectionId': 'direct:localhost:6767',
      'createdAt': '2026-07-26T00:00:00.000Z',
      'updatedAt': '2026-07-26T00:00:00.000Z',
    };
    expect(HostProfile.fromJson(json).toJson(), json);
  });

  test('connectionFromListen matches socket, pipe and TCP rules', () {
    expect(connectionFromListen('127.0.0.1:6767')!.toJson(), {
      'id': 'direct:localhost:6767',
      'type': 'directTcp',
      'endpoint': 'localhost:6767',
      'useTls': false,
    });
    expect(
      connectionFromListen('unix:///tmp/paseo.sock'),
      isA<DirectSocketHostConnection>(),
    );
    expect(
      connectionFromListen(r'pipe://\\.\pipe\paseo'),
      isA<DirectPipeHostConnection>(),
    );
    expect(connectionFromListen(''), isNull);
    expect(connectionFromListen('not-an-endpoint'), isNull);
  });

  test('upsert merges profiles that identify the same connection', () {
    const direct = DirectTcpHostConnection(
      id: 'direct:localhost:6767',
      endpoint: 'localhost:6767',
    );
    const relay = RelayHostConnection(
      id: 'relay:wss:relay.example.com:443',
      relayEndpoint: 'relay.example.com:443',
      useTls: true,
      daemonPublicKeyB64: 'key',
    );
    const old = HostProfile(
      serverId: 'placeholder',
      label: 'placeholder',
      connections: [direct],
      preferredConnectionId: 'direct:localhost:6767',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    );
    final merged = upsertHostConnectionInProfiles(
      profiles: const [old],
      serverId: 'real-server',
      label: 'Workstation',
      connection: relay,
      now: '2026-07-26T00:00:00.000Z',
    );
    expect(merged, hasLength(2));

    final reconciled = upsertHostConnectionInProfiles(
      profiles: merged,
      serverId: 'real-server',
      label: 'Workstation',
      connection: direct,
      now: '2026-07-26T01:00:00.000Z',
    );
    expect(reconciled, hasLength(1));
    expect(reconciled.single.serverId, 'real-server');
    expect(reconciled.single.connections, hasLength(2));
    expect(reconciled.single.createdAt, '2026-01-01T00:00:00.000Z');
  });

  test(
    'normalizes compatible stored profiles and drops invalid connections',
    () {
      final profile = normalizeStoredHostProfile({
        'serverId': ' server ',
        'label': ' ',
        'connections': [
          {'id': 'stale', 'type': 'directTcp', 'endpoint': '127.0.0.1:6767'},
          {'id': 'bad', 'type': 'directSocket', 'path': ''},
        ],
        'preferredConnectionId': 'stale',
      }, now: '2026-07-26T00:00:00.000Z');
      expect(profile?.serverId, 'server');
      expect(profile?.label, 'server');
      expect(profile?.connections.single.id, 'direct:localhost:6767');
      expect(profile?.preferredConnectionId, 'direct:localhost:6767');
      expect(normalizeStoredHostProfile({'serverId': 'empty'}), isNull);
    },
  );

  test(
    'orders the local host first and resolves only connected selections',
    () {
      final first = HostProfile.fromJson({
        'serverId': 'remote',
        'label': 'Remote',
        'connections': [
          {
            'id': 'direct:remote:6767',
            'type': 'directTcp',
            'endpoint': 'remote:6767',
          },
        ],
        'preferredConnectionId': null,
        'createdAt': '2026-07-26T00:00:00.000Z',
        'updatedAt': '2026-07-26T00:00:00.000Z',
      });
      final local = HostProfile.fromJson({
        ...first.toJson(),
        'serverId': 'local',
        'label': 'Local',
      });
      final ordered = orderHostsLocalFirst([first, local], 'local');
      expect(ordered.map((host) => host.serverId), ['local', 'remote']);
      expect(
        resolveActiveHostServerId(
          selectedServerId: 'stale',
          localServerId: 'local',
          hosts: [first, local],
          orderedHosts: ordered,
        ),
        'local',
      );
      expect(
        resolveActiveHostServerId(
          selectedServerId: 'stale',
          localServerId: 'stale-local',
          hosts: [first],
          orderedHosts: [first],
        ),
        'remote',
      );
    },
  );
}
