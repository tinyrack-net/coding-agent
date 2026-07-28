import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'provider_model.dart';

const scheduleDaemonRpcTimeout = Duration(seconds: 30);

typedef ScheduleRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

Future<int> runScheduleCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  ScheduleRpcRequester? request,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  try {
    final parsed = ScheduleCliInvocation.parse(arguments);
    final client = request == null
        ? await _ScheduleSocketClient.connect(
            loadDaemonRuntimeConfig(
              environment: environment ?? Platform.environment,
            ),
            hostOverride: parsed.host,
            environment: environment ?? Platform.environment,
          )
        : null;
    final send = request ?? client!.request;
    try {
      final result = await _execute(
        parsed,
        send,
        currentDirectory ?? Directory.current.path,
        environment ?? Platform.environment,
      );
      output(
        parsed.json
            ? '${const JsonEncoder.withIndent('  ').convert(result.json)}\n'
            : result.human,
      );
      return 0;
    } finally {
      await client?.close();
    }
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$_scheduleUsage\n');
    return 64;
  } on Object catch (error) {
    errorOutput('Schedule command failed: ${_errorText(error)}\n');
    return 1;
  }
}

final class ScheduleCliInvocation {
  const ScheduleCliInvocation({
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

  static ScheduleCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty)
      throw const FormatException('Missing schedule action');
    const actions = {
      'create',
      'ls',
      'inspect',
      'logs',
      'pause',
      'resume',
      'delete',
      'run-once',
      'update',
    };
    final action = arguments.first;
    if (!actions.contains(action)) {
      throw FormatException('Unknown schedule action: $action');
    }
    const booleanOptions = {
      '--json',
      '--run-now',
      '--no-max-runs',
      '--no-expires-in',
    };
    const valueOptions = {
      '--host',
      '--every',
      '--cron',
      '--timezone',
      '--name',
      '--target',
      '--provider',
      '--model',
      '--mode',
      '--cwd',
      '--max-runs',
      '--expires-in',
      '--prompt',
    };
    final positionals = <String>[];
    final values = <String, String>{};
    final flags = <String>{};
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (booleanOptions.contains(argument)) {
        flags.add(argument);
      } else if (valueOptions.contains(argument)) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        values[argument] = arguments[++index];
      } else if (argument.startsWith('-')) {
        throw FormatException('Unknown option: $argument');
      } else {
        positionals.add(argument);
      }
    }
    final expected = switch (action) {
      'ls' => 0,
      _ => 1,
    };
    if (positionals.length != expected) {
      throw FormatException(
        action == 'create'
            ? 'schedule create requires one prompt'
            : action == 'ls'
            ? 'schedule ls does not accept an argument'
            : 'schedule $action requires one schedule id',
      );
    }
    return ScheduleCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      flags: Set.unmodifiable(flags),
      json: flags.contains('--json'),
      host: values['--host'],
    );
  }
}

final class _ScheduleCommandResult {
  const _ScheduleCommandResult({required this.json, required this.human});
  final Object? json;
  final String human;
}

Future<_ScheduleCommandResult> _execute(
  ScheduleCliInvocation invocation,
  ScheduleRpcRequester request,
  String cwd,
  Map<String, String> environment,
) async {
  final requestId = 'schedule_${DateTime.now().microsecondsSinceEpoch}';
  switch (invocation.action) {
    case 'create':
      final message = _createRequest(invocation, requestId, cwd, environment);
      final payload = await request(message);
      final schedule = _requiredSchedule(payload);
      return _scheduleResult(schedule);
    case 'ls':
      final payload = await request({
        'type': ScheduleListRequest.type,
        'requestId': requestId,
      });
      _throwPayloadError(payload);
      final schedules = _mapList(
        payload['schedules'],
      ).where(_isNewAgentSchedule).toList(growable: false);
      return _ScheduleCommandResult(
        json: schedules,
        human: _scheduleTable(schedules),
      );
    case 'inspect':
      final schedule = await _inspectNewAgent(
        request,
        invocation.positionals.single,
        requestId,
      );
      return _ScheduleCommandResult(
        json: schedule,
        human: _inspectTable(schedule),
      );
    case 'logs':
      final id = invocation.positionals.single;
      await _inspectNewAgent(request, id, '${requestId}_inspect');
      final payload = await request({
        'type': ScheduleIdRequest.logsType,
        'requestId': requestId,
        'scheduleId': id,
      });
      _throwPayloadError(payload);
      final runs = _mapList(payload['runs']);
      return _ScheduleCommandResult(json: runs, human: _logsTable(runs));
    case 'delete':
      final id = invocation.positionals.single;
      await _inspectNewAgent(request, id, '${requestId}_inspect');
      final payload = await request({
        'type': ScheduleIdRequest.deleteType,
        'requestId': requestId,
        'scheduleId': id,
      });
      _throwPayloadError(payload);
      final row = {'id': payload['scheduleId'], 'status': 'deleted'};
      return _ScheduleCommandResult(
        json: row,
        human: _table(
          const ['ID', 'STATUS'],
          [
            [row['id']?.toString() ?? '', 'deleted'],
          ],
        ),
      );
    case 'pause':
    case 'resume':
    case 'run-once':
      final id = invocation.positionals.single;
      await _inspectNewAgent(request, id, '${requestId}_inspect');
      final type = switch (invocation.action) {
        'pause' => ScheduleIdRequest.pauseType,
        'resume' => ScheduleIdRequest.resumeType,
        _ => ScheduleIdRequest.runOnceType,
      };
      final payload = await request({
        'type': type,
        'requestId': requestId,
        'scheduleId': id,
      });
      return _scheduleResult(_requiredSchedule(payload));
    case 'update':
      final id = invocation.positionals.single;
      await _inspectNewAgent(request, id, '${requestId}_inspect');
      final payload = await request(_updateRequest(invocation, requestId, id));
      final schedule = _requiredSchedule(payload);
      return _ScheduleCommandResult(
        json: schedule,
        human: _inspectTable(schedule),
      );
  }
  throw StateError('Unhandled schedule action');
}

Map<String, Object?> _createRequest(
  ScheduleCliInvocation invocation,
  String requestId,
  String cwd,
  Map<String, String> environment,
) {
  final prompt = invocation.positionals.single.trim();
  if (prompt.isEmpty)
    throw const FormatException('Schedule prompt cannot be empty');
  final cadence = _cadence(invocation, required: true)!;
  final cwdOption = invocation.values['--cwd']?.trim();
  if (invocation.host != null && (cwdOption == null || cwdOption.isEmpty)) {
    throw const FormatException('--cwd is required when --host is specified');
  }
  final targetValue = invocation.values['--target']?.trim();
  final explicitNewAgentOption =
      invocation.values.containsKey('--provider') ||
      invocation.values.containsKey('--mode');
  if (targetValue != null &&
      targetValue != 'new-agent' &&
      explicitNewAgentOption) {
    throw const FormatException(
      '--provider/--mode can only be used with a new-agent target',
    );
  }
  final target = switch (targetValue) {
    null || '' || 'new-agent' => () {
      final providerModel = resolveProviderAndModel(
        provider: invocation.values['--provider'],
      );
      return <String, Object?>{
        'type': 'new-agent',
        'config': <String, Object?>{
          'provider': providerModel.provider,
          'cwd': cwdOption?.isNotEmpty == true ? cwdOption : cwd,
          if (providerModel.model != null) 'model': providerModel.model,
          if (invocation.values['--mode']?.trim().isNotEmpty == true)
            'modeId': invocation.values['--mode']!.trim(),
        },
      };
    }(),
    'self' => {
      'type': 'self',
      'agentId':
          environment['TINYRACK_AGENT_ID']?.trim() ??
          environment['PASEO_AGENT_ID']?.trim() ??
          (throw const FormatException(
            '--target self requires running inside an agent',
          )),
    },
    final value => {'type': 'agent', 'agentId': value},
  };
  final maxRuns = _positiveIntOption(
    invocation.values['--max-runs'],
    '--max-runs',
  );
  final expiresIn = invocation.values['--expires-in'];
  return {
    'type': ScheduleCreateRequest.type,
    'requestId': requestId,
    'prompt': prompt,
    'cadence': cadence.toJson(),
    'target': target,
    'runOnCreate': invocation.flags.contains('--run-now'),
    if (invocation.values['--name']?.trim().isNotEmpty == true)
      'name': invocation.values['--name']!.trim(),
    if (maxRuns != null) 'maxRuns': maxRuns,
    if (expiresIn != null)
      'expiresAt': DateTime.now()
          .toUtc()
          .add(Duration(milliseconds: _parseDuration(expiresIn)))
          .toIso8601String(),
  };
}

Map<String, Object?> _updateRequest(
  ScheduleCliInvocation invocation,
  String requestId,
  String id,
) {
  final result = <String, Object?>{
    'type': ScheduleUpdateRequest.type,
    'requestId': requestId,
    'scheduleId': id,
  };
  if (invocation.values.containsKey('--name')) {
    final name = invocation.values['--name']!.trim();
    result['name'] = name.isEmpty ? null : name;
  }
  if (invocation.values.containsKey('--prompt')) {
    final prompt = invocation.values['--prompt']!.trim();
    if (prompt.isEmpty) throw const FormatException('--prompt cannot be empty');
    result['prompt'] = prompt;
  }
  final cadence = _cadence(invocation, required: false);
  if (cadence != null) result['cadence'] = cadence.toJson();
  final patch = <String, Object?>{};
  if (invocation.values.containsKey('--provider') ||
      invocation.values.containsKey('--model')) {
    final providerModel = resolveProviderAndModel(
      provider: invocation.values['--provider'],
      model: invocation.values['--model'],
    );
    patch['provider'] = providerModel.provider;
    if (providerModel.model != null) patch['model'] = providerModel.model;
  }
  if (invocation.values.containsKey('--mode')) {
    final mode = invocation.values['--mode']!.trim();
    patch['modeId'] = mode.isEmpty ? null : mode;
  }
  if (invocation.values.containsKey('--cwd')) {
    final nextCwd = invocation.values['--cwd']!.trim();
    if (nextCwd.isEmpty) throw const FormatException('--cwd cannot be empty');
    patch['cwd'] = nextCwd;
  }
  if (patch.isNotEmpty) result['newAgentConfig'] = patch;
  if (invocation.values.containsKey('--max-runs') &&
      invocation.flags.contains('--no-max-runs')) {
    throw const FormatException(
      'Use either --max-runs or --no-max-runs, not both',
    );
  }
  if (invocation.flags.contains('--no-max-runs')) {
    result['maxRuns'] = null;
  } else if (invocation.values['--max-runs'] case final value?) {
    result['maxRuns'] = _positiveIntOption(value, '--max-runs');
  }
  if (invocation.values.containsKey('--expires-in') &&
      invocation.flags.contains('--no-expires-in')) {
    throw const FormatException(
      'Use either --expires-in or --no-expires-in, not both',
    );
  }
  if (invocation.flags.contains('--no-expires-in')) {
    result['expiresAt'] = null;
  } else if (invocation.values['--expires-in'] case final value?) {
    result['expiresAt'] = DateTime.now()
        .toUtc()
        .add(Duration(milliseconds: _parseDuration(value)))
        .toIso8601String();
  }
  if (result.length == 3) {
    throw const FormatException('Specify at least one field to update');
  }
  return result;
}

ScheduleCadence? _cadence(
  ScheduleCliInvocation invocation, {
  required bool required,
}) {
  final every = invocation.values['--every'];
  final cron = invocation.values['--cron'];
  final timezone = invocation.values['--timezone']?.trim();
  if (every != null && cron != null) {
    throw const FormatException('Specify at most one of --every or --cron');
  }
  if (timezone != null && cron == null) {
    throw const FormatException('--timezone can only be used with --cron');
  }
  if (every != null) {
    final expression = everyMsToFiveFieldCron(_parseDuration(every));
    if (expression == null) {
      throw FormatException(
        '$every cannot be represented faithfully by five-field cron',
      );
    }
    return CronScheduleCadence(expression: expression);
  }
  if (cron != null) {
    final expression = cron.trim();
    if (expression.isEmpty)
      throw const FormatException('--cron cannot be empty');
    return CronScheduleCadence(
      expression: expression,
      timezone: timezone?.isEmpty == true ? null : timezone,
    );
  }
  if (required) {
    throw const FormatException('Specify exactly one of --every or --cron');
  }
  return null;
}

int _parseDuration(String input) {
  final value = input.trim();
  if (RegExp(r'^\d+$').hasMatch(value)) return int.parse(value) * 1000;
  if (!RegExp(r'^(?:\d+[smhd])+$').hasMatch(value)) {
    throw FormatException(
      'Invalid duration format: $input. Use formats like: 5m, 30s, 1h, 2h30m, 1d',
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

int? _positiveIntOption(String? value, String flag) {
  if (value == null) return null;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw FormatException('$flag must be a positive integer');
  }
  return parsed;
}

Future<Map<String, Object?>> _inspectNewAgent(
  ScheduleRpcRequester request,
  String id,
  String requestId,
) async {
  final payload = await request({
    'type': ScheduleIdRequest.inspectType,
    'requestId': requestId,
    'scheduleId': id,
  });
  final schedule = _requiredSchedule(payload);
  if (!_isNewAgentSchedule(schedule)) {
    throw StateError('Schedule not found: $id');
  }
  return schedule;
}

Map<String, Object?> _requiredSchedule(Map<String, Object?> payload) {
  _throwPayloadError(payload);
  final schedule = payload['schedule'];
  if (schedule is! Map) throw StateError('Schedule not found');
  return Map<String, Object?>.from(schedule);
}

void _throwPayloadError(Map<String, Object?> payload) {
  if (payload['error'] case final String error when error.isNotEmpty) {
    throw StateError(error);
  }
}

List<Map<String, Object?>> _mapList(Object? value) => [
  for (final entry in value is List ? value : const [])
    if (entry is Map) Map<String, Object?>.from(entry),
];

bool _isNewAgentSchedule(Map<String, Object?> schedule) {
  final target = schedule['target'];
  return target is Map && target['type'] == 'new-agent';
}

_ScheduleCommandResult _scheduleResult(Map<String, Object?> schedule) =>
    _ScheduleCommandResult(json: schedule, human: _scheduleTable([schedule]));

String _scheduleTable(List<Map<String, Object?>> schedules) => _table(
  const ['ID', 'NAME', 'CADENCE', 'TARGET', 'STATUS', 'NEXT RUN'],
  [
    for (final schedule in schedules)
      [
        schedule['id']?.toString() ?? '',
        schedule['name']?.toString() ?? '',
        _formatCadence(schedule['cadence']),
        _formatTarget(schedule['target']),
        schedule['status']?.toString() ?? '',
        schedule['nextRunAt']?.toString() ?? '',
      ],
  ],
);

String _inspectTable(Map<String, Object?> schedule) => _table(
  const ['KEY', 'VALUE'],
  [
    ['Id', '${schedule['id']}'],
    ['Name', '${schedule['name']}'],
    ['Prompt', '${schedule['prompt']}'],
    ['Cadence', _formatCadence(schedule['cadence'], inspect: true)],
    ['Target', _formatTarget(schedule['target'])],
    ['Status', '${schedule['status']}'],
    ['CreatedAt', '${schedule['createdAt']}'],
    ['UpdatedAt', '${schedule['updatedAt']}'],
    ['NextRunAt', '${schedule['nextRunAt']}'],
    ['LastRunAt', '${schedule['lastRunAt']}'],
    ['PausedAt', '${schedule['pausedAt']}'],
    ['ExpiresAt', '${schedule['expiresAt']}'],
    ['MaxRuns', '${schedule['maxRuns']}'],
    [
      'RunCount',
      '${schedule['runs'] is List ? (schedule['runs'] as List).length : 0}',
    ],
  ],
);

String _logsTable(List<Map<String, Object?>> runs) => _table(
  const ['RUN ID', 'STATUS', 'STARTED', 'AGENT', 'OUTPUT', 'ERROR'],
  [
    for (final run in runs)
      [
        '${run['id']}',
        '${run['status']}',
        '${run['startedAt']}',
        run['agentId'] == null ? '' : run['agentId'].toString().substring(0, 7),
        run['output']?.toString() ?? '',
        run['error']?.toString() ?? '',
      ],
  ],
);

String _formatCadence(Object? value, {bool inspect = false}) {
  if (value is! Map) return '';
  if (value['type'] == 'cron') {
    final zone = value['timezone'];
    return 'cron:${value['expression']}${zone == null ? '' : ' ($zone)'}';
  }
  return inspect
      ? 'every:${value['everyMs']}ms'
      : 'every:${_formatDuration(value['everyMs'] as int? ?? 0)}';
}

String _formatTarget(Object? value) {
  if (value is! Map) return '';
  if (value['type'] == 'agent' || value['type'] == 'self') {
    final id = '${value['agentId']}';
    return '${value['type']}:${id.substring(0, id.length.clamp(0, 7))}';
  }
  final config = value['config'];
  if (config is! Map) return 'new-agent';
  final model = config['model'];
  return 'new-agent:${config['provider']}${model == null ? '' : '/$model'}';
}

String _formatDuration(int milliseconds) {
  var remaining = milliseconds;
  final parts = <String>[];
  final hours = remaining ~/ (60 * 60 * 1000);
  if (hours > 0) {
    parts.add('${hours}h');
    remaining -= hours * 60 * 60 * 1000;
  }
  final minutes = remaining ~/ (60 * 1000);
  if (minutes > 0) {
    parts.add('${minutes}m');
    remaining -= minutes * 60 * 1000;
  }
  final seconds = remaining ~/ 1000;
  if (seconds > 0 || parts.isEmpty) parts.add('${seconds}s');
  return parts.join();
}

String _table(List<String> headers, List<List<String>> rows) {
  final widths = [
    for (var column = 0; column < headers.length; column++)
      [
        headers[column].length,
        for (final row in rows) row[column].length,
      ].reduce((a, b) => a > b ? a : b),
  ];
  String line(List<String> cells) => [
    for (var index = 0; index < cells.length; index++)
      cells[index].padRight(widths[index]),
  ].join('  ').trimRight();
  return '${[line(headers), for (final row in rows) line(row)].join('\n')}\n';
}

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class _ScheduleSocketClient {
  _ScheduleSocketClient(this._socket, this._frames);

  final WebSocket _socket;
  final StreamIterator<dynamic> _frames;

  static Future<_ScheduleSocketClient> connect(
    DaemonRuntimeConfig config, {
    required String? hostOverride,
    required Map<String, String> environment,
  }) async {
    var host = switch (config.host) {
      '0.0.0.0' || '::' => '127.0.0.1',
      final value => value,
    };
    var port = config.port;
    if (hostOverride != null) {
      final uri = Uri.parse(
        hostOverride.contains('://') ? hostOverride : 'ws://$hostOverride',
      );
      host = uri.host;
      port = uri.hasPort ? uri.port : config.port;
    }
    final password = environment['TINYRACK_PASSWORD']?.trim();
    final socket = await WebSocket.connect(
      Uri(scheme: 'ws', host: host, port: port, path: '/ws').toString(),
      protocols: password == null || password.isEmpty
          ? null
          : ['tinyrack.bearer.$password'],
      compression: CompressionOptions.compressionOff,
    ).timeout(scheduleDaemonRpcTimeout);
    final frames = StreamIterator<dynamic>(socket);
    socket.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'coding-agent-cli',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await _nextMessage(
      frames,
      (message) => message['status'] == 'server_info',
      allowEnvelope: false,
    );
    return _ScheduleSocketClient(socket, frames);
  }

  Future<Map<String, Object?>> request(Map<String, Object?> request) async {
    _socket.add(jsonEncode({'type': 'session', 'message': request}));
    final requestId = request['requestId'];
    final response = await _nextMessage(_frames, (message) {
      final payload = message['payload'];
      return payload is Map && payload['requestId'] == requestId;
    });
    if (response['type'] == 'rpc_error') {
      final payload = response['payload'];
      throw StateError(
        payload is Map
            ? '${payload['error'] ?? 'Schedule RPC failed'}'
            : 'Schedule RPC failed',
      );
    }
    final payload = response['payload'];
    if (payload is! Map) throw StateError('Invalid schedule response');
    return Map<String, Object?>.from(payload);
  }

  Future<void> close() async {
    await _frames.cancel();
    await _socket.close();
  }
}

Future<Map<String, Object?>> _nextMessage(
  StreamIterator<dynamic> frames,
  bool Function(Map<String, Object?> message) predicate, {
  bool allowEnvelope = true,
}) async {
  final deadline = DateTime.now().add(scheduleDaemonRpcTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (!await frames.moveNext().timeout(remaining)) {
      throw StateError('Daemon closed during schedule request');
    }
    final frame = frames.current;
    if (frame is! String) continue;
    final decoded = jsonDecode(frame);
    if (decoded is! Map<String, Object?>) continue;
    final candidate =
        allowEnvelope &&
            decoded['type'] == 'session' &&
            decoded['message'] is Map
        ? (decoded['message'] as Map).cast<String, Object?>()
        : decoded;
    if (predicate(candidate)) return candidate;
  }
  throw TimeoutException('Daemon schedule request timed out');
}

const _scheduleUsage =
    'Usage: coding-agent schedule create <prompt> '
    '(--every <duration> | --cron <expr>) --provider <provider[/model]> '
    '[--cwd <path>] [--json]\n'
    '       coding-agent schedule ls [--json]\n'
    '       coding-agent schedule <inspect|logs|pause|resume|delete|run-once> '
    '<id> [--json]\n'
    '       coding-agent schedule update <id> [fields] [--json]';
