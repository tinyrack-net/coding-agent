/// Manual end-to-end smoke for M5 terminals over the real WebSocket API.
///
/// Starts the daemon on an ephemeral port, opens a ConPTY terminal in a temp
/// dir, subscribes, types `echo conpty-ok`, asserts the echoed output arrives
/// as binary frames, resizes, kills the terminal, and expects the
/// `terminal.exited` broadcast. Exits 0 on success.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  final tempDir = Directory.systemTemp.createTempSync('smoke-term-');
  final dataDir = Directory.systemTemp.createTempSync('smoke-term-data-');
  const port = 6897;

  var ok = false;
  Process? daemon;
  try {
    daemon = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        'agent_daemon:daemon',
        '--port',
        '$port',
        '--data-dir',
        dataDir.path,
      ],
      workingDirectory: Directory.current.path,
    );
    daemon.stdout
        .transform(utf8.decoder)
        .listen((l) => stdout.write('[daemon] $l'));
    daemon.stderr
        .transform(utf8.decoder)
        .listen((l) => stderr.write('[daemon:err] $l'));
    await Future<void>.delayed(const Duration(seconds: 4));

    final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
    await channel.ready;

    final textFrames = StreamController<Map<String, Object?>>.broadcast();
    final output = BytesBuilder();
    var outputFrames = 0;
    var snapshotSeen = false;
    final exited = Completer<Map<String, Object?>>();

    channel.stream.listen((frame) {
      if (frame is String) {
        final decoded = jsonDecode(frame) as Map<String, Object?>;
        if (decoded['type'] == MessageTypes.terminalExitedEvent &&
            !exited.isCompleted) {
          exited.complete(decoded['payload'] as Map<String, Object?>);
        }
        textFrames.add(decoded);
        return;
      }
      final bytes = frame is Uint8List
          ? frame
          : Uint8List.fromList(frame as List<int>);
      final binary = TerminalFrame.decode(bytes);
      if (binary == null) {
        stderr.writeln('[smoke] undecodable binary frame (${bytes.length}B)');
        return;
      }
      switch (binary.opcode) {
        case TerminalOpcode.snapshot:
          snapshotSeen = true;
          output.add(binary.payload);
        case TerminalOpcode.output:
          outputFrames++;
          output.add(binary.payload);
        default:
          stderr.writeln('[smoke] unexpected opcode ${binary.opcode}');
      }
    });

    var nextId = 0;
    Future<Map<String, Object?>> request(
        String type, Map<String, Object?> payload) async {
      final id = 'r${nextId++}';
      channel.sink.add(jsonEncode(
          RpcRequest(type: type, requestId: id, payload: payload).toJson()));
      final response = await textFrames.stream
          .firstWhere((f) => f['requestId'] == id)
          .timeout(const Duration(seconds: 10));
      if (response['error'] != null) {
        throw StateError('rpc error for $type: ${response['error']}');
      }
      return (response['payload'] as Map<String, Object?>?) ?? const {};
    }

    await request(MessageTypes.clientHelloRequest,
        const ClientHello(clientName: 'smoke-terminal', clientVersion: '0').toJson());
    stdout.writeln('[smoke] hello ok');

    final created = await request(
        MessageTypes.terminalCreateRequest, {'cwd': tempDir.path});
    final terminal = created['terminal'] as Map<String, Object?>;
    final terminalId = terminal['terminalId'] as String;
    stdout.writeln('[smoke] created terminal $terminalId '
        'shell=${terminal['shell']} cwd=${terminal['cwd']}');

    final listed = await request(MessageTypes.terminalListRequest, {});
    stdout.writeln(
        '[smoke] list has ${(listed['terminals'] as List).length} terminal(s)');

    final subscribed = await request(
        MessageTypes.terminalSubscribeRequest, {'terminalId': terminalId});
    final slotId = (subscribed['slotId'] as num).toInt();
    stdout.writeln('[smoke] subscribed slotId=$slotId');

    // Give the shell a moment to paint its prompt, then type the command.
    await Future<void>.delayed(const Duration(seconds: 3));
    channel.sink.add(TerminalFrame(
      opcode: TerminalOpcode.input,
      slotId: slotId,
      payload: utf8.encode('echo conpty-ok\r'),
    ).encode());

    // Collect output for a few seconds.
    await Future<void>.delayed(const Duration(seconds: 5));
    final combined = utf8.decode(output.toBytes(), allowMalformed: true);
    stdout.writeln('[smoke] snapshotSeen=$snapshotSeen '
        'outputFrames=$outputFrames bytes=${output.length}');
    if (!snapshotSeen) {
      throw StateError('no snapshot frame received after subscribe');
    }
    if (!combined.contains('conpty-ok')) {
      stderr.writeln('[smoke] combined output:\n$combined');
      throw StateError('output does not contain "conpty-ok"');
    }
    stdout.writeln('[smoke] found "conpty-ok" in terminal output');

    channel.sink.add(TerminalFrame.resize(slotId, cols: 100, rows: 30).encode());
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('[smoke] resize frame sent');

    await request(MessageTypes.terminalKillRequest, {'terminalId': terminalId});
    final exitPayload =
        await exited.future.timeout(const Duration(seconds: 10));
    if (exitPayload['terminalId'] != terminalId) {
      throw StateError('terminal.exited for wrong terminal: $exitPayload');
    }
    stdout.writeln(
        '[smoke] terminal.exited exitCode=${exitPayload['exitCode']}');

    await channel.sink.close(1000);
    ok = true;
  } catch (e, st) {
    stderr.writeln('[smoke] error: $e\n$st');
  } finally {
    // Never leave a stale daemon (or its ConPTY shells) behind.
    if (daemon != null) {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/T', '/F', '/PID', '${daemon.pid}']);
      } else {
        daemon.kill(ProcessSignal.sigkill);
      }
    }
    try {
      tempDir.deleteSync(recursive: true);
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  }
  stdout.writeln(ok ? '[smoke] PASS' : '[smoke] FAIL');
  exit(ok ? 0 : 1);
}
