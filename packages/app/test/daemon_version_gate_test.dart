import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

ServerHello hello(String version) =>
    ServerHello(daemonVersion: version, protocolVersion: 1);

void main() {
  group('isLoopbackHost', () {
    test('recognizes loopback hosts', () {
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
    });

    test('rejects remote hosts', () {
      expect(isLoopbackHost('192.168.0.10'), isFalse);
      expect(isLoopbackHost('daemon.example.com'), isFalse);
    });
  });

  group('shouldRejectHello', () {
    final remote = Uri.parse('ws://192.168.0.10:6868');
    final local = Uri.parse('ws://127.0.0.1:6868');

    test('never rejects loopback daemons regardless of version', () {
      expect(
        shouldRejectHello(local, hello('9.0.0'), appDaemonVersion: '0.2.0'),
        isFalse,
      );
    });

    test('accepts remote daemon with same major', () {
      expect(
        shouldRejectHello(remote, hello('0.9.9'), appDaemonVersion: '0.2.0'),
        isFalse,
      );
      expect(
        shouldRejectHello(remote, hello('1.0.0'), appDaemonVersion: '1.4.2'),
        isFalse,
      );
    });

    test('rejects remote daemon with different major', () {
      expect(
        shouldRejectHello(remote, hello('1.0.0'), appDaemonVersion: '0.2.0'),
        isTrue,
      );
      expect(
        shouldRejectHello(remote, hello('0.2.0'), appDaemonVersion: '1.0.0'),
        isTrue,
      );
    });

    test('rejects remote daemon with unparseable version', () {
      expect(
        shouldRejectHello(remote, hello('garbage'), appDaemonVersion: '0.2.0'),
        isTrue,
      );
    });

    test('uses bundled daemon version by default', () {
      // Same-major as the bundled version must pass.
      expect(shouldRejectHello(local, hello('0.0.1')), isFalse);
    });
  });

  group('versionMismatchMessage', () {
    test('names the remote version and the supported major', () {
      final message = versionMismatchMessage(
        hello('2.3.0'),
        appDaemonVersion: '1.4.0',
      );
      expect(message, contains('원격 데몬 v2.3.0'));
      expect(message, contains('v1.x만 지원합니다'));
      expect(message, contains('데몬 또는 앱을 업데이트하세요'));
    });
  });
}
