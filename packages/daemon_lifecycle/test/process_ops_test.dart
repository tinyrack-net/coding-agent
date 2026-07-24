import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('isPidAlive is false for non-positive pids without spawning anything',
      () async {
    expect(await isPidAlive(0), isFalse);
    expect(await isPidAlive(-1), isFalse);
  });

  test('isPidAlive is true for the current process', () async {
    expect(await isPidAlive(pid), isTrue);
  });

  test('isPidAlive is false for a pid that is very unlikely to exist',
      () async {
    expect(await isPidAlive(999999), isFalse);
  });

  test('killTree on an already-dead pid does not throw', () async {
    await killTree(999999);
  });

  group('against a real spawned process', () {
    late Process proc;

    setUp(() async {
      proc = Platform.isWindows
          ? await Process.start('ping', ['-n', '30', '127.0.0.1'])
          : await Process.start('sleep', ['30']);
    });

    tearDown(() async {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });

    test('isPidAlive is true while the process runs', () async {
      expect(await isPidAlive(proc.pid), isTrue);
    });

    test('killTree terminates the process tree', () async {
      expect(await isPidAlive(proc.pid), isTrue);
      await killTree(proc.pid);
      expect(await isPidAlive(proc.pid), isFalse);
      await proc.exitCode;
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
