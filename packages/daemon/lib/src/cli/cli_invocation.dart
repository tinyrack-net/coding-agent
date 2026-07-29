import 'dart:io';

import 'package:path/path.dart' as p;

sealed class CliInvocation {
  const CliInvocation();
}

List<String> defaultEmptyCliArguments(List<String> arguments) =>
    arguments.isEmpty ? const ['onboard'] : arguments;

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
