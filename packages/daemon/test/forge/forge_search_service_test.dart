import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/forge_search_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory repo;

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('forge-search-service-');
    await _git(repo.path, ['init', '-b', 'main']);
  });

  tearDown(() {
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  test(
    'resolves cwd remote and emits the exact forge search response',
    () async {
      await _git(repo.path, [
        'remote',
        'add',
        'origin',
        'https://github.com/acme/repo.git',
      ]);
      final service = ForgeSearchService(
        resolver: ForgeResolver(
          transport: _FakeTransport((_, args) {
            if (args.first == 'issue') return _json([]);
            return _json([
              {
                'number': 8,
                'title': 'Ship',
                'url': 'https://github.com/acme/repo/pull/8',
                'state': 'OPEN',
                'body': null,
                'labels': const [],
                'baseRefName': 'main',
                'headRefName': 'feature',
                'updatedAt': '2026-07-27T00:00:00Z',
              },
            ]);
          }),
        ),
      );
      final response = ForgeSearchResponse.fromJson(
        (await service.handle({
          'type': 'forge.search.request',
          'cwd': repo.path,
          'query': 'ship',
          'requestId': 'r1',
        }))!,
      );
      expect(response.authState, 'authenticated');
      expect(response.error, isNull);
      expect(response.items.single.forge, 'github');
      expect(response.items.single.number, 8);
    },
  );

  test('returns no_remote without invoking a forge CLI', () async {
    final transport = _FakeTransport((_, _) => throw StateError('unused'));
    final service = ForgeSearchService(
      resolver: ForgeResolver(transport: transport),
    );
    final response = ForgeSearchResponse.fromJson(
      (await service.handle({
        'type': 'forge.search.request',
        'cwd': repo.path,
        'query': '',
        'requestId': 'r2',
      }))!,
    );
    expect(response.authState, 'no_remote');
    expect(response.items, isEmpty);
    expect(transport.calls, 0);
    expect(await service.handle({'type': 'other'}), isNull);
  });

  test('preserves unavailable and command-error auth states', () async {
    await _git(repo.path, [
      'remote',
      'add',
      'origin',
      'https://gitlab.com/acme/repo.git',
    ]);
    Future<ForgeSearchResponse> search(_Handler handler) async {
      final service = ForgeSearchService(
        resolver: ForgeResolver(transport: _FakeTransport(handler)),
      );
      return ForgeSearchResponse.fromJson(
        (await service.handle({
          'type': 'forge.search.request',
          'cwd': repo.path,
          'query': 'x',
          'requestId': 'r3',
        }))!,
      );
    }

    final missing = await search(
      (_, _) => throw const ForgeCliMissingException('glab'),
    );
    expect(missing.authState, 'cli_missing');
    expect(missing.error, isNull);

    final failed = await search((_, _) => _fail('network exploded'));
    expect(failed.authState, 'error');
    expect(failed.error, contains('glab CLI command failed'));
  });
}

Future<void> _git(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
}

ForgeCommandResult _json(Object? value) =>
    ForgeCommandResult(exitCode: 0, stdout: jsonEncode(value), stderr: '');

ForgeCommandResult _fail(String value) =>
    ForgeCommandResult(exitCode: 1, stdout: '', stderr: value);

typedef _Handler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _FakeTransport implements ForgeCommandTransport {
  _FakeTransport(this.handler);

  final _Handler handler;
  int calls = 0;

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls += 1;
    return handler(executable, args);
  }
}
