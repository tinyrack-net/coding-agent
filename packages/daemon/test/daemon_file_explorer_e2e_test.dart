import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('v2 explorer list, read, write, watch, and binary frames', () async {
    final home = Directory.systemTemp.createTempSync('daemon-explorer-e2e-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    final file = File(p.join(home.path, 'note.txt'))..writeAsStringSync('one');
    final public = Directory(p.join(home.path, 'public'))..createSync();
    File(p.join(public.path, 'favicon.svg')).writeAsStringSync('<svg/>');
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: p.join(home.path, '.tinyrack')),
      host: '127.0.0.1',
      port: 0,
      dataDir: p.join(home.path, '.data'),
      log: (_) {},
    );
    addTearDown(handle.stop);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final allFrames = channel.stream.asBroadcastStream();
    final jsonFrames = allFrames
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>);
    final binaryFrames = allFrames
        .where((frame) => frame is List<int>)
        .map((frame) => Uint8List.fromList((frame as List).cast<int>()));
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'file-explorer-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await jsonFrames.firstWhere((frame) => frame['status'] == 'server_info');

    void send(Map<String, Object?> message) =>
        channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
    Future<Map<String, Object?>> response(String type) async {
      final frame = await jsonFrames.firstWhere(
        (value) =>
            value['type'] == 'session' &&
            (value['message'] as Map?)?['type'] == type,
      );
      return (frame['message'] as Map).cast<String, Object?>();
    }

    final updateFuture = response('fs.file.update');
    send({
      'type': 'file_explorer_request',
      'cwd': home.path,
      'mode': 'list',
      'requestId': 'list-1',
    });
    final list = await response('file_explorer_response');
    final directory = ((list['payload'] as Map)['directory'] as Map);
    expect(
      (directory['entries'] as List).map((entry) => (entry as Map)['name']),
      contains('note.txt'),
    );

    send({
      'type': 'project_icon_request',
      'cwd': home.path,
      'requestId': 'icon-1',
    });
    final icon = await response('project_icon_response');
    final iconPayload = (icon['payload'] as Map);
    expect((iconPayload['icon'] as Map)['mimeType'], 'image/svg+xml');
    expect(
      utf8.decode(base64Decode((iconPayload['icon'] as Map)['data'] as String)),
      '<svg/>',
    );

    send({
      'type': 'file_explorer_request',
      'cwd': home.path,
      'path': 'note.txt',
      'mode': 'file',
      'requestId': 'read-1',
    });
    final read = await response('file_explorer_response');
    final inline = ((read['payload'] as Map)['file'] as Map);
    expect(inline['content'], 'one');

    send({
      'type': 'fs.file.subscribe.request',
      'cwd': home.path,
      'path': 'note.txt',
      'subscriptionId': 'sub-1',
      'requestId': 'subscribe-1',
    });
    final subscription = await response('fs.file.subscribe.response');
    final initial = ((subscription['payload'] as Map)['initial'] as Map);

    send({
      'type': 'fs.file.write.request',
      'cwd': home.path,
      'path': 'note.txt',
      'content': 'two',
      'expectedModifiedAt': initial['modifiedAt'],
      'expectedRevision': initial['revision'],
      'requestId': 'write-1',
    });
    final write = await response('fs.file.write.response');
    expect(((write['payload'] as Map)['result'] as Map)['status'], 'written');
    expect(file.readAsStringSync(), 'two');
    final update = await updateFuture;
    expect(((update['payload'] as Map)['version'] as Map)['status'], 'ready');

    final binaryFuture = binaryFrames.take(3).toList();
    send({
      'type': 'file_explorer_request',
      'cwd': home.path,
      'path': 'note.txt',
      'mode': 'file',
      'requestId': 'binary-1',
      'acceptBinary': true,
    });
    final binary = await binaryFuture;
    final begin = FileTransferFrame.decode(binary[0])!;
    final chunk = FileTransferFrame.decode(binary[1])!;
    final end = FileTransferFrame.decode(binary[2])!;
    expect(begin.opcode, FileTransferOpcode.fileBegin);
    expect(begin.metadata!.encoding, 'utf-8');
    expect(utf8.decode(chunk.payload), 'two');
    expect(end.opcode, FileTransferOpcode.fileEnd);

    send({
      'type': 'fs.file.unsubscribe.request',
      'subscriptionId': 'sub-1',
      'requestId': 'unsubscribe-1',
    });
    expect(
      (await response('fs.file.unsubscribe.response'))['type'],
      'fs.file.unsubscribe.response',
    );
  });
}
