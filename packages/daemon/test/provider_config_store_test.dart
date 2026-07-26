import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/native/provider_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ProviderConfig _config({
  String id = '',
  String displayName = 'Claude',
  ProviderKind kind = ProviderKind.anthropic,
  String baseUrl = 'https://api.anthropic.com/v1',
}) =>
    ProviderConfig(
      id: id,
      displayName: displayName,
      kind: kind,
      baseUrl: baseUrl,
    );

void main() {
  late Directory tempDir;
  late ProviderConfigStore store;

  String filePath() => p.join(tempDir.path, 'providers.json');

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_config_store_');
    store = ProviderConfigStore(dataDir: tempDir.path);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('starts empty — presets are added by the user, not seeded', () async {
    expect(await store.list(), isEmpty);
  });

  test('upsert assigns an id on create and returns the stored config', () async {
    final stored = await store.upsert(_config());
    expect(stored.id, isNotEmpty);
    expect(stored.displayName, 'Claude');
    expect(stored.kind, ProviderKind.anthropic);

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.id, stored.id);
  });

  test('ids are unique across creates, including same display name', () async {
    final a = await store.upsert(_config(displayName: 'Claude'));
    final b = await store.upsert(_config(displayName: 'Claude'));
    expect(a.id, isNot(b.id));
    expect(await store.list(), hasLength(2));
  });

  test('upsert with an existing id updates in place', () async {
    final created = await store.upsert(_config(displayName: 'Old'));
    final updated = await store.upsert(
      created.copyWith(displayName: 'New', baseUrl: 'https://x.example/v1'),
    );

    expect(updated.id, created.id);
    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.displayName, 'New');
    expect(list.single.baseUrl, 'https://x.example/v1');
  });

  test('upsert with an unknown non-empty id creates a fresh entry', () async {
    // Guards against a stale client id silently vanishing into a no-op.
    final stored = await store.upsert(_config(id: 'does-not-exist'));
    expect(stored.id, isNot('does-not-exist'));
    expect(await store.list(), hasLength(1));
  });

  test('get returns the config by id, or null', () async {
    final created = await store.upsert(_config());
    expect((await store.get(created.id))?.displayName, 'Claude');
    expect(await store.get('nope'), isNull);
  });

  test('delete removes and reports whether anything was removed', () async {
    final created = await store.upsert(_config());
    expect(await store.delete(created.id), isTrue);
    expect(await store.list(), isEmpty);
    expect(await store.delete(created.id), isFalse);
  });

  test('persists across store instances', () async {
    final created = await store.upsert(_config(displayName: 'Persisted'));

    final reopened = ProviderConfigStore(dataDir: tempDir.path);
    final list = await reopened.list();
    expect(list, hasLength(1));
    expect(list.single.id, created.id);
    expect(list.single.displayName, 'Persisted');
    expect(list.single.kind, ProviderKind.anthropic);
  });

  test('corrupt JSON starts fresh rather than failing every request', () async {
    File(filePath()).writeAsStringSync('{not valid json');
    expect(await store.list(), isEmpty);
  });

  test('entries without an id are dropped on load', () async {
    // An id-less entry could never be resolved to a backend or credential.
    File(filePath()).writeAsStringSync(jsonEncode({
      'providers': [
        {'id': '', 'displayName': 'Broken', 'baseUrl': 'https://x/v1'},
        {'id': 'ok', 'displayName': 'Fine', 'baseUrl': 'https://y/v1'},
      ],
    }));
    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.id, 'ok');
  });

  test('writes atomically, leaving no .tmp behind', () async {
    await store.upsert(_config());
    expect(File(filePath()).existsSync(), isTrue);
    expect(File('${filePath()}.tmp').existsSync(), isFalse);
  });

  test('list is unmodifiable', () async {
    await store.upsert(_config());
    final list = await store.list();
    expect(() => list.add(_config()), throwsUnsupportedError);
  });

  test('defaults dataDir under the user profile', () {
    // Matches the other stores' convention; not exercised elsewhere because
    // tests always inject a temp dir.
    expect(
      ProviderConfigStore().dataDir,
      endsWith('.tinyrack-agent'),
    );
    expect(ProviderConfigStore.defaultDataDir(), endsWith('.tinyrack-agent'));
  });
}
