import 'dart:io';

import 'package:agent_daemon/src/providers/exe_resolver.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Resolver whose answers are fully controlled by the test.
class FakeExeResolver implements ExeResolver {
  FakeExeResolver(this.paths);

  final Map<String, String?> paths;
  final List<String> resolved = [];

  @override
  Future<String?> resolve(String command) async {
    resolved.add(command);
    return paths[command];
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_registry_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeScript(String name, {required int exitCode, String? stdout}) {
    final path = p.join(tempDir.path, '$name.bat');
    File(path).writeAsStringSync(
      '@echo off\r\n'
      '${stdout == null ? '' : 'echo $stdout\r\n'}'
      'exit /b $exitCode\r\n',
    );
    return path;
  }

  test('both providers unavailable when neither CLI is found', () async {
    final resolver = FakeExeResolver({'claude': null, 'codex': null});
    final registry = ProviderRegistry(resolver);
    final list = await registry.list();

    expect(list, hasLength(2));
    final claude = list.firstWhere((p) => p.id == ProviderId.claude);
    expect(claude.available, isFalse);
    expect(claude.unavailableReason, 'claude not found on PATH');
    expect(claude.executablePath, isNull);
    expect(claude.version, isNull);

    final codex = list.firstWhere((p) => p.id == ProviderId.codex);
    expect(codex.available, isFalse);
    expect(codex.unavailableReason, 'codex not found on PATH');
  });

  test('available provider reports version and static model catalog',
      () async {
    final claudePath = writeScript('fake_claude', exitCode: 0, stdout: '1.2.3 (claude)');
    final codexPath = writeScript('fake_codex', exitCode: 0, stdout: '9.9.9');
    final resolver = FakeExeResolver({'claude': claudePath, 'codex': codexPath});
    final registry = ProviderRegistry(resolver);

    final list = await registry.list();
    final claude = list.firstWhere((p) => p.id == ProviderId.claude);
    expect(claude.available, isTrue);
    expect(claude.executablePath, claudePath);
    expect(claude.version, '1.2.3 (claude)');
    expect(claude.models, isNotEmpty);
    expect(claude.models.map((m) => m.id), contains('claude-sonnet-5'));

    final codex = list.firstWhere((p) => p.id == ProviderId.codex);
    expect(codex.available, isTrue);
    expect(codex.models.map((m) => m.id), contains('gpt-5.4-codex'));
  });

  test('resolved path exists but --version exits nonzero: reported as '
      'unavailable with executablePath still set', () async {
    final claudePath = writeScript('failing_claude', exitCode: 1);
    final resolver = FakeExeResolver({'claude': claudePath, 'codex': null});
    final registry = ProviderRegistry(resolver);

    final list = await registry.list();
    final claude = list.firstWhere((p) => p.id == ProviderId.claude);
    expect(claude.available, isFalse);
    expect(claude.executablePath, claudePath);
    expect(claude.unavailableReason, 'claude --version failed');
  });

  test('list() caches results; refresh:true re-probes', () async {
    final resolver = FakeExeResolver({'claude': null, 'codex': null});
    final registry = ProviderRegistry(resolver);

    await registry.list();
    final callsAfterFirst = resolver.resolved.length;
    await registry.list();
    expect(resolver.resolved.length, callsAfterFirst); // cached, no new calls

    await registry.list(refresh: true);
    expect(resolver.resolved.length, greaterThan(callsAfterFirst));
  });

  test('a resolved path that cannot be executed (e.g. a directory) is '
      'reported as unavailable via the ProcessException fallback', () async {
    // Executing a directory always fails to launch a process (on every OS),
    // which exercises the `on ProcessException` catch clause distinctly
    // from a non-zero --version exit.
    final resolver = FakeExeResolver({'claude': tempDir.path, 'codex': null});
    final registry = ProviderRegistry(resolver);

    final list = await registry.list();
    final claude = list.firstWhere((p) => p.id == ProviderId.claude);
    expect(claude.available, isFalse);
    expect(claude.executablePath, tempDir.path);
    expect(claude.unavailableReason, 'claude --version failed');
  });

  test('takes only the first line of multi-line --version output', () async {
    final path = p.join(tempDir.path, 'multiline.bat');
    File(path).writeAsStringSync(
      '@echo off\r\necho 2.0.0\r\necho extra line\r\nexit /b 0\r\n',
    );
    final resolver = FakeExeResolver({'claude': path, 'codex': null});
    final registry = ProviderRegistry(resolver);

    final list = await registry.list();
    final claude = list.firstWhere((p) => p.id == ProviderId.claude);
    expect(claude.version, '2.0.0');
  });
}
