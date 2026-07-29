import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_output.dart';
import 'terminal_command.dart';

typedef AgentImportRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runAgentImportCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  AgentImportRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  AgentImportCliInvocation? invocation;
  try {
    invocation = AgentImportCliInvocation.parse(arguments);
    final cwd = _resolveImportCwd(
      invocation.cwd,
      currentDirectory ?? Directory.current.path,
    );
    final env = environment ?? Platform.environment;
    if (request == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      final daemonHost = invocation.host ?? '${config.host}:${config.port}';
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
      } catch (error) {
        throw AgentImportCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $daemonHost: ${_errorText(error)}',
          details: 'Start the daemon with: coding-agent daemon start',
        );
      }
    }

    final response = await (request ?? client!.request)(
      ImportAgentRequest(
        requestId: 'agent_import_${DateTime.now().microsecondsSinceEpoch}',
        provider: invocation.provider,
        sessionId: invocation.sessionId,
        cwd: cwd,
        labels: invocation.labels.isEmpty ? null : invocation.labels,
      ).toJson(),
    );
    final status = ImportAgentStatusResponse.fromJson(response);
    if (!status.succeeded) {
      throw AgentImportCommandException(
        'AGENT_IMPORT_FAILED',
        'Failed to import agent: ${status.error}',
      );
    }
    final agent = status.agent!;
    final result = <String, Object?>{
      'agentId': agent.agentId,
      'status':
          agent.runState == AgentRunState.running ||
              agent.runState == AgentRunState.awaitingPermission
          ? 'running'
          : 'created',
      'provider': agent.provider,
      'cwd': agent.cwd,
      'title': agent.title.isEmpty ? null : agent.title,
    };
    final rendered = renderCliOutput(
      CliOutputResult.single(row: result, schema: _agentImportSchema),
      invocation.output,
    );
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentImportUsage\n');
    return 64;
  } on AgentImportCommandException catch (error) {
    _writeImportError(
      errorOutput,
      error,
      invocation?.output ?? _outputOptionsFromArguments(arguments),
    );
    return 1;
  } on Object catch (error) {
    _writeImportError(
      errorOutput,
      AgentImportCommandException(
        'AGENT_IMPORT_FAILED',
        'Failed to import agent: ${_errorText(error)}',
      ),
      invocation?.output ?? _outputOptionsFromArguments(arguments),
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentImportCliInvocation {
  const AgentImportCliInvocation({
    required this.sessionId,
    required this.provider,
    required this.cwd,
    required this.labels,
    required this.host,
    required this.output,
  });

  final String sessionId;
  final String provider;
  final String? cwd;
  final Map<String, String> labels;
  final String? host;
  final CliOutputOptions output;

  static AgentImportCliInvocation parse(List<String> arguments) {
    String? sessionId;
    String? provider;
    String? cwd;
    String? host;
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    var positionalOnly = false;
    final labels = <String, String>{};

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly) {
        final longOption = _splitLongOption(argument);
        if (longOption != null) {
          final (option, value) = longOption;
          switch (option) {
            case '--provider':
              provider = value;
              continue;
            case '--cwd':
              cwd = _parseImportCwd(value);
              continue;
            case '--label':
              _addImportLabel(labels, value);
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
        sessionId = _addSessionId(sessionId, argument);
        continue;
      }
      switch (argument) {
        case '--provider':
          provider = _requiredOptionValue(arguments, ++index, argument);
        case '--cwd':
          cwd = _parseImportCwd(
            _requiredOptionValue(arguments, ++index, argument),
          );
        case '--label':
          _addImportLabel(
            labels,
            _requiredOptionValue(arguments, ++index, argument),
          );
        case '--host':
          host = _requiredOptionValue(arguments, ++index, argument);
        case '--json':
          json = true;
        case '-o' || '--format':
          format = normalizeCliOutputFormat(
            _requiredOptionValue(arguments, ++index, argument),
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
            sessionId = _addSessionId(sessionId, argument);
          }
      }
    }

    final normalizedSessionId = sessionId?.trim();
    if (normalizedSessionId == null || normalizedSessionId.isEmpty) {
      throw const AgentImportCommandException(
        'MISSING_SESSION_ID',
        'Session ID is required',
        details: 'Usage: coding-agent import --provider <provider> <id>',
      );
    }
    final normalizedProvider = provider?.trim();
    if (normalizedProvider == null || normalizedProvider.isEmpty) {
      throw const AgentImportCommandException(
        'MISSING_PROVIDER',
        'Provider is required',
        details: 'Usage: coding-agent import --provider <provider> <id>',
      );
    }
    return AgentImportCliInvocation(
      sessionId: normalizedSessionId,
      provider: normalizedProvider,
      cwd: cwd?.trim(),
      labels: Map.unmodifiable(labels),
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

final _agentImportSchema = CliOutputSchema(
  idField: (row) => '${row['agentId']}',
  columns: [
    CliOutputColumn(
      header: 'AGENT ID',
      field: (row) => row['agentId'],
      width: 12,
    ),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status'], width: 10),
    CliOutputColumn(
      header: 'PROVIDER',
      field: (row) => row['provider'],
      width: 10,
    ),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 30),
    CliOutputColumn(header: 'TITLE', field: (row) => row['title'], width: 20),
  ],
);

String _parseImportCwd(String value) {
  if (value.trim().isEmpty) {
    throw const AgentImportCommandException(
      'INVALID_CWD',
      '--cwd cannot be empty',
      details: 'Provide a working directory path or omit --cwd',
    );
  }
  return value;
}

String _resolveImportCwd(String? explicit, String defaultDirectory) {
  final cwd = explicit?.trim() ?? defaultDirectory;
  if (cwd.trim().isEmpty) {
    throw const AgentImportCommandException(
      'INVALID_CWD',
      '--cwd cannot be empty',
      details: 'Provide a working directory path or omit --cwd',
    );
  }
  return cwd;
}

void _addImportLabel(Map<String, String> labels, String label) {
  final separator = label.indexOf('=');
  if (separator < 0 || label.substring(0, separator).trim().isEmpty) {
    throw AgentImportCommandException(
      'INVALID_LABEL',
      'Invalid label format: $label',
      details: separator < 0
          ? 'Labels must be in key=value format'
          : 'Labels must include a non-empty key in key=value format',
    );
  }
  labels[label.substring(0, separator).trim()] = label.substring(separator + 1);
}

String _addSessionId(String? current, String value) {
  if (current != null) {
    throw const FormatException('Only one session ID may be imported');
  }
  return value;
}

void _writeImportError(
  void Function(String value) write,
  AgentImportCommandException error,
  CliOutputOptions options,
) {
  write(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
}

CliOutputOptions _outputOptionsFromArguments(List<String> arguments) {
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
        format = _safeOutputFormat(arguments[++index], format);
      }
    } else if (argument.startsWith('--format=')) {
      format = _safeOutputFormat(
        argument.substring('--format='.length),
        format,
      );
    } else if (argument.startsWith('-o') && argument.length > 2) {
      format = _safeOutputFormat(argument.substring(2), format);
    }
  }
  return CliOutputOptions(
    format: json ? 'json' : format,
    quiet: quiet,
    noHeaders: noHeaders,
    noColor: noColor,
  );
}

String _safeOutputFormat(String value, String fallback) {
  try {
    return normalizeCliOutputFormat(value);
  } on FormatException {
    return fallback;
  }
}

String _requiredOptionValue(List<String> arguments, int index, String option) {
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

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class AgentImportCommandException implements Exception {
  const AgentImportCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const agentImportUsage =
    'Usage: coding-agent import --provider <provider> <id> '
    '[--cwd <path>] [--label <key=value>] [--host <host>] '
    '[-o|--format <table|json|yaml>] [--json] [-q|--quiet] [--no-headers]';
