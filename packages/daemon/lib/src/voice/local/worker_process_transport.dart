import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'sherpa/runtime_env.dart';
import 'worker_protocol.dart';
import 'worker_transport.dart';

const String localSpeechWorkerExecutableEnvironment =
    'TINYRACK_LOCAL_SPEECH_WORKER';

final class LocalSpeechWorkerCommand {
  const LocalSpeechWorkerCommand({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
}

LocalSpeechWorkerCommand resolveLocalSpeechWorkerCommand({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool? isWindows,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final os = (isWindows ?? Platform.isWindows)
      ? 'windows'
      : Platform.operatingSystem;
  final configured = env[localSpeechWorkerExecutableEnvironment]?.trim();
  if (configured != null && configured.isNotEmpty) {
    return LocalSpeechWorkerCommand(
      executable: configured,
      environment: _workerEnvironment(env, configured, os),
    );
  }

  final runtime = resolvedExecutable ?? Platform.resolvedExecutable;
  final windows = os == 'windows';
  final exists = fileExists ?? (path) => File(path).existsSync();
  final runtimeName = p.basenameWithoutExtension(runtime).toLowerCase();
  if (runtimeName == 'dart' || runtimeName == 'dartaotruntime') {
    final workerEnvironment = _workerEnvironment(env, runtime, os);
    return LocalSpeechWorkerCommand(
      executable: runtime,
      arguments: const ['run', 'agent_daemon:local_speech_worker'],
      environment: workerEnvironment,
    );
  }

  final sibling = p.join(
    p.dirname(runtime),
    windows ? 'coding-agent-voice.exe' : 'coding-agent-voice',
  );
  if (!exists(sibling)) {
    throw StateError(
      'Local speech worker executable not found at $sibling. '
      'Set $localSpeechWorkerExecutableEnvironment to its path.',
    );
  }
  return LocalSpeechWorkerCommand(
    executable: sibling,
    environment: _workerEnvironment(env, sibling, os),
  );
}

Map<String, String> _workerEnvironment(
  Map<String, String> environment,
  String executable,
  String operatingSystem,
) {
  final libraryDirectory = resolveSherpaLibraryDirectory(
    environment: environment,
    resolvedExecutable: executable,
    operatingSystem: operatingSystem,
  );
  var result = libraryDirectory == null
      ? Map<String, String>.from(environment)
      : applySherpaLoaderEnvironment(
          environment: environment,
          libraryDirectory: libraryDirectory,
          operatingSystem: operatingSystem,
        );
  try {
    final sileroAsset = resolveBundledSileroVadModelPath(
      environment: result,
      resolvedExecutable: executable,
    );
    result = {...result, sileroVadAssetEnvironment: sileroAsset};
  } on StateError {
    // The worker reports the actionable missing-asset error if VAD is used.
  }
  return result;
}

Future<LocalSpeechWorkerTransport> startLocalSpeechWorkerProcess({
  LocalSpeechWorkerCommand? command,
  ProcessStartMode mode = ProcessStartMode.normal,
}) async {
  final resolved = command ?? resolveLocalSpeechWorkerCommand();
  final process = await Process.start(
    resolved.executable,
    resolved.arguments,
    workingDirectory: resolved.workingDirectory,
    environment: resolved.environment,
    mode: mode,
    runInShell: false,
  );
  return LocalSpeechWorkerProcessTransport(process);
}

final class LocalSpeechWorkerProcessTransport
    implements LocalSpeechWorkerTransport {
  LocalSpeechWorkerProcessTransport(Process process) : _process = process {
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: _messages.addError,
          onDone: _messages.close,
        );
    _stderrSubscription = process.stderr.listen(
      _stderr.add,
      onError: _stderr.addError,
      onDone: _stderr.close,
    );
    unawaited(
      process.exitCode.then((code) {
        _connected = false;
        _killed = true;
        if (!_exit.isCompleted) {
          _exit.complete(LocalSpeechWorkerExit(exitCode: code));
        }
      }),
    );
  }

  final Process _process;
  final StreamController<LocalSpeechWorkerMessage> _messages =
      StreamController.broadcast(sync: true);
  final StreamController<List<int>> _stderr = StreamController.broadcast(
    sync: true,
  );
  final Completer<LocalSpeechWorkerExit> _exit = Completer();
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<List<int>> _stderrSubscription;
  Future<void> _writeChain = Future.value();
  bool _connected = true;
  bool _killed = false;
  bool _shutdownStarted = false;

  @override
  int get pid => _process.pid;

  @override
  bool get connected => _connected;

  @override
  bool get killed => _killed;

  @override
  Stream<LocalSpeechWorkerMessage> get messages => _messages.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<LocalSpeechWorkerExit> get exited => _exit.future;

  @override
  Future<void> send(LocalSpeechWorkerRequest request) {
    if (!_connected || _shutdownStarted) {
      return Future.error(StateError('Local speech worker is not connected'));
    }
    final encoded = '${jsonEncode(request.toJson())}\n';
    final next = _writeChain.then((_) async {
      if (!_connected || _shutdownStarted) {
        throw StateError('Local speech worker is not connected');
      }
      _process.stdin.add(utf8.encode(encoded));
      await _process.stdin.flush();
    });
    _writeChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<void> shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    _connected = false;
    try {
      await _process.stdin.close();
    } on Object {
      // The process may already have closed its input channel.
    }
    if (!_killed) {
      _process.kill();
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException(
          'Local speech worker message must be an object',
        );
      }
      _messages.add(
        LocalSpeechWorkerMessage.fromJson(Map<String, Object?>.from(decoded)),
      );
    } on Object catch (error, stackTrace) {
      _messages.addError(error, stackTrace);
    }
  }

  Future<void> dispose() async {
    await shutdown();
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    if (!_messages.isClosed) await _messages.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}
