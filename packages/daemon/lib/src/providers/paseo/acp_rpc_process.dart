import 'dart:async';
import 'dart:convert';
import 'dart:io';

const acpRpcDefaultTimeout = Duration(seconds: 30);

/// Wait for a response, process exit, or [AcpRpcProcess.close].
///
/// Long-running blocking provider work, such as Pi context compaction, must
/// not use the control-plane wall-clock timeout: the provider can legitimately
/// spend longer than 30 seconds generating and persisting its summary.
const Duration? acpRpcNoTimeout = null;
const _stderrBufferLimit = 8192;
const _gracefulShutdownTimeout = Duration(seconds: 2);
const _forceShutdownTimeout = Duration(seconds: 1);

typedef AcpRpcProcessStarter =
    Future<Process> Function(AcpRpcProcessLaunch launch);
typedef AcpRpcIncomingHandler =
    Future<Object?> Function(String method, Map<String, Object?> params);
typedef AcpRpcWarningSink =
    void Function(String message, Object? error, String? line);

final class AcpRpcProcessLaunch {
  const AcpRpcProcessLaunch({
    required this.command,
    required this.args,
    required this.cwd,
    this.environment = const {},
    this.includeParentEnvironment = true,
  });

  final String command;
  final List<String> args;
  final String cwd;
  final Map<String, String> environment;
  final bool includeParentEnvironment;
}

final class AcpRpcError implements Exception {
  const AcpRpcError({required this.code, required this.message, this.data});

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() {
    final suffix = data == null ? '' : ' | data=${jsonEncode(data)}';
    return '$message | code=$code$suffix';
  }
}

final class AcpRpcExit {
  const AcpRpcExit({required this.code, required this.error});

  final int code;
  final StateError error;
}

final class _PendingRequest {
  _PendingRequest(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer? timer;
}

/// ACP's newline-delimited JSON-RPC 2.0 transport.
///
/// ACP agents may initiate requests (notably `session/request_permission`) on
/// the same stream. Responses accept both numeric ids and stringified numeric
/// ids for compatibility with the providers supported by Paseo 0.2.0.
final class AcpRpcProcess {
  AcpRpcProcess._({
    required Process process,
    required this.diagnosticName,
    required AcpRpcIncomingHandler incomingHandler,
    required AcpRpcWarningSink warningSink,
  }) : _process = process,
       _incomingHandler = incomingHandler,
       _warningSink = warningSink {
    _stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_handleStdoutChunk);
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_handleStderrChunk);
    _exitSubscription = process.exitCode.asStream().listen(_handleExit);
  }

  static Future<AcpRpcProcess> start({
    required AcpRpcProcessLaunch launch,
    required AcpRpcIncomingHandler onIncoming,
    String diagnosticName = 'ACP',
    AcpRpcWarningSink? onWarning,
    AcpRpcProcessStarter? spawn,
  }) async {
    final process = await (spawn ?? _spawnProcess)(launch);
    return AcpRpcProcess._(
      process: process,
      diagnosticName: diagnosticName,
      incomingHandler: onIncoming,
      warningSink: onWarning ?? _ignoreWarning,
    );
  }

  final Process _process;
  final String diagnosticName;
  final AcpRpcIncomingHandler _incomingHandler;
  final AcpRpcWarningSink _warningSink;
  final Map<String, _PendingRequest> _pending = {};
  final Set<void Function(AcpRpcExit)> _exitSubscribers = {};

  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  late final StreamSubscription<int> _exitSubscription;
  final Completer<void> _exitCleanup = Completer<void>();
  Future<void>? _closeFuture;

  var _stderrBuffer = '';
  var _stdoutBuffer = '';
  var _nextRequestId = 1;
  var _disposed = false;
  var _exited = false;

  bool get isClosed => _disposed;

  void Function() onExit(void Function(AcpRpcExit) callback) {
    _exitSubscribers.add(callback);
    return () => _exitSubscribers.remove(callback);
  }

  Future<Object?> request(
    String method,
    Map<String, Object?> params, {
    Duration? timeout = acpRpcDefaultTimeout,
  }) {
    if (_disposed) {
      return Future.error(StateError('$diagnosticName process is closed'));
    }
    final id = _nextRequestId++;
    final key = '$id';
    final completer = Completer<Object?>();
    Timer? timer;
    if (timeout != null && timeout > Duration.zero) {
      timer = Timer(timeout, () {
        _pending.remove(key);
        completer.completeError(
          StateError(
            '$diagnosticName request timed out for $method${_stderrSuffix()}',
          ),
        );
      });
    }
    _pending[key] = _PendingRequest(completer, timer);
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  void notify(String method, Map<String, Object?> params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  Future<void> close([StateError? error]) => _closeFuture ??= _close(error);

  Future<void> _close(StateError? error) async {
    if (_disposed) {
      await _waitForExitCleanup();
      return;
    }
    _failAll(error ?? StateError('$diagnosticName process is closed'));
    try {
      await _process.stdin.close();
    } on Object {
      // The child may close stdin before shutdown reaches this point.
    }
    if (_exited) {
      await _waitForExitCleanup();
      return;
    }

    _process.kill();
    if (await _waitForExit(_gracefulShutdownTimeout)) {
      await _waitForExitCleanup();
      return;
    }
    await _forceKillProcessTree(_process);
    if (!await _waitForExit(_forceShutdownTimeout)) {
      _warningSink(
        '$diagnosticName process did not report exit after forced termination',
        null,
        null,
      );
    } else {
      await _waitForExitCleanup();
    }
  }

  void _send(Map<String, Object?> message) {
    if (_disposed) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on Object {
      // Process exit is the authoritative error for cleanup races.
    }
  }

  void _handleStdoutChunk(String chunk) {
    _stdoutBuffer += chunk;
    while (true) {
      final newline = _stdoutBuffer.indexOf('\n');
      if (newline < 0) return;
      var line = _stdoutBuffer.substring(0, newline);
      _stdoutBuffer = _stdoutBuffer.substring(newline + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.trim().isNotEmpty) _handleLine(line);
    }
  }

  void _handleStderrChunk(String chunk) {
    _stderrBuffer += chunk;
    if (_stderrBuffer.length > _stderrBufferLimit) {
      _stderrBuffer = _stderrBuffer.substring(
        _stderrBuffer.length - _stderrBufferLimit,
      );
    }
  }

  void _handleLine(String line) {
    Object? parsed;
    try {
      parsed = jsonDecode(line);
    } on Object catch (error) {
      _warningSink(
        'Ignoring non-JSON $diagnosticName stdout line',
        error,
        line,
      );
      return;
    }
    final message = _stringMap(parsed);
    if (message == null || message['jsonrpc'] != '2.0') return;
    final method = message['method'];
    if (method is String) {
      unawaited(_handleIncoming(message, method));
      return;
    }
    if (message.containsKey('id')) _handleResponse(message);
  }

  void _handleResponse(Map<String, Object?> message) {
    final id = message['id'];
    if (id is! num && id is! String) return;
    final pending = _pending.remove('$id');
    if (pending == null) return;
    pending.timer?.cancel();
    final error = _stringMap(message['error']);
    if (error != null) {
      pending.completer.completeError(
        AcpRpcError(
          code: (error['code'] as num?)?.toInt() ?? -32603,
          message: error['message'] as String? ?? 'ACP request failed',
          data: error['data'],
        ),
      );
      return;
    }
    pending.completer.complete(message['result']);
  }

  Future<void> _handleIncoming(
    Map<String, Object?> message,
    String method,
  ) async {
    final params = _stringMap(message['params']) ?? const <String, Object?>{};
    final id = message['id'];
    try {
      final result = await _incomingHandler(method, params);
      if (id != null) {
        _send({'jsonrpc': '2.0', 'id': id, 'result': result ?? const {}});
      }
    } on Object catch (error) {
      if (id != null) {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': error.toString()},
        });
      } else {
        _warningSink('$diagnosticName notification failed', error, method);
      }
    }
  }

  void _handleExit(int code) {
    if (_exited) return;
    _exited = true;
    final error = StateError(
      '$diagnosticName process exited with code $code${_stderrSuffix()}',
    );
    final exit = AcpRpcExit(code: code, error: error);
    for (final subscriber in _exitSubscribers.toList(growable: false)) {
      subscriber(exit);
    }
    _failAll(error);
    unawaited(_cleanupExitSubscriptions());
  }

  Future<void> _cleanupExitSubscriptions() async {
    try {
      await Future.wait([
        _stdoutSubscription.cancel(),
        _stderrSubscription.cancel(),
        _exitSubscription.cancel(),
      ]);
    } finally {
      if (!_exitCleanup.isCompleted) _exitCleanup.complete();
    }
  }

  Future<void> _waitForExitCleanup() =>
      _exited ? _exitCleanup.future : Future.value();

  void _failAll(StateError error) {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.completer.completeError(error);
    }
    _pending.clear();
  }

  String _stderrSuffix() =>
      _stderrBuffer.isEmpty ? '' : '\n${_stderrBuffer.trimRight()}';

  Future<bool> _waitForExit(Duration timeout) async {
    if (_exited) return true;
    try {
      final code = await _process.exitCode.timeout(timeout);
      _handleExit(code);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

Future<Process> _spawnProcess(AcpRpcProcessLaunch launch) {
  final command = launch.command.toLowerCase();
  return Process.start(
    launch.command,
    launch.args,
    workingDirectory: launch.cwd,
    environment: launch.environment,
    includeParentEnvironment: launch.includeParentEnvironment,
    runInShell:
        Platform.isWindows &&
        (command.endsWith('.cmd') || command.endsWith('.bat')),
  );
}

Future<void> _forceKillProcessTree(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
  } else {
    Process.killPid(process.pid, ProcessSignal.sigkill);
  }
}

void _ignoreWarning(String message, Object? error, String? line) {}
