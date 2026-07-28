import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const int servicePortScriptMaxOutputBytes = 1024;
const Duration servicePortScriptTimeout = Duration(seconds: 10);

final class ServicePortAllocation {
  const ServicePortAllocation({this.range, this.portScript});

  final String? range;
  final String? portScript;
}

typedef PortAvailability = Future<bool> Function(int port);
typedef FreePortFinder = Future<int> Function();

Future<int> allocateWorkspaceServicePort({
  required ServicePortAllocation? allocation,
  required String cwd,
  required String scriptName,
  required String workspaceId,
  required String? branchName,
  Set<int> reservedPorts = const {},
  Random? random,
  PortAvailability portAvailable = isTcpPortAvailable,
  FreePortFinder findFreePort = findAvailableTcpPort,
  Duration scriptTimeout = servicePortScriptTimeout,
}) async {
  final portScript = allocation?.portScript?.trim();
  if (portScript != null && portScript.isNotEmpty) {
    return _allocateFromScript(
      cwd: cwd,
      command: portScript,
      scriptName: scriptName,
      workspaceId: workspaceId,
      branchName: branchName,
      reservedPorts: reservedPorts,
      timeout: scriptTimeout,
    );
  }
  final range = allocation?.range?.trim();
  if (range != null && range.isNotEmpty) {
    final parsed = _parsePortRange(range);
    final count = parsed.$2 - parsed.$1 + 1;
    final startOffset = (random ?? Random()).nextInt(count);
    for (var offset = 0; offset < count; offset++) {
      final port = parsed.$1 + ((startOffset + offset) % count);
      if (reservedPorts.contains(port)) continue;
      if (await portAvailable(port)) return port;
    }
    throw StateError(
      'No available service port in configured range '
      '${parsed.$1}-${parsed.$2}',
    );
  }
  return findFreePort();
}

Future<int> _allocateFromScript({
  required String cwd,
  required String command,
  required String scriptName,
  required String workspaceId,
  required String? branchName,
  required Set<int> reservedPorts,
  required Duration timeout,
}) async {
  Process? process;
  try {
    final started = await Process.start(
      command,
      [scriptName, workspaceId, branchName ?? '', cwd],
      workingDirectory: cwd,
      environment: {
        'TINYRACK_SCRIPTNAME': scriptName,
        'TINYRACK_WORKSPACE_ID': workspaceId,
        'TINYRACK_BRANCH_NAME': branchName ?? '',
        'TINYRACK_WORKTREE_PATH': cwd,
      },
      includeParentEnvironment: true,
      runInShell: Platform.isWindows,
    );
    process = started;
    final result = await Future.wait<Object>([
      _collectBounded(started.stdout, started),
      _collectBounded(started.stderr, started),
      started.exitCode,
    ]).timeout(timeout);
    final stdout = result[0] as String;
    final stderr = result[1] as String;
    final exitCode = result[2] as int;
    if (exitCode != 0) {
      throw StateError(
        'exit code $exitCode${stderr.trim().isEmpty ? '' : ': ${stderr.trim()}'}',
      );
    }
    final output = stdout.trim();
    if (!RegExp(r'^\d+$').hasMatch(output)) {
      throw StateError(
        "Service port script '$command' must print exactly one TCP port",
      );
    }
    final port = int.parse(output);
    if (!_validTcpPort(port)) {
      throw StateError(
        "Service port script '$command' returned invalid TCP port '$output'",
      );
    }
    if (reservedPorts.contains(port)) {
      throw StateError(
        "Service port script '$command' returned reserved port $port",
      );
    }
    return port;
  } catch (error) {
    if (error is TimeoutException && process != null) {
      await _terminatePortScript(process);
    }
    if (error is StateError &&
        error.message.toString().startsWith('Service port script')) {
      rethrow;
    }
    throw StateError("Service port script '$command' failed: $error");
  }
}

Future<void> _terminatePortScript(Process process) async {
  if (Platform.isWindows) {
    // Process.start(runInShell: true) owns a cmd.exe which can itself own the
    // configured script's child processes. Killing only cmd.exe leaks those
    // children and keeps the workspace (and its temporary test fixture) open.
    await Process.run('taskkill', [
      '/PID',
      '${process.pid}',
      '/T',
      '/F',
    ], runInShell: false);
  } else {
    process.kill();
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
  }
}

Future<String> _collectBounded(
  Stream<List<int>> stream,
  Process process,
) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
    if (bytes.length > servicePortScriptMaxOutputBytes) {
      process.kill();
      throw StateError(
        'Service port script output exceeded '
        '$servicePortScriptMaxOutputBytes bytes',
      );
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

(int, int) _parsePortRange(String value) {
  final match = RegExp(r'^(\d{1,5})-(\d{1,5})$').firstMatch(value);
  if (match == null) throw StateError("Invalid service port range '$value'");
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  if (!_validTcpPort(start) || !_validTcpPort(end) || start > end) {
    throw StateError("Invalid service port range '$value'");
  }
  return (start, end);
}

bool _validTcpPort(int port) => port >= 1 && port <= 65535;

Future<bool> isTcpPortAvailable(int port) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    return true;
  } on SocketException {
    return false;
  } finally {
    await socket?.close();
  }
}

Future<int> findAvailableTcpPort() async {
  final socket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    shared: false,
  );
  final port = socket.port;
  await socket.close();
  return port;
}
