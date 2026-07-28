import 'dart:io';

import 'package:agent_daemon/src/server/trusted_proxies.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('parses environment and persisted trusted proxy contracts', () {
    expect(parseTrustedProxiesEnv(null), ['loopback']);
    expect(parseTrustedProxiesEnv(' yes '), isTrue);
    expect(parseTrustedProxiesEnv('off'), isEmpty);
    expect(parseTrustedProxiesEnv('loopback, 10.0.0.0/8'), [
      'loopback',
      '10.0.0.0/8',
    ]);
    expect(parsePersistedTrustedProxies(true), isTrue);
    expect(parsePersistedTrustedProxies(['LOOPBACK']), ['loopback']);
    expect(() => parsePersistedTrustedProxies(false), throwsFormatException);
    expect(
      () => parsePersistedTrustedProxies(['10.0.0.0/99']),
      throwsFormatException,
    );
  });

  test('matches Express proxy-addr names, exact addresses, and CIDRs', () {
    expect(
      isTrustedProxy(InternetAddress.loopbackIPv4, const <String>['loopback']),
      isTrue,
    );
    expect(
      isTrustedProxy(InternetAddress('10.2.3.4'), const <String>['10.0.0.0/8']),
      isTrue,
    );
    expect(
      isTrustedProxy(InternetAddress('192.168.1.2'), const <String>[
        'uniquelocal',
      ]),
      isTrue,
    );
    expect(
      isTrustedProxy(InternetAddress('8.8.8.8'), const <String>['loopback']),
      isFalse,
    );
    expect(isTrustedProxy(InternetAddress('8.8.8.8'), true), isTrue);
  });

  test('uses forwarded protocol only when the immediate proxy is trusted', () {
    final trusted = Request(
      'GET',
      Uri.parse('http://daemon.test/'),
      headers: {'x-forwarded-proto': 'https, http'},
      context: {
        'shelf.io.connection_info': _ConnectionInfo(
          InternetAddress.loopbackIPv4,
        ),
      },
    );
    expect(effectiveRequestScheme(trusted, const ['loopback']), 'https');
    expect(effectiveRequestScheme(trusted, const <String>[]), 'http');
  });
}

class _ConnectionInfo implements HttpConnectionInfo {
  const _ConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get localPort => 6868;

  @override
  int get remotePort => 12345;
}
