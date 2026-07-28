import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_diagnostic_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const host = HostProfile(
    serverId: 'server-1',
    label: 'Desktop',
    connections: [
      DirectTcpHostConnection(
        id: 'direct:127.0.0.1:6868',
        endpoint: '127.0.0.1:6868',
        password: 'secret-password',
      ),
      RelayHostConnection(
        id: 'relay:relay.example:443',
        relayEndpoint: 'relay.example:443',
        daemonPublicKeyB64: 'public-key-secret',
      ),
    ],
    preferredConnectionId: 'direct:127.0.0.1:6868',
    createdAt: '2026-07-27T00:00:00.000Z',
    updatedAt: '2026-07-27T00:00:00.000Z',
  );

  test('formats app, host, and server sections with stable labels', () {
    expect(
      formatAppDiagnosticHeader(
        collectedAt: DateTime.utc(2026, 7, 27),
        appVersion: '0.2.0',
        platform: 'windows',
        isDesktopApp: true,
        hostCount: 1,
      ),
      contains(
        'Tinyrack app diagnostics\n'
        '  Collected at: 2026-07-27T00:00:00.000Z\n'
        '  App version: 0.2.0\n'
        '  Platform: windows\n'
        '  Desktop app: true\n'
        '  Saved hosts: 1',
      ),
    );
    expect(
      formatHostDiagnosticSection(
        host: host,
        status: 'connected',
        activeConnection: 'direct TCP',
      ),
      allOf(
        contains('Host: Desktop'),
        contains('Connection 1: direct TCP, active'),
        contains('Connection 2: relay, inactive'),
      ),
    );
    expect(
      formatServerInfoSection(
        const ServerInfoStatus(
          serverId: 'server-1',
          hostname: 'workstation',
          version: '0.2.0',
          desktopManaged: true,
          features: {'z': true, 'a': true},
        ),
      ),
      contains('Features: a, z'),
    );
    expect(formatServerInfoSection(null), contains('Status: not received'));
  });

  test('describes every connection kind', () {
    expect(describeConnectionKind(host.connections[0]), 'direct TCP');
    expect(describeConnectionKind(host.connections[1]), 'relay');
    expect(
      describeConnectionKind(
        const DirectSocketHostConnection(id: 'socket', path: '/tmp/paseo'),
      ),
      'local socket',
    );
    expect(
      describeConnectionKind(
        const DirectPipeHostConnection(id: 'pipe', path: r'\\.\pipe\paseo'),
      ),
      'local pipe',
    );
  });

  test('redacts saved connection details and inline secrets', () {
    const localHost = HostProfile(
      serverId: 'server-2',
      label: 'Local transports',
      connections: [
        DirectSocketHostConnection(id: 'socket', path: '/tmp/paseo.sock'),
        DirectPipeHostConnection(id: 'pipe', path: r'\\.\pipe\paseo-secret'),
      ],
      preferredConnectionId: 'socket',
      createdAt: '2026-07-27T00:00:00.000Z',
      updatedAt: '2026-07-27T00:00:00.000Z',
    );
    final report = redactAppDiagnosticReport(
      'direct:127.0.0.1:6868 127.0.0.1:6868 secret-password\n'
      'relay.example:443 public-key-secret\n'
      '/tmp/paseo.sock ${r'\\.\pipe\paseo-secret'}\n'
      'coding-agent://pair?token=deep-link-token\n'
      'https://example.test/path?token=query-secret\n'
      'api_key = api-secret Authorization: bearer-secret',
      const [host, localHost],
    );
    for (final secret in [
      '127.0.0.1:6868',
      'secret-password',
      'relay.example:443',
      'public-key-secret',
      '/tmp/paseo.sock',
      r'\\.\pipe\paseo-secret',
      'deep-link-token',
      'query-secret',
      'api-secret',
      'bearer-secret',
    ]) {
      expect(report, isNot(contains(secret)));
    }
  });
}
