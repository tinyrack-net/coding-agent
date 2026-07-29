import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_output.dart';
import 'terminal_command.dart';

const cloneCommandTimeout = Duration(minutes: 5, seconds: 15);

abstract interface class CloneDaemonClient {
  ServerInfoStatus get serverInfo;
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  });
  Future<void> close();
}

typedef CloneClientConnector =
    Future<CloneDaemonClient> Function({
      required String? host,
      required Map<String, String> environment,
    });

Future<int> runCloneCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  CloneClientConnector connect = connectCloneClient,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(cloneHelp);
    return 0;
  }

  CloneCliInvocation? invocation;
  try {
    invocation = CloneCliInvocation.parse(arguments);
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$cloneUsage\n');
    return 64;
  } on CloneCommandException catch (error) {
    _renderError(
      errorOutput,
      error,
      invocation?.output ?? _recoverCloneOutputOptions(arguments),
    );
    return 1;
  }

  CloneDaemonClient? client;
  final env = environment ?? Platform.environment;
  try {
    try {
      client = await connect(host: invocation.host, environment: env);
    } on Object catch (error) {
      final config = loadDaemonRuntimeConfig(environment: env);
      final host = invocation.host ?? '${config.host}:${config.port}';
      throw CloneCommandException(
        'DAEMON_NOT_RUNNING',
        'Cannot connect to daemon at $host: ${_errorText(error)}',
        details: 'Start the daemon with: coding-agent daemon start',
      );
    }
    if (client.serverInfo.features['projectGithubClone'] != true) {
      throw const CloneCommandException(
        'UNSUPPORTED_BY_HOST',
        'This daemon does not support cloning GitHub repos.',
        details: 'Update the host to a newer Tinyrack version.',
      );
    }

    final response = ProjectGithubCloneResponse.fromJson(
      await _requestClone(client, invocation),
    );
    if (response.error != null ||
        response.project == null ||
        response.checkoutPath == null) {
      throw CloneCommandException(
        'CLONE_FAILED',
        'Failed to clone GitHub repo: '
            '${response.error ?? 'no project returned'}',
      );
    }
    final row = <String, Object?>{
      'repo': response.repo,
      'checkoutPath': response.checkoutPath,
      'projectId': response.project!.projectId,
      'projectName': response.project!.projectDisplayName,
    };
    final rendered = renderCliOutput(
      CliOutputResult.single(row: row, schema: _cloneSchema),
      invocation.output,
    );
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on CloneCommandException catch (error) {
    _renderError(errorOutput, error, invocation.output);
    return 1;
  } on Object catch (error) {
    _renderError(
      errorOutput,
      CloneCommandException(
        'CLONE_FAILED',
        'Failed to clone GitHub repo: ${_errorText(error)}',
      ),
      invocation.output,
    );
    return 1;
  } finally {
    try {
      await client?.close();
    } on Object {
      // Paseo treats connection cleanup as best effort.
    }
  }
}

Future<Map<String, Object?>> _requestClone(
  CloneDaemonClient client,
  CloneCliInvocation invocation,
) async {
  final request = ProjectGithubCloneRequest(
    requestId: 'clone_${DateTime.now().microsecondsSinceEpoch}',
    repo: invocation.repo,
    cloneProtocol: isCompleteGitRemote(invocation.repo)
        ? null
        : invocation.protocol,
    targetDirectory: invocation.targetDirectory,
  );
  final payload = await client.request(
    request.toJson(),
    timeout: cloneCommandTimeout,
  );
  return {'type': ProjectGithubCloneResponse.type, 'payload': payload};
}

Future<CloneDaemonClient> connectCloneClient({
  required String? host,
  required Map<String, String> environment,
}) async {
  final client = await DaemonCliSocketClient.connect(
    loadDaemonRuntimeConfig(environment: environment),
    hostOverride: host,
    environment: environment,
  );
  return _SocketCloneClient(client);
}

final class _SocketCloneClient implements CloneDaemonClient {
  const _SocketCloneClient(this.client);

  final DaemonCliSocketClient client;

  @override
  ServerInfoStatus get serverInfo => client.serverInfo;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) => client.request(request, timeout: timeout);

  @override
  Future<void> close() => client.close();
}

final class CloneCliInvocation {
  const CloneCliInvocation({
    required this.repo,
    required this.targetDirectory,
    required this.protocol,
    required this.host,
    required this.output,
  });

  final String repo;
  final String targetDirectory;
  final ProjectGithubCloneProtocol? protocol;
  final String? host;
  final CliOutputOptions output;

  static CloneCliInvocation parse(List<String> arguments) {
    final positional = <String>[];
    String? targetDirectory;
    ProjectGithubCloneProtocol? protocol;
    String? host;
    var json = false;
    var format = 'table';
    var quiet = false;
    var headers = true;
    var color = true;
    var positionalOnly = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly) {
        final longOption = _splitLongOption(argument);
        if (longOption != null) {
          final (option, value) = longOption;
          switch (option) {
            case '--dir':
              targetDirectory = value;
              continue;
            case '--protocol':
              protocol = _parseCloneProtocol(value);
              continue;
            case '--host':
              host = value;
              continue;
            case '--format':
              format = normalizeCliOutputFormat(value);
              continue;
          }
        }
      }
      if (!positionalOnly && argument == '--') {
        positionalOnly = true;
        continue;
      }
      if (positionalOnly) {
        positional.add(argument);
        continue;
      }
      switch (argument) {
        case '--dir':
          targetDirectory = _requiredValue(arguments, ++index, argument);
        case '--protocol':
          protocol = _parseCloneProtocol(
            _requiredValue(arguments, ++index, argument),
          );
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
        case '-o' || '--format':
          format = normalizeCliOutputFormat(
            _requiredValue(arguments, ++index, argument),
          );
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          color = false;
        default:
          if (argument.startsWith('-o') && argument.length > 2) {
            format = normalizeCliOutputFormat(argument.substring(2));
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            positional.add(argument);
          }
      }
    }
    if (positional.length != 1) {
      throw const FormatException('Exactly one repository is required');
    }
    final target = targetDirectory?.trim() ?? '';
    if (target.isEmpty) {
      throw const CloneCommandException(
        'INVALID_ARGUMENT',
        '--dir is required',
      );
    }
    final repo = positional.single.trim();
    if (repo.isEmpty) {
      throw const CloneCommandException(
        'INVALID_ARGUMENT',
        'Repository is required',
      );
    }
    if (!isCompleteGitRemote(repo) && protocol == null) {
      throw const CloneCommandException(
        'INVALID_ARGUMENT',
        '--protocol is required for owner/repo repository names',
      );
    }
    return CloneCliInvocation(
      repo: repo,
      targetDirectory: target,
      protocol: protocol,
      host: host,
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
    );
  }
}

final _cloneSchema = CliOutputSchema(
  idField: (row) => '${row['projectId']}',
  columns: [
    CliOutputColumn(header: 'REPO', field: (row) => row['repo'], width: 28),
    CliOutputColumn(
      header: 'PROJECT',
      field: (row) => row['projectName'],
      width: 28,
    ),
    CliOutputColumn(
      header: 'PATH',
      field: (row) => row['checkoutPath'],
      width: 56,
    ),
  ],
);

void _renderError(
  void Function(String value) write,
  CloneCommandException error,
  CliOutputOptions options,
) {
  write(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
}

ProjectGithubCloneProtocol _parseCloneProtocol(String value) {
  if (!const {'https', 'ssh'}.contains(value)) {
    throw FormatException('--protocol must be one of: https, ssh');
  }
  return ProjectGithubCloneProtocol.values.byName(value);
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

CliOutputOptions _recoverCloneOutputOptions(List<String> arguments) {
  var format = 'table';
  var json = false;
  var quiet = false;
  var noHeaders = false;
  var noColor = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--') {
      break;
    } else if (argument == '--json') {
      json = true;
    } else if (argument == '-q' || argument == '--quiet') {
      quiet = true;
    } else if (argument == '--no-headers') {
      noHeaders = true;
    } else if (argument == '--no-color') {
      noColor = true;
    } else if (argument == '-o' || argument == '--format') {
      if (index + 1 < arguments.length) {
        format = _safeCloneOutputFormat(arguments[++index], format);
      }
    } else if (argument.startsWith('--format=')) {
      format = _safeCloneOutputFormat(
        argument.substring('--format='.length),
        format,
      );
    } else if (argument.startsWith('-o') && argument.length > 2) {
      format = _safeCloneOutputFormat(argument.substring(2), format);
    }
  }
  return CliOutputOptions(
    format: json ? 'json' : format,
    quiet: quiet,
    noHeaders: noHeaders,
    noColor: noColor,
  );
}

String _safeCloneOutputFormat(String value, String fallback) {
  try {
    return normalizeCliOutputFormat(value);
  } on FormatException {
    return fallback;
  }
}

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  FormatException(message: final message) => message,
  _ => '$error',
};

final class CloneCommandException implements Exception {
  const CloneCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const cloneUsage =
    'Usage: coding-agent clone <repo> --dir <path> '
    '[--protocol <https|ssh>] [--host <host>] [--json]';

const cloneHelp =
    'Usage: coding-agent clone [options] <repo>\n'
    'Clone a GitHub repo and register it as a Tinyrack workspace\n\n'
    'Options:\n'
    '  --dir <path>           Parent directory to clone into\n'
    '  --protocol <protocol>  https or ssh for owner/repo shorthand\n'
    '  --host <host>          Daemon host target\n'
    '  --json                 Output in JSON format\n';
