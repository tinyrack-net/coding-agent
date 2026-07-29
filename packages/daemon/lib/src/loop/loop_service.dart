import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/structured_generation.dart';

const _maxVerifyOutputBytes = 64 * 1024;

final class LoopWorkspacePlacement {
  const LoopWorkspacePlacement({
    required this.cwd,
    this.workspaceId,
    this.projectPath,
    this.branch,
    this.isWorktree = false,
  });

  final String cwd;
  final String? workspaceId;
  final String? projectPath;
  final String? branch;
  final bool isWorktree;
}

final class LoopAgentSpec {
  const LoopAgentSpec({
    required this.cwd,
    required this.provider,
    required this.model,
    required this.modeId,
    required this.title,
    required this.workspace,
    required this.onLog,
  });

  final String cwd;
  final String provider;
  final String? model;
  final String? modeId;
  final String title;
  final LoopWorkspacePlacement workspace;
  final void Function(String text, {bool error}) onLog;
}

abstract interface class LoopAgentSession {
  String get agentId;
  Future<String> run(String prompt);
  Future<void> cancel();
  Future<void> dispose({required bool archive});
}

typedef LoopAgentSessionFactory =
    Future<LoopAgentSession> Function(LoopAgentSpec spec);
typedef LoopWorkspaceResolver =
    Future<LoopWorkspacePlacement> Function(String cwd, String prompt);
typedef LoopVerifyCheckRunner =
    Future<LoopVerifyCheckResult> Function(String cwd, String command);

final class LoopService {
  LoopService({
    required String home,
    required LoopAgentSessionFactory createAgentSession,
    LoopWorkspaceResolver? resolveWorkspace,
    LoopVerifyCheckRunner? runVerifyCheck,
    DateTime Function()? now,
    String Function()? idFactory,
    void Function(Object error, StackTrace stack)? onError,
  }) : _storePath = p.join(home, 'loops', 'loops.json'),
       _createAgentSession = createAgentSession,
       _resolveWorkspace =
           resolveWorkspace ??
           ((cwd, _) async => LoopWorkspacePlacement(cwd: cwd)),
       _runVerifyCheck = runVerifyCheck ?? runLoopVerifyCheck,
       _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _randomLoopId,
       _onError = onError;

  final String _storePath;
  final LoopAgentSessionFactory _createAgentSession;
  final LoopWorkspaceResolver _resolveWorkspace;
  final LoopVerifyCheckRunner _runVerifyCheck;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final void Function(Object error, StackTrace stack)? _onError;
  final Map<String, _LoopState> _loops = {};
  final Map<String, _LoopExecution> _running = {};
  Future<void> _persistQueue = Future.value();
  bool _initialized = false;
  bool _shuttingDown = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _loops.clear();
    final file = File(_storePath);
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! List) {
          throw const FormatException('loops store must be an array');
        }
        for (final value in decoded) {
          final record = LoopRecord.fromJson(
            Map<String, Object?>.from(value as Map),
          );
          final state = _LoopState.fromRecord(record);
          if (state.status == LoopStatus.running) {
            final timestamp = _timestamp();
            state
              ..status = LoopStatus.stopped
              ..updatedAt = timestamp
              ..completedAt = timestamp
              ..stopRequestedAt = timestamp
              ..activeIteration = null
              ..activeWorkerAgentId = null
              ..activeVerifierAgentId = null;
            state.appendLog(
              timestamp: timestamp,
              iteration: null,
              source: LoopLogSource.loop,
              level: LoopLogLevel.error,
              text: 'Loop was interrupted by daemon restart.',
            );
            if (state.iterations.lastOrNull case final iteration?
                when iteration.status == LoopIterationStatus.running) {
              iteration
                ..status = LoopIterationStatus.stopped
                ..failureReason = 'Daemon restarted'
                ..workerCompletedAt = timestamp;
            }
          }
          _loops[state.id] = state;
        }
      }
    } on FileSystemException catch (error, stack) {
      if (error.osError?.errorCode != 2) _onError?.call(error, stack);
    } on Object catch (error, stack) {
      _onError?.call(error, stack);
    }
    _initialized = true;
    await _persist();
  }

  Future<LoopRecord> runLoop(LoopRunRequest request) async {
    await initialize();
    final prompt = request.prompt.trim();
    if (prompt.isEmpty) throw StateError('prompt cannot be empty');
    final verifyPrompt = _optionalText(request.verifyPrompt, 'verifyPrompt');
    final verifyChecks = [
      for (final command in request.verifyChecks)
        _requiredText(command, 'verifyChecks'),
    ];
    if (verifyPrompt == null && verifyChecks.isEmpty) {
      throw StateError('Loop requires --verify or at least one --verify-check');
    }
    final cwd = p.normalize(p.absolute(request.cwd));
    final directory = Directory(cwd);
    if (!await directory.exists()) {
      throw StateError('Working directory $cwd no longer exists');
    }
    if ((await directory.stat()).type != FileSystemEntityType.directory) {
      throw StateError('Working directory $cwd is not a directory');
    }
    final sleepMs = request.sleepMs ?? 0;
    if (sleepMs < 0) throw StateError('sleepMs must be a non-negative integer');
    final id = _uniqueId();
    final timestamp = _timestamp();
    final state = _LoopState(
      id: id,
      name: _optionalText(request.name, 'name'),
      prompt: prompt,
      cwd: cwd,
      provider: request.provider ?? 'claude',
      model: _optionalText(request.model, 'model'),
      modeId: _optionalText(request.modeId, 'modeId'),
      workerProvider: _optionalText(request.workerProvider, 'workerProvider'),
      workerModel: _optionalText(request.workerModel, 'workerModel'),
      verifierProvider: _optionalText(
        request.verifierProvider,
        'verifierProvider',
      ),
      verifierModel: _optionalText(request.verifierModel, 'verifierModel'),
      verifierModeId: _optionalText(request.verifierModeId, 'verifierModeId'),
      verifyPrompt: verifyPrompt,
      verifyChecks: verifyChecks,
      archive: request.archive ?? false,
      sleepMs: sleepMs,
      maxIterations: request.maxIterations,
      maxTimeMs: request.maxTimeMs,
      status: LoopStatus.running,
      createdAt: timestamp,
      updatedAt: timestamp,
      startedAt: timestamp,
    );
    state.appendLog(
      timestamp: timestamp,
      iteration: null,
      source: LoopLogSource.loop,
      level: LoopLogLevel.info,
      text: 'Loop created in ${state.cwd}',
    );
    _loops[id] = state;
    await _persist();

    final execution = _LoopExecution();
    _running[id] = execution;
    execution.task = _execute(state, execution).whenComplete(() {
      _running.remove(id);
    });
    unawaited(
      execution.task.catchError((Object error, StackTrace stack) {
        _onError?.call(error, stack);
      }),
    );
    return state.snapshot();
  }

  Future<List<LoopListItem>> listLoops() async {
    await initialize();
    await _awaitTerminalPersists();
    final values = _loops.values.toList()
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return [
      for (final state in values)
        LoopListItem(
          id: state.id,
          name: state.name,
          status: state.status,
          cwd: state.cwd,
          createdAt: state.createdAt,
          updatedAt: state.updatedAt,
          activeIteration: state.activeIteration,
        ),
    ];
  }

  Future<LoopRecord> inspectLoop(String idOrPrefix) async {
    await initialize();
    final state = _requireLoop(idOrPrefix);
    await _awaitTerminalPersist(state);
    return state.snapshot();
  }

  Future<({LoopRecord loop, List<LoopLogEntry> entries, int nextCursor})>
  getLoopLogs(String idOrPrefix, {int afterSeq = 0}) async {
    await initialize();
    if (afterSeq < 0) throw StateError('afterSeq must be non-negative');
    final state = _requireLoop(idOrPrefix);
    await _awaitTerminalPersist(state);
    return (
      loop: state.snapshot(),
      entries: List<LoopLogEntry>.unmodifiable(
        state.logs.where((entry) => entry.seq > afterSeq),
      ),
      nextCursor: state.nextLogSeq - 1,
    );
  }

  Future<LoopRecord> stopLoop(String idOrPrefix) async {
    await initialize();
    final state = _requireLoop(idOrPrefix);
    if (state.status != LoopStatus.running) return state.snapshot();
    final timestamp = _timestamp();
    state
      ..stopRequestedAt ??= timestamp
      ..updatedAt = timestamp;
    state.appendLog(
      timestamp: timestamp,
      iteration: state.activeIteration,
      source: LoopLogSource.loop,
      level: LoopLogLevel.info,
      text: 'Stop requested.',
    );
    await _persist();
    final execution = _running[state.id];
    if (execution == null) {
      _finish(state, LoopStatus.stopped, 'Loop stopped.');
      await _persist();
      return state.snapshot();
    }
    execution.requestStop();
    try {
      await execution.activeSession?.cancel();
    } on Object {
      // The execution observes the stop flag even when a provider is gone.
    }
    await execution.task;
    return state.snapshot();
  }

  /// Settles live provider calls without converting durable running records.
  ///
  /// Paseo recovers those records as daemon-restart interruptions on the next
  /// startup, rather than reporting a user-requested stop or execution failure.
  Future<void> prepareForDaemonShutdown() async {
    _shuttingDown = true;
    final executions = _running.values.toList(growable: false);
    for (final execution in executions) {
      execution.requestStop();
      try {
        await execution.activeSession?.cancel();
      } on Object {
        // Manager disposal remains the final shutdown fence.
      }
    }
    await Future.wait([for (final execution in executions) execution.task]);
    await _persistQueue;
  }

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final type = message['type'];
    if (type is! String || !type.startsWith('loop/')) return null;
    final requestId = message['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    try {
      switch (type) {
        case LoopRunRequest.type:
          final loop = await runLoop(LoopRunRequest.fromJson(message));
          return loopResponse(
            requestType: type,
            requestId: requestId,
            payload: {'loop': loop.toJson(), 'error': null},
          );
        case LoopListRequest.type:
          LoopListRequest.fromJson(message);
          final loops = await listLoops();
          return loopResponse(
            requestType: type,
            requestId: requestId,
            payload: {
              'loops': loops.map((loop) => loop.toJson()).toList(),
              'error': null,
            },
          );
        default:
          final request = LoopIdRequest.fromJson(message);
          return await _handleIdRequest(request);
      }
    } on Object catch (error) {
      final text = _errorText(error);
      return loopResponse(
        requestType: type,
        requestId: requestId,
        payload: switch (type) {
          LoopListRequest.type => {'loops': <Object?>[], 'error': text},
          LoopIdRequest.logsType => {
            'loop': null,
            'entries': <Object?>[],
            'nextCursor': 0,
            'error': text,
          },
          _ => {'loop': null, 'error': text},
        },
      );
    }
  }

  Future<Map<String, Object?>> _handleIdRequest(LoopIdRequest request) async {
    late final Map<String, Object?> payload;
    switch (request.type) {
      case LoopIdRequest.inspectType:
        payload = {
          'loop': (await inspectLoop(request.id)).toJson(),
          'error': null,
        };
      case LoopIdRequest.logsType:
        final result = await getLoopLogs(
          request.id,
          afterSeq: request.afterSeq ?? 0,
        );
        payload = {
          'loop': result.loop.toJson(),
          'entries': result.entries.map((entry) => entry.toJson()).toList(),
          'nextCursor': result.nextCursor,
          'error': null,
        };
      case LoopIdRequest.stopType:
        payload = {
          'loop': (await stopLoop(request.id)).toJson(),
          'error': null,
        };
      default:
        throw StateError('Unsupported loop request ${request.type}');
    }
    return loopResponse(
      requestType: request.type,
      requestId: request.requestId,
      payload: payload,
    );
  }

  Future<void> _execute(_LoopState loop, _LoopExecution execution) async {
    final deadline = loop.maxTimeMs == null
        ? null
        : _now().add(Duration(milliseconds: loop.maxTimeMs!));
    late final LoopWorkspacePlacement workspace;
    try {
      workspace = await _resolveWorkspace(loop.cwd, loop.prompt);
      for (var index = 1; ; index++) {
        _throwIfStopped(execution);
        if (loop.maxIterations != null && index > loop.maxIterations!) {
          _finish(
            loop,
            LoopStatus.failed,
            'Reached max iterations (${loop.maxIterations}).',
          );
          await _persist();
          return;
        }
        if (deadline != null && _now().isAfter(deadline)) {
          _finish(
            loop,
            LoopStatus.failed,
            'Reached max time (${loop.maxTimeMs}ms).',
          );
          await _persist();
          return;
        }
        final iteration = _LoopIterationState(
          index: index,
          workerStartedAt: _timestamp(),
        );
        loop.iterations.add(iteration);
        loop
          ..activeIteration = index
          ..updatedAt = _timestamp();
        _append(
          loop,
          iteration: index,
          source: LoopLogSource.loop,
          text: 'Starting iteration $index.',
        );
        await _persist();

        final workerPassed = await _runWorker(
          loop,
          iteration,
          execution,
          workspace,
        );
        _throwIfStopped(execution);
        if (!workerPassed) {
          if (iteration.status != LoopIterationStatus.stopped) {
            iteration.status = LoopIterationStatus.failed;
          }
        } else {
          final verificationPassed = await _runVerification(
            loop,
            iteration,
            execution,
            workspace,
          );
          if (verificationPassed) {
            iteration.status = LoopIterationStatus.succeeded;
            _finish(
              loop,
              LoopStatus.succeeded,
              'Iteration $index passed verification.',
            );
            await _persist();
            return;
          }
          if (iteration.status == LoopIterationStatus.running) {
            iteration.status = LoopIterationStatus.failed;
          }
        }

        loop
          ..activeIteration = null
          ..activeWorkerAgentId = null
          ..activeVerifierAgentId = null
          ..updatedAt = _timestamp();
        await _persist();
        if (loop.sleepMs > 0) {
          _append(
            loop,
            iteration: index,
            source: LoopLogSource.loop,
            text: 'Sleeping ${loop.sleepMs}ms before next iteration.',
          );
          await _persist();
          await execution.sleep(Duration(milliseconds: loop.sleepMs));
        }
      }
    } on _LoopAborted {
      if (_shuttingDown) {
        await _persist();
        return;
      }
      final activeIteration = loop.activeIteration;
      _finish(loop, LoopStatus.stopped, 'Loop stopped.');
      if (activeIteration case final active?) {
        final iteration = loop.iterations
            .where((candidate) => candidate.index == active)
            .firstOrNull;
        if (iteration?.status == LoopIterationStatus.running) {
          iteration!
            ..status = LoopIterationStatus.stopped
            ..failureReason = 'Loop stopped'
            ..workerCompletedAt = _timestamp();
        }
      }
      await _persist();
    } on Object catch (error, stack) {
      if (_shuttingDown) {
        await _persist();
        return;
      }
      final message = _errorText(error);
      _onError?.call(error, stack);
      final activeIteration = loop.activeIteration;
      _finish(loop, LoopStatus.failed, message);
      if (activeIteration case final active?) {
        final iteration = loop.iterations
            .where((candidate) => candidate.index == active)
            .firstOrNull;
        if (iteration?.status == LoopIterationStatus.running) {
          iteration!
            ..status = LoopIterationStatus.failed
            ..failureReason = message
            ..workerCompletedAt = _timestamp();
        }
      }
      await _persist();
    }
  }

  Future<bool> _runWorker(
    _LoopState loop,
    _LoopIterationState iteration,
    _LoopExecution execution,
    LoopWorkspacePlacement workspace,
  ) async {
    LoopAgentSession? session;
    try {
      session = await _createAgentSession(
        LoopAgentSpec(
          cwd: workspace.cwd,
          provider: loop.workerProvider ?? loop.provider,
          model: loop.workerModel ?? loop.model,
          modeId: loop.modeId,
          title:
              '${loop.name ?? loop.id} '
              '[loop ${iteration.index} worker]',
          workspace: workspace,
          onLog: (text, {error = false}) {
            _append(
              loop,
              iteration: iteration.index,
              source: LoopLogSource.worker,
              level: error ? LoopLogLevel.error : LoopLogLevel.info,
              text: text,
            );
            unawaited(_persist());
          },
        ),
      );
      execution.activeSession = session;
      iteration.workerAgentId = session.agentId;
      loop
        ..activeWorkerAgentId = session.agentId
        ..updatedAt = _timestamp();
      await _persist();
      await session.run(loop.prompt);
      _throwIfStopped(execution);
      iteration
        ..workerCompletedAt = _timestamp()
        ..workerOutcome = LoopWorkerOutcome.completed;
      return true;
    } on _LoopAborted {
      if (!_shuttingDown) {
        iteration
          ..workerCompletedAt = _timestamp()
          ..workerOutcome = LoopWorkerOutcome.canceled;
      }
      rethrow;
    } on Object catch (error) {
      if (execution.stopRequested) {
        if (!_shuttingDown) {
          iteration
            ..workerCompletedAt = _timestamp()
            ..workerOutcome = LoopWorkerOutcome.canceled;
        }
        throw const _LoopAborted();
      }
      iteration
        ..workerCompletedAt = _timestamp()
        ..workerOutcome = LoopWorkerOutcome.failed
        ..failureReason = _errorText(error);
      _append(
        loop,
        iteration: iteration.index,
        source: LoopLogSource.loop,
        level: LoopLogLevel.error,
        text: 'Worker failed: ${iteration.failureReason}',
      );
      return false;
    } finally {
      execution.activeSession = null;
      loop
        ..activeWorkerAgentId = null
        ..updatedAt = _timestamp();
      if (session != null) {
        try {
          await session.dispose(archive: loop.archive);
        } on Object {
          // Cleanup cannot hide the worker result.
        }
      }
      await _persist();
    }
  }

  Future<bool> _runVerification(
    _LoopState loop,
    _LoopIterationState iteration,
    _LoopExecution execution,
    LoopWorkspacePlacement workspace,
  ) async {
    for (final command in loop.verifyChecks) {
      _throwIfStopped(execution);
      _append(
        loop,
        iteration: iteration.index,
        source: LoopLogSource.verifyCheck,
        text: '\$ $command',
      );
      final result = await _runVerifyCheck(loop.cwd, command);
      iteration.verifyChecks.add(result);
      final output = [
        result.stdout.trim(),
        result.stderr.trim(),
      ].where((value) => value.isNotEmpty).join('\n');
      _append(
        loop,
        iteration: iteration.index,
        source: LoopLogSource.verifyCheck,
        level: result.passed ? LoopLogLevel.info : LoopLogLevel.error,
        text: output.isEmpty
            ? 'exit ${result.exitCode}'
            : 'exit ${result.exitCode}\n$output',
      );
      await _persist();
      if (!result.passed) {
        iteration.failureReason = 'Verify check failed: $command';
        return false;
      }
    }
    final verifyPrompt = loop.verifyPrompt;
    if (verifyPrompt == null) return true;

    final startedAt = _timestamp();
    LoopAgentSession? session;
    try {
      session = await _createAgentSession(
        LoopAgentSpec(
          cwd: workspace.cwd,
          provider: loop.verifierProvider ?? loop.provider,
          model: loop.verifierModel ?? loop.model,
          modeId: loop.verifierModeId ?? loop.modeId,
          title:
              '${loop.name ?? loop.id} '
              '[loop ${iteration.index} verifier]',
          workspace: workspace,
          onLog: (text, {error = false}) {
            _append(
              loop,
              iteration: iteration.index,
              source: LoopLogSource.verifier,
              level: error ? LoopLogLevel.error : LoopLogLevel.info,
              text: text,
            );
            unawaited(_persist());
          },
        ),
      );
      execution.activeSession = session;
      iteration.verifierAgentId = session.agentId;
      loop
        ..activeVerifierAgentId = session.agentId
        ..updatedAt = _timestamp();
      await _persist();
      final result = await getStructuredAgentResponse(
        caller: session.run,
        prompt: verifyPrompt,
        jsonSchema: const {
          'type': 'object',
          'properties': {
            'passed': {'type': 'boolean'},
            'reason': {'type': 'string', 'minLength': 1},
          },
          'required': ['passed', 'reason'],
          'additionalProperties': false,
        },
        maxRetries: 2,
      );
      _throwIfStopped(execution);
      final passed = result['passed'] as bool;
      final reason = result['reason'] as String;
      iteration.verifyPrompt = LoopVerifyPromptResult(
        passed: passed,
        reason: reason,
        verifierAgentId: session.agentId,
        startedAt: startedAt,
        completedAt: _timestamp(),
      );
      _append(
        loop,
        iteration: iteration.index,
        source: LoopLogSource.loop,
        level: passed ? LoopLogLevel.info : LoopLogLevel.error,
        text: 'Verifier result: $reason',
      );
      if (!passed) iteration.failureReason = reason;
      return passed;
    } on Object {
      if (execution.stopRequested) throw const _LoopAborted();
      rethrow;
    } finally {
      execution.activeSession = null;
      loop
        ..activeVerifierAgentId = null
        ..updatedAt = _timestamp();
      if (session != null) {
        try {
          await session.dispose(archive: loop.archive);
        } on Object {
          // Cleanup cannot hide the verifier result.
        }
      }
      await _persist();
    }
  }

  void _finish(_LoopState loop, LoopStatus status, String message) {
    final timestamp = _timestamp();
    loop
      ..status = status
      ..completedAt = timestamp
      ..updatedAt = timestamp
      ..activeIteration = null
      ..activeWorkerAgentId = null
      ..activeVerifierAgentId = null;
    loop.appendLog(
      timestamp: timestamp,
      iteration: null,
      source: LoopLogSource.loop,
      level: status == LoopStatus.succeeded
          ? LoopLogLevel.info
          : LoopLogLevel.error,
      text: message,
    );
  }

  void _append(
    _LoopState loop, {
    required int? iteration,
    required LoopLogSource source,
    LoopLogLevel level = LoopLogLevel.info,
    required String text,
  }) => loop.appendLog(
    timestamp: _timestamp(),
    iteration: iteration,
    source: source,
    level: level,
    text: text,
  );

  _LoopState _requireLoop(String idOrPrefix) {
    final id = idOrPrefix.trim();
    if (id.isEmpty) throw StateError('Loop id is required');
    final exact = _loops[id];
    if (exact != null) return exact;
    final matches = _loops.values
        .where((record) => record.id.startsWith(id))
        .toList();
    if (matches.length == 1) return matches.single;
    if (matches.length > 1) {
      throw StateError('Loop id prefix is ambiguous: $id');
    }
    throw StateError('Loop not found: $id');
  }

  String _uniqueId() {
    for (var attempt = 0; attempt < 100; attempt++) {
      final id = _idFactory();
      if (id.isNotEmpty && !_loops.containsKey(id)) return id;
    }
    throw StateError('Unable to allocate a unique loop id');
  }

  String _timestamp() => _now().toUtc().toIso8601String();

  Future<void> _awaitTerminalPersists() async {
    final pending = [
      for (final state in _loops.values)
        if (state.status != LoopStatus.running)
          if (_running[state.id] case final execution?) execution.task,
    ];
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  Future<void> _awaitTerminalPersist(_LoopState state) async {
    if (state.status == LoopStatus.running) return;
    final execution = _running[state.id];
    if (execution != null) await execution.task;
  }

  Future<void> _persist() {
    final next = _persistQueue.then((_) async {
      final file = File(_storePath);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      final records = _loops.values.toList()
        ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
      await temporary.writeAsString(
        jsonEncode(
          records.map((record) => record.snapshot().toJson()).toList(),
        ),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    _persistQueue = next.catchError((_) {});
    return next;
  }
}

final class _LoopExecution {
  bool stopRequested = false;
  LoopAgentSession? activeSession;
  late Future<void> task;
  final Completer<void> _stop = Completer<void>();

  void requestStop() {
    stopRequested = true;
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<void> sleep(Duration duration) async {
    await Future.any([Future<void>.delayed(duration), _stop.future]);
    if (stopRequested) throw const _LoopAborted();
  }
}

final class _LoopAborted implements Exception {
  const _LoopAborted();
}

void _throwIfStopped(_LoopExecution execution) {
  if (execution.stopRequested) throw const _LoopAborted();
}

final class _LoopState {
  _LoopState({
    required this.id,
    required this.name,
    required this.prompt,
    required this.cwd,
    required this.provider,
    required this.model,
    required this.modeId,
    required this.workerProvider,
    required this.workerModel,
    required this.verifierProvider,
    required this.verifierModel,
    required this.verifierModeId,
    required this.verifyPrompt,
    required this.verifyChecks,
    required this.archive,
    required this.sleepMs,
    required this.maxIterations,
    required this.maxTimeMs,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    this.completedAt,
    this.stopRequestedAt,
    List<_LoopIterationState>? iterations,
    List<LoopLogEntry>? logs,
    this.nextLogSeq = 1,
    this.activeIteration,
    this.activeWorkerAgentId,
    this.activeVerifierAgentId,
  }) : iterations = iterations ?? [],
       logs = logs ?? [];

  factory _LoopState.fromRecord(LoopRecord record) => _LoopState(
    id: record.id,
    name: record.name,
    prompt: record.prompt,
    cwd: record.cwd,
    provider: record.provider,
    model: record.model,
    modeId: record.modeId,
    workerProvider: record.workerProvider,
    workerModel: record.workerModel,
    verifierProvider: record.verifierProvider,
    verifierModel: record.verifierModel,
    verifierModeId: record.verifierModeId,
    verifyPrompt: record.verifyPrompt,
    verifyChecks: [...record.verifyChecks],
    archive: record.archive,
    sleepMs: record.sleepMs,
    maxIterations: record.maxIterations,
    maxTimeMs: record.maxTimeMs,
    status: record.status,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    startedAt: record.startedAt,
    completedAt: record.completedAt,
    stopRequestedAt: record.stopRequestedAt,
    iterations: record.iterations.map(_LoopIterationState.fromRecord).toList(),
    logs: [...record.logs],
    nextLogSeq: record.nextLogSeq,
    activeIteration: record.activeIteration,
    activeWorkerAgentId: record.activeWorkerAgentId,
    activeVerifierAgentId: record.activeVerifierAgentId,
  );

  final String id;
  final String? name;
  final String prompt;
  final String cwd;
  final String provider;
  final String? model;
  final String? modeId;
  final String? workerProvider;
  final String? workerModel;
  final String? verifierProvider;
  final String? verifierModel;
  final String? verifierModeId;
  final String? verifyPrompt;
  final List<String> verifyChecks;
  final bool archive;
  final int sleepMs;
  final int? maxIterations;
  final int? maxTimeMs;
  LoopStatus status;
  final String createdAt;
  String updatedAt;
  final String startedAt;
  String? completedAt;
  String? stopRequestedAt;
  final List<_LoopIterationState> iterations;
  final List<LoopLogEntry> logs;
  int nextLogSeq;
  int? activeIteration;
  String? activeWorkerAgentId;
  String? activeVerifierAgentId;

  void appendLog({
    required String timestamp,
    required int? iteration,
    required LoopLogSource source,
    required LoopLogLevel level,
    required String text,
  }) {
    logs.add(
      LoopLogEntry(
        seq: nextLogSeq++,
        timestamp: timestamp,
        iteration: iteration,
        source: source,
        level: level,
        text: text,
      ),
    );
    updatedAt = timestamp;
  }

  LoopRecord snapshot() => LoopRecord(
    id: id,
    name: name,
    prompt: prompt,
    cwd: cwd,
    provider: provider,
    model: model,
    modeId: modeId,
    workerProvider: workerProvider,
    workerModel: workerModel,
    verifierProvider: verifierProvider,
    verifierModel: verifierModel,
    verifierModeId: verifierModeId,
    verifyPrompt: verifyPrompt,
    verifyChecks: List.unmodifiable(verifyChecks),
    archive: archive,
    sleepMs: sleepMs,
    maxIterations: maxIterations,
    maxTimeMs: maxTimeMs,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    startedAt: startedAt,
    completedAt: completedAt,
    stopRequestedAt: stopRequestedAt,
    iterations: List.unmodifiable(
      iterations.map((iteration) => iteration.snapshot()),
    ),
    logs: List.unmodifiable(logs),
    nextLogSeq: nextLogSeq,
    activeIteration: activeIteration,
    activeWorkerAgentId: activeWorkerAgentId,
    activeVerifierAgentId: activeVerifierAgentId,
  );
}

final class _LoopIterationState {
  _LoopIterationState({
    required this.index,
    required this.workerStartedAt,
    this.workerAgentId,
    this.workerCompletedAt,
    this.verifierAgentId,
    this.status = LoopIterationStatus.running,
    this.workerOutcome,
    this.failureReason,
    List<LoopVerifyCheckResult>? verifyChecks,
    this.verifyPrompt,
  }) : verifyChecks = verifyChecks ?? [];

  factory _LoopIterationState.fromRecord(LoopIterationRecord record) =>
      _LoopIterationState(
        index: record.index,
        workerAgentId: record.workerAgentId,
        workerStartedAt: record.workerStartedAt,
        workerCompletedAt: record.workerCompletedAt,
        verifierAgentId: record.verifierAgentId,
        status: record.status,
        workerOutcome: record.workerOutcome,
        failureReason: record.failureReason,
        verifyChecks: [...record.verifyChecks],
        verifyPrompt: record.verifyPrompt,
      );

  final int index;
  String? workerAgentId;
  final String workerStartedAt;
  String? workerCompletedAt;
  String? verifierAgentId;
  LoopIterationStatus status;
  LoopWorkerOutcome? workerOutcome;
  String? failureReason;
  final List<LoopVerifyCheckResult> verifyChecks;
  LoopVerifyPromptResult? verifyPrompt;

  LoopIterationRecord snapshot() => LoopIterationRecord(
    index: index,
    workerAgentId: workerAgentId,
    workerStartedAt: workerStartedAt,
    workerCompletedAt: workerCompletedAt,
    verifierAgentId: verifierAgentId,
    status: status,
    workerOutcome: workerOutcome,
    failureReason: failureReason,
    verifyChecks: List.unmodifiable(verifyChecks),
    verifyPrompt: verifyPrompt,
  );
}

Future<LoopVerifyCheckResult> runLoopVerifyCheck(
  String cwd,
  String command,
) async {
  final startedAt = DateTime.now().toUtc().toIso8601String();
  ProcessResult result;
  try {
    result = Platform.isWindows
        ? await Process.run(
            'cmd.exe',
            ['/d', '/s', '/c', command],
            workingDirectory: cwd,
            runInShell: false,
          )
        : await Process.run(
            '/bin/sh',
            ['-lc', command],
            workingDirectory: cwd,
            runInShell: false,
          );
  } on Object catch (error) {
    return LoopVerifyCheckResult(
      command: command,
      exitCode: 1,
      passed: false,
      stdout: '',
      stderr: _truncateUtf8('$error'),
      startedAt: startedAt,
      completedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
  return LoopVerifyCheckResult(
    command: command,
    exitCode: result.exitCode,
    passed: result.exitCode == 0,
    stdout: _truncateUtf8('${result.stdout}'),
    stderr: _truncateUtf8('${result.stderr}'),
    startedAt: startedAt,
    completedAt: DateTime.now().toUtc().toIso8601String(),
  );
}

String _truncateUtf8(String value) {
  final bytes = utf8.encode(value);
  if (bytes.length <= _maxVerifyOutputBytes) return value;
  return utf8.decode(
    bytes.sublist(0, _maxVerifyOutputBytes),
    allowMalformed: true,
  );
}

String _requiredText(String value, String field) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw StateError('$field cannot be empty');
  return trimmed;
}

String? _optionalText(String? value, String field) =>
    value == null ? null : _requiredText(value, field);

String _errorText(Object error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => '$error',
};

String _randomLoopId() {
  final random = Random.secure();
  return List.generate(
    4,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
