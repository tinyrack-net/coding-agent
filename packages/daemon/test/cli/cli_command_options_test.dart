import 'package:agent_daemon/src/cli/cli_command_options.dart';
import 'package:test/test.dart';

void main() {
  test('collectMultiple appends without mutating the previous values', () {
    final previous = <String>['first'];
    final result = collectMultiple('second', previous);

    expect(result, ['first', 'second']);
    expect(previous, ['first']);
    expect(result, isNot(same(previous)));
  });

  test('registers the frozen JSON and daemon host option metadata', () {
    final options = <CliCommandOptionSpec>[];
    expect(addJsonAndDaemonHostOptions(options), same(options));
    expect(options, [same(cliJsonOption), same(cliDaemonHostOption)]);
    expect(cliJsonOption.flags, '--json');
    expect(cliJsonOption.description, 'Output in JSON format');
    expect(cliDaemonHostOption.flags, '--host <host>');
    expect(
      cliDaemonHostOption.description,
      'Daemon host target: host:port or '
      'tcp://host:port?ssl=true&password=secret '
      '(default: local socket/pipe, then localhost:6767)',
    );
  });

  test(
    'individual registration helpers mutate and return the same registry',
    () {
      final jsonOptions = <CliCommandOptionSpec>[];
      expect(addJsonOption(jsonOptions), same(jsonOptions));
      expect(jsonOptions, [same(cliJsonOption)]);

      final hostOptions = <CliCommandOptionSpec>[];
      expect(addDaemonHostOption(hostOptions), same(hostOptions));
      expect(hostOptions, [same(cliDaemonHostOption)]);
    },
  );
}
