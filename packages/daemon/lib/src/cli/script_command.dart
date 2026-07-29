import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_config.dart';
import 'cli_output.dart';
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
  ScriptCliInvocation? invocation;
  try {
    invocation = ScriptCliInvocation.parse(arguments);
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
    final rendered = renderCliOutput(result, invocation.output);
    if (rendered.isNotEmpty) output('$rendered\n');
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$scriptUsage\n');
    return 64;
  } on ScriptCommandException catch (error) {
    _writeCommandError(
      errorOutput,
      error,
      options: invocation?.output ?? const CliOutputOptions(),
    );
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      ScriptCommandException('WORKSPACE_SCRIPT_ERROR', _errorText(error)),
      options: invocation?.output ?? const CliOutputOptions(),
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
    required this.output,
  });

  final String action;
  final String? scriptName;
  final String? cwd;
  final String? workspaceId;
  final String? host;
  final CliOutputOptions output;

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
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (_splitLongOption(argument) case (final option, final value)) {
        switch (option) {
          case '--cwd':
            cwd = value;
            continue;
          case '--workspace':
            workspaceId = value;
            continue;
          case '--host':
            host = value;
            continue;
          case '--format':
            format = normalizeCliOutputFormat(value);
            continue;
        }
      }
      switch (argument) {
        case '--cwd':
          cwd = _requiredValue(arguments, ++index, argument);
        case '--workspace':
          workspaceId = _requiredValue(arguments, ++index, argument);
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
          if (argument.startsWith('--format=')) {
            format = normalizeCliOutputFormat(
              argument.substring('--format='.length),
            );
          } else if (argument.startsWith('-o') && argument.length > 2) {
            format = normalizeCliOutputFormat(argument.substring(2));
          } else if (argument.startsWith('-')) {
            throw FormatException('Unknown option: $argument');
          } else {
            positionals.add(argument);
          }
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
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
    );
  }
}

Future<CliOutputResult> _execute(
  ScriptCliInvocation invocation,
  ScriptRpcRequester request,
  String currentDirectory,
) async {
  final operationCode = switch (invocation.action) {
    'ls' => 'WORKSPACE_SCRIPT_LIST_FAILED',
    'start' => 'WORKSPACE_SCRIPT_START_FAILED',
    'stop' => 'WORKSPACE_SCRIPT_STOP_FAILED',
    _ => throw StateError('Unhandled script action'),
  };
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
    throw ScriptCommandException(
      operationCode,
      invocation.action == 'ls'
          ? 'Failed to list workspace scripts: $error'
          : error,
    );
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
    return CliOutputResult.list(rows: rows, schema: _workspaceScriptSchema);
  }
  final script = response['script'];
  if (script is! Map) {
    throw ScriptCommandException(
      operationCode,
      "Script '${invocation.scriptName}' did not return status metadata",
    );
  }
  return CliOutputResult.single(
    row: _scriptRow(script.cast<String, Object?>(), operationCode),
    schema: _workspaceScriptSchema,
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
    final action = switch (code) {
      'WORKSPACE_SCRIPT_LIST_FAILED' => 'list workspace scripts',
      'WORKSPACE_SCRIPT_START_FAILED' => 'start workspace script',
      'WORKSPACE_SCRIPT_STOP_FAILED' => 'stop workspace script',
      _ => 'manage workspace scripts',
    };
    throw ScriptCommandException(
      code,
      'Failed to $action: ${_errorText(error)}',
    );
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

final _workspaceScriptSchema = CliOutputSchema(
  idField: (row) => '${row['scriptName']}',
  columns: [
    CliOutputColumn(
      header: 'NAME',
      field: (row) => row['scriptName'],
      width: 20,
    ),
    CliOutputColumn(header: 'TYPE', field: (row) => row['type'], width: 9),
    CliOutputColumn(
      header: 'LIFECYCLE',
      field: (row) => row['lifecycle'],
      width: 10,
    ),
    CliOutputColumn(
      header: 'HEALTH',
      field: (row) => row['health'] ?? '-',
      width: 10,
    ),
    CliOutputColumn(
      header: 'PORT',
      field: (row) => row['port'] ?? '-',
      width: 7,
    ),
    CliOutputColumn(
      header: 'PROXY URL',
      field: (row) => row['proxyUrl'] ?? '-',
      width: 42,
    ),
    CliOutputColumn(
      header: 'TERMINAL',
      field: (row) => row['terminalId'] ?? '-',
      width: 12,
    ),
  ],
);

void _writeCommandError(
  void Function(String value) write,
  ScriptCommandException error, {
  required CliOutputOptions options,
}) {
  write(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
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
