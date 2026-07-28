import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('v2 token download and binary upload cross daemon assembly', () async {
    final home = Directory.systemTemp.createTempSync('daemon-transfer-e2e-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    File(
      '${home.path}${Platform.pathSeparator}download.txt',
    ).writeAsStringSync('download body');
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      host: '127.0.0.1',
      port: 0,
      dataDir: home.path,
      log: (_) {},
    );
    addTearDown(handle.stop);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'file-transfer-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'file_download_token_request',
          'cwd': home.path,
          'path': 'download.txt',
          'requestId': 'download-1',
        },
      }),
    );
    final tokenFrame = await frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] == 'file_download_token_response',
    );
    final tokenPayload = ((tokenFrame['message'] as Map)['payload'] as Map)
        .cast<String, Object?>();
    expect(tokenPayload['error'], isNull);
    expect(tokenPayload['fileName'], 'download.txt');

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${handle.server.port}/api/files/download'
        '?token=${tokenPayload['token']}',
      ),
    );
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType!.mimeType, 'text/plain');
    expect(await utf8.decodeStream(response), 'download body');

    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': {
          'type': 'file.upload.request',
          'fileName': 'upload.txt',
          'mimeType': 'text/plain',
          'size': 11,
          'modifiedAt': '2026-05-02T00:00:00.000Z',
          'requestId': 'upload-1',
        },
      }),
    );
    channel.sink.add(
      FileTransferFrame(
        opcode: FileTransferOpcode.fileBegin,
        requestId: 'upload-1',
        metadata: const FileBeginMetadata(
          mime: 'text/plain',
          size: 11,
          encoding: 'binary',
          modifiedAt: '2026-05-02T00:00:00.000Z',
          fileName: 'upload.txt',
        ),
      ).encode(),
    );
    channel.sink.add(
      FileTransferFrame(
        opcode: FileTransferOpcode.fileChunk,
        requestId: 'upload-1',
        payload: utf8.encode('hello world'),
      ).encode(),
    );
    channel.sink.add(
      FileTransferFrame(
        opcode: FileTransferOpcode.fileEnd,
        requestId: 'upload-1',
      ).encode(),
    );
    final uploadFrame = await frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] == 'file.upload.response',
    );
    final uploadPayload = ((uploadFrame['message'] as Map)['payload'] as Map)
        .cast<String, Object?>();
    expect(uploadPayload['error'], isNull);
    final attachment = (uploadPayload['file'] as Map).cast<String, Object?>();
    expect(attachment['type'], 'uploaded_file');
    expect(
      File(attachment['path']! as String).readAsStringSync(),
      'hello world',
    );
  });
}
