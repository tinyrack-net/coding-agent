import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
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

  late final CloneCliInvocation invocation;
  try {
    invocation = CloneCliInvocation.parse(arguments);
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$cloneUsage\n');
    return 64;
  } on CloneCommandException catch (error) {
    _renderError(errorOutput, error, json: _requestsJson(arguments));
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
    output(_render(row, invocation));
    return 0;
  } on CloneCommandException catch (error) {
    _renderError(errorOutput, error, json: invocation.json);
    return 1;
  } on Object catch (error) {
    _renderError(
      errorOutput,
      CloneCommandException(
        'CLONE_FAILED',
        'Failed to clone GitHub repo: ${_errorText(error)}',
      ),
      json: invocation.json,
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
    required this.json,
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String repo;
  final String targetDirectory;
  final ProjectGithubCloneProtocol? protocol;
  final String? host;
  final bool json;
  final String format;
  final bool quiet;
  final bool headers;

  static CloneCliInvocation parse(List<String> arguments) {
    final positional = <String>[];
    String? targetDirectory;
    ProjectGithubCloneProtocol? protocol;
    String? host;
    var json = false;
    var format = 'table';
    var quiet = false;
    var headers = true;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--dir':
          targetDirectory = _requiredValue(arguments, ++index, argument);
        case '--protocol':
          final value = _requiredValue(arguments, ++index, argument);
          if (!const {'https', 'ssh'}.contains(value)) {
            throw FormatException('--protocol must be one of: https, ssh');
          }
          protocol = ProjectGithubCloneProtocol.values.byName(value);
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
          format = 'json';
        case '-o' || '--format':
          format = _requiredValue(arguments, ++index, argument).toLowerCase();
          if (format == 'cli') format = 'table';
          if (!const {'table', 'json', 'yaml'}.contains(format)) {
            throw FormatException('Unsupported output format: $format');
          }
        case '-q' || '--quiet':
          quiet = true;
        case '--no-headers':
          headers = false;
        case '--no-color':
          break;
        default:
          if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          }
          positional.add(argument);
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
      json: json || format == 'json',
      format: format,
      quiet: quiet,
      headers: headers,
    );
  }
}

String _render(Map<String, Object?> row, CloneCliInvocation invocation) {
  if (invocation.quiet) return '${row['projectId']}\n';
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(row)}\n';
  }
  if (invocation.format == 'yaml') {
    return '${[for (final entry in row.entries) '${entry.key}: ${jsonEncode(entry.value)}'].join('\n')}\n';
  }
  const columns = [
    ('REPO', 'repo', 28),
    ('PROJECT', 'projectName', 28),
    ('PATH', 'checkoutPath', 56),
  ];
  final widths = [
    for (final column in columns)
      math.max(
        math.max(column.$1.length, column.$3),
        '${row[column.$2] ?? ''}'.length,
      ),
  ];
  String line(Iterable<String> cells) {
    final values = cells.toList();
    return [
      for (var index = 0; index < values.length; index++)
        values[index].padRight(widths[index]),
    ].join('  ').trimRight();
  }

  return '${[
    if (invocation.headers) line([for (final column in columns) column.$1]),
    line([for (final column in columns) '${row[column.$2] ?? ''}']),
  ].join('\n')}\n';
}

void _renderError(
  void Function(String value) write,
  CloneCommandException error, {
  required bool json,
}) {
  if (json) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
      })}\n',
    );
    return;
  }
  write('Error: ${error.message}\n');
  if (error.details != null) write('${error.details}\n');
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

bool _requestsJson(List<String> arguments) {
  if (arguments.contains('--json')) return true;
  for (var index = 0; index < arguments.length - 1; index++) {
    if ((arguments[index] == '--format' || arguments[index] == '-o') &&
        arguments[index + 1].toLowerCase() == 'json') {
      return true;
    }
  }
  return false;
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
