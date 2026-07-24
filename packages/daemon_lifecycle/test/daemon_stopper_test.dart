import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

import 'support/fake_daemon_server.dart';

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test('StopRefusedException.toString includes the reason', () {
    final exception = StopRefusedException('some reason');
    expect(exception.toString(), 'StopRefusedException: some reason');
  });

  late Directory temp;
  late DaemonPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('stopper-test-');
    paths = DaemonPaths(dataDir: temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  PidLockData lockData({
    int pid = 100,
    bool desktopManaged = false,
  }) =>
      PidLockData(
        pid: pid,
        startedAtMs: 1,
        host: '127.0.0.1',
        port: 6868,
        version: '0.2.0',
        desktopManaged: desktopManaged,
      );

  group('no daemon reachable, no lock file', () {
    test('refuses to stop without force', () async {
      final port = await _freePort();
      await expectLater(
        stopDaemon(paths: paths, host: '127.0.0.1', port: port),
        throwsA(isA<StopRefusedException>()),
      );
    });

    test('force=true completes as a no-op', () async {
      final port = await _freePort();
      await stopDaemon(
          paths: paths, host: '127.0.0.1', port: port, force: true);
    });
  });

  group('lock file present, no daemon reachable (dead pid)', () {
    test('desktop-managed dead-pid lock is cleaned up without force',
        () async {
      final lock = PidLock(paths.lockFile);
      await lock.acquire(lockData(pid: 999999, desktopManaged: true));
      final port = await _freePort();

      await stopDaemon(paths: paths, host: '127.0.0.1', port: port);

      expect(File(paths.lockFile).existsSync(), isFalse);
    });

    test('non-desktop-managed lock refuses without force, and lock survives',
        () async {
      final lock = PidLock(paths.lockFile);
      await lock.acquire(lockData(pid: 999999, desktopManaged: false));
      final port = await _freePort();

      await expectLater(
        stopDaemon(paths: paths, host: '127.0.0.1', port: port),
        throwsA(isA<StopRefusedException>()),
      );
      expect(File(paths.lockFile).existsSync(), isTrue);
    });

    test('non-desktop-managed lock is cleaned up with force', () async {
      final lock = PidLock(paths.lockFile);
      await lock.acquire(lockData(pid: 999999, desktopManaged: false));
      final port = await _freePort();

      await stopDaemon(
          paths: paths, host: '127.0.0.1', port: port, force: true);

      expect(File(paths.lockFile).existsSync(), isFalse);
    });
  });

  group('lock file present with a live pid, no daemon reachable', () {
    test('killTree is used to reap the process and the lock is cleaned up',
        () async {
      final proc = Platform.isWindows
          ? await Process.start('ping', ['-n', '30', '127.0.0.1'])
          : await Process.start('sleep', ['30']);
      addTearDown(() {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });

      final lock = PidLock(paths.lockFile);
      await lock.acquire(lockData(pid: proc.pid, desktopManaged: false));
      final port = await _freePort();

      await stopDaemon(
          paths: paths, host: '127.0.0.1', port: port, force: true);

      expect(await isPidAlive(proc.pid), isFalse);
      expect(File(paths.lockFile).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('daemon reachable via hello', () {
    test('desktop-managed daemon whose pid exits on its own is not killTree-d',
        () async {
      // A process that exits well within the exitWait window on its own.
      final proc = Platform.isWindows
          ? await Process.start('ping', ['-n', '1', '127.0.0.1'])
          : await Process.start('sh', ['-c', 'exit 0']);
      addTearDown(() async {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });

      final server =
          FakeDaemonServer(pid: proc.pid, desktopManaged: true);
      await server.start();
      addTearDown(server.stop);

      await stopDaemon(
        paths: paths,
        host: '127.0.0.1',
        port: server.port,
        exitWait: const Duration(seconds: 5),
      );

      expect(await isPidAlive(proc.pid), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('falls back to killTree when the pid outlives exitWait', () async {
      final proc = Platform.isWindows
          ? await Process.start('ping', ['-n', '30', '127.0.0.1'])
          : await Process.start('sleep', ['30']);
      addTearDown(() {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });

      final server =
          FakeDaemonServer(pid: proc.pid, desktopManaged: true);
      await server.start();
      addTearDown(server.stop);

      await stopDaemon(
        paths: paths,
        host: '127.0.0.1',
        port: server.port,
        exitWait: const Duration(milliseconds: 200),
      );

      expect(await isPidAlive(proc.pid), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('non-desktop-managed daemon refuses to stop without force',
        () async {
      final server = FakeDaemonServer(desktopManaged: false);
      await server.start();
      addTearDown(server.stop);

      await expectLater(
        stopDaemon(paths: paths, host: '127.0.0.1', port: server.port),
        throwsA(isA<StopRefusedException>()),
      );
    });
  });
}
