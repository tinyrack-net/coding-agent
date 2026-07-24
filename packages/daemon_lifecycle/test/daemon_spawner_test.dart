import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late Directory temp;
  late DaemonPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('spawner-test-');
    paths = DaemonPaths(dataDir: temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  // We can't exercise the "becomes healthy" success path without a real
  // daemon executable that opens the requested host:port and answers the
  // hello handshake (spawnDaemonDetached's argument list is fixed to
  // --host/--port/--data-dir, so there's no seam to inject a fake WS server
  // script as the target of `exePath`). We do fully exercise the timeout /
  // failure path below, including the log-tail attachment.
  test('throws DaemonSpawnException when the process never answers hello',
      () async {
    final port = await _freePort();
    // `ping` accepts arbitrary bogus flags without ever opening the daemon's
    // WebSocket port, so probeDaemon will never succeed and the deadline
    // will be hit.
    final exe = Platform.isWindows ? 'ping' : 'sleep';

    DaemonSpawnException? caught;
    try {
      await spawnDaemonDetached(
        exePath: exe,
        paths: paths,
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(milliseconds: 800),
      );
      fail('expected a DaemonSpawnException');
    } on DaemonSpawnException catch (e) {
      caught = e;
    }

    expect(caught, isNotNull);
    expect(caught.message, contains('did not become healthy'));
    expect(caught.message,
        contains('${const Duration(milliseconds: 800).inSeconds}s'));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('logTail is attached and contains the tail of daemon.log when present',
      () async {
    final port = await _freePort();
    final logLines = List.generate(60, (i) => 'log line $i');
    File(paths.logFile).writeAsStringSync(logLines.join('\n'));

    DaemonSpawnException? caught;
    try {
      await spawnDaemonDetached(
        exePath: Platform.isWindows ? 'ping' : 'sleep',
        paths: paths,
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(milliseconds: 500),
      );
      fail('expected a DaemonSpawnException');
    } on DaemonSpawnException catch (e) {
      caught = e;
    }

    expect(caught, isNotNull);
    expect(caught.logTail, isNotNull);
    // Only the last 40 lines should be kept.
    expect(caught.logTail, isNot(contains('log line 0\n')));
    expect(caught.logTail, contains('log line 59'));
    expect(caught.toString(), contains('--- daemon.log ---'));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('logTail is null when daemon.log does not exist', () async {
    final port = await _freePort();

    DaemonSpawnException? caught;
    try {
      await spawnDaemonDetached(
        exePath: Platform.isWindows ? 'ping' : 'sleep',
        paths: paths,
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(milliseconds: 500),
      );
      fail('expected a DaemonSpawnException');
    } on DaemonSpawnException catch (e) {
      caught = e;
    }

    expect(caught, isNotNull);
    expect(caught.logTail, isNull);
  }, timeout: const Timeout(Duration(seconds: 15)));
}
