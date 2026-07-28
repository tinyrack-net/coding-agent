import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

Map<String, Object?> buildAcpClientCapabilities(
  Map<String, Object?> providerParams,
) {
  final configured =
      _map(providerParams['clientCapabilities']) ?? const <String, Object?>{};
  final filesystem = _map(configured['fs']) ?? const <String, Object?>{};
  return {
    'fs': {
      'readTextFile': filesystem['readTextFile'] == true,
      'writeTextFile': filesystem['writeTextFile'] == true,
    },
    'terminal': configured['terminal'] == true,
  };
}

bool acpSupportsMcpServers(Map<String, Object?> providerParams) =>
    providerParams['supportsMcpServers'] != false;

List<Map<String, Object?>> normalizeAcpMcpServers(
  Map<String, Object?> servers,
) => [
  for (final entry in servers.entries)
    _normalizeMcpServer(entry.key, _requiredMap(entry.value, 'MCP server')),
];

Map<String, Object?> _normalizeMcpServer(
  String name,
  Map<String, Object?> config,
) {
  final type = config['type'];
  if (type == 'stdio') {
    return {
      'name': name,
      'command': _requiredString(config, 'command'),
      'args': _stringList(config['args'], 'MCP stdio args'),
      'env': [
        for (final entry in _stringMap(config['env'], 'MCP stdio env').entries)
          {'name': entry.key, 'value': entry.value},
      ],
    };
  }
  if (type == 'http' || type == 'sse') {
    return {
      'type': type,
      'name': name,
      'url': _requiredString(config, 'url'),
      'headers': [
        for (final entry in _stringMap(
          config['headers'],
          'MCP headers',
        ).entries)
          {'name': entry.key, 'value': entry.value},
      ],
    };
  }
  throw FormatException('MCP server "$name" has unsupported type: $type');
}

final class AcpClientRuntime {
  AcpClientRuntime({
    required this.cwd,
    required this.environment,
    Uuid uuid = const Uuid(),
  }) : _uuid = uuid;

  final String cwd;
  final Map<String, String> environment;
  final Uuid _uuid;
  final Map<String, _AcpTerminalEntry> _terminals = {};

  Future<Object?> handle(String method, Map<String, Object?> params) =>
      switch (method) {
        'fs/read_text_file' => _readTextFile(params),
        'fs/write_text_file' => _writeTextFile(params),
        'terminal/create' => _createTerminal(params),
        'terminal/output' => _terminalOutput(params),
        'terminal/wait_for_exit' => _waitForTerminalExit(params),
        'terminal/kill' => _killTerminal(params),
        'terminal/release' => _releaseTerminal(params),
        _ => throw UnsupportedError('Unsupported ACP client method: $method'),
      };

  bool supports(String method) =>
      method == 'fs/read_text_file' ||
      method == 'fs/write_text_file' ||
      method == 'terminal/create' ||
      method == 'terminal/output' ||
      method == 'terminal/wait_for_exit' ||
      method == 'terminal/kill' ||
      method == 'terminal/release';

  Future<Map<String, Object?>> _readTextFile(
    Map<String, Object?> params,
  ) async {
    final raw = await File(_requiredString(params, 'path')).readAsString();
    final line = _optionalInt(params['line'], 'line');
    final limit = _optionalInt(params['limit'], 'limit');
    if ((line == null || line == 0) && (limit == null || limit == 0)) {
      return {'content': raw};
    }
    final lines = raw.split(RegExp(r'\r?\n'));
    final start = ((line ?? 1) - 1).clamp(0, lines.length);
    final end = limit == null || limit == 0
        ? lines.length
        : (start + limit).clamp(start, lines.length);
    return {'content': lines.sublist(start, end).join('\n')};
  }

  Future<Map<String, Object?>> _writeTextFile(
    Map<String, Object?> params,
  ) async {
    final file = File(_requiredString(params, 'path'));
    await Directory(p.dirname(file.path)).create(recursive: true);
    await file.writeAsString(_requiredString(params, 'content'));
    return const {};
  }

  Future<Map<String, Object?>> _createTerminal(
    Map<String, Object?> params,
  ) async {
    final requestedCommand = _requiredString(params, 'command');
    final requestedArgs = _stringList(params['args'], 'terminal args');
    final (command, args) = _terminalCommand(requestedCommand, requestedArgs);
    final requestedEnvironment = <String, String>{
      for (final row in _listOfMaps(params['env']))
        _requiredString(row, 'name'): _requiredString(row, 'value'),
    };
    final process = await Process.start(
      command,
      args,
      workingDirectory: _optionalString(params['cwd']) ?? cwd,
      environment: {
        ...Platform.environment,
        ...environment,
        ...requestedEnvironment,
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    final entry = _AcpTerminalEntry(
      id: _uuid.v4(),
      process: process,
      outputByteLimit: _optionalInt(
        params['outputByteLimit'],
        'outputByteLimit',
      ),
    );
    _terminals[entry.id] = entry;
    entry.attach();
    return {'terminalId': entry.id};
  }

  Future<Map<String, Object?>> _terminalOutput(
    Map<String, Object?> params,
  ) async {
    final entry = _terminal(params);
    return {
      'output': entry.output,
      'truncated': entry.truncated,
      if (entry.exitStatus != null) 'exitStatus': entry.exitStatus,
    };
  }

  Future<Map<String, Object?>> _waitForTerminalExit(
    Map<String, Object?> params,
  ) => _terminal(params).exit;

  Future<Map<String, Object?>> _killTerminal(
    Map<String, Object?> params,
  ) async {
    await _terminate(_terminal(params));
    return const {};
  }

  Future<Map<String, Object?>> _releaseTerminal(
    Map<String, Object?> params,
  ) async {
    final entry = _terminal(params);
    await _terminate(entry);
    _terminals.remove(entry.id);
    await entry.dispose();
    return const {};
  }

  _AcpTerminalEntry _terminal(Map<String, Object?> params) {
    final terminalId = _requiredString(params, 'terminalId');
    return _terminals[terminalId] ??
        (throw StateError("Unknown terminal '$terminalId'"));
  }

  Future<void> _terminate(_AcpTerminalEntry entry) async {
    if (entry.exitStatus != null) return;
    entry.process.kill();
    try {
      await entry.exit.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      entry.process.kill(ProcessSignal.sigkill);
      await entry.exit.timeout(
        const Duration(seconds: 2),
        onTimeout: () => const {'exitCode': null, 'signal': 'SIGKILL'},
      );
    }
  }

  Future<void> dispose() async {
    final entries = _terminals.values.toList(growable: false);
    _terminals.clear();
    await Future.wait([
      for (final entry in entries)
        () async {
          await _terminate(entry);
          await entry.dispose();
        }(),
    ]);
  }
}

final class _AcpTerminalEntry {
  _AcpTerminalEntry({
    required this.id,
    required this.process,
    required this.outputByteLimit,
  });

  final String id;
  final Process process;
  final int? outputByteLimit;
  final Completer<Map<String, Object?>> _exit = Completer();
  final List<StreamSubscription<String>> _subscriptions = [];
  String output = '';
  bool truncated = false;
  Map<String, Object?>? exitStatus;

  Future<Map<String, Object?>> get exit => _exit.future;

  void attach() {
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    _subscriptions
      ..add(
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(_append, onDone: stdoutDone.complete),
      )
      ..add(
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(_append, onDone: stderrDone.complete),
      );
    unawaited(() async {
      final code = await process.exitCode;
      await Future.wait([stdoutDone.future, stderrDone.future]);
      final status = <String, Object?>{'exitCode': code, 'signal': null};
      exitStatus = status;
      if (!_exit.isCompleted) _exit.complete(status);
    }());
  }

  void _append(String chunk) {
    output += chunk;
    final limit = outputByteLimit;
    if (limit == null || limit == 0) return;
    while (utf8.encode(output).length > limit && output.isNotEmpty) {
      output = String.fromCharCodes(output.runes.skip(1));
      truncated = true;
    }
  }

  Future<void> dispose() async {
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    _subscriptions.clear();
  }
}

(String, List<String>) _terminalCommand(String command, List<String> args) {
  if (args.isNotEmpty || !RegExp(r'\s').hasMatch(command.trim())) {
    return (command, args);
  }
  if (Platform.isWindows) {
    return (
      Platform.environment['COMSPEC'] ?? 'cmd.exe',
      ['/d', '/s', '/c', command],
    );
  }
  return (Platform.environment['SHELL'] ?? '/bin/sh', ['-lc', command]);
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, Object?> _requiredMap(Object? value, String label) =>
    _map(value) ?? (throw FormatException('$label must be an object'));

List<Map<String, Object?>> _listOfMaps(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('value must be an array');
  return value.map((row) => _requiredMap(row, 'array item')).toList();
}

String _requiredString(Map<String, Object?> value, String key) =>
    _optionalString(value[key]) ??
    (throw FormatException('$key must be a non-empty string'));

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _optionalInt(Object? value, String label) {
  if (value == null) return null;
  if (value is! num || value.toInt() != value) {
    throw FormatException('$label must be an integer');
  }
  return value.toInt();
}

List<String> _stringList(Object? value, String label) {
  if (value == null) return const [];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$label must be a string array');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Map<String, String> _stringMap(Object? value, String label) {
  if (value == null) return const {};
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.values.any((item) => item is! String)) {
    throw FormatException('$label must be a string map');
  }
  return Map<String, String>.unmodifiable(
    value.map((key, item) => MapEntry(key as String, item as String)),
  );
}
