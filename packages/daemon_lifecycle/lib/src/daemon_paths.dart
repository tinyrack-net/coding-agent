import 'dart:io';

import 'package:path/path.dart' as p;

/// Well-known daemon file locations, shared by daemon and app.
class DaemonPaths {
  DaemonPaths({String? dataDir}) : dataDir = dataDir ?? defaultDataDir();

  final String dataDir;

  String get lockFile => p.join(dataDir, 'daemon.pid');
  String get logFile => p.join(dataDir, 'daemon.log');

  static String defaultDataDir() {
    final home = Platform.environment['USERPROFILE'] ??
        // coverage:ignore-start
        // USERPROFILE is always set on Windows, the only supported/tested
        // platform; Platform.environment can't be mutated in-process to
        // reach this fallback under `dart test`.
        Platform.environment['HOME'] ??
        Directory.current.path;
        // coverage:ignore-end
    return p.join(home, '.tinyrack-agent');
  }
}

/// Env var the desktop app sets when spawning its bundled daemon; the daemon
/// stamps it into the pid lock and its hello as `desktopManaged`.
const String desktopManagedEnvVar = 'TINYRACK_DESKTOP_MANAGED';
