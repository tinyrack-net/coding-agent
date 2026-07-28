import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_config.dart';
import 'terminal_command.dart';

typedef ScriptRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runScriptCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  ScriptRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_scriptHelp(arguments.firstOrNull));
    return 0;
  }
  try {
    final invocation = ScriptCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    var send = request;
    if (send == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await DaemonCliSocketClient.connect(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
      } on Object catch (error) {
        final host = invocation.host ?? '${config.host}:${config.port}';
        throw ScriptCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          details: 'Start the daemon with: coding-agent daemon start',
        );
      }
      if (client.serverInfo.features['workspaceScriptManagement'] != true) {
        throw const ScriptCommandException(
          'DAEMON_UPDATE_REQUIRED',
          'Update the host to use workspace script management.',
        );
      }
      send = client.request;
    }
    final result = await _execute(
      invocation,
      send,
      currentDirectory ?? Directory.current.path,
    );
    output(_render(result, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$scriptUsage\n');
    return 64;
  } on ScriptCommandException catch (error) {
    _writeCommandError(errorOutput, error, arguments);
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      ScriptCommandException('WORKSPACE_SCRIPT_ERROR', _errorText(error)),
      arguments,
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class ScriptCliInvocation {
  const ScriptCliInvocation({
    required this.action,
    required this.scriptName,
    required this.cwd,
    required this.workspaceId,
    required this.host,
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String action;
  final String? scriptName;
  final String? cwd;
  final String? workspaceId;
  final String? host;
  final String format;
  final bool quiet;
  final bool headers;

  static ScriptCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing script action');
    }
    final action = arguments.first;
    if (!const {'ls', 'start', 'stop'}.contains(action)) {
      throw FormatException('Unknown script action: $action');
    }
    final positionals = <String>[];
    String? cwd;
    String? workspaceId;
    String? host;
    var format = 'table';
    var quiet = false;
    var headers = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--cwd':
          cwd = _requiredValue(arguments, ++index, argument);
        case '--workspace':
          workspaceId = _requiredValue(arguments, ++index, argument);
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          format = 'json';
        case '-o' || '--format':
          format = _requiredValue(arguments, ++index, argument);
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
          positionals.add(argument);
      }
    }
    if (action == 'ls' && positionals.isNotEmpty) {
      throw const FormatException('script ls does not accept an argument');
    }
    if (action != 'ls' &&
        (positionals.length != 1 || positionals.single.trim().isEmpty)) {
      throw FormatException('script $action requires one script name');
    }
    return ScriptCliInvocation(
      action: action,
      scriptName: positionals.firstOrNull?.trim(),
      cwd: cwd,
      workspaceId: _nonEmpty(workspaceId),
      host: host,
      format: format,
      quiet: quiet,
      headers: headers,
    );
  }
}

Future<_ScriptCommandResult> _execute(
  ScriptCliInvocation invocation,
  ScriptRpcRequester request,
  String currentDirectory,
) async {
  final operationCode =
      'WORKSPACE_SCRIPT_${invocation.action.toUpperCase()}_FAILED';
  final workspaceId = await _resolveWorkspaceId(
    invocation,
    request,
    currentDirectory,
    operationCode,
  );
  final requestId = _requestId('workspace_script_${invocation.action}');
  final response = await _request(request, switch (invocation.action) {
    'ls' => WorkspaceScriptListRequest(
      workspaceId: workspaceId,
      requestId: requestId,
    ).toJson(),
    'start' => WorkspaceScriptStartRequest(
      workspaceId: workspaceId,
      scriptName: invocation.scriptName!,
      requestId: requestId,
    ).toJson(),
    'stop' => WorkspaceScriptStopRequest(
      workspaceId: workspaceId,
      scriptName: invocation.scriptName!,
      requestId: requestId,
    ).toJson(),
    _ => throw StateError('Unhandled script action'),
  }, code: operationCode);
  final error = _nonEmpty(response['error']?.toString());
  if (error != null) {
    throw ScriptCommandException(operationCode, error);
  }
  if (invocation.action == 'ls') {
    final scripts = response['scripts'];
    if (scripts is! List) {
      throw const ScriptCommandException(
        'WORKSPACE_SCRIPT_LIST_FAILED',
        'Workspace script list response is missing scripts',
      );
    }
    final rows = <Map<String, Object?>>[];
    for (final script in scripts) {
      if (script is! Map) {
        throw const ScriptCommandException(
          'WORKSPACE_SCRIPT_LIST_FAILED',
          'Workspace script list contains an invalid entry',
        );
      }
      rows.add(_scriptRow(script.cast<String, Object?>(), operationCode));
    }
    return _ScriptCommandResult.list(rows);
  }
  final script = response['script'];
  if (script is! Map) {
    throw ScriptCommandException(
      operationCode,
      "Script '${invocation.scriptName}' did not return status metadata",
    );
  }
  return _ScriptCommandResult.single(
    _scriptRow(script.cast<String, Object?>(), operationCode),
  );
}

Future<String> _resolveWorkspaceId(
  ScriptCliInvocation invocation,
  ScriptRpcRequester request,
  String currentDirectory,
  String operationCode,
) async {
  if (invocation.workspaceId case final workspaceId?) return workspaceId;
  final rawCwd = invocation.cwd ?? currentDirectory;
  final cwd = p.normalize(
    p.isAbsolute(rawCwd) ? rawCwd : p.join(currentDirectory, rawCwd),
  );
  final response = await _request(
    request,
    FetchWorkspacesRequest(
      requestId: _requestId('workspace_script_resolve'),
      limit: 200,
    ).toJson(),
    code: operationCode,
  );
  final entries = response['entries'];
  if (entries is! List) {
    throw ScriptCommandException(
      operationCode,
      'Workspace list response is missing entries',
    );
  }
  final matches = <String>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final workspace = entry.cast<String, Object?>();
    final directory = workspace['workspaceDirectory'];
    final id = workspace['id'];
    if (directory is String &&
        id is String &&
        p.normalize(
              p.isAbsolute(directory)
                  ? directory
                  : p.join(currentDirectory, directory),
            ) ==
            cwd) {
      matches.add(id);
    }
  }
  if (matches.length == 1) return matches.single;
  if (matches.length > 1) {
    throw ScriptCommandException(
      'WORKSPACE_AMBIGUOUS',
      'Multiple workspaces use $cwd',
      details: 'Pass --workspace <workspace-id> to select one.',
    );
  }
  throw ScriptCommandException(
    'WORKSPACE_NOT_FOUND',
    'No Tinyrack workspace found for $cwd',
    details:
        'Open the directory in Tinyrack first, or pass '
        '--workspace <workspace-id>.',
  );
}

Future<Map<String, Object?>> _request(
  ScriptRpcRequester request,
  Map<String, Object?> message, {
  required String code,
}) async {
  try {
    return await request(message);
  } on ScriptCommandException {
    rethrow;
  } on Object catch (error) {
    throw ScriptCommandException(code, _errorText(error));
  }
}

Map<String, Object?> _scriptRow(
  Map<String, Object?> json,
  String operationCode,
) {
  try {
    return WorkspaceScript.fromJson(json).toJson();
  } on Object catch (error) {
    throw ScriptCommandException(
      operationCode,
      'Invalid workspace script response: ${_errorText(error)}',
    );
  }
}

final class _ScriptCommandResult {
  const _ScriptCommandResult._({required this.rows, required this.single});

  factory _ScriptCommandResult.list(List<Map<String, Object?>> rows) =>
      _ScriptCommandResult._(rows: List.unmodifiable(rows), single: false);

  factory _ScriptCommandResult.single(Map<String, Object?> row) =>
      _ScriptCommandResult._(rows: [Map.unmodifiable(row)], single: true);

  final List<Map<String, Object?>> rows;
  final bool single;
}

String _render(_ScriptCommandResult result, ScriptCliInvocation invocation) {
  if (invocation.quiet) {
    return result.rows.map((row) => row['scriptName']).join('\n') +
        (result.rows.isEmpty ? '' : '\n');
  }
  final value = result.single ? result.rows.single : result.rows;
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(value)}\n';
  }
  if (invocation.format == 'yaml') {
    return result.single
        ? _yamlMap(result.rows.single)
        : _yamlList(result.rows);
  }
  const columns = [
    ('NAME', 'scriptName', 20),
    ('TYPE', 'type', 9),
    ('LIFECYCLE', 'lifecycle', 10),
    ('HEALTH', 'health', 10),
    ('PORT', 'port', 7),
    ('PROXY URL', 'proxyUrl', 42),
    ('TERMINAL', 'terminalId', 12),
  ];
  final displayRows = [
    for (final row in result.rows)
      {
        for (final column in columns)
          column.$2:
              row[column.$2] ??
              (const {
                    'health',
                    'port',
                    'proxyUrl',
                    'terminalId',
                  }.contains(column.$2)
                  ? '-'
                  : ''),
      },
  ];
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in displayRows) '${row[column.$2]}'.length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return [
        if (invocation.headers) line([for (final column in columns) column.$1]),
        for (final row in displayRows)
          line([for (final column in columns) '${row[column.$2]}']),
      ].join('\n') +
      (invocation.headers || displayRows.isNotEmpty ? '\n' : '');
}

String _yamlList(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlMap(Map<String, Object?> row) =>
    '${[for (final entry in row.entries) '${entry.key}: ${_yamlScalar(entry.value)}'].join('\n')}\n';

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

void _writeCommandError(
  void Function(String value) write,
  ScriptCommandException error,
  List<String> arguments,
) {
  if (arguments.contains('--json')) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
      })}\n',
    );
  } else {
    write(
      'Error: ${error.message}\n'
      '${error.details == null ? '' : '${error.details}\n'}',
    );
  }
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class ScriptCommandException implements Exception {
  const ScriptCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const scriptUsage =
    'Usage: coding-agent script ls [--cwd <path> | --workspace <workspace-id>]\n'
    '       coding-agent script start <name> '
    '[--cwd <path> | --workspace <workspace-id>]\n'
    '       coding-agent script stop <name> '
    '[--cwd <path> | --workspace <workspace-id>]';

String _scriptHelp(String? action) => switch (action) {
  'ls' =>
    'Usage: coding-agent script ls [options]\n'
        'List configured workspace scripts\n',
  'start' =>
    'Usage: coding-agent script start [options] <name>\n'
        'Start a configured workspace script\n',
  'stop' =>
    'Usage: coding-agent script stop [options] <name>\n'
        'Stop a running workspace script\n',
  _ =>
    'Usage: coding-agent script [command]\n'
        'Manage configured workspace scripts\n\n'
        'Commands:\n'
        '  ls     List configured workspace scripts\n'
        '  start  Start a configured workspace script\n'
        '  stop   Stop a running workspace script\n',
};
