import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('credential_store_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('get returns null when nothing is stored', () async {
    final store = CredentialStore(dataDir: tempDir.path);
    expect(await store.get('openai'), isNull);
  });

  test('set then get round-trips the plaintext key', () async {
    final store = CredentialStore(dataDir: tempDir.path);
    await store.set('openai', 'sk-abc-123');
    expect(await store.get('openai'), 'sk-abc-123');
  });

  test('clear removes a stored key', () async {
    final store = CredentialStore(dataDir: tempDir.path);
    await store.set('deepseek', 'ds-key');
    await store.clear('deepseek');
    expect(await store.get('deepseek'), isNull);
  });

  test('persists across instances (simulating a daemon restart)', () async {
    final first = CredentialStore(dataDir: tempDir.path);
    await first.set('openrouter', 'or-key-xyz');

    final second = CredentialStore(dataDir: tempDir.path);
    expect(await second.get('openrouter'), 'or-key-xyz');
  });

  test('credentials.json on disk never contains the plaintext key', () async {
    final store = CredentialStore(dataDir: tempDir.path);
    const secret = 'sk-super-secret-value';
    await store.set('openai', secret);

    final raw = await File('${tempDir.path}/credentials.json').readAsString();
    expect(raw.contains(secret), isFalse);

    final decoded = jsonDecode(raw) as Map<String, Object?>;
    expect(decoded['openai'], isA<String>());
    expect((decoded['openai'] as String).contains(secret), isFalse);
  });

  test('multiple providers coexist independently', () async {
    final store = CredentialStore(dataDir: tempDir.path);
    await store.set('openai', 'key-openai');
    await store.set('deepseek', 'key-deepseek');
    await store.set('openrouter', 'key-openrouter');

    expect(await store.get('openai'), 'key-openai');
    expect(await store.get('deepseek'), 'key-deepseek');
    expect(await store.get('openrouter'), 'key-openrouter');
  });
}
