import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// defaultDataDir()'s USERPROFILE/HOME/Directory.current.path fallback chain
// can't be exercised in-process on this machine: USERPROFILE is always set
// on Windows, and while dart:io has no supported way to change env vars for
// the *current* process, Platform.environment turns out to be a snapshot
// that's already cached by the time any of *our* code runs (something in
// `package:test`'s own bootstrap reads it first) even when mutated directly
// via the real Win32 SetEnvironmentVariableW API from setUpAll. So the
// fallback branches are instead probed in a genuinely separate OS process
// via Process.run(includeParentEnvironment: false), mirroring the approach
// in daemon_exe_resolver_test.dart. That process-level env is real and
// controllable; only Platform.environment's in-process caching defeats
// in-process mutation.
final _packageRoot = Directory.current.path.endsWith('daemon_lifecycle')
    ? Directory.current.path
    : p.join(Directory.current.path, 'packages', 'daemon_lifecycle');
final _probeScript =
    p.join(_packageRoot, 'test', 'support', 'default_data_dir_probe.dart');

Future<String> _defaultDataDirWithEnv(
    Map<String, String> environment, String cwd) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', _probeScript],
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return (result.stdout as String).trim();
}

void main() {
  test('explicit dataDir drives lockFile and logFile paths', () {
    final paths = DaemonPaths(dataDir: p.join('some', 'dir'));
    expect(paths.dataDir, p.join('some', 'dir'));
    expect(paths.lockFile, p.join('some', 'dir', 'daemon.pid'));
    expect(paths.logFile, p.join('some', 'dir', 'daemon.log'));
  });

  test('defaultDataDir resolves under the user home directory', () {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    expect(DaemonPaths.defaultDataDir(), p.join(home, '.tinyrack-agent'));
  });

  test('no-arg constructor uses defaultDataDir', () {
    final paths = DaemonPaths();
    expect(paths.dataDir, DaemonPaths.defaultDataDir());
  });

  test('desktopManagedEnvVar is the well-known env var name', () {
    expect(desktopManagedEnvVar, 'TINYRACK_DESKTOP_MANAGED');
  });

  group('defaultDataDir fallback chain (out-of-process)', () {
    final minimalEnv = {
      'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'PATH': Platform.environment['PATH'] ?? '',
      'TEMP': Platform.environment['TEMP'] ?? '',
      'TMP': Platform.environment['TMP'] ?? '',
    };

    test('falls back to HOME when USERPROFILE is unset', () async {
      final cwd = Directory.systemTemp.createTempSync('default-data-dir-');
      addTearDown(() => cwd.deleteSync(recursive: true));

      final resolved = await _defaultDataDirWithEnv(
        {...minimalEnv, 'HOME': cwd.path},
        cwd.path,
      );

      expect(resolved, p.join(cwd.path, '.tinyrack-agent'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
        'falls back to Directory.current.path when both USERPROFILE and '
        'HOME are unset', () async {
      final cwd = Directory.systemTemp.createTempSync('default-data-dir-');
      addTearDown(() => cwd.deleteSync(recursive: true));

      final resolved = await _defaultDataDirWithEnv(minimalEnv, cwd.path);

      expect(resolved, p.join(cwd.path, '.tinyrack-agent'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
