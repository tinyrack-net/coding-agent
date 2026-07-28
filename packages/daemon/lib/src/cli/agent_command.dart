import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'terminal_command.dart';

typedef AgentRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runAgentCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  AgentRpcRequester? request,
  DateTime Function()? now,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  DaemonCliSocketClient? client;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(_agentHelp(arguments.firstOrNull));
    return 0;
  }
  try {
    final invocation = AgentCliInvocation.parse(arguments);
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
        send = client.request;
      } on Object catch (error) {
        final host = invocation.host ?? '${config.host}:${config.port}';
        throw AgentCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          details: invocation.action == 'ls'
              ? 'Start the daemon with: coding-agent daemon start\n'
                    'For a remote daemon, pass --host <host:port> or set '
                    'TINYRACK_HOST.'
              : 'Start the daemon with: coding-agent daemon start',
        );
      }
    }
    final result = await _execute(
      invocation,
      send,
      env,
      (now ?? DateTime.now)().toUtc(),
    );
    output(_render(result, invocation));
    return 0;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$agentUsage\n');
    return 64;
  } on AgentCommandException catch (error) {
    _writeCommandError(errorOutput, error, arguments);
    return 1;
  } on Object catch (error) {
    _writeCommandError(
      errorOutput,
      AgentCommandException('AGENT_ERROR', _errorText(error)),
      arguments,
    );
    return 1;
  } finally {
    await client?.close();
  }
}

final class AgentCliInvocation {
  const AgentCliInvocation({
    required this.action,
    required this.agentId,
    required this.includeArchived,
    required this.global,
    required this.labels,
    required this.thinking,
    required this.host,
    required this.format,
    required this.quiet,
    required this.headers,
  });

  final String action;
  final String? agentId;
  final bool includeArchived;
  final bool global;
  final List<String> labels;
  final String? thinking;
  final String? host;
  final String format;
  final bool quiet;
  final bool headers;

  static AgentCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing agent action');
    }
    final action = arguments.first;
    if (!const {'ls', 'inspect'}.contains(action)) {
      throw FormatException('Unknown agent action: $action');
    }
    final positionals = <String>[];
    final labels = <String>[];
    var includeArchived = false;
    var global = false;
    String? thinking;
    String? host;
    var format = 'table';
    var quiet = false;
    var headers = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '-a' || '--all':
          _onlyList(action, argument);
          includeArchived = true;
        case '-g' || '--global':
          _onlyList(action, argument);
          global = true;
        case '-ag' || '-ga':
          _onlyList(action, argument);
          includeArchived = true;
          global = true;
        case '--label':
          _onlyList(action, argument);
          labels.add(_requiredValue(arguments, ++index, argument));
        case '--thinking':
          _onlyList(action, argument);
          thinking = _requiredValue(arguments, ++index, argument);
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
      throw const FormatException('agent ls does not accept an argument');
    }
    if (action == 'inspect' &&
        (positionals.length != 1 || positionals.single.trim().isEmpty)) {
      throw const FormatException('Agent ID is required');
    }
    final normalizedThinking = thinking?.trim();
    return AgentCliInvocation(
      action: action,
      agentId: positionals.firstOrNull?.trim(),
      includeArchived: includeArchived,
      global: global,
      labels: List.unmodifiable(labels),
      thinking: normalizedThinking,
      host: host,
      format: format,
      quiet: quiet,
      headers: headers,
    );
  }
}

Future<_AgentCommandResult> _execute(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
  DateTime now,
) async {
  return switch (invocation.action) {
    'ls' => _listAgents(invocation, request, environment, now),
    'inspect' => _inspectAgent(invocation, request, environment),
    _ => throw StateError('Unhandled agent action'),
  };
}

Future<_AgentCommandResult> _listAgents(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
  DateTime now,
) async {
  if (invocation.thinking != null && invocation.thinking!.isEmpty) {
    throw const AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: [object Object]',
    );
  }
  final labels = _parseLabelFilters(invocation.labels);
  final filter = AgentDirectoryFilter(
    labels: labels,
    includeArchived: invocation.includeArchived ? true : null,
    thinkingOptionId: invocation.thinking,
    hasThinkingOptionId: invocation.thinking != null,
  );
  Map<String, Object?> payload;
  try {
    payload = await request(
      FetchAgentsRequest(
        requestId: _requestId('agent_ls'),
        activeScope: !invocation.global,
        filter: filter.toJson().isEmpty ? null : filter,
      ).toJson(),
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: ${_errorText(error)}',
    );
  }
  final entries = payload['entries'];
  if (entries is! List) {
    throw const AgentCommandException(
      'LIST_AGENTS_FAILED',
      'Failed to list agents: response is missing entries',
    );
  }
  final snapshots = <Map<String, Object?>>[];
  for (final rawEntry in entries) {
    if (rawEntry is! Map) {
      throw const AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: response contains an invalid entry',
      );
    }
    final entry = Map<String, Object?>.from(rawEntry);
    final rawAgent = entry['agent'];
    if (rawAgent is! Map) {
      throw const AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: response entry is missing agent',
      );
    }
    final snapshot = Map<String, Object?>.from(rawAgent);
    try {
      PaseoAgentSnapshotCodec.decode(snapshot);
    } on Object catch (error) {
      throw AgentCommandException(
        'LIST_AGENTS_FAILED',
        'Failed to list agents: ${_errorText(error)}',
      );
    }
    if (!invocation.includeArchived && snapshot['archivedAt'] != null) {
      continue;
    }
    final agentLabels = _mapOrNull(snapshot['labels']) ?? const {};
    if (labels.entries.any((entry) => agentLabels[entry.key] != entry.value)) {
      continue;
    }
    snapshots.add(snapshot);
  }
  snapshots.sort((left, right) {
    final statusComparison =
        _statusOrder(_string(left, 'status')) -
        _statusOrder(_string(right, 'status'));
    if (statusComparison != 0) return statusComparison;
    return _date(right, 'createdAt').compareTo(_date(left, 'createdAt'));
  });
  return _AgentCommandResult.list([
    for (final snapshot in snapshots) _agentListRow(snapshot, environment, now),
  ]);
}

Future<_AgentCommandResult> _inspectAgent(
  AgentCliInvocation invocation,
  AgentRpcRequester request,
  Map<String, String> environment,
) async {
  Map<String, Object?> payload;
  try {
    payload = await request(
      FetchAgentRequest(
        requestId: _requestId('agent_inspect'),
        agentId: invocation.agentId!,
      ).toJson(),
    );
  } on Object catch (error) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: ${_errorText(error)}',
    );
  }
  final responseError = payload['error'];
  if (responseError is String && responseError.isNotEmpty) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: $responseError',
    );
  }
  final rawAgent = payload['agent'];
  if (rawAgent == null) {
    throw AgentCommandException(
      'AGENT_NOT_FOUND',
      'Agent not found: ${invocation.agentId}',
      details: 'Use "coding-agent ls" to list available agents',
    );
  }
  if (rawAgent is! Map) {
    throw const AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: response contains an invalid agent',
    );
  }
  final snapshot = Map<String, Object?>.from(rawAgent);
  try {
    PaseoAgentSnapshotCodec.decode(snapshot);
  } on Object catch (error) {
    throw AgentCommandException(
      'INSPECT_FAILED',
      'Failed to inspect agent: ${_errorText(error)}',
    );
  }
  final data = _agentInspectData(snapshot);
  return _AgentCommandResult.inspect(
    rows: _agentInspectRows(data, environment),
    structured: data,
  );
}

Map<String, Object?> _agentListRow(
  Map<String, Object?> snapshot,
  Map<String, String> environment,
  DateTime now,
) {
  final id = _string(snapshot, 'id');
  final runtimeInfo = _mapOrNull(snapshot['runtimeInfo']);
  final model =
      _normalizeModel(runtimeInfo?['model']) ??
      _normalizeModel(snapshot['model']);
  final provider = _string(snapshot, 'provider');
  return {
    'id': id,
    'shortId': id.substring(0, id.length < 7 ? id.length : 7),
    'name': _nullableString(snapshot['title']) ?? '-',
    'provider': model == null ? provider : '$provider/$model',
    'thinking':
        _nullableString(snapshot['effectiveThinkingOptionId']) ?? 'auto',
    'status': _string(snapshot, 'status'),
    'cwd': _shortenPath(_string(snapshot, 'cwd'), environment),
    'created': _relativeTime(_date(snapshot, 'createdAt'), now),
  };
}

Map<String, Object?> _agentInspectData(Map<String, Object?> snapshot) {
  final runtimeInfo = _mapOrNull(snapshot['runtimeInfo']);
  final model =
      _normalizeModel(runtimeInfo?['model']) ??
      _normalizeModel(snapshot['model']);
  final usage = _mapOrNull(snapshot['lastUsage']);
  final capabilities = _mapOrNull(snapshot['capabilities']);
  final modes = snapshot['availableModes'];
  final pending = snapshot['pendingPermissions'];
  final labels = _mapOrNull(snapshot['labels']) ?? const {};
  return {
    'Id': _string(snapshot, 'id'),
    'Name': _nullableString(snapshot['title']) ?? '-',
    'Provider': _string(snapshot, 'provider'),
    'Model': model ?? '-',
    'Thinking':
        _nullableString(snapshot['effectiveThinkingOptionId']) ?? 'auto',
    'Status': _string(snapshot, 'status'),
    'Archived': snapshot['archivedAt'] != null,
    'ArchivedAt': snapshot['archivedAt'],
    'Mode': _nullableString(snapshot['currentModeId']) ?? 'default',
    'Cwd': _string(snapshot, 'cwd'),
    'CreatedAt': _string(snapshot, 'createdAt'),
    'UpdatedAt': _string(snapshot, 'updatedAt'),
    'LastUsage': usage == null
        ? null
        : {
            'InputTokens': _intOrZero(usage['inputTokens']),
            'OutputTokens': _intOrZero(usage['outputTokens']),
            'CachedTokens': _intOrZero(usage['cachedInputTokens']),
            'CostUsd': _numOrZero(usage['totalCostUsd']),
          },
    'Capabilities': capabilities == null
        ? null
        : {
            'Streaming': capabilities['supportsStreaming'] == true,
            'Persistence': capabilities['supportsSessionPersistence'] == true,
            'DynamicModes': capabilities['supportsDynamicModes'] == true,
            'McpServers': capabilities['supportsMcpServers'] == true,
          },
    'AvailableModes': modes is! List
        ? null
        : [
            for (final rawMode in modes)
              if (rawMode is Map)
                {
                  'id': _string(Map<String, Object?>.from(rawMode), 'id'),
                  'label': _string(Map<String, Object?>.from(rawMode), 'label'),
                },
          ],
    'PendingPermissions': pending is! List
        ? <Object?>[]
        : [
            for (final rawPermission in pending)
              if (rawPermission is Map)
                {
                  'id': _string(Map<String, Object?>.from(rawPermission), 'id'),
                  'tool':
                      _nullableString(
                        Map<String, Object?>.from(rawPermission)['name'],
                      ) ??
                      'unknown',
                },
          ],
    'Worktree': _nullableString(labels['paseo.worktree']),
    'ParentAgentId': _nullableString(labels[paseoParentAgentIdLabel]),
  };
}

List<Map<String, Object?>> _agentInspectRows(
  Map<String, Object?> data,
  Map<String, String> environment,
) {
  final rows = <Map<String, Object?>>[
    for (final key in const [
      'Id',
      'Name',
      'Provider',
      'Model',
      'Thinking',
      'Status',
      'Archived',
      'ArchivedAt',
      'Mode',
      'Cwd',
      'CreatedAt',
      'UpdatedAt',
    ])
      {
        'key': key,
        'value': switch (key) {
          'Cwd' => _shortenPath('${data[key]}', environment),
          _ => data[key]?.toString() ?? 'null',
        },
      },
  ];
  if (data['LastUsage'] case final Map usage) {
    final cost = (usage['CostUsd'] as num).toDouble();
    rows.add({
      'key': 'LastUsage',
      'value':
          'InputTokens: ${usage['InputTokens']}, '
          'OutputTokens: ${usage['OutputTokens']}, '
          'CachedTokens: ${usage['CachedTokens']}, '
          'CostUsd: ${_formatCost(cost)}',
    });
  }
  if (data['Capabilities'] case final Map capabilities) {
    rows.add({
      'key': 'Capabilities',
      'value':
          'Streaming: ${capabilities['Streaming']}, '
          'Persistence: ${capabilities['Persistence']}, '
          'DynamicModes: ${capabilities['DynamicModes']}, '
          'McpServers: ${capabilities['McpServers']}',
    });
  }
  final modes = data['AvailableModes'];
  if (modes is List && modes.isNotEmpty) {
    rows.add({
      'key': 'AvailableModes',
      'value': modes
          .whereType<Map>()
          .map((mode) => '${mode['id']} (${mode['label']})')
          .join(', '),
    });
  }
  final permissions = (data['PendingPermissions'] as List).whereType<Map>();
  rows.add({
    'key': 'PendingPermissions',
    'value': permissions.isEmpty
        ? '[]'
        : permissions
              .map(
                (permission) => '${permission['id']} (${permission['tool']})',
              )
              .join(', '),
  });
  rows.add({
    'key': 'Worktree',
    'value': data['Worktree']?.toString() ?? 'null',
  });
  rows.add({
    'key': 'ParentAgentId',
    'value': data['ParentAgentId']?.toString() ?? 'null',
  });
  return rows;
}

final class _AgentCommandResult {
  const _AgentCommandResult._({
    required this.rows,
    required this.inspect,
    required this.structured,
  });

  factory _AgentCommandResult.list(List<Map<String, Object?>> rows) =>
      _AgentCommandResult._(
        rows: List.unmodifiable(rows),
        inspect: false,
        structured: null,
      );

  factory _AgentCommandResult.inspect({
    required List<Map<String, Object?>> rows,
    required Map<String, Object?> structured,
  }) => _AgentCommandResult._(
    rows: List.unmodifiable(rows),
    inspect: true,
    structured: Map.unmodifiable(structured),
  );

  final List<Map<String, Object?>> rows;
  final bool inspect;
  final Map<String, Object?>? structured;
}

String _render(_AgentCommandResult result, AgentCliInvocation invocation) {
  if (invocation.quiet) {
    final field = result.inspect ? 'key' : 'shortId';
    return result.rows.map((row) => row[field]).join('\n') +
        (result.rows.isEmpty ? '' : '\n');
  }
  final structured = result.structured ?? result.rows;
  if (invocation.format == 'json') {
    return '${const JsonEncoder.withIndent('  ').convert(structured)}\n';
  }
  if (invocation.format == 'yaml') {
    return structured is Map
        ? _yamlMap(structured.cast<String, Object?>())
        : _yamlList(result.rows);
  }
  if (result.rows.isEmpty) return '';
  final columns = result.inspect
      ? const [('KEY', 'key', 3), ('VALUE', 'value', 5)]
      : const [
          ('AGENT ID', 'shortId', 12),
          ('NAME', 'name', 20),
          ('PROVIDER', 'provider', 15),
          ('THINKING', 'thinking', 12),
          ('STATUS', 'status', 10),
          ('CWD', 'cwd', 30),
          ('CREATED', 'created', 15),
        ];
  final widths = [
    for (final column in columns)
      [
        column.$1.length,
        column.$3,
        for (final row in result.rows) '${row[column.$2] ?? ''}'.length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return [
        if (invocation.headers) line([for (final column in columns) column.$1]),
        for (final row in result.rows)
          line([for (final column in columns) '${row[column.$2] ?? ''}']),
      ].join('\n') +
      (invocation.headers || result.rows.isNotEmpty ? '\n' : '');
}

Map<String, String> _parseLabelFilters(List<String> labels) {
  final result = <String, String>{};
  for (final label in labels) {
    final separator = label.indexOf('=');
    if (separator >= 0) {
      result[label.substring(0, separator)] = label.substring(separator + 1);
    }
  }
  return result;
}

int _statusOrder(String status) => switch (status) {
  'running' => 0,
  'idle' => 1,
  _ => 999,
};

String _relativeTime(DateTime value, DateTime now) {
  final seconds = now.difference(value.toUtc()).inSeconds;
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return '${seconds ~/ 60} minutes ago';
  if (seconds < 86400) return '${seconds ~/ 3600} hours ago';
  return '${seconds ~/ 86400} days ago';
}

String _shortenPath(String path, Map<String, String> environment) {
  final home = environment['HOME'];
  if (home != null && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

String? _normalizeModel(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.toLowerCase() == 'default') return null;
  return normalized;
}

String _formatCost(double cost) {
  if (cost == 0) return r'$0.00';
  if (cost < 0.01) return '\$${cost.toStringAsFixed(4)}';
  return '\$${cost.toStringAsFixed(2)}';
}

String _yamlList(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return '[]\n';
  return '${[
    for (final row in rows) ['- ${row.entries.first.key}: ${_yamlScalar(row.entries.first.value)}', for (final entry in row.entries.skip(1)) '  ${entry.key}: ${_yamlScalar(entry.value)}'].join('\n'),
  ].join('\n')}\n';
}

String _yamlMap(Map<String, Object?> map, [int indent = 0]) {
  final prefix = ' ' * indent;
  final lines = <String>[];
  for (final entry in map.entries) {
    final value = entry.value;
    if (value is Map) {
      lines
        ..add('$prefix${entry.key}:')
        ..add(
          _yamlMap(Map<String, Object?>.from(value), indent + 2).trimRight(),
        );
    } else if (value is List) {
      if (value.isEmpty) {
        lines.add('$prefix${entry.key}: []');
      } else {
        lines.add('$prefix${entry.key}:');
        for (final item in value) {
          if (item is Map) {
            final itemMap = Map<String, Object?>.from(item);
            final first = itemMap.entries.first;
            lines.add(
              '${' ' * (indent + 2)}- ${first.key}: '
              '${_yamlScalar(first.value)}',
            );
            for (final nested in itemMap.entries.skip(1)) {
              lines.add(
                '${' ' * (indent + 4)}${nested.key}: '
                '${_yamlScalar(nested.value)}',
              );
            }
          } else {
            lines.add('${' ' * (indent + 2)}- ${_yamlScalar(item)}');
          }
        }
      }
    } else {
      lines.add('$prefix${entry.key}: ${_yamlScalar(value)}');
    }
  }
  return '${lines.join('\n')}\n';
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

void _writeCommandError(
  void Function(String value) write,
  AgentCommandException error,
  List<String> arguments,
) {
  final json = arguments.contains('--json');
  final yaml =
      !json &&
      (arguments.contains('yaml') &&
          (arguments.contains('--format') || arguments.contains('-o')));
  if (json) {
    write(
      '${const JsonEncoder.withIndent('  ').convert({
        'error': {'code': error.code, 'message': error.message, if (error.details != null) 'details': error.details},
      })}\n',
    );
  } else if (yaml) {
    write(
      _yamlMap({
        'error': {
          'code': error.code,
          'message': error.message,
          if (error.details != null) 'details': error.details,
        },
      }),
    );
  } else {
    write(
      'Error: ${error.message}\n'
      '${error.details == null ? '' : '${error.details}\n'}',
    );
  }
}

void _onlyList(String action, String option) {
  if (action != 'ls') {
    throw FormatException('$option is only valid for agent ls');
  }
}

String _requiredValue(List<String> arguments, int index, String option) {
  if (index >= arguments.length) {
    throw FormatException('$option requires a value');
  }
  return arguments[index];
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

String? _nullableString(Object? value) => value is String ? value : null;

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

DateTime _date(Map<String, Object?> json, String key) {
  final parsed = DateTime.tryParse(_string(json, key));
  if (parsed == null) throw FormatException('$key must be an ISO timestamp');
  return parsed;
}

int _intOrZero(Object? value) => value is num ? value.toInt() : 0;

num _numOrZero(Object? value) => value is num ? value : 0;

String _requestId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}';

String _errorText(Object error) => switch (error) {
  FormatException(message: final message) => message,
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class AgentCommandException implements Exception {
  const AgentCommandException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final String? details;
}

const agentUsage =
    'Usage: coding-agent agent ls [options]\n'
    '       coding-agent agent inspect <id> [options]\n'
    '       coding-agent ls [options]\n'
    '       coding-agent inspect <id> [options]';

String _agentHelp(String? action) => switch (action) {
  'ls' =>
    'Usage: coding-agent agent ls [options]\n'
        'List agents. By default excludes archived agents.\n',
  'inspect' =>
    'Usage: coding-agent agent inspect [options] <id>\n'
        'Show detailed information about an agent\n',
  _ =>
    'Usage: coding-agent agent [command]\n'
        'Manage agents (advanced operations)\n\n'
        'Commands:\n'
        '  ls       List agents\n'
        '  inspect  Show detailed information about an agent\n'
        '  logs     View agent activity/timeline\n',
};
