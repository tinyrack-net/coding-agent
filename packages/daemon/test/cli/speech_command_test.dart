import 'package:agent_daemon/src/cli/speech_command.dart';
import 'package:test/test.dart';

void main() {
  test('frozen speech namespace is intentionally inert', () async {
    final output = StringBuffer();

    expect(
      await runSpeechCommand(arguments: const [], writeOutput: output.write),
      0,
    );
    expect(
      await runSpeechCommand(
        arguments: const ['future-subcommand', '--json', '--no-color'],
        writeOutput: output.write,
      ),
      0,
    );
    expect(output, isEmpty);
  });

  test('speech help preserves the frozen namespace description', () async {
    for (final flag in const ['--help', '-h']) {
      final output = StringBuffer();
      expect(
        await runSpeechCommand(arguments: [flag], writeOutput: output.write),
        0,
      );
      expect(output.toString(), speechHelp);
      expect(output.toString(), contains('Speech commands'));
      expect(output.toString(), contains('coding-agent speech [options]'));
    }
  });

  test('speech inherits the root version option', () async {
    for (final flag in const ['--version', '-v']) {
      final output = StringBuffer();
      expect(
        await runSpeechCommand(arguments: [flag], writeOutput: output.write),
        0,
      );
      expect(output.toString(), '0.2.0\n');
    }
  });
}
