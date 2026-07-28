import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
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
  try {
    final invocation = AgentImportCliInvocation.parse(arguments);
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
        cwd: invocation.cwd ?? currentDirectory ?? Directory.current.path,
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
    output(_renderImportResult(result, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentImportUsage\n');
    return 64;
  } on AgentImportCommandException catch (error) {
    final format = arguments.contains('--json')
        ? 'json'
        : _optionValue(arguments, '--format') ??
              _optionValue(arguments, '-o') ??
              'table';
    if (format == 'json') {
      errorOutput(
        '${const JsonEncoder.withIndent('  ').convert({
          'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
        })}\n',
      );
    } else if (format == 'yaml') {
      errorOutput(
        'error:\n'
        '  code: ${_yamlScalar(error.code)}\n'
        '  message: ${_yamlScalar(error.message)}\n'
        '${error.details == null ? '' : '  details: ${_yamlScalar(error.details)}\n'}',
      );
    } else {
      errorOutput('Error: ${error.message}\n');
      if (error.details != null) errorOutput('${error.details}\n');
    }
    return 1;
  } on Object catch (error) {
    errorOutput('AGENT_IMPORT_FAILED: ${_errorText(error)}\n');
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
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String sessionId;
  final String provider;
  final String? cwd;
  final Map<String, String> labels;
  final String? host;
  final String format;
  final bool quiet;
  final bool headers;

  static AgentImportCliInvocation parse(List<String> arguments) {
    String? sessionId;
    String? provider;
    String? cwd;
    String? host;
    var format = 'table';
    var quiet = false;
    var headers = true;
    final labels = <String, String>{};

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--provider':
          provider = _requiredOptionValue(arguments, ++index, argument);
        case '--cwd':
          cwd = _requiredOptionValue(arguments, ++index, argument);
          if (cwd.trim().isEmpty) {
            throw const AgentImportCommandException(
              'INVALID_CWD',
              '--cwd cannot be empty',
              details: 'Provide a working directory path or omit --cwd',
            );
          }
        case '--label':
          final label = _requiredOptionValue(arguments, ++index, argument);
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
          labels[label.substring(0, separator).trim()] = label.substring(
            separator + 1,
          );
        case '--host':
          host = _requiredOptionValue(arguments, ++index, argument);
        case '--json':
          format = 'json';
        case '-o' || '--format':
          format = _requiredOptionValue(arguments, ++index, argument);
          if (!const {'table', 'json', 'yaml'}.contains(format)) {
            throw FormatException('Unknown output format: $format');
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
          if (sessionId != null) {
            throw const FormatException('Only one session ID may be imported');
          }
          sessionId = argument;
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
      format: format,
      quiet: quiet,
      headers: headers,
    );
  }
}

String _renderImportResult(
  Map<String, Object?> result,
  AgentImportCliInvocation invocation,
) {
  if (invocation.quiet) return '${result['agentId']}\n';
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(result)}\n';
  }
  if (invocation.format == 'yaml') {
    return [
          for (final entry in result.entries)
            '${entry.key}: ${_yamlScalar(entry.value)}',
        ].join('\n') +
        '\n';
  }
  const headers = ['AGENT ID', 'STATUS', 'PROVIDER', 'CWD', 'TITLE'];
  const minimumWidths = [12, 10, 10, 30, 20];
  final cells = [
    '${result['agentId']}',
    '${result['status']}',
    '${result['provider']}',
    '${result['cwd']}',
    '${result['title'] ?? ''}',
  ];
  final widths = <int>[
    for (var index = 0; index < headers.length; index++)
      [
        headers[index].length,
        cells[index].length,
        minimumWidths[index],
      ].reduce((a, b) => a > b ? a : b),
  ];
  String row(List<String> values) => [
    for (var index = 0; index < values.length; index++)
      values[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return '${[if (invocation.headers) row(headers), row(cells)].join('\n')}\n';
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is num || value is bool) return '$value';
  final text = '$value';
  if (text.isNotEmpty &&
      !RegExp(
        r'''[:#\[\]{},&*!|>'"%@`]|^\s|\s$|^(null|true|false|~)$''',
        caseSensitive: false,
      ).hasMatch(text)) {
    return text;
  }
  return jsonEncode(text);
}

String _requiredOptionValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String? _optionValue(List<String> arguments, String option) {
  final index = arguments.indexOf(option);
  return index >= 0 && index + 1 < arguments.length
      ? arguments[index + 1]
      : null;
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
