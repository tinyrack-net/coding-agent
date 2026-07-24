/// Shared daemon lifecycle logic used by both the daemon process (lock write,
/// heartbeat) and the desktop app (probe, spawn, stop, supervise).
library;

export 'src/daemon_exe_resolver.dart';
export 'src/daemon_paths.dart';
export 'src/daemon_spawner.dart';
export 'src/daemon_stopper.dart';
export 'src/daemon_supervisor.dart';
export 'src/hello_probe.dart';
export 'src/pid_lock.dart';
export 'src/process_ops.dart';
export 'src/versions.dart';
