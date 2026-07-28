import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('connection URI parsing', () {
    test('round-trips tcp, TLS, IPv6, and password forms', () {
      final plain = parseConnectionUri('tcp://localhost:6767');
      expect(plain.host, 'localhost');
      expect(plain.port, 6767);
      expect(plain.isIpv6, isFalse);
      expect(plain.useTls, isFalse);
      expect(serializeConnectionUri(plain), 'tcp://localhost:6767');

      final tls = parseConnectionUri('tcp://example.com:443?ssl=true');
      expect(tls.useTls, isTrue);
      expect(serializeConnectionUri(tls), 'tcp://example.com:443?ssl=true');

      final ipv6 = parseConnectionUri('tcp://[::1]:6767?ssl=true');
      expect(ipv6.host, '::1');
      expect(ipv6.isIpv6, isTrue);
      expect(serializeConnectionUri(ipv6), 'tcp://[::1]:6767?ssl=true');

      final secret = parseConnectionUri(
        'tcp://localhost:6767?ssl=true&password=secret',
      );
      expect(secret.password, 'secret');
      expect(serializeConnectionUri(secret), 'tcp://localhost:6767?ssl=true');
      expect(
        serializeConnectionUriForStorage(secret),
        'tcp://localhost:6767?ssl=true&password=secret',
      );
    });

    test('rejects malformed connection URIs', () {
      expect(
        () => parseConnectionUri('tcp://localhost'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Connection URI port is required',
          ),
        ),
      );
      expect(
        () => parseConnectionUri('http://localhost:6767'),
        throwsFormatException,
      );
      expect(
        () => parseConnectionUri('tcp://:secret@localhost:6767?ssl=true'),
        throwsFormatException,
      );
    });
  });

  group('daemon and relay WebSocket URLs', () {
    test('honors explicit TLS independently of port', () {
      expect(
        buildDaemonWebSocketUrl('example.com:443', useTls: false),
        'ws://example.com:443/ws',
      );
      expect(
        buildDaemonWebSocketUrl('example.com:6767', useTls: true),
        'wss://example.com:6767/ws',
      );
    });

    test('builds versioned relay URLs and data socket IDs', () {
      final defaultUrl = Uri.parse(
        buildRelayWebSocketUrl(
          endpoint: 'relay.tinyrack.dev:443',
          useTls: true,
          serverId: 'srv_test',
          role: RelayRole.client,
        ),
      );
      expect(defaultUrl.queryParameters['v'], currentRelayProtocolVersion);
      expect(defaultUrl.queryParameters.containsKey('connectionId'), isFalse);

      final dataUrl = Uri.parse(
        buildRelayWebSocketUrl(
          endpoint: 'relay.tinyrack.dev:443',
          useTls: true,
          serverId: 'srv_test',
          role: RelayRole.server,
          connectionId: 'conn_abc123',
          version: 1,
        ),
      );
      expect(dataUrl.queryParameters['v'], '1');
      expect(dataUrl.queryParameters['connectionId'], 'conn_abc123');
    });

    test('round-trips IPv6 relay endpoints', () {
      final url = buildRelayWebSocketUrl(
        endpoint: '[::1]:443',
        useTls: true,
        serverId: 'srv_test',
        role: RelayRole.client,
      );
      expect(Uri.parse(url).scheme, 'wss');
      expect(extractHostPortFromWebSocketUrl(url), '[::1]:443');
    });

    test('normalizes and rejects relay protocol versions', () {
      expect(normalizeRelayProtocolVersion(null), '2');
      expect(normalizeRelayProtocolVersion(2), '2');
      expect(normalizeRelayProtocolVersion('1'), '1');
      expect(() => normalizeRelayProtocolVersion('3'), throwsFormatException);
    });
  });

  test('host helpers preserve Paseo behavior', () {
    expect(normalizeHostPort(' example.com:6767 '), 'example.com:6767');
    expect(normalizeHostPort('[::1]:6767'), '[::1]:6767');
    expect(normalizeLoopbackToLocalhost('127.0.0.1:6767'), 'localhost:6767');
    expect(normalizeLoopbackToLocalhost('[::1]:6767'), 'localhost:6767');
    expect(
      normalizeLoopbackToLocalhost('example.com:6767'),
      'example.com:6767',
    );
    expect(deriveLabelFromEndpoint('bad'), 'Unnamed Host');
    expect(shouldUseTlsForDefaultHostedRelay('relay.example.com:443'), isTrue);
    expect(shouldUseTlsForDefaultHostedRelay('bad'), isFalse);
  });

  test('WebSocket inspection handles defaults and malformed URLs', () {
    expect(
      extractHostPortFromWebSocketUrl('wss://example.com/ws'),
      'example.com:443',
    );
    expect(
      extractHostPortFromWebSocketUrl('ws://example.com/ws'),
      'example.com:80',
    );
    expect(
      () => extractHostPortFromWebSocketUrl('http://example.com/ws'),
      throwsFormatException,
    );
    expect(
      () => extractHostPortFromWebSocketUrl('ws://example.com/not-ws'),
      throwsFormatException,
    );
    expect(
      isRelayClientWebSocketUrl(
        'wss://relay.example.com/ws?role=client&serverId=srv',
      ),
      isTrue,
    );
    expect(
      isRelayClientWebSocketUrl('wss://relay.example.com/ws?role=server'),
      isFalse,
    );
    expect(isRelayClientWebSocketUrl('http://['), isFalse);
  });

  test('host and port validation rejects boundary failures', () {
    expect(() => parseHostPort('host:0'), throwsFormatException);
    expect(() => parseHostPort('host:65536'), throwsFormatException);
    expect(() => parseHostPort('[::1]'), throwsFormatException);
    expect(() => parseHostPort(''), throwsFormatException);
  });
}
