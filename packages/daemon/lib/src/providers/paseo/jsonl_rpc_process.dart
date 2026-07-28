import 'dart:async';
import 'dart:convert';
import 'dart:io';

const jsonlRpcDefaultTimeout = Duration(seconds: 30);
const _stderrBufferLimit = 8192;
const _gracefulShutdownTimeout = Duration(seconds: 2);
const _forceShutdownTimeout = Duration(seconds: 1);

typedef JsonlRpcWarningSink =
    void Function(String message, Object? error, String? line);
typedef JsonlRpcProcessStarter =
    Future<Process> Function(JsonlRpcLaunch launch);

final class JsonlRpcLaunch {
  const JsonlRpcLaunch({
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

final class JsonlRpcExit {
  const JsonlRpcExit({required this.code, required this.error});

  final int code;
  final StateError error;
}

final class JsonlRpcRequestHandle {
  const JsonlRpcRequestHandle({required this.id, required this.response});

  final String id;
  final Future<Object?> response;
}

final class _PendingRequest {
  _PendingRequest(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer? timer;
}

/// Line-delimited JSON request transport used by Paseo CLI provider runtimes.
///
/// A null, zero, or negative [timeout] waits until a response, process exit, or
/// [close]. This mirrors Paseo's `JSONL_RPC_NO_TIMEOUT` behavior.
final class JsonlRpcProcess {
  JsonlRpcProcess._({
    required Process process,
    required this.diagnosticName,
    required JsonlRpcWarningSink warningSink,
  }) : _process = process,
       _warningSink = warningSink {
    _stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_handleStdoutChunk);
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_handleStderrChunk);
    _exitSubscription = process.exitCode.asStream().listen(_handleExit);
  }

  static Future<JsonlRpcProcess> start({
    required JsonlRpcLaunch launch,
    String diagnosticName = 'JSONL RPC',
    JsonlRpcWarningSink? onWarning,
    JsonlRpcProcessStarter? spawn,
  }) async {
    final process = await (spawn ?? _spawnProcess)(launch);
    return JsonlRpcProcess._(
      process: process,
      diagnosticName: diagnosticName,
      warningSink: onWarning ?? _ignoreWarning,
    );
  }

  final Process _process;
  final String diagnosticName;
  final JsonlRpcWarningSink _warningSink;
  final Map<String, _PendingRequest> _pending = {};
  final Set<void Function(Map<String, Object?>)> _messageSubscribers = {};
  final Set<void Function(JsonlRpcExit)> _exitSubscribers = {};

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

  void Function() onMessage(void Function(Map<String, Object?>) callback) {
    _messageSubscribers.add(callback);
    return () => _messageSubscribers.remove(callback);
  }

  void Function() onExit(void Function(JsonlRpcExit) callback) {
    _exitSubscribers.add(callback);
    return () => _exitSubscribers.remove(callback);
  }

  JsonlRpcRequestHandle startRequest(
    Map<String, Object?> command, {
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) {
    if (_disposed) {
      return JsonlRpcRequestHandle(
        id: '',
        response: Future.error(StateError('$diagnosticName process is closed')),
      );
    }

    final id = 'req_${_nextRequestId++}';
    final completer = Completer<Object?>();
    Timer? timer;
    if (timeout != null && timeout > Duration.zero) {
      timer = Timer(timeout, () {
        _pending.remove(id);
        completer.completeError(
          StateError(
            '$diagnosticName request timed out for ${command['type']}'
            '${_stderrSuffix()}',
          ),
        );
      });
    }
    _pending[id] = _PendingRequest(completer, timer);
    send({...command, 'id': id});
    return JsonlRpcRequestHandle(id: id, response: completer.future);
  }

  Future<Object?> request(
    Map<String, Object?> command, {
    Duration? timeout = jsonlRpcDefaultTimeout,
  }) {
    return startRequest(command, timeout: timeout).response;
  }

  void send(Map<String, Object?> message) {
    if (_disposed) {
      return;
    }
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on Object {
      // Cleanup races and a child closing stdin are reported by process exit.
    }
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
      // Ignore cleanup races.
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

    _warningSink(
      '$diagnosticName process did not exit after the graceful signal; '
      'forcing termination',
      null,
      null,
    );
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

  void _handleStdoutChunk(String chunk) {
    _stdoutBuffer += chunk;
    while (true) {
      final newlineIndex = _stdoutBuffer.indexOf('\n');
      if (newlineIndex == -1) {
        return;
      }
      var line = _stdoutBuffer.substring(0, newlineIndex);
      _stdoutBuffer = _stdoutBuffer.substring(newlineIndex + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.trim().isNotEmpty) {
        _handleLine(line);
      }
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
    if (parsed is! Map) {
      return;
    }
    final message = <String, Object?>{};
    for (final entry in parsed.entries) {
      if (entry.key is! String) {
        return;
      }
      message[entry.key as String] = entry.value;
    }
    if (message['type'] == 'response') {
      _handleResponse(message);
      return;
    }
    for (final subscriber in _messageSubscribers.toList(growable: false)) {
      subscriber(message);
    }
  }

  void _handleResponse(Map<String, Object?> response) {
    final id = response['id'];
    if (id is! String) {
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) {
      return;
    }
    pending.timer?.cancel();
    if (response['success'] != true) {
      final command = response['command'];
      pending.completer.completeError(
        StateError(
          response['error'] is String
              ? response['error']! as String
              : '$diagnosticName '
                    '${command is String ? command : 'request'} failed',
        ),
      );
      return;
    }
    pending.completer.complete(response['data']);
  }

  void _handleExit(int code) {
    if (_exited) return;
    _exited = true;
    final error = StateError(
      '$diagnosticName process exited with code $code and signal null'
      '${_stderrSuffix()}',
    );
    final exit = JsonlRpcExit(code: code, error: error);
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
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.completer.completeError(error);
    }
    _pending.clear();
  }

  String _stderrSuffix() {
    return _stderrBuffer.isEmpty ? '' : '\n$_stderrBuffer';
  }

  Future<bool> _waitForExit(Duration timeout) async {
    if (_exited) {
      return true;
    }
    try {
      final code = await _process.exitCode.timeout(timeout);
      _handleExit(code);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

Future<Process> _spawnProcess(JsonlRpcLaunch launch) {
  final lowerCommand = launch.command.toLowerCase();
  final runInShell =
      Platform.isWindows &&
      (lowerCommand.endsWith('.cmd') || lowerCommand.endsWith('.bat'));
  return Process.start(
    launch.command,
    launch.args,
    workingDirectory: launch.cwd,
    environment: launch.environment,
    includeParentEnvironment: launch.includeParentEnvironment,
    runInShell: runInShell,
  );
}

Future<void> _forceKillProcessTree(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']);
    return;
  }
  Process.killPid(process.pid, ProcessSignal.sigkill);
}

void _ignoreWarning(String message, Object? error, String? line) {}
