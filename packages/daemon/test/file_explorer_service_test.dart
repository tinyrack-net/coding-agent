import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/file_explorer_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-explorer-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('lists newest-first and reads text, image, and binary files', () async {
    final older = File(p.join(root.path, 'older.txt'))
      ..writeAsStringSync('hello');
    older.setLastModifiedSync(DateTime.utc(2025));
    Directory(p.join(root.path, 'src')).createSync();
    File(p.join(root.path, 'new.json')).writeAsStringSync('{"ok":true}');
    File(p.join(root.path, 'pixel.png')).writeAsBytesSync([0, 1, 2]);
    File(p.join(root.path, 'raw.bin')).writeAsBytesSync([0, 255]);

    final directory = await listDirectoryEntries(root.path, '.');
    final entries = directory['entries']! as List;
    expect(directory['path'], '.');
    expect(
      entries.map((entry) => entry['name']),
      containsAll(['older.txt', 'src']),
    );
    expect(entries.first['name'], isNot('older.txt'));

    final text = await readExplorerFileBytes(root.path, 'new.json');
    expect(text.kind, 'text');
    expect(text.mimeType, 'application/json');
    expect(text.toInlineJson()['content'], '{"ok":true}');
    final image = await readExplorerFileBytes(root.path, 'pixel.png');
    expect(image.kind, 'image');
    expect(image.toInlineJson()['encoding'], 'base64');
    final binary = await readExplorerFileBytes(root.path, 'raw.bin');
    expect(binary.kind, 'binary');
    expect(binary.toInlineJson(), isNot(contains('content')));
  });

  test('serves frozen directory suggestions with legacy directories', () async {
    Directory(p.join(root.path, 'src')).createSync();
    File(p.join(root.path, 'src', 'message.dart')).writeAsStringSync('');
    final service = WorkspaceFileExplorerService();
    addTearDown(service.close);
    final response = await service.handle(
      Connection.external(
        frames: const Stream<Object>.empty(),
        send: (_) {},
        close: (_, _) {},
        id: 'directory-search',
        transport: 'test',
        externalSessionKey: null,
        relayConnectionId: null,
      ),
      DirectorySuggestionsRequest(
        query: 'mess',
        cwd: root.path,
        includeFiles: true,
        includeDirectories: true,
        limit: 50,
        requestId: 'suggest-1',
      ).toJson(),
    );

    final parsed = DirectorySuggestionsResponse.fromJson(
      Map<String, Object?>.from(response! as Map),
    );
    expect(parsed.error, isNull);
    expect(parsed.requestId, 'suggest-1');
    expect(parsed.directories, isEmpty);
    expect(parsed.entries.single.toJson(), {
      'path': 'src/message.dart',
      'kind': 'file',
    });
  });

  test('rejects traversal and wrong entity kinds', () async {
    final outside = File(p.join(root.parent.path, 'outside.txt'))
      ..writeAsStringSync('outside');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });
    expect(
      () => readExplorerFileBytes(root.path, '../outside.txt'),
      throwsStateError,
    );
    expect(() => listDirectoryEntries(root.path, 'missing'), throwsStateError);
    File(p.join(root.path, 'file')).writeAsStringSync('x');
    expect(() => listDirectoryEntries(root.path, 'file'), throwsStateError);
    expect(() => readExplorerFileBytes(root.path, '.'), throwsStateError);
  });

  test('optimistic writes succeed and report conflicts and guards', () async {
    final file = File(p.join(root.path, 'note.txt'))..writeAsStringSync('old');
    final version = await getExplorerFileVersion(root.path, 'note.txt');
    final written = await writeExplorerFile(
      FileWriteRequest(
        cwd: root.path,
        path: 'note.txt',
        content: 'new',
        expectedModifiedAt: version['modifiedAt']! as String,
        expectedRevision: version['revision']! as String,
        requestId: 'w1',
      ),
    );
    expect(written['status'], 'written');
    expect(file.readAsStringSync(), 'new');

    final conflict = await writeExplorerFile(
      FileWriteRequest(
        cwd: root.path,
        path: 'note.txt',
        content: 'stale',
        expectedModifiedAt: 'old',
        expectedRevision: version['revision']! as String,
        requestId: 'w2',
      ),
    );
    expect(conflict['status'], 'conflict');

    File(p.join(root.path, 'binary')).writeAsBytesSync([0, 1]);
    final binaryVersion = await getExplorerFileVersion(root.path, 'binary');
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: 'binary',
          content: 'x',
          expectedModifiedAt: binaryVersion['modifiedAt']! as String,
          requestId: 'w3',
        ),
      ))['error'],
      'Binary files cannot be edited',
    );
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: 'note.txt',
          content: 'x' * (maxEditableFileBytes + 1),
          expectedModifiedAt: 'now',
          requestId: 'w4',
        ),
      ))['error'],
      'File is too large to edit',
    );
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: 'missing',
          content: 'x',
          expectedModifiedAt: 'now',
          requestId: 'w5',
        ),
      ))['version'],
      containsPair('status', 'missing'),
    );
  });

  test(
    'observer publishes changed and missing versions then cancels',
    () async {
      final file = File(p.join(root.path, 'watch.txt'))
        ..writeAsStringSync('one');
      final observer = FileObserver();
      final changes = StreamController<Map<String, Object?>>.broadcast();
      final observation = await observer.observe(
        cwd: root.path,
        path: 'watch.txt',
        onChange: changes.add,
      );
      expect(observation.initial['status'], 'ready');
      await Future<void>.delayed(const Duration(milliseconds: 75));
      file.writeAsStringSync('two-two');
      expect(
        (await changes.stream.first.timeout(
          const Duration(seconds: 3),
        ))['status'],
        'ready',
      );

      final missing = changes.stream.firstWhere(
        (value) => value['status'] == 'missing',
      );
      file.deleteSync();
      expect(
        (await missing.timeout(const Duration(seconds: 3)))['path'],
        'watch.txt',
      );
      observation.cancel();
      observer.close();
      await changes.close();
    },
  );

  test(
    'session service returns error envelopes and releases watches',
    () async {
      final file = File(p.join(root.path, 'watch.txt'))
        ..writeAsStringSync('one');
      final sent = <Map<String, Object?>>[];
      final connection = _connection(sent);
      final service = WorkspaceFileExplorerService();

      final empty =
          await service.handle(connection, {
                'type': 'file_explorer_request',
                'cwd': ' ',
                'mode': 'list',
                'requestId': 'empty',
              })
              as Map;
      expect((empty['payload'] as Map)['error'], 'cwd is required');
      final missing =
          await service.handle(connection, {
                'type': 'file_explorer_request',
                'cwd': root.path,
                'path': 'missing',
                'mode': 'file',
                'requestId': 'missing',
              })
              as Map;
      expect((missing['payload'] as Map)['error'], isNotNull);
      final failedSubscription =
          await service.handle(connection, {
                'type': 'fs.file.subscribe.request',
                'cwd': root.path,
                'path': '../outside',
                'subscriptionId': 'bad',
                'requestId': 'bad',
              })
              as Map;
      expect(
        ((failedSubscription['payload'] as Map)['initial'] as Map)['status'],
        'error',
      );
      final subscribed =
          await service.handle(connection, {
                'type': 'fs.file.subscribe.request',
                'cwd': root.path,
                'path': p.basename(file.path),
                'subscriptionId': 'live',
                'requestId': 'sub',
              })
              as Map;
      expect((subscribed['payload'] as Map)['subscriptionId'], 'live');
      service.onConnectionClosed(connection.id);

      final second = WorkspaceFileExplorerService();
      await second.handle(connection, {
        'type': 'fs.file.subscribe.request',
        'cwd': root.path,
        'path': p.basename(file.path),
        'subscriptionId': 'close',
        'requestId': 'sub2',
      });
      second.close();
      service.close();
      expect(await service.handle(connection, {'type': 'unknown'}), isNull);
    },
  );

  test('versions and writes cover legacy timestamps and guards', () async {
    final directoryVersion = await getExplorerFileVersion(root.path, '.');
    expect(directoryVersion['status'], 'error');
    final outsideVersion = await getExplorerFileVersion(root.path, '../x');
    expect(outsideVersion['status'], 'error');
    final missingRoot = await getExplorerFileVersion(
      p.join(root.path, 'missing-root'),
      'x',
    );
    expect(missingRoot['status'], 'missing');

    final legacy = File(p.join(root.path, 'legacy.txt'))
      ..writeAsStringSync('legacy');
    final legacyVersion = await getExplorerFileVersion(root.path, 'legacy.txt');
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: 'legacy.txt',
          content: 'updated',
          expectedModifiedAt: legacyVersion['modifiedAt']! as String,
          requestId: 'legacy',
        ),
      ))['status'],
      'written',
    );
    expect(legacy.readAsStringSync(), 'updated');

    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: '.',
          content: 'x',
          expectedModifiedAt: 'now',
          requestId: 'directory',
        ),
      ))['error'],
      'Requested path is not a file',
    );
    File(
      p.join(root.path, 'large.txt'),
    ).writeAsBytesSync(List.filled(maxEditableFileBytes + 1, 65));
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: 'large.txt',
          content: 'small',
          expectedModifiedAt: 'now',
          requestId: 'large',
        ),
      ))['error'],
      'File is too large to edit',
    );
    expect(
      (await writeExplorerFile(
        FileWriteRequest(
          cwd: root.path,
          path: '../outside',
          content: 'x',
          expectedModifiedAt: 'now',
          requestId: 'outside',
        ),
      ))['error'],
      contains('outside'),
    );

    File(p.join(root.path, 'controls.bin')).writeAsBytesSync([1, 2, 3, 65]);
    expect(
      (await readExplorerFileBytes(root.path, 'controls.bin')).kind,
      'binary',
    );
    File(p.join(root.path, 'invalid.bin')).writeAsBytesSync([0xc3, 0x28]);
    expect(
      (await readExplorerFileBytes(root.path, 'invalid.bin')).kind,
      'binary',
    );
  });
}

Connection _connection(List<Map<String, Object?>> sent) => Connection.external(
  frames: const Stream.empty(),
  send: (value) {
    if (value is String) {
      sent.add((jsonDecode(value) as Map).cast<String, Object?>());
    }
  },
  close: (_, __) {},
  id: 'explorer-test',
  transport: 'direct',
  externalSessionKey: null,
  relayConnectionId: null,
);
