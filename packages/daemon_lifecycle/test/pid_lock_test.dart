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

  test(
      'acquire gives up with StateError when the stale lock file cannot be '
      'deleted across both retry attempts', () async {
    File(lockPath).writeAsStringSync('not-json');
    // Hold an open read handle on the lock file so File.delete() inside
    // acquire()'s stale-cleanup path fails every time (Windows refuses to
    // delete a file that's still open elsewhere), forcing both retry
    // attempts to be exhausted.
    final blocker = await File(lockPath).open(mode: FileMode.read);
    addTearDown(blocker.close);

    final lock = PidLock(lockPath);
    await expectLater(lock.acquire(data()), throwsA(isA<StateError>()));
  });

  test('LockHeldException.toString includes pid and port', () {
    final exception = LockHeldException(data(pid: 321));
    expect(exception.toString(),
        'daemon already running (pid 321, port 6868)');
  });

  group('startHeartbeat', () {
    test('periodically rewrites the lock file while held', () async {
      final lock = PidLock(lockPath);
      await lock.acquire(data());
      final before = File(lockPath).lastModifiedSync();

      lock.startHeartbeat(interval: const Duration(milliseconds: 50));
      addTearDown(lock.release);

      // Poll for an mtime change instead of a single fixed sleep, to avoid
      // flakiness from coarse filesystem mtime resolution.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var changed = false;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (File(lockPath).lastModifiedSync().isAfter(before)) {
          changed = true;
          break;
        }
      }
      expect(changed, isTrue,
          reason: 'heartbeat should have rewritten the lock file by now');
      expect((await lock.read())!.pid, 100);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('does nothing before a lock is held (no-op tick)', () async {
      final lock = PidLock(lockPath);
      // Never call acquire(): _held stays null, so each timer tick should
      // just return early instead of touching the filesystem.
      lock.startHeartbeat(interval: const Duration(milliseconds: 20));
      addTearDown(lock.release);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File(lockPath).existsSync(), isFalse);
    });
  });

  group('isStale', () {
    test('is false when no lock file exists', () async {
      final lock = PidLock(lockPath);
      expect(await lock.isStale(), isFalse);
    });

    test('is true when the lock file exists but is corrupt', () async {
      File(lockPath).writeAsStringSync('not-json');
      final lock = PidLock(lockPath);
      expect(await lock.isStale(), isTrue);
    });

    test('is false for a fresh lock held by a live pid', () async {
      final lock = PidLock(lockPath, isPidAlive: (_) async => true);
      await lock.acquire(data());
      expect(await lock.isStale(), isFalse);
    });

    test('is true for an old lock whose pid is dead', () async {
      final lock = PidLock(lockPath);
      await lock.acquire(data());
      final future = DateTime.now().add(const Duration(minutes: 10));
      final staleView = PidLock(
        lockPath,
        now: () => future,
        isPidAlive: (_) async => false,
      );
      expect(await staleView.isStale(), isTrue);
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
