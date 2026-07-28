import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/file_transfer_service.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tinyrack-transfer-');
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('download tokens are single-use, expiring capabilities', () {
    var now = DateTime.utc(2026);
    final store = DownloadTokenStore(
      ttl: const Duration(milliseconds: 100),
      clock: () => now,
    );
    DownloadTokenEntry issue() => store.issueToken(
      path: 'file.txt',
      absolutePath: p.join(home.path, 'file.txt'),
      fileName: 'file.txt',
      mimeType: 'text/plain',
      size: 4,
    );

    final first = issue();
    expect(store.consumeToken(first.token), same(first));
    expect(store.consumeToken(first.token), isNull);
    final expired = issue();
    now = now.add(const Duration(milliseconds: 100));
    expect(store.consumeToken(expired.token), isNull);
  });

  test('download HTTP route validates and consumes its own token', () async {
    final file = File(p.join(home.path, 'report.txt'))
      ..writeAsStringSync('hello');
    final tokens = DownloadTokenStore();
    final handler = FileDownloadHandler(tokens);
    expect(
      (await handler(_request('/api/files/download')))!.statusCode,
      HttpStatus.badRequest,
    );
    expect(
      (await handler(
        _request('/api/files/download?token=invalid'),
      ))!.statusCode,
      HttpStatus.forbidden,
    );

    final entry = tokens.issueToken(
      path: 'report.txt',
      absolutePath: file.path,
      fileName: 'bad"\r\nname.txt',
      mimeType: 'text/plain',
      size: 5,
    );
    final response = await handler(
      _request('/api/files/download?token=${entry.token}'),
    );
    expect(response!.statusCode, 200);
    expect(response.headers['content-disposition'], contains('bad___name.txt'));
    expect(response.headers['content-length'], '5');
    expect(await response.readAsString(), 'hello');
    expect(
      (await handler(
        _request('/api/files/download?token=${entry.token}'),
      ))!.statusCode,
      HttpStatus.forbidden,
    );

    final missing = tokens.issueToken(
      path: 'gone',
      absolutePath: p.join(home.path, 'gone'),
      fileName: 'gone',
      mimeType: 'application/octet-stream',
      size: 1,
    );
    expect(
      (await handler(
        _request('/api/files/download?token=${missing.token}'),
      ))!.statusCode,
      HttpStatus.notFound,
    );
  });

  test(
    'workspace request issues a scoped token and rejects traversal',
    () async {
      File(p.join(home.path, 'report.txt')).writeAsStringSync('hello world');
      final tokens = DownloadTokenStore();
      final service = WorkspaceFileTransferService(
        home: home.path,
        downloadTokens: tokens,
      );
      final connection = _connection();
      final response =
          await service.handle(connection, {
                'type': 'file_download_token_request',
                'cwd': home.path,
                'path': 'report.txt',
                'requestId': 'req-token',
              })
              as Map<String, Object?>;
      final payload = response['payload']! as Map<String, Object?>;
      expect(response['type'], 'file_download_token_response');
      expect(payload['fileName'], 'report.txt');
      expect(payload['mimeType'], 'text/plain');
      expect(payload['size'], 11);
      expect(tokens.consumeToken(payload['token']! as String), isNotNull);

      final outside =
          await service.handle(connection, {
                'type': 'file_download_token_request',
                'cwd': home.path,
                'path': '../outside.txt',
                'requestId': 'req-outside',
              })
              as Map<String, Object?>;
      expect(
        (outside['payload']! as Map<String, Object?>)['error'],
        contains('Access outside workspace'),
      );
      final empty =
          await service.handle(connection, {
                'type': 'file_download_token_request',
                'cwd': ' ',
                'path': 'x',
                'requestId': 'req-empty',
              })
              as Map<String, Object?>;
      expect(
        (empty['payload']! as Map<String, Object?>)['error'],
        'cwd is required',
      );

      Directory(p.join(home.path, 'folder')).createSync();
      final directory =
          await service.handle(connection, {
                'type': 'file_download_token_request',
                'cwd': home.path,
                'path': 'folder',
                'requestId': 'req-directory',
              })
              as Map<String, Object?>;
      expect(
        (directory['payload']! as Map<String, Object?>)['error'],
        contains('not a file'),
      );

      const mimeCases = <String, String>{
        'code.dart': 'text/plain',
        'code.ts': 'text/plain',
        'view.tsx': 'text/plain',
        'view.jsx': 'text/plain',
        'data.json': 'application/json',
        'page.html': 'text/html',
        'style.css': 'text/css',
        'app.js': 'application/javascript',
        'image.png': 'image/png',
      };
      for (final entry in mimeCases.entries) {
        File(p.join(home.path, entry.key)).writeAsBytesSync(
          entry.key == 'image.png' ? [0] : utf8.encode('text'),
        );
        final result =
            await service.handle(connection, {
                  'type': 'file_download_token_request',
                  'cwd': home.path,
                  'path': entry.key,
                  'requestId': 'req-${entry.key}',
                })
                as Map<String, Object?>;
        expect(
          (result['payload']! as Map<String, Object?>)['mimeType'],
          entry.value,
        );
      }
      File(p.join(home.path, 'binary.bin')).writeAsBytesSync([1, 0, 2]);
      final binary =
          await service.handle(connection, {
                'type': 'file_download_token_request',
                'cwd': home.path,
                'path': 'binary.bin',
                'requestId': 'req-binary',
              })
              as Map<String, Object?>;
      expect(
        (binary['payload']! as Map<String, Object?>)['mimeType'],
        'application/octet-stream',
      );
    },
  );

  test(
    'upload request and binary frames produce an uploaded attachment',
    () async {
      final sent = <Map<String, Object?>>[];
      final connection = _connection(sent);
      final service = WorkspaceFileTransferService(
        home: home.path,
        downloadTokens: DownloadTokenStore(),
      );
      expect(
        await service.handle(connection, {
          'type': 'file.upload.request',
          'fileName': '../notes?.txt',
          'mimeType': 'text/plain',
          'size': 11,
          'modifiedAt': '2026-05-02T00:00:00.000Z',
          'requestId': 'req-upload',
        }),
        isA<V2HandledNoResponse>(),
      );
      await service.handleFrame(
        connection,
        _frame(FileTransferOpcode.fileBegin, 'req-upload'),
      );
      await service.handleFrame(
        connection,
        _frame(
          FileTransferOpcode.fileChunk,
          'req-upload',
          utf8.encode('hello world'),
        ),
      );
      await service.handleFrame(
        connection,
        _frame(FileTransferOpcode.fileEnd, 'req-upload'),
      );
      expect(sent, hasLength(1));
      final message = sent.single['message']! as Map<String, Object?>;
      final payload = message['payload']! as Map<String, Object?>;
      final attachment = payload['file']! as Map<String, Object?>;
      expect(message['type'], 'file.upload.response');
      expect(attachment['fileName'], 'notes_.txt');
      expect(
        File(attachment['path']! as String).readAsStringSync(),
        'hello world',
      );
    },
  );

  test('replays an early binary begin after upload registration', () async {
    final sent = <Map<String, Object?>>[];
    final connection = _connection(sent);
    final service = WorkspaceFileTransferService(
      home: home.path,
      downloadTokens: DownloadTokenStore(),
    );

    await service.handleFrame(
      connection,
      _frame(FileTransferOpcode.fileBegin, 'early-upload'),
    );
    expect(sent, isEmpty);
    expect(
      await service.handle(connection, {
        'type': 'file.upload.request',
        'fileName': 'early.txt',
        'mimeType': 'text/plain',
        'size': 5,
        'modifiedAt': '2026-07-27T00:00:00.000Z',
        'requestId': 'early-upload',
      }),
      isA<V2HandledNoResponse>(),
    );
    await service.handleFrame(
      connection,
      _frame(
        FileTransferOpcode.fileChunk,
        'early-upload',
        utf8.encode('early'),
      ),
    );
    await service.handleFrame(
      connection,
      _frame(FileTransferOpcode.fileEnd, 'early-upload'),
    );

    final message = sent.single['message']! as Map<String, Object?>;
    final payload = message['payload']! as Map<String, Object?>;
    expect(payload['error'], isNull);
    expect(
      File(
        (payload['file']! as Map<String, Object?>)['path']! as String,
      ).readAsStringSync(),
      'early',
    );
  });

  test('upload errors clean partial data and stale uploads expire', () async {
    final store = FileUploadStore(
      home: home.path,
      staleUploadTimeout: const Duration(milliseconds: 20),
    );
    const request = FileUploadRequest(
      fileName: 'bad.txt',
      mimeType: 'text/plain',
      size: 2,
      modifiedAt: 'now',
      requestId: 'bad',
    );
    store.beginUpload(request);
    final beforeBegin = await store.receiveFrame(
      _frame(FileTransferOpcode.fileChunk, 'bad', [1]),
    );
    expect(
      (beforeBegin!['payload']! as Map<String, Object?>)['error'],
      contains('before file begin'),
    );

    store.beginUpload(request);
    await store.receiveFrame(_frame(FileTransferOpcode.fileBegin, 'bad'));
    final overflow = await store.receiveFrame(
      _frame(FileTransferOpcode.fileChunk, 'bad', [1, 2, 3]),
    );
    expect(
      (overflow!['payload']! as Map<String, Object?>)['error'],
      contains('exceeded declared size'),
    );

    store.beginUpload(request);
    await store.receiveFrame(_frame(FileTransferOpcode.fileBegin, 'bad'));
    await store.receiveFrame(_frame(FileTransferOpcode.fileChunk, 'bad', [1]));
    final mismatch = await store.receiveFrame(
      _frame(FileTransferOpcode.fileEnd, 'bad'),
    );
    expect(
      (mismatch!['payload']! as Map<String, Object?>)['error'],
      contains('size mismatch'),
    );

    store.beginUpload(request);
    await store.receiveFrame(_frame(FileTransferOpcode.fileBegin, 'bad'));
    store.beginUpload(request);
    await store.receiveFrame(_frame(FileTransferOpcode.fileBegin, 'bad'));
    store.close();
    await Future<void>.delayed(Duration.zero);

    store.beginUpload(request);
    await store.receiveFrame(_frame(FileTransferOpcode.fileBegin, 'bad'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      await store.receiveFrame(_frame(FileTransferOpcode.fileEnd, 'bad')),
      isNull,
    );
    store.close();
  });
}

Connection _connection([List<Map<String, Object?>>? sent]) =>
    Connection.external(
      frames: const Stream.empty(),
      send: (value) {
        if (value is String) {
          sent?.add((jsonDecode(value) as Map).cast<String, Object?>());
        }
      },
      close: (_, __) {},
      id: 'connection-1',
      transport: 'direct',
      externalSessionKey: null,
      relayConnectionId: null,
    );

FileTransferFrame _frame(
  FileTransferOpcode opcode,
  String requestId, [
  List<int> payload = const [],
]) => FileTransferFrame(
  opcode: opcode,
  requestId: requestId,
  metadata: opcode == FileTransferOpcode.fileBegin
      ? const FileBeginMetadata(
          mime: 'text/plain',
          size: 0,
          encoding: 'binary',
          modifiedAt: 'now',
        )
      : null,
  payload: payload,
);

Request _request(String path) =>
    Request('GET', Uri.parse('http://localhost$path'));
