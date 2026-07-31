import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ClientHello', () {
    test('round-trips with token', () {
      const hello = ClientHello(
        clientName: 'desktop',
        clientVersion: '1.2.3',
        token: 'secret',
      );
      final decoded = ClientHello.fromJson(roundTrip(hello.toJson()));
      expect(decoded.clientName, 'desktop');
      expect(decoded.clientVersion, '1.2.3');
      expect(decoded.token, 'secret');
    });

    test('omits token from json when null', () {
      const hello = ClientHello(clientName: 'cli', clientVersion: '0.1.0');
      expect(hello.toJson().containsKey('token'), isFalse);
      final decoded = ClientHello.fromJson(hello.toJson());
      expect(decoded.token, isNull);
    });

    test('fromJson applies defaults when fields missing', () {
      final decoded = ClientHello.fromJson(const {});
      expect(decoded.clientName, 'unknown');
      expect(decoded.clientVersion, '0.0.0');
      expect(decoded.token, isNull);
    });
  });

  group('ServerHello', () {
    test('round-trips with all fields', () {
      const hello = ServerHello(
        daemonVersion: '2.0.0',
        protocolVersion: 1,
        capabilities: ['terminals', 'diff'],
        pid: 4242,
        desktopManaged: true,
      );
      final decoded = ServerHello.fromJson(roundTrip(hello.toJson()));
      expect(decoded.daemonVersion, '2.0.0');
      expect(decoded.protocolVersion, 1);
      expect(decoded.capabilities, ['terminals', 'diff']);
      expect(decoded.pid, 4242);
      expect(decoded.desktopManaged, isTrue);
    });

    test('omits pid from json when null', () {
      const hello = ServerHello(daemonVersion: '1.0.0', protocolVersion: 1);
      expect(hello.toJson().containsKey('pid'), isFalse);
      final decoded = ServerHello.fromJson(hello.toJson());
      expect(decoded.pid, isNull);
      expect(decoded.desktopManaged, isFalse);
      expect(decoded.capabilities, isEmpty);
    });

    test('fromJson applies defaults when fields missing', () {
      final decoded = ServerHello.fromJson(const {});
      expect(decoded.daemonVersion, '0.0.0');
      expect(decoded.protocolVersion, 0);
      expect(decoded.capabilities, isEmpty);
      expect(decoded.pid, isNull);
      expect(decoded.desktopManaged, isFalse);
    });
  });

  group('MessageTypes', () {
    test('exposes stable wire strings for well-known constants', () {
      expect(MessageTypes.clientHelloRequest, 'client.hello.request');
      expect(MessageTypes.agentCreateRequest, 'agent.create.request');
      expect(MessageTypes.agentStreamEvent, 'agent.stream');
      expect(
        MessageTypes.terminalSubscribeRequest,
        'terminal.subscribe.request',
      );
      expect(MessageTypes.daemonShutdownRequest, 'daemon.shutdown.request');
    });
  });
}
