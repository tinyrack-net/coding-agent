import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String lockPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('lock-test-');
    lockPath = p.join(temp.path, 'daemon.pid');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  PidLockData data({int pid = 100, bool desktopManaged = true}) => PidLockData(
        pid: pid,
        startedAtMs: 1,
        host: '127.0.0.1',
        port: 6868,
        version: '0.2.0',
        desktopManaged: desktopManaged,
      );

  test('acquire writes lock and release deletes it', () async {
    final lock = PidLock(lockPath);
    await lock.acquire(data());
    expect((await lock.read())!.pid, 100);
    await lock.release();
    expect(File(lockPath).existsSync(), isFalse);
  });

  test('second acquire fails while holder is fresh', () async {
    final first = PidLock(lockPath);
    await first.acquire(data());
    final second = PidLock(lockPath, isPidAlive: (_) async => true);
    await expectLater(
        second.acquire(data(pid: 200)), throwsA(isA<LockHeldException>()));
  });

  test('stale lock (old mtime + dead pid) is reclaimed', () async {
    final first = PidLock(lockPath);
    await first.acquire(data());
    final future = DateTime.now().add(const Duration(minutes: 10));
    final second = PidLock(
      lockPath,
      now: () => future,
      isPidAlive: (_) async => false,
    );
    await second.acquire(data(pid: 200));
    expect((await second.read())!.pid, 200);
  });

  test('old mtime but live pid is NOT stale', () async {
    final first = PidLock(lockPath);
    await first.acquire(data());
    final future = DateTime.now().add(const Duration(minutes: 10));
    final second = PidLock(
      lockPath,
      now: () => future,
      isPidAlive: (_) async => true,
    );
    await expectLater(
        second.acquire(data(pid: 200)), throwsA(isA<LockHeldException>()));
  });

  test('corrupt lock file is treated as stale', () async {
    File(lockPath).writeAsStringSync('not-json');
    final lock = PidLock(lockPath);
    await lock.acquire(data());
    expect((await lock.read())!.pid, 100);
  });

  test('update rewrites contents', () async {
    final lock = PidLock(lockPath);
    await lock.acquire(data());
    await lock.update(data(pid: 100).let((d) => PidLockData(
          pid: d.pid,
          startedAtMs: d.startedAtMs,
          host: d.host,
          port: 7000,
          version: d.version,
          desktopManaged: d.desktopManaged,
        )));
    expect((await lock.read())!.port, 7000);
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
