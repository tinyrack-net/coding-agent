import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'terminal_command.dart';

abstract interface class PermitDaemonClient {
  Future<Map<String, Object?>> request(Map<String, Object?> request);
  Future<void> send(Map<String, Object?> message);
  Future<void> close();
}

typedef PermitClientConnector =
    Future<PermitDaemonClient> Function({
      required String? host,
      required Map<String, String> environment,
    });

Future<int> runPermitCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  PermitClientConnector connect = connectPermitClient,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_permitHelp(arguments.firstOrNull));
    return 0;
  }

  PermitDaemonClient? client;
  late final PermitCliInvocation invocation;
  try {
    invocation = PermitCliInvocation.parse(arguments);
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$permitUsage\n');
    return 64;
  } on PermitCommandException catch (error) {
    _renderError(errorOutput, error, json: arguments.contains('--json'));
    return 1;
  }

  final env = environment ?? Platform.environment;
  try {
    try {
      client = await connect(host: invocation.host, environment: env);
    } on Object catch (error) {
      final config = loadDaemonRuntimeConfig(environment: env);
      final host = invocation.host ?? '${config.host}:${config.port}';
      throw PermitCommandException(
        'DAEMON_NOT_RUNNING',
        'Cannot connect to daemon at $host: ${_errorText(error)}',
        details: 'Start the daemon with: coding-agent daemon start',
      );
    }

    final rows = await _execute(client, invocation);
    output(_renderRows(rows, invocation));
    return 0;
  } on PermitCommandException catch (error) {
    _renderError(errorOutput, error, json: invocation.json);
    return 1;
  } on Object catch (error) {
    final code = switch (invocation.action) {
      'ls' => 'LIST_PERMISSIONS_FAILED',
      'allow' => 'ALLOW_PERMISSION_FAILED',
      _ => 'DENY_PERMISSION_FAILED',
    };
    final verb = switch (invocation.action) {
      'ls' => 'list permissions',
      'allow' => 'allow permission',
      _ => 'deny permission',
    };
    _renderError(
      errorOutput,
      PermitCommandException(code, 'Failed to $verb: ${_errorText(error)}'),
      json: invocation.json,
    );
    return 1;
  } finally {
    await client?.close();
  }
}

Future<PermitDaemonClient> connectPermitClient({
  required String? host,
  required Map<String, String> environment,
}) async {
  final client = await DaemonCliSocketClient.connect(
    loadDaemonRuntimeConfig(environment: environment),
    hostOverride: host,
    environment: environment,
  );
  return _SocketPermitClient(client);
}

final class _SocketPermitClient implements PermitDaemonClient {
  const _SocketPermitClient(this.client);

  final DaemonCliSocketClient client;

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> request) =>
      client.request(request);

  @override
  Future<void> send(Map<String, Object?> message) => client.send(message);

  @override
  Future<void> close() => client.close();
}

final class PermitCliInvocation {
  const PermitCliInvocation({
    required this.action,
    required this.agent,
    required this.requestId,
    required this.all,
    required this.updatedInput,
    required this.message,
    required this.interrupt,
    required this.host,
    required this.json,
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String action;
  final String? agent;
  final String? requestId;
  final bool all;
  final Map<String, Object?>? updatedInput;
  final String? message;
  final bool interrupt;
  final String? host;
  final bool json;
  final String format;
  final bool quiet;
  final bool headers;

  static PermitCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing permit action');
    }
    final action = arguments.first;
    if (!const {'ls', 'allow', 'deny'}.contains(action)) {
      throw FormatException('Unknown permit action: $action');
    }

    final positional = <String>[];
    String? inputJson;
    String? message;
    String? host;
    var all = false;
    var interrupt = false;
    var json = false;
    var format = 'table';
    var quiet = false;
    var headers = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--all' when action != 'ls':
          all = true;
        case '--input' when action == 'allow':
          inputJson = _requiredValue(arguments, ++index, argument);
        case '--message' when action == 'deny':
          message = _requiredValue(arguments, ++index, argument);
        case '--interrupt' when action == 'deny':
          interrupt = true;
        case '--host':
          host = _requiredValue(arguments, ++index, argument);
        case '--json':
          json = true;
          format = 'json';
        case '-o' || '--format':
          format = _requiredValue(arguments, ++index, argument).toLowerCase();
          if (!const {'table', 'json', 'yaml', 'cli'}.contains(format)) {
            throw FormatException('Unsupported output format: $format');
          }
          if (format == 'cli') format = 'table';
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

    if (action == 'ls') {
      if (positional.isNotEmpty) {
        throw const FormatException('permit ls does not accept arguments');
      }
    } else {
      if (positional.isEmpty) {
        throw FormatException('Agent ID is required for permit $action');
      }
      if (positional.length > 2) {
        throw FormatException('Too many arguments for permit $action');
      }
    }

    Map<String, Object?>? updatedInput;
    if (inputJson != null) {
      try {
        final decoded = jsonDecode(inputJson);
        if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
          throw const FormatException('JSON value must be an object');
        }
        updatedInput = Map<String, Object?>.from(decoded);
      } on Object catch (error) {
        if (error is PermitCommandException) rethrow;
        throw PermitCommandException(
          'INVALID_JSON',
          'Invalid JSON for --input: ${_errorText(error)}',
          details: 'Provide valid JSON, e.g., --input \'{"key": "value"}\'',
        );
      }
    }

    final requestId = positional.length > 1 ? positional[1] : null;
    if (action == 'deny' && !all && requestId == null) {
      throw const PermitCommandException(
        'MISSING_ARGUMENT',
        'Request ID is required unless --all is specified',
        details:
            'Usage: coding-agent permit deny <agent> <req_id> or '
            'coding-agent permit deny <agent> --all',
      );
    }
    return PermitCliInvocation(
      action: action,
      agent: positional.firstOrNull,
      requestId: requestId,
      all: all,
      updatedInput: updatedInput,
      message: message,
      interrupt: interrupt,
      host: host,
      json: json || format == 'json',
      format: format,
      quiet: quiet,
      headers: headers,
    );
  }
}

Future<List<Map<String, Object?>>> _execute(
  PermitDaemonClient client,
  PermitCliInvocation invocation,
) async {
  if (invocation.action == 'ls') {
    final payload = await client.request(
      FetchAgentsRequest(
        requestId: _requestId('permit_ls'),
        filter: const AgentDirectoryFilter(includeArchived: true),
      ).toJson(),
    );
    final rows = <Map<String, Object?>>[];
    for (final entry in _objectList(payload, 'entries')) {
      final agent = _requiredObject(entry, 'agent');
      final agentId = _requiredString(agent, 'id');
      for (final permission in _pendingPermissions(agent)) {
        rows.add({
          'id': _short(permission.id, 8),
          'agentId': agentId,
          'agentShortId': _short(agentId, 7),
          'name': permission.name,
          'description': permission.description ?? '-',
        });
      }
    }
    return rows;
  }

  final payload = await client.request(
    FetchAgentRequest(
      requestId: _requestId('permit_agent'),
      agentId: invocation.agent!,
    ).toJson(),
  );
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw PermitCommandException(
      'AGENT_NOT_FOUND',
      'Agent not found: ${invocation.agent}',
      details: 'Use "coding-agent ls" to list available agents',
    );
  }
  if (rawAgent is! Map) {
    throw const FormatException('fetch_agent_response contains invalid agent');
  }
  final agent = Map<String, Object?>.from(rawAgent);
  final agentId = _requiredString(agent, 'id');
  final pending = _pendingPermissions(agent);
  if (pending.isEmpty) {
    throw PermitCommandException(
      'NO_PENDING_PERMISSIONS',
      'No pending permissions for agent ${_short(agentId, 7)}',
    );
  }

  final List<_PendingPermission> selected;
  if (invocation.action == 'allow' &&
      (invocation.requestId == null || invocation.all)) {
    selected = pending;
  } else if (invocation.action == 'deny' && invocation.all) {
    selected = pending;
  } else {
    final requestId = invocation.requestId!;
    final match = pending
        .where(
          (permission) =>
              permission.id == requestId || permission.id.startsWith(requestId),
        )
        .firstOrNull;
    if (match == null) {
      throw PermitCommandException(
        'PERMISSION_NOT_FOUND',
        'Permission request not found: $requestId',
        details:
            'Available requests: '
            '${pending.map((permission) => _short(permission.id, 8)).join(', ')}',
      );
    }
    selected = [match];
  }

  final behavior = invocation.action == 'allow'
      ? AgentPermissionBehavior.allow
      : AgentPermissionBehavior.deny;
  await Future.wait([
    for (final permission in selected)
      client.send(
        AgentPermissionResponseMessage(
          agentId: agentId,
          requestId: permission.id,
          response: behavior == AgentPermissionBehavior.allow
              ? AgentPermissionResponse.allow(
                  updatedInput: invocation.updatedInput,
                )
              : AgentPermissionResponse.deny(
                  message: invocation.message,
                  interrupt: invocation.interrupt ? true : null,
                ),
        ).toJson(),
      ),
  ]);

  return [
    for (final permission in selected)
      {
        'requestId': _short(permission.id, 8),
        'agentId': agentId,
        'agentShortId': _short(agentId, 7),
        'name': permission.name,
        'result': behavior == AgentPermissionBehavior.allow
            ? 'allowed'
            : 'denied',
      },
  ];
}

final class _PendingPermission {
  const _PendingPermission({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String? description;
}

List<_PendingPermission> _pendingPermissions(Map<String, Object?> agent) {
  final raw = agent['pendingPermissions'];
  if (raw is! List) {
    throw const FormatException('pendingPermissions must be an array');
  }
  return [
    for (final entry in raw)
      if (entry is Map)
        _PendingPermission(
          id: _requiredString(Map<String, Object?>.from(entry), 'id'),
          name: _requiredString(Map<String, Object?>.from(entry), 'name'),
          description: _optionalString(
            Map<String, Object?>.from(entry),
            'description',
          ),
        )
      else
        throw const FormatException(
          'pendingPermissions entries must be objects',
        ),
  ];
}

String _renderRows(
  List<Map<String, Object?>> rows,
  PermitCliInvocation invocation,
) {
  final idField = invocation.action == 'ls' ? 'id' : 'requestId';
  if (invocation.quiet) {
    return rows.isEmpty
        ? ''
        : '${rows.map((row) => row[idField]).join('\n')}\n';
  }
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(rows)}\n';
  }
  if (invocation.format == 'yaml') return _yamlRows(rows);
  final columns = invocation.action == 'ls'
      ? const [
          ('AGENT', 'agentShortId', 12),
          ('REQ_ID', 'id', 12),
          ('TOOL', 'name', 20),
          ('DESCRIPTION', 'description', 50),
        ]
      : const [
          ('REQUEST ID', 'requestId', 12),
          ('AGENT', 'agentShortId', 10),
          ('TOOL', 'name', 20),
          ('RESULT', 'result', 10),
        ];
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in rows) '${row[column.$2] ?? ''}'.length,
      ].reduce(math.max),
  ];
  String line(Iterable<String> cells) {
    final values = cells.toList();
    return [
      for (var index = 0; index < values.length; index++)
        values[index].padRight(widths[index]),
    ].join('  ').trimRight();
  }

  final lines = <String>[
    if (invocation.headers) line([for (final column in columns) column.$1]),
    for (final row in rows)
      line([for (final column in columns) '${row[column.$2] ?? ''}']),
  ];
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

String _yamlRows(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlScalar(Object? value) {
  if (value == null) return 'null';
  if (value is bool || value is num) return '$value';
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

void _renderError(
  void Function(String value) write,
  PermitCommandException error, {
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

List<Map<String, Object?>> _objectList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) throw FormatException('$key must be an array');
  return [
    for (final entry in value)
      if (entry is Map)
        Map<String, Object?>.from(entry)
      else
        throw FormatException('$key entries must be objects'),
  ];
}

Map<String, Object?> _requiredObject(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

String _requiredString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _short(String value, int length) =>
    value.substring(0, math.min(length, value.length));

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class PermitCommandException implements Exception {
  const PermitCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const permitUsage =
    'Usage: coding-agent permit ls [--host <host>] [--json]\n'
    '       coding-agent permit allow <agent> [req_id] '
    '[--all] [--input <json>] [--host <host>] [--json]\n'
    '       coding-agent permit deny <agent> [req_id] '
    '[--all] [--message <msg>] [--interrupt] [--host <host>] [--json]';

String _permitHelp(String? action) => switch (action) {
  'ls' =>
    'Usage: coding-agent permit ls [options]\n'
        'List all pending permissions\n',
  'allow' =>
    'Usage: coding-agent permit allow [options] <agent> [req_id]\n'
        'Allow a permission request\n',
  'deny' =>
    'Usage: coding-agent permit deny [options] <agent> [req_id]\n'
        'Deny a permission request\n',
  _ =>
    'Usage: coding-agent permit [command]\n'
        'Manage permission requests\n\n'
        'Commands:\n'
        '  ls       List all pending permissions\n'
        '  allow    Allow a permission request\n'
        '  deny     Deny a permission request\n',
};
