/// Throwaway probe: talks to the real `codex app-server` over stdio JSON-RPC
/// and dumps every line so we can verify the protocol empirically.
///
/// Usage: dart run spikes/codex_app_server/probe.dart [--approve|--deny]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final deny = args.contains('--deny');
  final tempDir = Directory.systemTemp.createTempSync('codex-probe-');
  stdout.writeln('cwd: ${tempDir.path}');

  final process = await Process.start(
    r'C:\Users\winetree94\AppData\Local\Microsoft\WinGet\Links\codex.exe',
    ['app-server'],
    workingDirectory: tempDir.path,
  );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) => stdout.writeln('[stderr] $l'));

  var nextId = 1;
  final pending = <int, Completer<Object?>>{};

  void send(Map<String, Object?> obj) {
    final line = jsonEncode(obj);
    stdout.writeln('>> $line');
    process.stdin.add(utf8.encode('$line\n'));
  }

  Future<Object?> request(String method, [Object? params]) {
    final id = nextId++;
    final completer = Completer<Object?>();
    pending[id] = completer;
    send({'id': id, 'method': method, if (params != null) 'params': params});
    return completer.future;
  }

  String? threadId;
  String? turnId;
  final done = Completer<void>();

  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    stdout.writeln('<< $line');
    Map<String, Object?> msg;
    try {
      msg = jsonDecode(line) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final id = msg['id'];
    final method = msg['method'];
    if (id is int && method == null) {
      // response
      pending.remove(id)?.complete(msg['result'] ?? msg['error']);
      return;
    }
    if (id != null && method is String) {
      // server -> client request (approval etc.)
      if (method.endsWith('requestApproval')) {
        send({
          'id': id,
          'result': {'decision': deny ? 'decline' : 'accept'},
        });
      } else {
        send({'id': id, 'result': <String, Object?>{}});
      }
      return;
    }
    if (method == 'thread/started') {
      final params = msg['params'] as Map<String, Object?>?;
      threadId = ((params?['thread'] as Map?)?['id']) as String?;
    }
    if (method == 'turn/started') {
      final params = msg['params'] as Map<String, Object?>?;
      turnId = ((params?['turn'] as Map?)?['id']) as String?;
      stdout.writeln('** turnId=$turnId');
    }
    if (method == 'turn/completed' || method == 'turn/failed') {
      if (!done.isCompleted) done.complete();
    }
  });

  final initResult = await request('initialize', {
    'clientInfo': {'name': 'probe', 'title': 'Probe', 'version': '0.0.0'},
  });
  stdout.writeln('** initialize result: ${jsonEncode(initResult)}');
  send({'method': 'initialized', 'params': <String, Object?>{}});

  final startResult = await request('thread/start', {
    'cwd': tempDir.path,
    'approvalPolicy': 'on-request',
    'sandbox': 'workspace-write',
  });
  stdout.writeln('** thread/start result: ${jsonEncode(startResult)}');
  threadId ??= (((startResult as Map?)?['thread'] as Map?)?['id']) as String?;
  stdout.writeln('** threadId=$threadId');

  final turnResult = await request('turn/start', {
    'threadId': threadId,
    'input': [
      {
        'type': 'text',
        'text': 'Run the shell command `git --version` and then create a file '
            'named probe.txt containing exactly "probe-ok". Reply briefly.',
      },
    ],
    'approvalPolicy': 'on-request',
    'sandboxPolicy': {'type': 'workspaceWrite', 'networkAccess': false},
    'cwd': tempDir.path,
  });
  stdout.writeln('** turn/start result: ${jsonEncode(turnResult)}');

  await done.future.timeout(const Duration(minutes: 4), onTimeout: () {});
  final probeFile = File('${tempDir.path}\\probe.txt');
  stdout.writeln('** probe.txt exists=${probeFile.existsSync()} '
      'content=${probeFile.existsSync() ? probeFile.readAsStringSync() : '-'}');
  await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
  exit(0);
}
