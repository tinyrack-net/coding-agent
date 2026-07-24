@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Integration tests for the daemon lifecycle: pid lock, hello probe,
/// single-instance enforcement, status and shutdown RPCs.
void main() {
  late Directory tempDir;
  late int port;
  final spawnedPids = <int>[];

  String daemonPackageDir() {
    var dir = Directory.current;
    for (var depth = 0; depth < 6; depth++) {
      if (File(p.join(dir.path, 'bin', 'daemon.dart')).existsSync() &&
          File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
        return dir.path;
      }
      final nested = p.join(dir.path, 'packages', 'daemon');
      if (File(p.join(nested, 'bin', 'daemon.dart')).existsSync()) {
        return nested;
      }
      dir = dir.parent;
    }
    throw StateError('could not locate packages/daemon from ${Directory.current}');
  }

  Future<Process> spawnDaemon() async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        p.join('bin', 'daemon.dart'),
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--data-dir',
        tempDir.path,
      ],
      workingDirectory: daemonPackageDir(),
    );
    spawnedPids.add(process.pid);
    // Drain stdio so the child never blocks on full pipes.
    process.stdout.transform(utf8.decoder).listen((data) => print('[daemon stdout] $data'));
    process.stderr.transform(utf8.decoder).listen((data) => print('[daemon stderr] $data'));
    return process;
  }

  // probeDaemon's cleanup awaits closing a channel that never connected and
  // can hang when nothing is listening yet, so wait for the TCP port to
  // accept connections first and bound every probe with an outer timeout.
  Future<ServerHello> waitForHello(
      {Duration timeout = const Duration(seconds: 120)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(seconds: 2));
        socket.destroy();
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      final hello = await probeDaemon('127.0.0.1', port)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (hello != null) return hello;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    fail('daemon did not answer hello on port $port within $timeout');
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('daemon_lock_test_');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
  });

  tearDown(() async {
    for (final pid in spawnedPids) {
      try {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
        } else {
          await killTree(pid);
        }
      } catch (_) {}
    }
    spawnedPids.clear();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('lock file, probe, single instance, status and shutdown', () async {
    final daemon = await spawnDaemon();
    final hello = await waitForHello();

    // Hello exposes pid and desktopManaged=false (spawned without env var).
    expect(hello.pid, isNotNull);
    expect(hello.desktopManaged, isFalse);
    expect(hello.daemonVersion, daemonVersion);

    // Lock file exists with correct pid/port/version.
    final paths = DaemonPaths(dataDir: tempDir.path);
    final lockData = await PidLock(paths.lockFile).read();
    expect(lockData, isNotNull, reason: 'daemon.pid should exist');
    expect(lockData!.pid, hello.pid);
    expect(lockData.port, port);
    expect(lockData.version, daemonVersion);
    expect(lockData.desktopManaged, isFalse);

    // A second daemon on the same data-dir + port exits with code 11.
    final second = await spawnDaemon();
    final secondExit =
        await second.exitCode.timeout(const Duration(seconds: 120));
    expect(secondExit, 11);

    // First daemon must still be reachable and holding its lock.
    expect(await probeDaemon('127.0.0.1', port), isNotNull);
    expect(File(paths.lockFile).existsSync(), isTrue);

    // daemon.status RPC returns the version.
    final status = await _rpc(port, MessageTypes.daemonStatusRequest);
    expect(status.isError, isFalse);
    expect(status.payload['version'], daemonVersion);
    expect((status.payload['pid'] as num?)?.toInt(), hello.pid);
    expect(status.payload['desktopManaged'], isFalse);
    expect(status.payload['uptimeMs'], isA<num>());

    // daemon.shutdown RPC from loopback: process exits, lock file disappears.
    final ok = await sendLifecycleRequest(
        '127.0.0.1', port, MessageTypes.daemonShutdownRequest);
    expect(ok, isTrue);
    final exitCode =
        await daemon.exitCode.timeout(const Duration(seconds: 60));
    expect(exitCode, 0);

    // The lock is released just before exit; allow a short grace period.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (File(paths.lockFile).existsSync() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(File(paths.lockFile).existsSync(), isFalse,
        reason: 'daemon.pid should be deleted on shutdown');
  });
}

/// Performs hello then a single [type] request; returns the response.
Future<RpcResponse> _rpc(int port, String type) async {
  final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
  await channel.ready.timeout(const Duration(seconds: 10));
  try {
    final frames = channel.stream
        .where((f) => f is String)
        .map((f) =>
            RpcFrame.fromJson(jsonDecode(f as String) as Map<String, Object?>))
        .asBroadcastStream();

    channel.sink.add(jsonEncode(RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'hello',
      payload: const ClientHello(clientName: 'test', clientVersion: '0')
          .toJson(),
    ).toJson()));
    await frames
        .firstWhere((f) => f is RpcResponse && f.requestId == 'hello')
        .timeout(const Duration(seconds: 10));

    channel.sink
        .add(jsonEncode(RpcRequest(type: type, requestId: 'req').toJson()));
    return await frames
        .firstWhere((f) => f is RpcResponse && f.requestId == 'req')
        .timeout(const Duration(seconds: 10)) as RpcResponse;
  } finally {
    try {
      await channel.sink.close(1000);
    } catch (_) {}
  }
}
