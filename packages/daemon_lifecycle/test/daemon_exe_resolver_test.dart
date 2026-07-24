import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// NOTE: resolveDaemonExe() consults Directory.current (via a private
// walk-up-to-the-workspace-root helper). Directory.current is process-global
// in Dart, and `dart test` runs multiple test files concurrently in the same
// process by default, so mutating it directly from a test would race with
// unrelated test files. Instead, the cwd-dependent scenarios below run
// resolveDaemonExe() in a genuinely separate OS process (via
// support/resolve_daemon_exe_probe.dart) with `workingDirectory` set on that
// child process only.

final _packageRoot = Directory.current.path.endsWith('daemon_lifecycle')
    ? Directory.current.path
    : p.join(Directory.current.path, 'packages', 'daemon_lifecycle');
final _probeScript =
    p.join(_packageRoot, 'test', 'support', 'resolve_daemon_exe_probe.dart');

Future<String?> _resolveWithCwd(String cwd,
    {Map<String, String>? environment}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', _probeScript],
    workingDirectory: cwd,
    environment: environment,
  );
  expect(result.exitCode, 0, reason: result.stderr.toString());
  final out = (result.stdout as String).trim();
  return out.isEmpty ? null : out;
}

/// `dart run` on Windows can briefly hold a handle on files the child process
/// touched even after the process exits (AV scanning, slow disk), which races
/// with an immediate recursive delete. Retry a few times instead of flaking.
void _deleteWithRetry(Directory dir) {
  for (var attempt = 0; ; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on PathAccessException {
      if (attempt >= 5) rethrow;
      sleep(const Duration(milliseconds: 200));
    }
  }
}

void main() {
  final exeName = Platform.isWindows ? 'daemon.exe' : 'daemon';

  test('called directly, resolveDaemonExe completes without throwing',
      () async {
    // Smoke test against the real repo working directory (whatever it is
    // when `dart test` invoked this suite) - just ensures no exception and,
    // if something is found, that it is a real file.
    final resolved = await resolveDaemonExe();
    if (resolved != null) {
      expect(File(resolved).existsSync(), isTrue);
    }
  });

  test(
      'walks up to the workspace root and finds the dev build exe',
      () async {
    final workspaceRoot =
        Directory.systemTemp.createTempSync('daemon-exe-resolver-test-');
    addTearDown(() => _deleteWithRetry(workspaceRoot));

    File(p.join(workspaceRoot.path, 'pubspec.yaml'))
        .writeAsStringSync('name: coding_agent_workspace\n');
    final buildDir =
        Directory(p.join(workspaceRoot.path, 'packages', 'daemon', 'build'))
          ..createSync(recursive: true);
    final exeFile = File(p.join(buildDir.path, exeName))
      ..writeAsStringSync('not a real exe, just a marker file');

    final nested = Directory(p.join(workspaceRoot.path, 'a', 'b', 'c'))
      ..createSync(recursive: true);

    final resolved = await _resolveWithCwd(nested.path);

    // The bundled-desktop-build candidates (sibling of Platform.resolvedExecutable)
    // are extremely unlikely to exist on a dev/test machine, so we expect the
    // dev-workspace lookup to win.
    expect(resolved, exeFile.path);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
      'a pubspec.yaml without the workspace marker is not treated as root',
      () async {
    final workspaceRoot = Directory.systemTemp
        .createTempSync('daemon-exe-resolver-test-nomarker-');
    addTearDown(() => _deleteWithRetry(workspaceRoot));

    File(p.join(workspaceRoot.path, 'pubspec.yaml'))
        .writeAsStringSync('name: some_unrelated_package\n');
    final buildDir =
        Directory(p.join(workspaceRoot.path, 'packages', 'daemon', 'build'))
          ..createSync(recursive: true);
    final bogusExe = File(p.join(buildDir.path, exeName))
      ..writeAsStringSync('should not be picked up');

    final resolved = await _resolveWithCwd(workspaceRoot.path);

    // Must not resolve to the exe under this non-matching pubspec.yaml.
    expect(resolved, isNot(bogusExe.path));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
      'falls back to PATH lookup (where/which) when neither a bundled nor '
      'dev-workspace exe is found', () async {
    // A cwd with no ancestor pubspec.yaml carrying the workspace marker, so
    // the dev-workspace walk-up returns null and resolution falls through to
    // the `where`/`which` PATH lookup.
    final cwd =
        Directory.systemTemp.createTempSync('daemon-exe-resolver-path-');
    addTearDown(() => _deleteWithRetry(cwd));

    final fakePathDir =
        Directory.systemTemp.createTempSync('daemon-exe-resolver-fakepath-');
    addTearDown(() => _deleteWithRetry(fakePathDir));
    final fakeExe = File(p.join(fakePathDir.path, exeName))
      ..writeAsStringSync('not a real exe, just a marker file for `where`');

    final resolved = await _resolveWithCwd(
      cwd.path,
      environment: {
        'PATH': '${fakePathDir.path};${Platform.environment['PATH'] ?? ''}',
      },
    );

    // `where` on Windows can print the 8.3 short form of a path component
    // (e.g. `WINETR~1` for a long username) even though the long path was
    // used to build the PATH entry, so compare resolved-canonical paths
    // rather than the raw strings.
    expect(resolved, isNotNull);
    expect(File(resolved!).resolveSymbolicLinksSync(),
        fakeExe.resolveSymbolicLinksSync());
  }, timeout: const Timeout(Duration(seconds: 90)));
}
