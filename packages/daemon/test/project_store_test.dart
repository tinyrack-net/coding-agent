import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/store/project_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('project_store_test_');
    dataDir = p.join(tempDir.path, 'data');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('list is empty when no store file exists yet', () async {
    final store = ProjectStore(dataDir: dataDir);
    expect(await store.list(), isEmpty);
    // Nothing written until add() is called.
    expect(File(p.join(dataDir, 'projects.json')).existsSync(), isFalse);
  });

  test('add persists a new project and returns it normalized', () async {
    final store = ProjectStore(dataDir: dataDir);
    final added = await store.add(
      ProjectInfo(path: '${tempDir.path}/./proj', name: 'proj', isGitRepo: true),
    );
    expect(p.equals(added.path, p.join(tempDir.path, 'proj')), isTrue);

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.name, 'proj');
    expect(list.single.isGitRepo, isTrue);
  });

  test('list() returns an unmodifiable list', () async {
    final store = ProjectStore(dataDir: dataDir);
    await store.add(ProjectInfo(path: tempDir.path, name: 'x', isGitRepo: false));
    final list = await store.list();
    expect(() => list.add(ProjectInfo(path: 'y', name: 'y', isGitRepo: false)),
        throwsUnsupportedError);
  });

  test('add with an existing normalized path updates in place (no duplicate)',
      () async {
    final store = ProjectStore(dataDir: dataDir);
    final path = p.join(tempDir.path, 'proj');
    await store.add(ProjectInfo(path: path, name: 'old-name', isGitRepo: false));
    await store.add(ProjectInfo(path: path, name: 'new-name', isGitRepo: true));

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.name, 'new-name');
    expect(list.single.isGitRepo, isTrue);
  });

  test('multiple distinct projects are all retained in insertion order',
      () async {
    final store = ProjectStore(dataDir: dataDir);
    await store.add(ProjectInfo(path: p.join(tempDir.path, 'a'), name: 'a', isGitRepo: false));
    await store.add(ProjectInfo(path: p.join(tempDir.path, 'b'), name: 'b', isGitRepo: false));
    await store.add(ProjectInfo(path: p.join(tempDir.path, 'c'), name: 'c', isGitRepo: false));

    final list = await store.list();
    expect(list.map((e) => e.name).toList(), ['a', 'b', 'c']);
  });

  test('data survives reload via a fresh ProjectStore instance', () async {
    final path = p.join(tempDir.path, 'proj');
    final store = ProjectStore(dataDir: dataDir);
    await store.add(ProjectInfo(path: path, name: 'proj', isGitRepo: true));

    final reloaded = ProjectStore(dataDir: dataDir);
    final list = await reloaded.list();
    expect(list, hasLength(1));
    expect(list.single.name, 'proj');
    expect(p.equals(list.single.path, path), isTrue);
  });

  test('corrupt store file is treated as empty rather than throwing',
      () async {
    Directory(dataDir).createSync(recursive: true);
    File(p.join(dataDir, 'projects.json')).writeAsStringSync('{ not json');

    final store = ProjectStore(dataDir: dataDir);
    expect(await store.list(), isEmpty);

    // Store still works normally after recovering from corruption.
    await store.add(ProjectInfo(path: tempDir.path, name: 'x', isGitRepo: false));
    expect(await store.list(), hasLength(1));
  });

  test('store file missing the "projects" key is treated as empty',
      () async {
    Directory(dataDir).createSync(recursive: true);
    File(p.join(dataDir, 'projects.json'))
        .writeAsStringSync(jsonEncode({'other': 'value'}));

    final store = ProjectStore(dataDir: dataDir);
    expect(await store.list(), isEmpty);
  });

  test('defaultDataDir resolves to a directory under the home dir', () {
    final dir = ProjectStore.defaultDataDir();
    expect(dir, contains('.tinyrack-agent'));
  });

  test('writes are atomic: projects.json exists and is valid JSON after add',
      () async {
    final store = ProjectStore(dataDir: dataDir);
    await store.add(ProjectInfo(path: tempDir.path, name: 'x', isGitRepo: false));

    final file = File(p.join(dataDir, 'projects.json'));
    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(decoded['projects'], isA<List>());
  });
}
