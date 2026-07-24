import 'dart:io';

/// True when a process with [pid] is alive.
Future<bool> isPidAlive(int pid) async {
  if (pid <= 0) return false;
  if (Platform.isWindows) {
    final result = await Process.run(
      'tasklist',
      ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH'],
    );
    return result.exitCode == 0 &&
        (result.stdout as String).contains('"$pid"');
  }
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

/// Kills the process tree rooted at [pid]. Windows: taskkill /T /F.
/// Unix: SIGTERM, then SIGKILL after [grace] if still alive.
Future<void> killTree(int pid, {Duration grace = const Duration(seconds: 3)}) async {
  if (pid <= 0) return;
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    return;
  }
  await Process.run('kill', ['-TERM', '$pid']);
  final deadline = DateTime.now().add(grace);
  while (DateTime.now().isBefore(deadline)) {
    if (!await isPidAlive(pid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  await Process.run('kill', ['-KILL', '$pid']);
}
