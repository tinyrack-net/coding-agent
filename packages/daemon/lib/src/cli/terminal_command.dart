import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import 'cli_client_id.dart';
import 'cli_output.dart';

const terminalDaemonRpcTimeout = Duration(seconds: 30);

typedef TerminalRpcRequester =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef TerminalMessageSender =
    Future<void> Function(Map<String, Object?> message);

Future<int> runTerminalCommand({
  required List<String> arguments,
  Map<String, String>? environment,
  String? currentDirectory,
  TerminalRpcRequester? request,
  TerminalMessageSender? send,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  TerminalCliInvocation? invocation;
  try {
    invocation = TerminalCliInvocation.parse(arguments);
    final env = environment ?? Platform.environment;
    final client = request == null
        ? await _connectTerminalClient(
            loadDaemonRuntimeConfig(environment: env),
            hostOverride: invocation.host,
            environment: env,
          )
        : null;
    final rpc = request ?? client!.request;
    final notify = send ?? client?.send ?? ((_) async {});
    try {
      final result = await _execute(
        invocation,
        rpc,
        notify,
        currentDirectory ?? Directory.current.path,
      );
      if (result.output case final shared?) {
        final rendered = renderCliOutput(shared, invocation.output);
        if (rendered.isNotEmpty) output('$rendered\n');
      } else {
        output(
          invocation.json
              ? '${const JsonEncoder.withIndent('  ').convert(result.json)}\n'
              : result.human,
        );
      }
      return 0;
    } finally {
      await client?.close();
    }
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$_terminalUsage\n');
    return 64;
  } on _TerminalCommandException catch (error) {
    errorOutput(
      '${renderCliError(code: error.code, message: error.message, details: error.details, options: invocation?.errorOutput ?? const CliOutputOptions())}\n',
    );
    return 1;
  } on Object catch (error) {
    errorOutput(
      '${renderCliError(code: 'TERMINAL_COMMAND_FAILED', message: _errorText(error), options: invocation?.errorOutput ?? const CliOutputOptions())}\n',
    );
    return 1;
  }
}

Future<DaemonCliSocketClient> _connectTerminalClient(
  DaemonRuntimeConfig config, {
  required String? hostOverride,
  required Map<String, String> environment,
}) async {
  final daemonHost = hostOverride ?? '${config.host}:${config.port}';
  try {
    return await DaemonCliSocketClient.connect(
      config,
      hostOverride: hostOverride,
      environment: environment,
    );
  } catch (error) {
    throw _TerminalCommandException(
      'DAEMON_NOT_RUNNING',
      'Cannot connect to daemon at $daemonHost: ${_errorText(error)}',
      details: 'Start the daemon with: coding-agent daemon start',
    );
  }
}

final class TerminalCliInvocation {
  const TerminalCliInvocation({
    required this.action,
    required this.positionals,
    required this.values,
    required this.flags,
    required this.json,
    required this.output,
    required this.host,
  });

  final String action;
  final List<String> positionals;
  final Map<String, String> values;
  final Set<String> flags;
  final bool json;
  final CliOutputOptions output;
  final String? host;

  bool get usesSharedOutput =>
      action == 'ls' || action == 'create' || action == 'kill';

  CliOutputOptions get errorOutput => usesSharedOutput
      ? output
      : CliOutputOptions(
          format: json ? 'json' : 'table',
          noColor: output.noColor,
        );

  static TerminalCliInvocation parse(List<String> arguments) {
    if (arguments.isEmpty)
      throw const FormatException('Missing terminal action');
    const actions = {'ls', 'create', 'capture', 'send-keys', 'kill'};
    final action = arguments.first;
    if (!actions.contains(action)) {
      throw FormatException('Unknown terminal action: $action');
    }
    const booleanOptions = {
      '--all',
      '--json',
      '--scrollback',
      '-S',
      '--ansi',
      '--literal',
      '-l',
    };
    const valueOptions = {'--host', '--cwd', '--name', '--start', '--end'};
    final positionals = <String>[];
    final values = <String, String>{};
    final flags = <String>{};
    var format = 'table';
    var json = false;
    var quiet = false;
    var headers = true;
    var color = true;
    for (var index = 1; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--json') {
        flags.add(argument);
        json = true;
      } else if (argument == '-q' || argument == '--quiet') {
        quiet = true;
      } else if (argument == '--no-headers') {
        headers = false;
      } else if (argument == '--no-color') {
        color = false;
      } else if (argument == '-o' || argument == '--format') {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        format = normalizeCliOutputFormat(arguments[++index]);
      } else if (argument.startsWith('--format=')) {
        format = normalizeCliOutputFormat(
          argument.substring('--format='.length),
        );
      } else if (argument.startsWith('-o') && argument.length > 2) {
        format = normalizeCliOutputFormat(argument.substring(2));
      } else if (booleanOptions.contains(argument)) {
        flags.add(argument);
      } else if (valueOptions.contains(argument)) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        values[argument] = arguments[++index];
      } else if (argument.startsWith('-') &&
          !(action == 'send-keys' && !argument.startsWith('--'))) {
        throw FormatException('Unknown option: $argument');
      } else {
        positionals.add(argument);
      }
    }
    final validCount = switch (action) {
      'ls' || 'create' => positionals.isEmpty,
      'capture' || 'kill' => positionals.length == 1,
      'send-keys' => positionals.length >= 2,
      _ => false,
    };
    if (!validCount) {
      throw FormatException('Invalid arguments for terminal $action');
    }
    return TerminalCliInvocation(
      action: action,
      positionals: List.unmodifiable(positionals),
      values: Map.unmodifiable(values),
      flags: Set.unmodifiable(flags),
      json: json,
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

final class _TerminalCommandResult {
  const _TerminalCommandResult.direct({required this.json, required this.human})
    : output = null;

  const _TerminalCommandResult.shared(this.output) : json = null, human = '';

  final Object? json;
  final String human;
  final CliOutputResult? output;
}

Future<_TerminalCommandResult> _execute(
  TerminalCliInvocation invocation,
  TerminalRpcRequester request,
  TerminalMessageSender send,
  String currentDirectory,
) async {
  final requestId = 'terminal_${DateTime.now().microsecondsSinceEpoch}';
  switch (invocation.action) {
    case 'ls':
      final cwd = invocation.flags.contains('--all')
          ? null
          : invocation.values['--cwd'] ?? currentDirectory;
      final payload = await _rpc(
        request,
        {
          'type': ListTerminalsRequest.type,
          if (cwd != null) 'cwd': cwd,
          'requestId': requestId,
        },
        'TERMINAL_LIST_FAILED',
        'list terminals',
      );
      final rows = _terminalRows(payload, fallbackCwd: cwd);
      return _TerminalCommandResult.shared(
        CliOutputResult.list(rows: rows, schema: _terminalOutputSchema),
      );
    case 'create':
      final cwd = invocation.values['--cwd'] ?? currentDirectory;
      final opened = await _rpc(
        request,
        {
          'type': OpenProjectRequest.type,
          'cwd': cwd,
          'requestId': '${requestId}_open',
        },
        'WORKSPACE_OPEN_FAILED',
        'open workspace',
      );
      final workspace = _mapOrNull(opened['workspace']);
      if (workspace == null) {
        throw _TerminalCommandException(
          'WORKSPACE_OPEN_FAILED',
          opened['error'] as String? ?? 'Failed to open workspace',
        );
      }
      final payload = await _rpc(
        request,
        {
          'type': CreateTerminalRequest.type,
          'cwd': cwd,
          'workspaceId': workspace['id'],
          if (invocation.values['--name'] case final String name) 'name': name,
          'requestId': requestId,
        },
        'TERMINAL_CREATE_FAILED',
        'create terminal',
      );
      final terminal = _mapOrNull(payload['terminal']);
      if (terminal == null) {
        throw _TerminalCommandException(
          'TERMINAL_CREATE_FAILED',
          payload['error'] as String? ?? 'Failed to create terminal',
        );
      }
      final row = _terminalRow(terminal, fallbackCwd: cwd);
      return _TerminalCommandResult.shared(
        CliOutputResult.single(row: row, schema: _terminalOutputSchema),
      );
    case 'capture':
      final terminalId = await _requireTerminalId(
        request,
        invocation.positionals.single,
      );
      final start =
          invocation.flags.intersection({'--scrollback', '-S'}).isNotEmpty
          ? 0
          : _lineNumber('--start', invocation.values['--start']);
      final end = _lineNumber('--end', invocation.values['--end']);
      final payload = await _rpc(
        request,
        {
          'type': CaptureTerminalRequest.type,
          'terminalId': terminalId,
          if (start != null) 'start': start,
          if (end != null) 'end': end,
          'stripAnsi': !invocation.flags.contains('--ansi'),
          'requestId': requestId,
        },
        'TERMINAL_CAPTURE_FAILED',
        'capture terminal output',
      );
      final lines = _strings(payload['lines']);
      final json = {
        'terminalId': payload['terminalId'],
        'lines': lines,
        'totalLines': payload['totalLines'],
      };
      return _TerminalCommandResult.direct(
        json: json,
        human: lines.isEmpty ? '' : '${lines.join('\n')}\n',
      );
    case 'send-keys':
      final terminalId = await _requireTerminalId(
        request,
        invocation.positionals.first,
      );
      final literal =
          invocation.flags.contains('--literal') ||
          invocation.flags.contains('-l');
      final text = invocation.positionals
          .skip(1)
          .map((key) => literal ? key : _keyToken(key))
          .join();
      try {
        await send({
          'type': TerminalInputRequest.type,
          'terminalId': terminalId,
          'message': {'type': 'input', 'data': text},
        });
      } catch (error) {
        throw _TerminalCommandException(
          'TERMINAL_SEND_KEYS_FAILED',
          'Failed to send terminal keys: ${_errorText(error)}',
        );
      }
      return _TerminalCommandResult.direct(
        json: {'terminalId': terminalId, 'keysSent': text.length},
        human: '',
      );
    case 'kill':
      final terminalId = await _requireTerminalId(
        request,
        invocation.positionals.single,
      );
      final payload = await _rpc(
        request,
        {
          'type': KillTerminalRequest.type,
          'terminalId': terminalId,
          'requestId': requestId,
        },
        'TERMINAL_KILL_FAILED',
        'kill terminal',
      );
      final row = {
        'terminalId': payload['terminalId'],
        'success': payload['success'],
      };
      return _TerminalCommandResult.shared(
        CliOutputResult.single(row: row, schema: _terminalKillOutputSchema),
      );
  }
  throw StateError('unreachable terminal action');
}

Future<Map<String, Object?>> _rpc(
  TerminalRpcRequester request,
  Map<String, Object?> message,
  String code,
  String action,
) async {
  try {
    return await request(message);
  } catch (error) {
    throw _TerminalCommandException(
      code,
      'Failed to $action: ${_errorText(error)}',
    );
  }
}

Future<String> _requireTerminalId(
  TerminalRpcRequester request,
  String query,
) async {
  final payload = await _rpc(
    request,
    {
      'type': ListTerminalsRequest.type,
      'requestId': 'terminal_lookup_${DateTime.now().microsecondsSinceEpoch}',
    },
    'TERMINAL_LIST_FAILED',
    'list terminals',
  );
  final terminals = _maps(payload['terminals']);
  final resolved = resolveTerminalIdentifier(query, terminals);
  if (resolved != null) return resolved;
  throw _TerminalCommandException(
    'TERMINAL_NOT_FOUND',
    'No terminal found matching: $query',
    details:
        'Use `coding-agent terminal ls --all` to list available terminals.',
  );
}

String? resolveTerminalIdentifier(
  String query,
  List<Map<String, Object?>> terminals,
) {
  if (query.isEmpty) return null;
  final lower = query.toLowerCase();
  final exact = terminals.where((entry) => entry['id'] == query).toList();
  if (exact.length == 1) return exact.single['id'] as String;
  final prefixes = terminals
      .where((entry) => (entry['id'] as String).toLowerCase().startsWith(lower))
      .toList();
  if (prefixes.length == 1) return prefixes.single['id'] as String;
  if (prefixes.length > 1) return null;
  final names = terminals
      .where((entry) => (entry['name'] as String).toLowerCase() == lower)
      .toList();
  if (names.length == 1) return names.single['id'] as String;
  if (names.length > 1) return null;
  final partial = terminals
      .where((entry) => (entry['name'] as String).toLowerCase().contains(lower))
      .toList();
  return partial.length == 1 ? partial.single['id'] as String : null;
}

String _keyToken(String key) => switch (key) {
  'Enter' => '\r',
  'Tab' => '\t',
  'Escape' => '\x1b',
  'Space' => ' ',
  'BSpace' => '\x7f',
  'C-c' => '\x03',
  'C-d' => '\x04',
  'C-z' => '\x1a',
  'C-l' => '\x0c',
  'C-a' => '\x01',
  'C-e' => '\x05',
  _ => key,
};

int? _lineNumber(String flag, String? value) {
  if (value == null) return null;
  final parsed = int.tryParse(RegExp(r'^[+-]?\d+').stringMatch(value) ?? '');
  if (parsed == null) {
    throw _TerminalCommandException(
      'INVALID_LINE_NUMBER',
      'Invalid $flag value: $value',
      details: 'Use an integer line number.',
    );
  }
  return parsed;
}

List<Map<String, Object?>> _terminalRows(
  Map<String, Object?> payload, {
  String? fallbackCwd,
}) => [
  for (final terminal in _maps(payload['terminals']))
    _terminalRow(
      terminal,
      fallbackCwd: payload['cwd'] as String? ?? fallbackCwd,
    ),
];

Map<String, Object?> _terminalRow(
  Map<String, Object?> terminal, {
  String? fallbackCwd,
}) => {
  'id': terminal['id'],
  'name': terminal['name'],
  'cwd': terminal['cwd'] ?? fallbackCwd ?? '-',
};

final _terminalOutputSchema = CliOutputSchema(
  idField: (row) => '${row['id']}',
  columns: [
    CliOutputColumn(
      header: 'ID',
      field: (row) => _shortTerminalId('${row['id']}'),
      width: 8,
    ),
    CliOutputColumn(header: 'NAME', field: (row) => row['name'], width: 24),
    CliOutputColumn(header: 'CWD', field: (row) => row['cwd'], width: 48),
  ],
);

final _terminalKillOutputSchema = CliOutputSchema(
  idField: (row) => '${row['terminalId']}',
  columns: [
    CliOutputColumn(
      header: 'ID',
      field: (row) => _shortTerminalId('${row['terminalId']}'),
      width: 8,
    ),
    CliOutputColumn(
      header: 'SUCCESS',
      field: (row) => row['success'],
      width: 8,
    ),
  ],
);

String _shortTerminalId(String value) =>
    value.substring(0, value.length.clamp(0, 8));

List<Map<String, Object?>> _maps(Object? value) => [
  for (final entry in value is List ? value : const [])
    if (entry is Map) entry.cast<String, Object?>(),
];

Map<String, Object?>? _mapOrNull(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<String> _strings(Object? value) => [
  for (final entry in value is List ? value : const [])
    if (entry is String) entry,
];

String _errorText(Object error) => switch (error) {
  StateError(message: final message) => message,
  ArgumentError(message: final message) => '$message',
  _ => '$error',
};

final class _TerminalCommandException implements Exception {
  const _TerminalCommandException(this.code, this.message, {this.details});
  final String code;
  final String message;
  final String? details;
}

final class DaemonCliSocketClient {
  DaemonCliSocketClient._(this._socket, this._frames, this.serverInfo);

  final WebSocket _socket;
  final StreamIterator<dynamic> _frames;
  final ServerInfoStatus serverInfo;
  final Map<Object?, Completer<Map<String, Object?>>> _responses = {};
  final Queue<Map<String, Object?>> _events = Queue();
  final Queue<Completer<Map<String, Object?>>> _eventWaiters = Queue();
  late final Future<void> _pump;
  var _closed = false;

  static Future<DaemonCliSocketClient> connect(
    DaemonRuntimeConfig config, {
    required String? hostOverride,
    required Map<String, String> environment,
    Duration timeout = terminalDaemonRpcTimeout,
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
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final value = deadline.difference(DateTime.now());
      return value.isNegative || value == Duration.zero
          ? const Duration(microseconds: 1)
          : value;
    }

    WebSocket? socket;
    StreamIterator<dynamic>? frames;
    try {
      final connectedSocket = await WebSocket.connect(
        Uri(scheme: 'ws', host: host, port: port, path: '/ws').toString(),
        protocols: password == null || password.isEmpty
            ? null
            : ['tinyrack.bearer.$password'],
        compression: CompressionOptions.compressionOff,
      ).timeout(remaining());
      socket = connectedSocket;
      final connectedFrames = StreamIterator<dynamic>(connectedSocket);
      frames = connectedFrames;
      final clientId = await getOrCreateCliClientId(
        home: config.home,
        environment: environment,
      );
      connectedSocket.add(
        jsonEncode(
          WebSocketHello(
            clientId: clientId,
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      final serverInfo = ServerInfoStatus.fromJson(
        await _nextMessage(
          connectedFrames,
          (message) => message['status'] == 'server_info',
          allowEnvelope: false,
          timeout: remaining(),
        ),
      );
      final client = DaemonCliSocketClient._(
        connectedSocket,
        connectedFrames,
        serverInfo,
      );
      client._pump = client._pumpFrames();
      return client;
    } on Object {
      await frames?.cancel();
      await socket?.close();
      rethrow;
    }
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout = terminalDaemonRpcTimeout,
  }) async {
    final requestId = request['requestId'];
    final responseCompleter = Completer<Map<String, Object?>>();
    if (_responses.containsKey(requestId)) {
      throw StateError('Duplicate CLI request ID: $requestId');
    }
    _responses[requestId] = responseCompleter;
    late final Map<String, Object?> response;
    try {
      await send(request);
      response = timeout == null
          ? await responseCompleter.future
          : await responseCompleter.future.timeout(timeout);
    } finally {
      _responses.remove(requestId);
    }
    if (response['type'] == 'rpc_error') {
      final payload = response['payload'];
      throw StateError(
        payload is Map
            ? '${payload['error'] ?? 'Terminal RPC failed'}'
            : 'Terminal RPC failed',
      );
    }
    final payload = response['payload'];
    if (payload is! Map) throw StateError('Invalid terminal response');
    return payload.cast<String, Object?>();
  }

  Future<Map<String, Object?>> nextSessionMessage() {
    if (_events.isNotEmpty) return Future.value(_events.removeFirst());
    final completer = Completer<Map<String, Object?>>();
    _eventWaiters.add(completer);
    return completer.future;
  }

  Future<void> send(Map<String, Object?> message) async {
    _socket.add(jsonEncode({'type': 'session', 'message': message}));
    // `terminal_input` intentionally has no response. Yield once so dart:io
    // writes the frame before the short-lived CLI connection is closed.
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _frames.cancel();
    await _socket.close();
    await _pump;
  }

  Future<void> _pumpFrames() async {
    try {
      while (await _frames.moveNext()) {
        final frame = _frames.current;
        if (frame is! String) continue;
        final decoded = jsonDecode(frame);
        if (decoded is! Map) continue;
        final message = Map<String, Object?>.from(decoded);
        final candidate =
            message['type'] == 'session' && message['message'] is Map
            ? Map<String, Object?>.from(message['message'] as Map)
            : message;
        final payload = candidate['payload'];
        final requestId = payload is Map ? payload['requestId'] : null;
        final response = _responses[requestId];
        if (response != null && !response.isCompleted) {
          response.complete(candidate);
        } else if (_eventWaiters.isNotEmpty) {
          _eventWaiters.removeFirst().complete(candidate);
        } else {
          _events.add(candidate);
        }
      }
    } on Object catch (error, stackTrace) {
      _completePendingWithError(error, stackTrace);
    } finally {
      _completePendingWithError(
        StateError('Daemon closed during CLI request'),
        StackTrace.current,
      );
    }
  }

  void _completePendingWithError(Object error, StackTrace stackTrace) {
    for (final response in _responses.values) {
      if (!response.isCompleted) response.completeError(error, stackTrace);
    }
    while (_eventWaiters.isNotEmpty) {
      final waiter = _eventWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
    }
  }
}

Future<Map<String, Object?>> _nextMessage(
  StreamIterator<dynamic> frames,
  bool Function(Map<String, Object?> message) predicate, {
  bool allowEnvelope = true,
  Duration timeout = terminalDaemonRpcTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (!await frames.moveNext().timeout(remaining)) {
      throw StateError('Daemon closed during terminal request');
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
  throw TimeoutException('Daemon terminal request timed out');
}

const _terminalUsage =
    'Usage: coding-agent terminal ls [--all] [--cwd <path>] [--host <host>] [--json]\n'
    '       coding-agent terminal create [--cwd <path>] [--name <name>] [--host <host>] [--json]\n'
    '       coding-agent terminal capture <terminal-id> [--start <line>] [--end <line>] [-S|--scrollback] [--ansi] [--json]\n'
    '       coding-agent terminal send-keys <terminal-id> <keys...> [-l|--literal] [--json]\n'
    '       coding-agent terminal kill <terminal-id> [--json]';
