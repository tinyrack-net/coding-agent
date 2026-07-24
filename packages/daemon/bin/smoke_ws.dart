/// Manual end-to-end smoke over the real WebSocket API + real claude CLI.
///
/// Starts the daemon on an ephemeral port, connects like the app would,
/// creates a fullAccess agent in a temp dir, prompts it, and prints the
/// timeline events as they stream. Exits 0 when the turn completes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  final tempDir = Directory.systemTemp.createTempSync('smoke-ws-');
  final dataDir = Directory.systemTemp.createTempSync('smoke-data-');
  const port = 6899;

  final daemon = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'agent_daemon:daemon', '--port', '$port', '--data-dir', dataDir.path],
    workingDirectory: Directory.current.path,
  );
  daemon.stdout.transform(utf8.decoder).listen((l) => stdout.write('[daemon] $l'));
  daemon.stderr.transform(utf8.decoder).listen((l) => stderr.write('[daemon:err] $l'));
  await Future<void>.delayed(const Duration(seconds: 4));

  final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
  await channel.ready;
  final frames = channel.stream
      .map((f) => jsonDecode(f as String) as Map<String, Object?>)
      .asBroadcastStream();

  var nextId = 0;
  Future<Map<String, Object?>> request(
      String type, Map<String, Object?> payload) async {
    final id = 'r${nextId++}';
    channel.sink.add(jsonEncode(
        RpcRequest(type: type, requestId: id, payload: payload).toJson()));
    final response =
        await frames.firstWhere((f) => f['requestId'] == id);
    if (response['error'] != null) {
      throw StateError('rpc error: ${response['error']}');
    }
    return (response['payload'] as Map<String, Object?>?) ?? const {};
  }

  final done = Completer<void>();
  frames.listen((f) {
    if (f['type'] == MessageTypes.permissionRequestedEvent) {
      final payload = f['payload'] as Map<String, Object?>;
      stdout.writeln('[smoke] permission requested for ${payload['toolName']} '
          '-> responding allow');
      unawaited(request(MessageTypes.permissionRespondRequest, {
        'permissionId': payload['permissionId'],
        'decision': 'allow',
      }));
    }
    if (f['type'] == MessageTypes.agentStreamEvent) {
      final payload =
          AgentStreamPayload.fromJson(f['payload'] as Map<String, Object?>);
      final item = payload.item;
      final summary = switch (item) {
        AssistantMessageItem(:final text, :final complete) =>
          'assistant(complete=$complete): ${text.length > 60 ? text.substring(0, 60) : text}',
        UserMessageItem(:final text) => 'user: $text',
        ToolCallItem(:final toolName, :final status) =>
          'tool $toolName [${status.name}]',
        TurnItem(:final phase) => 'turn ${phase.name}',
        _ => item.kind,
      };
      stdout.writeln('[stream] seq=${payload.seq} $summary');
      if (item is TurnItem &&
          (item.phase == TurnPhase.completed || item.phase == TurnPhase.failed)) {
        if (!done.isCompleted) done.complete();
      }
    }
  });

  await request(MessageTypes.clientHelloRequest,
      const ClientHello(clientName: 'smoke', clientVersion: '0').toJson());
  stdout.writeln('[smoke] hello ok');

  final created = await request(MessageTypes.agentCreateRequest, {
    'cwd': tempDir.path,
    'provider': 'claude',
    'model': '',
    'mode': 'normal',
    'title': 'ws-smoke',
  });
  final agent =
      AgentSummary.fromJson(created['agent'] as Map<String, Object?>);
  stdout.writeln('[smoke] created agent ${agent.agentId}');

  await request(MessageTypes.agentPromptRequest, {
    'agentId': agent.agentId,
    'text': 'Create a file named pong.txt containing exactly "pong". '
        'Then reply with one short sentence.',
  });

  await done.future.timeout(const Duration(minutes: 3));

  final fetch = await request(MessageTypes.agentTimelineFetchRequest,
      {'agentId': agent.agentId});
  final timeline = TimelineFetchResponse.fromJson(fetch);
  stdout.writeln('[smoke] fetch: epoch=${timeline.epoch} '
      'lastSeq=${timeline.lastSeq} items=${timeline.items.length}');

  final pong = File('${tempDir.path}${Platform.pathSeparator}pong.txt');
  stdout.writeln('[smoke] pong.txt exists=${pong.existsSync()} '
      'content=${pong.existsSync() ? pong.readAsStringSync().trim() : '-'}');

  await channel.sink.close(1000);
  daemon.kill();
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '${daemon.pid}']);
  }
  exit(pong.existsSync() ? 0 : 1);
}
