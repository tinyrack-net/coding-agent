import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('v2 hello round-trips Paseo protocol fields and capabilities', () {
    const hello = WebSocketHello(
      clientId: 'desktop-1',
      clientType: WebSocketClientType.browser,
      protocolVersion: paseoWebSocketProtocolVersion,
      appVersion: '0.2.0',
      capabilities: {'voice': true, 'terminalReflowableSnapshot': true},
    );

    final decoded = WebSocketHello.fromJson(hello.toJson());
    expect(decoded.clientId, hello.clientId);
    expect(decoded.clientType, hello.clientType);
    expect(decoded.protocolVersion, 1);
    expect(decoded.capabilities, hello.capabilities);
  });

  test(
    'v2 hello rejects invalid identity, client type, and protocol shape',
    () {
      expect(
        () => WebSocketHello.fromJson({
          'type': 'hello',
          'clientId': ' ',
          'clientType': 'browser',
          'protocolVersion': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => WebSocketHello.fromJson({
          'type': 'hello',
          'clientId': 'id',
          'clientType': 'desktop',
          'protocolVersion': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => WebSocketHello.fromJson({
          'type': 'hello',
          'clientId': 'id',
          'clientType': 'browser',
          'protocolVersion': 1.5,
        }),
        throwsFormatException,
      );
    },
  );

  test('server_info normalizes optional strings and feature flags', () {
    final info = ServerInfoStatus.fromJson({
      'status': 'server_info',
      'serverId': 'server-1',
      'hostname': '  ',
      'version': ' 0.2.0 ',
      'desktopManaged': true,
      'features': {'providersSnapshot': true, 'futureFlag': false},
    });

    expect(info.hostname, isNull);
    expect(info.version, '0.2.0');
    expect(info.desktopManaged, isTrue);
    expect(info.features, {'providersSnapshot': true, 'futureFlag': false});
    expect(info.toJson(), {
      'status': 'server_info',
      'serverId': 'server-1',
      'hostname': null,
      'version': '0.2.0',
      'desktopManaged': true,
      'features': {'providersSnapshot': true, 'futureFlag': false},
    });
  });
}
