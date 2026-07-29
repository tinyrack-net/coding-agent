import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'schedule_command.dart';

typedef HeartbeatRpcRequester = ScheduleRpcRequester;

Future<int> runHeartbeatCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  HeartbeatRpcRequester? request,
  DateTime Function()? now,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (_hasOptionBeforeTerminator(arguments, const {'--help', '-h'})) {
    output(heartbeatHelp(arguments.isEmpty ? null : arguments.first));
    return 0;
  }
  final jsonOutput = _hasOptionBeforeTerminator(arguments, const {'--json'});
  try {
    final invocation = HeartbeatCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    final agentId = _requireCallerAgentId(env);
    if (invocation.action != 'delete') _requireCron(invocation);

    ScheduleRpcClient? client;
    if (request == null) {
      final config = loadDaemonRuntimeConfig(environment: env);
      try {
        client = await connectScheduleRpcClient(
          config,
          hostOverride: invocation.host,
          environment: env,
        );
      } on Object catch (error) {
        final host =
            invocation.host ??
            env['TINYRACK_HOST'] ??
            '${config.host}:${config.port}';
        throw ScheduleCommandException(
          'DAEMON_NOT_RUNNING',
          'Cannot connect to daemon at $host: ${_errorText(error)}',
          'Start the daemon with: coding-agent daemon start',
        );
      }
    }

    try {
      final result = await _executeHeartbeat(
        invocation,
        request ?? client!.request,
        agentId,
        now ?? DateTime.now,
      );
      output(
        invocation.json
            ? '${const JsonEncoder.withIndent('  ').convert(result.json)}\n'
            : result.human,
      );
      return 0;
    } finally {
      await client?.close();
    }
  } on ScheduleCommandException catch (error) {
    _writeHeartbeatError(errorOutput, error, json: jsonOutput);
    return 1;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$_heartbeatUsage\n');
    return 64;
  } on Object catch (error) {
    _writeHeartbeatError(
      errorOutput,
      ScheduleCommandException('UNKNOWN_ERROR', _errorText(error)),
      json: jsonOutput,
    );
    return 1;
  }
}

final class HeartbeatCliInvocation {
  const HeartbeatCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.flags,
    required this.json,
    required this.host,
  });

  final String action;
  final List<String> positionals;
  final Map<String, String> values;
  final Set<String> flags;
  final bool json;
  final String? host;

  static HeartbeatCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const FormatException('Missing heartbeat action');
    }
    const actions = {'create', 'update', 'delete'};
    final action = arguments.first;
    if (!actions.contains(action)) {
      throw FormatException('Unknown heartbeat action: $action');
    }
    final valueOptions = {
      '--host',
      if (action != 'delete') ...{'--cron', '--timezone'},
      if (action == 'create') ...{'--name', '--max-runs', '--expires-in'},
    };
    final positionals = <String>[];
    final values = <String, String>{};
    final flags = <String>{};
    var positionalOnly = false;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly && argument == '--') {
        positionalOnly = true;
      } else if (positionalOnly) {
        positionals.add(argument);
      } else if (argument == '--json') {
        flags.add(argument);
      } else if (valueOptions.contains(argument)) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        values[argument] = arguments[++index];
      } else if (_splitLongOption(argument) case (
        final option,
        final value,
      ) when valueOptions.contains(option)) {
        values[option] = value;
      } else if (argument.startsWith('-')) {
        throw FormatException('Unknown option: $argument');
      } else {
        positionals.add(argument);
      }
    }
    if (positionals.length != 1) {
      throw FormatException(
        action == 'create'
            ? 'heartbeat create requires one prompt'
            : 'heartbeat $action requires one heartbeat id',
      );
    }
    return HeartbeatCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      flags: Set.unmodifiable(flags),
      json: flags.contains('--json'),
      host: values['--host'],
    );
  }
}

final class _HeartbeatResult {
  const _HeartbeatResult({required this.json, required this.human});

  final Object? json;
  final String human;
}

Future<_HeartbeatResult> _executeHeartbeat(
  HeartbeatCliInvocation invocation,
  HeartbeatRpcRequester request,
  String agentId,
  DateTime Function() now,
) async {
  final requestId = 'heartbeat_${DateTime.now().microsecondsSinceEpoch}';
  try {
    switch (invocation.action) {
      case 'create':
        final maxRuns = _parseMaxRuns(invocation.values['--max-runs']);
        final expiresIn = invocation.values['--expires-in'];
        final message = <String, Object?>{
          'type': ScheduleCreateRequest.type,
          'requestId': requestId,
          'prompt': invocation.positionals.single.trim(),
          'cadence': _heartbeatCadence(invocation),
          'target': {'type': 'agent', 'agentId': agentId},
          if (invocation.values['--name']?.trim().isNotEmpty == true)
            'name': invocation.values['--name']!.trim(),
          if (maxRuns != null) 'maxRuns': maxRuns,
          if (expiresIn != null && expiresIn.isNotEmpty)
            'expiresAt': _isoMilliseconds(
              now().toUtc().add(
                Duration(milliseconds: _parseDuration(expiresIn)),
              ),
            ),
        };
        final schedule = _requiredSchedule(await request(message));
        return _heartbeatScheduleResult(schedule);
      case 'update':
        final id = invocation.positionals.single;
        await _requireOwnedHeartbeat(
          request,
          id,
          agentId,
          '${requestId}_inspect',
        );
        final schedule = _requiredSchedule(
          await request({
            'type': ScheduleUpdateRequest.type,
            'requestId': requestId,
            'scheduleId': id,
            'cadence': _heartbeatCadence(invocation),
          }),
          notFound: 'Heartbeat update failed: $id',
        );
        return _heartbeatScheduleResult(schedule);
      case 'delete':
        final id = invocation.positionals.single;
        await _requireOwnedHeartbeat(
          request,
          id,
          agentId,
          '${requestId}_inspect',
        );
        final payload = await request({
          'type': ScheduleIdRequest.deleteType,
          'requestId': requestId,
          'scheduleId': id,
        });
        _throwPayloadError(payload);
        final row = {'id': payload['scheduleId'], 'status': 'deleted'};
        return _HeartbeatResult(json: row, human: _deleteTable(row));
    }
    throw StateError('Unhandled heartbeat action');
  } on ScheduleCommandException {
    rethrow;
  } on Object catch (error) {
    final (code, action) = switch (invocation.action) {
      'create' => ('HEARTBEAT_CREATE_FAILED', 'create heartbeat'),
      'update' => ('HEARTBEAT_UPDATE_FAILED', 'update heartbeat'),
      _ => ('HEARTBEAT_DELETE_FAILED', 'delete heartbeat'),
    };
    throw ScheduleCommandException(
      code,
      'Failed to $action: ${_errorText(error)}',
    );
  }
}

String _requireCallerAgentId(Map<String, String> environment) {
  for (final key in const ['TINYRACK_AGENT_ID', 'PASEO_AGENT_ID']) {
    final value = environment[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  throw StateError('Heartbeat commands must run inside a Tinyrack agent');
}

void _requireCron(HeartbeatCliInvocation invocation) {
  if (invocation.values['--cron']?.trim().isEmpty ?? true) {
    throw StateError('--cron is required');
  }
}

Map<String, Object?> _heartbeatCadence(HeartbeatCliInvocation invocation) => {
  'type': 'cron',
  'expression': invocation.values['--cron']!.trim(),
  if (invocation.values['--timezone']?.trim().isNotEmpty == true)
    'timezone': invocation.values['--timezone']!.trim(),
};

Future<void> _requireOwnedHeartbeat(
  HeartbeatRpcRequester request,
  String id,
  String agentId,
  String requestId,
) async {
  final schedule = _requiredSchedule(
    await request({
      'type': ScheduleIdRequest.inspectType,
      'requestId': requestId,
      'scheduleId': id,
    }),
    notFound: 'Heartbeat not found: $id',
  );
  final target = schedule['target'];
  if (target is! Map ||
      target['type'] != 'agent' ||
      target['agentId'] != agentId) {
    throw StateError('Heartbeat $id does not belong to agent $agentId');
  }
}

Map<String, Object?> _requiredSchedule(
  Map<String, Object?> payload, {
  String notFound = 'Heartbeat creation failed',
}) {
  _throwPayloadError(payload);
  final schedule = payload['schedule'];
  if (schedule is! Map) throw StateError(notFound);
  return Map<String, Object?>.from(schedule);
}

void _throwPayloadError(Map<String, Object?> payload) {
  if (payload['error'] case final String error when error.isNotEmpty) {
    throw StateError(error);
  }
}

_HeartbeatResult _heartbeatScheduleResult(Map<String, Object?> schedule) =>
    _HeartbeatResult(
      json: scheduleCliRow(schedule),
      human: scheduleCliTable([schedule]),
    );

int? _parseMaxRuns(String? value) {
  if (value == null || value.isEmpty) return null;
  final match = RegExp(r'^[\s]*([+-]?\d+)').firstMatch(value);
  final parsed = match == null ? null : int.tryParse(match.group(1)!);
  if (parsed == null || parsed <= 0 || parsed > 9007199254740991) {
    throw StateError('--max-runs must be a positive integer');
  }
  return parsed;
}

int _parseDuration(String input) {
  final value = input.trim();
  if (RegExp(r'^\d+$').hasMatch(value)) return int.parse(value) * 1000;
  if (!RegExp(r'^(?:\d+[smhd])+$').hasMatch(value)) {
    throw StateError(
      'Invalid duration format: $input. '
      'Use formats like: 5m, 30s, 1h, 2h30m, 1d',
    );
  }
  var total = 0;
  for (final match in RegExp(r'(\d+)([smhd])').allMatches(value)) {
    final amount = int.parse(match.group(1)!);
    total +=
        amount *
        switch (match.group(2)) {
          's' => 1000,
          'm' => 60 * 1000,
          'h' => 60 * 60 * 1000,
          _ => 24 * 60 * 60 * 1000,
        };
  }
  return total;
}

String _isoMilliseconds(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

String _deleteTable(Map<String, Object?> row) => _table(
  const ['ID', 'STATUS'],
  [
    ['${row['id'] ?? ''}', '${row['status'] ?? ''}'],
  ],
  minimumWidths: const [10, 12],
);

String _table(
  List<String> headers,
  List<List<String>> rows, {
  required List<int> minimumWidths,
}) {
  final widths = [
    for (var column = 0; column < headers.length; column++)
      [
        headers[column].length,
        minimumWidths[column],
        for (final row in rows) row[column].length,
      ].reduce((left, right) => left > right ? left : right),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ');
  return '${[line(headers), for (final row in rows) line(row)].join('\n')}\n';
}

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

void _writeHeartbeatError(
  void Function(String value) write,
  ScheduleCommandException error, {
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
  write(
    'Error: ${error.message}'
    '${error.details == null ? '' : '\n${error.details}'}\n',
  );
}

String heartbeatHelp(String? action) => switch (action) {
  'create' =>
    'Usage: coding-agent heartbeat create <prompt> [options]\n'
        'Create a recurring prompt for this agent\n\n'
        'Options:\n'
        '  --cron <expr>           Five-field cron cadence (required)\n'
        '  --timezone <iana>       IANA time zone\n'
        '  --name <name>           Heartbeat name\n'
        '  --max-runs <n>          Maximum number of runs\n'
        '  --expires-in <duration> Time to live\n'
        '  --host <host>           Daemon host target\n'
        '  --json                  Output in JSON format\n',
  'update' =>
    'Usage: coding-agent heartbeat update <id> [options]\n'
        'Change a heartbeat cron cadence\n\n'
        'Options:\n'
        '  --cron <expr>           Five-field cron cadence (required)\n'
        '  --timezone <iana>       IANA time zone\n'
        '  --host <host>           Daemon host target\n'
        '  --json                  Output in JSON format\n',
  'delete' =>
    'Usage: coding-agent heartbeat delete <id> [options]\n'
        'Delete a heartbeat\n\n'
        'Options:\n'
        '  --host <host>           Daemon host target\n'
        '  --json                  Output in JSON format\n',
  _ =>
    'Usage: coding-agent heartbeat <command> [options]\n'
        "Manage this agent's heartbeats\n\n"
        'Commands: create, update, delete\n',
};

bool _hasOptionBeforeTerminator(List<String> arguments, Set<String> options) {
  for (final argument in arguments) {
    if (argument == '--') return false;
    if (options.contains(argument)) return true;
  }
  return false;
}

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

const _heartbeatUsage =
    'Usage: coding-agent heartbeat <create|update|delete> ...';
