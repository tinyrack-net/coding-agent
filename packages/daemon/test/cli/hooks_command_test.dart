import 'package:agent_daemon/src/cli/hooks_command.dart';
import 'package:test/test.dart';

void main() {
  test('reports exactly one hook event with bounded input result', () async {
    Map<String, Object?>? captured;
    var reads = 0;
    final exitCode = await runHooksCommand(
      arguments: const ['claude', 'Notification'],
      environment: const {'TINYRACK_TERMINAL_ID': 'terminal'},
      inputIsTerminal: false,
      readInput: () async {
        reads++;
        return '{"reason":"idle_prompt"}';
      },
      report:
          ({
            required provider,
            required event,
            required environment,
            input,
            required inputIsTerminal,
          }) async {
            captured = {
              'provider': provider,
              'event': event,
              'environment': environment,
              'input': input,
              'inputIsTerminal': inputIsTerminal,
            };
          },
    );

    expect(exitCode, 0);
    expect(reads, 1);
    expect(captured, {
      'provider': 'claude',
      'event': 'Notification',
      'environment': {'TINYRACK_TERMINAL_ID': 'terminal'},
      'input': '{"reason":"idle_prompt"}',
      'inputIsTerminal': false,
    });
  });

  test('TTY hooks skip stdin and preserve agent/event text', () async {
    Map<String, Object?>? captured;
    expect(
      await runHooksCommand(
        arguments: const ['codex', 'Stop'],
        inputIsTerminal: true,
        readInput: () async => fail('TTY input must not be read'),
        report:
            ({
              required provider,
              required event,
              required environment,
              input,
              required inputIsTerminal,
            }) async {
              captured = {
                'provider': provider,
                'event': event,
                'input': input,
                'inputIsTerminal': inputIsTerminal,
              };
            },
      ),
      0,
    );
    expect(captured, {
      'provider': 'codex',
      'event': 'Stop',
      'input': null,
      'inputIsTerminal': true,
    });
  });

  test('help and malformed invocations never report', () async {
    Future<void> neverReport({
      required String provider,
      required String event,
      required Map<String, String> environment,
      String? input,
      required bool inputIsTerminal,
    }) async => fail('must not report');

    var output = '';
    expect(
      await runHooksCommand(
        arguments: const ['--help'],
        report: neverReport,
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, contains('Record agent hook activity'));

    for (final arguments in <List<String>>[
      [],
      ['codex'],
      ['codex', 'Stop', 'extra'],
      ['codex', '--bad'],
    ]) {
      var error = '';
      expect(
        await runHooksCommand(
          arguments: arguments,
          report: neverReport,
          writeError: (value) => error += value,
        ),
        64,
        reason: '$arguments',
      );
      expect(error, contains(hooksUsage));
    }
  });
}
