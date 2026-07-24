import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates the daemon executable. Resolution order:
/// 1. Bundled next to the app executable (packaged desktop build):
///    Windows: `daemon.exe` sibling of the app exe;
///    macOS: `../Helpers/daemon` relative to `Contents/MacOS/<app>`.
/// 2. Dev workspace: `packages/daemon/build/daemon(.exe)` found by walking up
///    from the current directory to the workspace root.
/// 3. `daemon` on PATH (standalone install).
Future<String?> resolveDaemonExe() async {
  final exeName = Platform.isWindows ? 'daemon.exe' : 'daemon';

  final appDir = p.dirname(Platform.resolvedExecutable);
  final candidates = <String>[
    p.join(appDir, exeName),
    if (Platform.isMacOS) p.normalize(p.join(appDir, '..', 'Helpers', 'daemon')),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }

  final devExe = _findDevExe(exeName);
  if (devExe != null) return devExe;

  final lookup = Platform.isWindows
      ? await Process.run('where', ['daemon'])
      : await Process.run('which', ['daemon']); // coverage:ignore-line
  if (lookup.exitCode == 0) {
    // coverage:ignore-start
    // Only reachable when `daemon` resolves on PATH, which the test suite
    // exercises via a child process with a scoped PATH override (see
    // daemon_exe_resolver_test.dart) — package:coverage cannot credit
    // coverage collected in a separate spawned process.
    final first = (lookup.stdout as String)
        .split(RegExp(r'\r?\n'))
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (first.trim().isNotEmpty) return first.trim();
    // coverage:ignore-end
  }
  return null;
}

String? _findDevExe(String exeName) {
  var dir = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('coding_agent_workspace')) {
      final exe =
          File(p.join(dir.path, 'packages', 'daemon', 'build', exeName));
      return exe.existsSync() ? exe.path : null;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
