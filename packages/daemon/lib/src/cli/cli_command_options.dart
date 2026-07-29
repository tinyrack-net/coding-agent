const String cliJsonOptionDescription = 'Output in JSON format';
const String cliDaemonHostOptionDescription =
    'Daemon host target: host:port or '
    'tcp://host:port?ssl=true&password=secret '
    '(default: local socket/pipe, then localhost:6767)';

final class CliCommandOptionSpec {
  const CliCommandOptionSpec({required this.flags, required this.description});

  final String flags;
  final String description;
}

const cliJsonOption = CliCommandOptionSpec(
  flags: '--json',
  description: cliJsonOptionDescription,
);

const cliDaemonHostOption = CliCommandOptionSpec(
  flags: '--host <host>',
  description: cliDaemonHostOptionDescription,
);

List<String> collectMultiple(String value, List<String> previous) => [
  ...previous,
  value,
];

List<CliCommandOptionSpec> addJsonOption(
  List<CliCommandOptionSpec> commandOptions,
) {
  commandOptions.add(cliJsonOption);
  return commandOptions;
}

List<CliCommandOptionSpec> addDaemonHostOption(
  List<CliCommandOptionSpec> commandOptions,
) {
  commandOptions.add(cliDaemonHostOption);
  return commandOptions;
}

List<CliCommandOptionSpec> addJsonAndDaemonHostOptions(
  List<CliCommandOptionSpec> commandOptions,
) => addDaemonHostOption(addJsonOption(commandOptions));
