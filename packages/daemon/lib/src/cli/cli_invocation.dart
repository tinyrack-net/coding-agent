import 'dart:io';

import 'package:path/path.dart' as p;

sealed class CliInvocation {
  const CliInvocation();
}

List<String> defaultEmptyCliArguments(List<String> arguments) =>
    arguments.isEmpty ? const ['onboard'] : arguments;

enum RootOutputForwarding { full, jsonOnly, none }

final class RootCliOutputOptions {
  const RootCliOutputOptions({
    this.format,
    this.json = false,
    this.quiet = false,
    this.noHeaders = false,
    this.noColor = false,
  });

  final String? format;
  final bool json;
  final bool quiet;
  final bool noHeaders;
  final bool noColor;

  bool get isEmpty =>
      format == null && !json && !quiet && !noHeaders && !noColor;

  List<String> forwardedArguments(RootOutputForwarding forwarding) {
    if (forwarding == RootOutputForwarding.none) return const [];
    if (forwarding == RootOutputForwarding.jsonOnly) {
      return json || format?.toLowerCase() == 'json'
          ? const ['--json']
          : const [];
    }
    return [
      if (format != null) ...['--format', format!],
      if (json) '--json',
      if (quiet) '--quiet',
      if (noHeaders) '--no-headers',
      if (noColor) '--no-color',
    ];
  }
}

final class NormalizedRootCliArguments {
  const NormalizedRootCliArguments({
    required this.arguments,
    required this.output,
  });

  final List<String> arguments;
  final RootCliOutputOptions output;

  List<String> forward() => [
    ...arguments,
    ...output.forwardedArguments(rootOutputForwarding(arguments)),
  ];
}

/// Extracts Commander-style global output options which precede the command.
///
/// Options after the first command token remain untouched because they may be
/// command-local options with the same spelling (for example terminal capture
/// has its own `--json`). JSON-only and inert command actions intentionally
/// receive only the subset their frozen action observes.
NormalizedRootCliArguments normalizeRootCliArguments(List<String> arguments) {
  String? format;
  var json = false;
  var quiet = false;
  var noHeaders = false;
  var noColor = false;
  var index = 0;

  while (index < arguments.length) {
    final argument = arguments[index];
    if (argument == '--') break;
    switch (argument) {
      case '--json':
        json = true;
        index++;
      case '-q' || '--quiet':
        quiet = true;
        index++;
      case '--no-headers':
        noHeaders = true;
        index++;
      case '--no-color':
        noColor = true;
        index++;
      case '-o' || '--format':
        if (index + 1 >= arguments.length) {
          return NormalizedRootCliArguments(
            arguments: arguments.sublist(index),
            output: RootCliOutputOptions(
              format: format,
              json: json,
              quiet: quiet,
              noHeaders: noHeaders,
              noColor: noColor,
            ),
          );
        }
        format = arguments[index + 1];
        index += 2;
      default:
        if (argument.startsWith('--format=')) {
          format = argument.substring('--format='.length);
          index++;
          continue;
        }
        if (argument.startsWith('-o') && argument.length > 2) {
          format = argument.substring(2);
          index++;
          continue;
        }
        return NormalizedRootCliArguments(
          arguments: arguments.sublist(index),
          output: RootCliOutputOptions(
            format: format,
            json: json,
            quiet: quiet,
            noHeaders: noHeaders,
            noColor: noColor,
          ),
        );
    }
  }

  return NormalizedRootCliArguments(
    arguments: arguments.sublist(index),
    output: RootCliOutputOptions(
      format: format,
      json: json,
      quiet: quiet,
      noHeaders: noHeaders,
      noColor: noColor,
    ),
  );
}

RootOutputForwarding rootOutputForwarding(List<String> arguments) {
  if (arguments.isEmpty) return RootOutputForwarding.none;
  final first = arguments.first;
  if (const {
    'run',
    'import',
    'clone',
    'ls',
    'inspect',
    'stop',
    'send',
    'wait',
    'archive',
    'delete',
    'permit',
    'provider',
    'script',
    'chat',
    'heartbeat',
    'schedule',
    'workspace',
    'worktree',
  }.contains(first)) {
    return RootOutputForwarding.full;
  }
  if (first == 'agent') {
    final action = arguments.length > 1 ? arguments[1] : null;
    return action == 'attach' || action == 'logs'
        ? RootOutputForwarding.none
        : RootOutputForwarding.full;
  }
  if (const {'status', 'restart', 'daemon', 'hub', 'loop'}.contains(first)) {
    return RootOutputForwarding.jsonOnly;
  }
  if (first == 'terminal') {
    final action = arguments.length > 1 ? arguments[1] : null;
    return const {'ls', 'create', 'kill'}.contains(action)
        ? RootOutputForwarding.jsonOnly
        : RootOutputForwarding.none;
  }
  return RootOutputForwarding.none;
}

final class CommandCliInvocation extends CliInvocation {
  const CommandCliInvocation(this.arguments);

  final List<String> arguments;
}

final class OpenProjectCliInvocation extends CliInvocation {
  const OpenProjectCliInvocation(this.resolvedPath);

  final String resolvedPath;
}

bool isPathLikeArgument(String argument) =>
    argument == '.' ||
    argument == '..' ||
    argument.startsWith('./') ||
    argument.startsWith('../') ||
    argument.startsWith('/') ||
    argument == '~' ||
    argument.startsWith('~/') ||
    argument.startsWith(r'~\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(argument);

String expandUserPath(String path, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final home = Platform.isWindows
      ? env['USERPROFILE'] ?? env['HOME']
      : env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) return path;
  if (path == '~') return home;
  if (path.startsWith('~/') || path.startsWith(r'~\')) {
    return p.join(home, path.substring(2));
  }
  return path;
}

String resolveCliPath({
  required String pathArgument,
  required String currentDirectory,
  Map<String, String>? environment,
}) {
  final expanded = expandUserPath(pathArgument, environment: environment);
  return p.normalize(
    p.absolute(
      p.isAbsolute(expanded) ? expanded : p.join(currentDirectory, expanded),
    ),
  );
}

bool isExistingDirectory({
  required String pathArgument,
  required String currentDirectory,
  Map<String, String>? environment,
  bool Function(String path)? directoryExists,
}) {
  final resolved = resolveCliPath(
    pathArgument: pathArgument,
    currentDirectory: currentDirectory,
    environment: environment,
  );
  return (directoryExists ?? (path) => Directory(path).existsSync())(resolved);
}

CliInvocation classifyCliInvocation({
  required List<String> arguments,
  required Set<String> knownCommands,
  required String currentDirectory,
  Map<String, String>? environment,
  bool Function(String path)? directoryExists,
}) {
  if (arguments.isEmpty) return CommandCliInvocation(arguments);
  final first = arguments.first;
  if (first.startsWith('-') || knownCommands.contains(first)) {
    return CommandCliInvocation(arguments);
  }
  final resolved = resolveCliPath(
    pathArgument: first,
    currentDirectory: currentDirectory,
    environment: environment,
  );
  if ((directoryExists ?? (path) => Directory(path).existsSync())(resolved)) {
    return OpenProjectCliInvocation(resolved);
  }
  return CommandCliInvocation(arguments);
}
