import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/provider_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('help exposes both provider subcommands', () async {
    for (final arguments in const [
      ['--help'],
      ['ls', '--help'],
      ['models', '--help'],
    ]) {
      final output = StringBuffer();
      expect(
        await runProviderCommand(
          arguments: arguments,
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), contains('Usage: coding-agent provider'));
    }
  });

  test('coding-agent binary dispatches the provider command', () async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    final result = await Process.run(Platform.resolvedExecutable, const [
      'run',
      'agent_daemon:coding_agent',
      'provider',
      '--help',
    ], workingDirectory: packageRoot);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Manage agent providers'));
    expect(result.stdout, contains('models <provider>'));
    expect(result.stderr, isEmpty);
  });

  test('ls renders the live provider snapshot with frozen columns', () async {
    final output = StringBuffer();
    Map<String, Object?>? sent;
    final exitCode = await runProviderCommand(
      arguments: const ['ls'],
      request: (request) async {
        sent = request;
        return {
          'entries': [
            const ProviderSnapshotEntry(
              provider: 'codex',
              status: ProviderCatalogStatus.ready,
              label: 'Codex',
              defaultModeId: 'auto-review',
              modes: [
                ProviderMode(id: 'ask', label: 'Always ask'),
                ProviderMode(id: 'full', label: 'Full access'),
              ],
            ).toJson(),
            const ProviderSnapshotEntry(
              provider: 'omp',
              status: ProviderCatalogStatus.unavailable,
              enabled: false,
            ).toJson(),
          ],
          'generatedAt': '2026-07-28T00:00:00.000Z',
          'requestId': request['requestId'],
        };
      },
      writeOutput: output.write,
    );

    expect(exitCode, 0);
    expect(sent?['type'], 'get_providers_snapshot_request');
    expect(
      output.toString(),
      contains(
        'PROVIDER      LABEL             STATUS        ENABLED     '
        'DEFAULT MODE    MODES',
      ),
    );
    expect(output.toString(), contains('codex'));
    expect(output.toString(), contains('available'));
    expect(output.toString(), contains('Always ask, Full access'));
    expect(output.toString(), contains('unavailable'));
    expect(output.toString(), contains('Disabled'));
  });

  test('ls falls back to the static manifest and supports json', () async {
    final output = StringBuffer();
    final exitCode = await runProviderCommand(
      arguments: const ['ls', '--json'],
      request: (_) => throw StateError('old daemon'),
      writeOutput: output.write,
    );

    expect(exitCode, 0);
    final rows = jsonDecode(output.toString()) as List<dynamic>;
    expect(
      rows.map((row) => (row as Map<String, dynamic>)['provider']),
      containsAll(['claude', 'codex', 'copilot', 'opencode', 'pi', 'omp']),
    );
    final omp = rows.cast<Map<String, dynamic>>().singleWhere(
      (row) => row['provider'] == 'omp',
    );
    expect(omp['enabled'], 'Disabled');
    expect(omp['defaultMode'], 'full');
  });

  test('models normalizes provider and renders thinking columns', () async {
    final output = StringBuffer();
    Map<String, Object?>? sent;
    final exitCode = await runProviderCommand(
      arguments: const ['models', ' CoDeX ', '--thinking', '--no-headers'],
      request: (request) async {
        sent = request;
        return {
          'provider': 'codex',
          'models': [
            const ProviderModelDefinition(
              provider: 'codex',
              id: 'gpt-5.2-codex',
              label: 'GPT-5.2 Codex',
              description: 'Coding model',
              thinkingOptions: [
                ProviderSelectOption(id: 'low', label: 'Low'),
                ProviderSelectOption(id: 'high', label: 'High'),
              ],
              defaultThinkingOptionId: 'high',
            ).toJson(),
            const ProviderModelDefinition(
              provider: 'codex',
              id: 'auto',
              label: 'Automatic',
            ).toJson(),
          ],
          'error': null,
          'fetchedAt': '2026-07-28T00:00:00.000Z',
          'requestId': request['requestId'],
        };
      },
      writeOutput: output.write,
    );

    expect(exitCode, 0);
    expect(sent?['type'], 'list_provider_models_request');
    expect(sent?['provider'], 'codex');
    expect(output.toString(), isNot(contains('THINKING IDS')));
    expect(output.toString(), contains('low, high'));
    expect(output.toString(), contains('high'));
    expect(output.toString(), contains('auto'));
  });

  test('models supports json yaml quiet and empty results', () async {
    Future<Map<String, Object?>> request(Map<String, Object?> message) async =>
        {
          'provider': message['provider'],
          'models': [
            const ProviderModelDefinition(
              provider: 'claude',
              id: 'sonnet',
              label: 'Claude Sonnet',
              description: 'Fast: capable',
              thinkingOptions: [ProviderSelectOption(id: 'on', label: 'On')],
            ).toJson(),
          ],
          'error': null,
          'fetchedAt': 'now',
          'requestId': message['requestId'],
        };

    final tableOutput = StringBuffer();
    await runProviderCommand(
      arguments: const ['models', 'claude'],
      request: request,
      writeOutput: tableOutput.write,
    );
    expect(tableOutput.toString(), contains('ID'));
    expect(tableOutput.toString(), contains('MODEL'));
    expect(tableOutput.toString(), contains('DESCRIPTION'));
    expect(tableOutput.toString(), contains('Fast: capable'));

    final jsonOutput = StringBuffer();
    expect(
      await runProviderCommand(
        arguments: const ['models', 'claude', '--json'],
        request: request,
        writeOutput: jsonOutput.write,
      ),
      0,
    );
    final row =
        (jsonDecode(jsonOutput.toString()) as List<dynamic>).single
            as Map<String, dynamic>;
    expect(row['thinkingOptionIds'], ['on']);
    expect(row['defaultThinkingOptionId'], isNull);

    final yamlOutput = StringBuffer();
    await runProviderCommand(
      arguments: const ['models', 'claude', '--format', 'yaml'],
      request: request,
      writeOutput: yamlOutput.write,
    );
    expect(yamlOutput.toString(), contains('- id: sonnet'));
    expect(yamlOutput.toString(), contains('description: "Fast: capable"'));

    final quietOutput = StringBuffer();
    await runProviderCommand(
      arguments: const ['models', 'claude', '--quiet'],
      request: request,
      writeOutput: quietOutput.write,
    );
    expect(quietOutput.toString(), 'sonnet\n');

    final emptyOutput = StringBuffer();
    await runProviderCommand(
      arguments: const ['models', 'claude', '--no-headers'],
      request: (request) async => {
        'provider': 'claude',
        'models': <Object?>[],
        'error': null,
        'fetchedAt': 'now',
        'requestId': request['requestId'],
      },
      writeOutput: emptyOutput.write,
    );
    expect(emptyOutput.toString(), isEmpty);
  });

  test('models returns structured provider errors', () async {
    final error = StringBuffer();
    final exitCode = await runProviderCommand(
      arguments: const ['models', 'missing', '--json'],
      request: (request) async => {
        'provider': 'missing',
        'models': null,
        'error': 'Unknown provider: missing',
        'fetchedAt': 'now',
        'requestId': request['requestId'],
      },
      writeError: error.write,
    );

    expect(exitCode, 1);
    final payload = jsonDecode(error.toString()) as Map<String, dynamic>;
    expect(payload['error']['code'], 'PROVIDER_ERROR');
    expect(
      payload['error']['message'],
      'Failed to fetch models for missing: Unknown provider: missing',
    );
  });

  test(
    'parser failures use usage exit code and malformed rows are errors',
    () async {
      for (final arguments in const [
        <String>[],
        ['wat'],
        ['ls', 'codex'],
        ['models'],
        ['models', 'codex', 'extra'],
        ['models', 'codex', '--wat'],
        ['ls', '--format', 'xml'],
        ['ls', '--host'],
      ]) {
        final error = StringBuffer();
        expect(
          await runProviderCommand(
            arguments: arguments,
            request: (_) async => const {},
            writeError: error.write,
          ),
          64,
        );
        expect(error.toString(), contains('Usage: coding-agent provider ls'));
      }

      final error = StringBuffer();
      expect(
        await runProviderCommand(
          arguments: const ['models', 'codex'],
          request: (_) async => {'models': 'bad'},
          writeError: error.write,
        ),
        1,
      );
      expect(error.toString(), contains('models must be a list'));
    },
  );

  test('connection failure falls back for ls but fails models', () async {
    final home = Directory.systemTemp.createTempSync('provider-cli-');
    addTearDown(() => home.deleteSync(recursive: true));
    final environment = {
      'TINYRACK_HOME': home.path,
      'TINYRACK_LISTEN': '127.0.0.1:1',
    };

    final listOutput = StringBuffer();
    expect(
      await runProviderCommand(
        arguments: const ['ls', '--quiet'],
        environment: environment,
        writeOutput: listOutput.write,
      ),
      0,
    );
    expect(listOutput.toString(), contains('claude\n'));

    final modelError = StringBuffer();
    expect(
      await runProviderCommand(
        arguments: const ['models', 'codex'],
        environment: environment,
        writeOutput: (_) {},
        writeError: modelError.write,
      ),
      1,
    );
    expect(modelError.toString(), contains('Cannot connect to daemon'));
    expect(modelError.toString(), contains('coding-agent daemon start'));
  });
}
