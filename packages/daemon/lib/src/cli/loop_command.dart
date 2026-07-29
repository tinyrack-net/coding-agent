import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_duration.dart';
import 'cli_output.dart';
import 'provider_model.dart';
import 'schedule_command.dart';

typedef LoopDelay = Future<void> Function(Duration duration);

Future<int> runLoopCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  ScheduleRpcRequester? request,
  LoopDelay? delay,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (_hasOptionBeforeTerminator(arguments, const {'--help', '-h'})) {
    output(loopHelp(arguments.isEmpty ? null : arguments.first));
    return 0;
  }
  LoopCliInvocation? invocation;
  try {
    invocation = LoopCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    final cwd = currentDirectory ?? Directory.current.path;
    final result = await _withClient(
      invocation,
      env,
      request,
      (send) => _execute(
        invocation!,
        send,
        cwd,
        delay ?? Future<void>.delayed,
        output,
      ),
    );
    if (result != null) {
      final rendered = renderCliOutput(result, invocation.output);
      if (rendered.isNotEmpty) output('$rendered\n');
    }
    return 0;
  } on LoopCommandException catch (error) {
    _writeLoopError(
      errorOutput,
      error,
      options: invocation?.output ?? const CliOutputOptions(),
    );
    return 1;
  } on ProviderModelFormatException catch (error) {
    _writeLoopError(
      errorOutput,
      LoopCommandException(error.code, error.message, error.details),
      options: invocation?.output ?? const CliOutputOptions(),
    );
    return 1;
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$_loopUsage\n');
    return 64;
  } on Object catch (error) {
    _writeLoopError(
      errorOutput,
      LoopCommandException('UNKNOWN_ERROR', _errorText(error)),
      options: invocation?.output ?? const CliOutputOptions(),
    );
    return 1;
  }
}

Future<T> _withClient<T>(
  LoopCliInvocation invocation,
  Map<String, String> environment,
  ScheduleRpcRequester? request,
  Future<T> Function(ScheduleRpcRequester request) operation,
) async {
  ScheduleRpcClient? client;
  if (request == null) {
    final config = loadDaemonRuntimeConfig(environment: environment);
    try {
      client = await connectScheduleRpcClient(
        config,
        hostOverride: invocation.host,
        environment: environment,
      );
    } on Object catch (error) {
      final host =
          invocation.host ??
          environment['TINYRACK_HOST'] ??
          '${config.host}:${config.port}';
      throw LoopCommandException(
        'DAEMON_NOT_RUNNING',
        'Cannot connect to daemon at $host: ${_errorText(error)}',
        'Start the daemon with: coding-agent daemon start',
      );
    }
  }
  try {
    return await operation(request ?? client!.request);
  } finally {
    await client?.close();
  }
}

final class LoopCommandException implements Exception {
  const LoopCommandException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final String? details;
}

final class LoopCliInvocation {
  const LoopCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.verifyChecks,
    required this.flags,
    required this.output,
    required this.host,
  });

  final String action;
  final List<String> positionals;
  final Map<String, String> values;
  final List<String> verifyChecks;
  final Set<String> flags;
  final CliOutputOptions output;
  final String? host;

  static LoopCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty) throw const FormatException('Missing loop action');
    const actions = {'run', 'ls', 'inspect', 'logs', 'stop'};
    final action = arguments.first;
    if (!actions.contains(action)) {
      throw FormatException('Unknown loop action: $action');
    }
    final booleanOptions = {if (action == 'run') '--archive'};
    final valueOptions = {
      '--host',
      if (action == 'run') ...{
        '--provider',
        '--model',
        '--mode',
        '--verify-provider',
        '--verify-model',
        '--verify-mode',
        '--verify',
        '--verify-check',
        '--name',
        '--sleep',
        '--max-iterations',
        '--max-time',
      },
      if (action == 'logs') '--poll-interval',
    };
    final positionals = <String>[];
    final values = <String, String>{};
    final verifyChecks = <String>[];
    final flags = <String>{};
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    var positionalOnly = false;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (!positionalOnly && argument == '--') {
        positionalOnly = true;
      } else if (positionalOnly) {
        positionals.add(argument);
      } else if (action != 'logs' && argument == '--json') {
        json = true;
      } else if (action != 'logs' &&
          (argument == '-q' || argument == '--quiet')) {
        quiet = true;
      } else if (action != 'logs' && argument == '--no-headers') {
        headers = false;
      } else if (action != 'logs' && argument == '--no-color') {
        color = false;
      } else if (action != 'logs' &&
          (argument == '-o' || argument == '--format')) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        format = normalizeCliOutputFormat(arguments[++index]);
      } else if (booleanOptions.contains(argument)) {
        flags.add(argument);
      } else if (valueOptions.contains(argument)) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        final value = arguments[++index];
        if (argument == '--verify-check') {
          verifyChecks.add(value);
        } else {
          values[argument] = value;
        }
      } else if (_splitLongOption(argument) case (
        final option,
        final value,
      ) when valueOptions.contains(option)) {
        if (option == '--verify-check') {
          verifyChecks.add(value);
        } else {
          values[option] = value;
        }
      } else if (action != 'logs' && argument.startsWith('--format=')) {
        format = normalizeCliOutputFormat(
          argument.substring('--format='.length),
        );
      } else if (action != 'logs' &&
          argument.startsWith('-o') &&
          argument.length > 2) {
        format = normalizeCliOutputFormat(argument.substring(2));
      } else if (argument.startsWith('-')) {
        throw FormatException('Unknown option: $argument');
      } else {
        positionals.add(argument);
      }
    }
    final expected = action == 'ls' ? 0 : 1;
    if (positionals.length != expected) {
      throw FormatException(
        action == 'ls'
            ? 'loop ls does not accept an argument'
            : 'loop $action requires one ${action == 'run' ? 'prompt' : 'loop id'}',
      );
    }
    return LoopCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      verifyChecks: List.unmodifiable(verifyChecks),
      flags: Set.unmodifiable(flags),
      output: CliOutputOptions(
        format: json ? 'json' : format,
        quiet: quiet,
        noHeaders: !headers,
        noColor: !color,
      ),
      host: values['--host'],
    );
  }
}

Future<CliOutputResult?> _execute(
  LoopCliInvocation invocation,
  ScheduleRpcRequester request,
  String cwd,
  LoopDelay delay,
  void Function(String value) output,
) async {
  final requestId = 'loop_${DateTime.now().microsecondsSinceEpoch}';
  try {
    switch (invocation.action) {
      case 'run':
        final message = _runRequest(invocation, requestId, cwd);
        final payload = await request(message);
        final loop = _requiredLoop(payload);
        final row = _runRow(loop);
        return CliOutputResult.single(row: row, schema: _loopRunSchema);
      case 'ls':
        final payload = await request({
          'type': LoopListRequest.type,
          'requestId': requestId,
        });
        _throwPayloadError(payload);
        final loops = [
          for (final value in _mapList(payload['loops']))
            LoopListItem.fromJson(value).toJson(),
        ];
        final rows = loops.map(_listRow).toList(growable: false);
        return CliOutputResult.list(rows: rows, schema: _loopListSchema);
      case 'inspect':
        final payload = await request({
          'type': LoopIdRequest.inspectType,
          'requestId': requestId,
          'id': invocation.positionals.single,
        });
        final loop = _requiredLoop(payload);
        return _loopInspectResult(loop);
      case 'stop':
        final payload = await request({
          'type': LoopIdRequest.stopType,
          'requestId': requestId,
          'id': invocation.positionals.single,
        });
        final loop = _requiredLoop(payload);
        final row = {
          'id': loop['id'],
          'status': loop['status'],
          'activeIteration': loop['activeIteration']?.toString() ?? '-',
        };
        return CliOutputResult.single(row: row, schema: _loopStopSchema);
      case 'logs':
        final pollInterval = _positiveInt(
          invocation.values['--poll-interval'] ?? '1000',
          '--poll-interval',
          code: 'INVALID_POLL_INTERVAL',
        );
        var cursor = 0;
        while (true) {
          final payload = await request({
            'type': LoopIdRequest.logsType,
            'requestId': '${requestId}_$cursor',
            'id': invocation.positionals.single,
            'afterSeq': cursor,
          });
          _throwPayloadError(payload);
          final loop = LoopRecord.fromJson(
            _map(payload['loop'], 'loop'),
          ).toJson();
          for (final rawEntry in _mapList(payload['entries'])) {
            final entry = LoopLogEntry.fromJson(rawEntry).toJson();
            output('${_renderLogEntry(entry)}\n');
          }
          cursor = _integer(payload['nextCursor'], 'nextCursor');
          if (loop['status'] != 'running') return null;
          await delay(Duration(milliseconds: pollInterval));
        }
    }
    throw StateError('Unhandled loop action');
  } on LoopCommandException {
    rethrow;
  } on ProviderModelFormatException {
    rethrow;
  } on Object catch (error) {
    final (code, prefix) = switch (invocation.action) {
      'run' => ('LOOP_RUN_FAILED', ''),
      'ls' => ('LOOP_LIST_FAILED', ''),
      'inspect' => ('LOOP_INSPECT_FAILED', ''),
      'logs' => ('LOOP_LOGS_FAILED', 'Failed to stream loop logs: '),
      'stop' => ('LOOP_STOP_FAILED', ''),
      _ => ('UNKNOWN_ERROR', ''),
    };
    throw LoopCommandException(code, '$prefix${_errorText(error)}');
  }
}

Map<String, Object?> _runRequest(
  LoopCliInvocation invocation,
  String requestId,
  String cwd,
) {
  final prompt = invocation.positionals.single;
  final result = <String, Object?>{
    'type': LoopRunRequest.type,
    'requestId': requestId,
    'prompt': prompt,
    'cwd': cwd,
  };
  final provider = invocation.values['--provider'];
  final model = invocation.values['--model']?.trim();
  if (provider != null) {
    final resolved = resolveProviderAndModel(provider: provider);
    result['provider'] = resolved.provider;
    if (model?.isNotEmpty == true) {
      result['model'] = model;
    } else if (resolved.model != null) {
      result['model'] = resolved.model;
    }
  } else if (model?.isNotEmpty == true) {
    result['model'] = model;
  }
  final mode = invocation.values['--mode']?.trim();
  if (mode?.isNotEmpty == true) result['modeId'] = mode;

  final verifierProvider = invocation.values['--verify-provider'];
  final verifierModel = invocation.values['--verify-model']?.trim();
  if (verifierProvider != null) {
    final resolved = resolveProviderAndModel(provider: verifierProvider);
    result['verifierProvider'] = resolved.provider;
    if (verifierModel?.isNotEmpty == true) {
      result['verifierModel'] = verifierModel;
    } else if (resolved.model != null) {
      result['verifierModel'] = resolved.model;
    }
  } else if (verifierModel?.isNotEmpty == true) {
    result['verifierModel'] = verifierModel;
  }
  final verifierMode = invocation.values['--verify-mode']?.trim();
  if (verifierMode?.isNotEmpty == true) {
    result['verifierModeId'] = verifierMode;
  }
  if (invocation.values.containsKey('--verify')) {
    final verify = invocation.values['--verify']!.trim();
    if (verify.isEmpty) {
      throw const LoopCommandException(
        'INVALID_VERIFY_PROMPT',
        '--verify cannot be empty',
      );
    }
    result['verifyPrompt'] = verify;
  }
  if (invocation.verifyChecks.isNotEmpty) {
    result['verifyChecks'] = invocation.verifyChecks;
  }
  if (invocation.flags.contains('--archive')) result['archive'] = true;
  final name = invocation.values['--name']?.trim();
  if (name?.isNotEmpty == true) result['name'] = name;
  if (invocation.values['--sleep'] case final sleep?) {
    result['sleepMs'] = parseLoopDuration(sleep);
  }
  if (invocation.values['--max-iterations'] case final max?) {
    result['maxIterations'] = _positiveInt(
      max,
      '--max-iterations',
      code: 'INVALID_MAX_ITERATIONS',
    );
  }
  if (invocation.values['--max-time'] case final max?) {
    result['maxTimeMs'] = parseLoopDuration(max);
  }
  return result;
}

int parseLoopDuration(String input) {
  try {
    return parseCliDurationMilliseconds(input);
  } on FormatException catch (error) {
    throw LoopCommandException('INVALID_DURATION', error.message);
  }
}

int _positiveInt(String value, String option, {required String code}) {
  final match = RegExp(r'^[+-]?\d+').firstMatch(value.trimLeft());
  final parsed = match == null ? null : int.tryParse(match.group(0)!);
  if (parsed == null || parsed <= 0) {
    throw LoopCommandException(code, '$option must be a positive integer');
  }
  return parsed;
}

Map<String, Object?> _requiredLoop(Map<String, Object?> payload) {
  _throwPayloadError(payload);
  return LoopRecord.fromJson(_map(payload['loop'], 'loop')).toJson();
}

void _throwPayloadError(Map<String, Object?> payload) {
  final error = payload['error'];
  if (error != null && error is! String) {
    throw StateError('error must be a string or null');
  }
  if (error is String && error.isNotEmpty) throw StateError(error);
}

Map<String, Object?> _runRow(Map<String, Object?> loop) => {
  'id': loop['id']?.toString(),
  'status': loop['status']?.toString(),
  'name': loop['name']?.toString(),
  'cwd': loop['cwd']?.toString(),
};

Map<String, Object?> _listRow(Map<String, Object?> loop) => {
  'id': loop['id']?.toString(),
  'name': loop['name']?.toString(),
  'status': loop['status']?.toString(),
  'activeIteration': loop['activeIteration']?.toString() ?? '-',
  'cwd': loop['cwd']?.toString(),
  'updated': loop['updatedAt']?.toString(),
};

final _loopRunSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'LOOP ID', field: (row) => row['id'], width: 10),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status'], width: 10),
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 20),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 40),
  ],
);

final _loopListSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'LOOP ID', field: (row) => row['id'], width: 10),
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 20),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status'], width: 10),
    CliOutputColumn(
      header: 'ITER',
      field: (row) => row['activeIteration'],
      width: 8,
    ),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 40),
    CliOutputColumn(
      header: 'UPDATED',
      field: (row) => row['updated'],
      width: 24,
    ),
  ],
);

final _loopStopSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(header: 'LOOP ID', field: (row) => row['id'], width: 10),
    CliOutputColumn(header: 'STATUS', field: (row) => row['status'], width: 10),
    CliOutputColumn(
      header: 'ITER',
      field: (row) => row['activeIteration'],
      width: 8,
    ),
  ],
);

CliOutputResult _loopInspectResult(Map<String, Object?> loop) =>
    CliOutputResult.list(
      rows: _inspectRows(loop),
      schema: CliOutputSchema(
        idField: (row) => '${row['key']}',
        columns: [
          CliOutputColumn(header: 'KEY', field: (row) => row['key'], width: 18),
          CliOutputColumn(
            header: 'VALUE',
            field: (row) => row['value'],
            width: 80,
          ),
        ],
        serialize: (_) => loop,
      ),
    );

List<Map<String, Object?>> _inspectRows(Map<String, Object?> loop) {
  final checks = _stringValues(loop['verifyChecks']);
  final iterations = _mapList(loop['iterations']);
  final iterationText = iterations.isEmpty
      ? '[]'
      : iterations
            .map((iteration) {
              final parts = <String>[
                '#${iteration['index']}',
                '${iteration['status']}',
                if (iteration['workerAgentId'] != null)
                  'worker=${iteration['workerAgentId']}',
                if (iteration['verifierAgentId'] != null)
                  'verifier=${iteration['verifierAgentId']}',
                if (iteration['failureReason'] != null)
                  'reason=${iteration['failureReason']}',
              ];
              return parts.join(' ');
            })
            .join(' | ');
  return <Map<String, Object?>>[
    {'key': 'Id', 'value': '${loop['id']}'},
    {'key': 'Name', 'value': loop['name']?.toString() ?? 'null'},
    {'key': 'Status', 'value': '${loop['status']}'},
    {'key': 'Cwd', 'value': '${loop['cwd']}'},
    {'key': 'Provider', 'value': '${loop['provider']}'},
    {'key': 'Model', 'value': loop['model']?.toString() ?? 'null'},
    {
      'key': 'WorkerProvider',
      'value': loop['workerProvider']?.toString() ?? 'null',
    },
    {'key': 'WorkerModel', 'value': loop['workerModel']?.toString() ?? 'null'},
    {
      'key': 'VerifierProvider',
      'value': loop['verifierProvider']?.toString() ?? 'null',
    },
    {
      'key': 'VerifierModel',
      'value': loop['verifierModel']?.toString() ?? 'null',
    },
    {'key': 'Prompt', 'value': '${loop['prompt']}'},
    {
      'key': 'VerifyPrompt',
      'value': loop['verifyPrompt']?.toString() ?? 'null',
    },
    {
      'key': 'VerifyChecks',
      'value': checks.isEmpty ? '[]' : checks.join(' | '),
    },
    {'key': 'Archive', 'value': '${loop['archive']}'},
    {'key': 'SleepMs', 'value': '${loop['sleepMs']}'},
    {
      'key': 'MaxIterations',
      'value': loop['maxIterations']?.toString() ?? 'null',
    },
    {'key': 'MaxTimeMs', 'value': loop['maxTimeMs']?.toString() ?? 'null'},
    {'key': 'CreatedAt', 'value': '${loop['createdAt']}'},
    {'key': 'UpdatedAt', 'value': '${loop['updatedAt']}'},
    {'key': 'CompletedAt', 'value': loop['completedAt']?.toString() ?? 'null'},
    {'key': 'Iterations', 'value': iterationText},
  ];
}

String _renderLogEntry(Map<String, Object?> entry) {
  final prefix = <String>[
    '${entry['timestamp']}',
    '${entry['source']}',
    if (entry['iteration'] != null) 'iteration=${entry['iteration']}',
    if (entry['level'] == 'error') 'ERROR',
  ].join(' ');
  return '$prefix\n${entry['text']}';
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw StateError('$field is missing');
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) throw StateError('Expected a list response');
  return [for (final item in value) _map(item, 'list item')];
}

List<String> _stringValues(Object? value) {
  if (value is! List) return const [];
  return [for (final item in value) '$item'];
}

int _integer(Object? value, String field) {
  if (value is! int) throw StateError('$field is missing');
  return value;
}

void _writeLoopError(
  void Function(String value) output,
  LoopCommandException error, {
  required CliOutputOptions options,
}) {
  output(
    '${renderCliError(code: error.code, message: error.message, details: error.details, options: options)}\n',
  );
}

String _errorText(Object error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => '$error',
};

(String, String)? _splitLongOption(String argument) {
  if (!argument.startsWith('--')) return null;
  final separator = argument.indexOf('=');
  if (separator < 3) return null;
  return (argument.substring(0, separator), argument.substring(separator + 1));
}

bool _hasOptionBeforeTerminator(List<String> arguments, Set<String> options) {
  for (final argument in arguments) {
    if (argument == '--') return false;
    if (options.contains(argument)) return true;
  }
  return false;
}

String loopHelp(String? action) => switch (action) {
  'run' =>
    'Usage: coding-agent loop run <prompt> [options]\n'
        '  --provider <provider>       Default worker/verifier provider\n'
        '  --model <model>             Default worker/verifier model\n'
        '  --mode <mode>               Worker provider mode\n'
        '  --verify-provider <value>   Verifier provider\n'
        '  --verify-model <value>      Verifier model\n'
        '  --verify-mode <value>       Verifier provider mode\n'
        '  --verify <prompt>           Verifier agent prompt\n'
        '  --verify-check <command>    Repeatable shell verification\n'
        '  --archive                   Archive iteration agents\n'
        '  --name <name>               Optional loop name\n'
        '  --sleep <duration>          Delay between iterations\n'
        '  --max-iterations <n>        Maximum iterations\n'
        '  --max-time <duration>       Maximum total runtime\n'
        '  --host <host>               Daemon host\n'
        '  --json                      JSON output\n',
  'ls' =>
    'Usage: coding-agent loop ls [--host <host>] [--json]\n'
        'List loops\n',
  'inspect' =>
    'Usage: coding-agent loop inspect <id> [--host <host>] [--json]\n'
        'Show loop details and iteration history\n',
  'logs' =>
    'Usage: coding-agent loop logs <id> '
        '[--poll-interval <ms>] [--host <host>]\n'
        'Stream loop logs\n',
  'stop' =>
    'Usage: coding-agent loop stop <id> [--host <host>] [--json]\n'
        'Stop a running loop\n',
  _ =>
    'Usage: coding-agent loop <run|ls|inspect|logs|stop> ...\n'
        'Run iterative worker loops\n',
};

const _loopUsage = 'Usage: coding-agent loop <run|ls|inspect|logs|stop> ...';
