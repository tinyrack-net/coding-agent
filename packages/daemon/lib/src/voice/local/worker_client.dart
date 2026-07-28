import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../speech_provider.dart';
import '../turn_detection_provider.dart';
import 'worker_bytes.dart';
import 'worker_process_transport.dart';
import 'worker_protocol.dart';
import 'worker_transport.dart';

const Duration defaultLocalSpeechWorkerRequestTimeout = Duration(seconds: 30);
const Duration defaultLocalSpeechWorkerIdleTtl = Duration(minutes: 5);
const int defaultLocalSpeechSampleRate = 16000;
const int localSpeechWorkerStderrTailMaxChars = 8000;
const int localSpeechWorkerUserErrorStderrMaxChars = 1000;

final class LocalSpeechWorkerClient {
  LocalSpeechWorkerClient({
    required this.config,
    LocalSpeechWorkerStarter startWorker = startLocalSpeechWorkerProcess,
    SpeechLogger logger = const NullSpeechLogger(),
    this.requestTimeout = defaultLocalSpeechWorkerRequestTimeout,
    this.idleTtl = defaultLocalSpeechWorkerIdleTtl,
    Uuid uuid = const Uuid(),
  }) : _startWorker = startWorker,
       _logger = logger.child({'component': 'local-speech-worker-client'}),
       _uuid = uuid;

  final LocalSpeechWorkerConfig config;
  final Duration requestTimeout;
  final Duration idleTtl;
  final LocalSpeechWorkerStarter _startWorker;
  final SpeechLogger _logger;
  final Uuid _uuid;
  final Map<String, _PendingRequest> _pendingRequests = {};
  final Set<String> _activeSessionIds = {};
  final Map<String, LocalSpeechSessionEventSink> _sessionSinks = {};
  final Set<LocalSpeechWorkerTransport> _intentionalWorkerCloses = {};

  LocalSpeechWorkerTransport? _worker;
  Future<LocalSpeechWorkerTransport>? _startingWorker;
  StreamSubscription<LocalSpeechWorkerMessage>? _messageSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  Timer? _idleTimer;
  String _stderrTail = '';
  String _stderrLineBuffer = '';
  int _inFlightRequests = 0;

  bool get hasWorker => _worker != null || _startingWorker != null;

  Future<SpeechStreamResult> synthesizeSpeech(String text) async {
    final result = LocalSpeechTtsResult.fromJson(
      await _sendRequest(
        (requestId) => LocalSpeechTtsSynthesizeRequest(
          requestId: requestId,
          config: config,
          text: text,
        ),
      ),
    );
    return SpeechStreamResult(
      stream: Stream.value(workerBytesToBuffer(result.audio)),
      format: result.format,
    );
  }

  Future<TranscriptionResult> transcribeVoice(
    List<int> audio,
    String format,
  ) async {
    final result = await _sendRequest(
      (requestId) => LocalSpeechSttTranscribeRequest(
        requestId: requestId,
        config: config,
        model: LocalSpeechTranscriptionModel.voice,
        audio: bufferToWorkerBytes(audio),
        format: format,
      ),
    );
    if (result is! Map) {
      throw const FormatException('Invalid local speech transcription result');
    }
    return TranscriptionResult.fromJson(Map<String, Object?>.from(result));
  }

  Future<LocalSpeechConnectedSession> createSession({
    required LocalSpeechSessionKind kind,
    required LocalSpeechSessionEventSink sink,
  }) async {
    final sessionId = _uuid.v4();
    _activeSessionIds.add(sessionId);
    _sessionSinks[sessionId] = sink;
    try {
      final result = LocalSpeechCreateSessionResult.fromJson(
        await _sendRequest(
          (requestId) => LocalSpeechSessionCreateRequest(
            requestId: requestId,
            config: config,
            sessionId: sessionId,
            kind: kind,
          ),
        ),
      );
      return LocalSpeechConnectedSession(
        sessionId: sessionId,
        requiredSampleRate: result.requiredSampleRate,
      );
    } on Object {
      _activeSessionIds.remove(sessionId);
      _sessionSinks.remove(sessionId);
      _scheduleIdleShutdownIfReady();
      rethrow;
    }
  }

  void appendSessionAudio(String sessionId, List<int> audio) {
    _sendSessionRequest(
      sessionId,
      (requestId) => LocalSpeechSessionAppendRequest(
        requestId: requestId,
        sessionId: sessionId,
        audio: bufferToWorkerBytes(audio),
      ),
    );
  }

  void commitSession(String sessionId) =>
      _sendSessionCommand(sessionId, 'session.commit');

  void clearSession(String sessionId) =>
      _sendSessionCommand(sessionId, 'session.clear');

  void flushSession(String sessionId) =>
      _sendSessionCommand(sessionId, 'session.flush');

  void resetSession(String sessionId) =>
      _sendSessionCommand(sessionId, 'session.reset');

  void closeSession(String sessionId) {
    _activeSessionIds.remove(sessionId);
    _sessionSinks.remove(sessionId);
    unawaited(
      _sendRequest(
        (requestId) => LocalSpeechSessionCommandRequest(
          requestId: requestId,
          sessionId: sessionId,
          type: 'session.close',
        ),
      ).catchError((_) => null),
    );
    _scheduleIdleShutdownIfReady();
  }

  Future<void> shutdown() async {
    _clearIdleTimer();
    final error = StateError('Local speech worker shut down');
    _rejectAllPending(error);
    _activeSessionIds.clear();
    _sessionSinks.clear();
    final worker = _worker;
    _worker = null;
    _startingWorker = null;
    await _cancelWorkerSubscriptions();
    if (worker != null && !worker.killed) {
      _intentionalWorkerCloses.add(worker);
      try {
        await worker.shutdown();
      } on Object {
        // Frozen worker shutdown is best effort.
      }
    }
  }

  Future<Object?> _sendRequest(
    LocalSpeechWorkerRequest Function(String requestId) createRequest,
  ) async {
    final worker = await _ensureWorker();
    final requestId = _uuid.v4();
    final request = createRequest(requestId);
    final completer = Completer<Object?>();
    _inFlightRequests++;
    _clearIdleTimer();
    late final Timer timeout;
    timeout = Timer(requestTimeout, () {
      final pending = _pendingRequests.remove(requestId);
      if (pending == null) return;
      _inFlightRequests = _decrement(_inFlightRequests);
      _scheduleIdleShutdownIfReady();
      pending.completer.completeError(
        TimeoutException(
          'Local speech worker request timed out: ${request.type}',
          requestTimeout,
        ),
      );
    });
    _pendingRequests[requestId] = _PendingRequest(
      request: request,
      completer: completer,
      timeout: timeout,
      startedAt: DateTime.now(),
    );

    try {
      await worker.send(request);
    } on Object catch (error, stackTrace) {
      final pending = _pendingRequests.remove(requestId);
      if (pending != null) {
        pending.timeout.cancel();
        _inFlightRequests = _decrement(_inFlightRequests);
        _scheduleIdleShutdownIfReady();
        pending.completer.completeError(error, stackTrace);
      }
    }
    return completer.future;
  }

  Future<LocalSpeechWorkerTransport> _ensureWorker() async {
    final current = _worker;
    if (current != null && !current.killed && current.connected) return current;
    final starting = _startingWorker;
    if (starting != null) return starting;
    final future = Future<LocalSpeechWorkerTransport>.sync(_startWorker);
    _startingWorker = future;
    try {
      final worker = await future;
      _worker = worker;
      _stderrTail = '';
      _stderrLineBuffer = '';
      _messageSubscription = worker.messages.listen(
        _handleWorkerMessage,
        onError: (Object error, StackTrace stackTrace) {
          _logger.warning(
            'Local speech worker message channel failed',
            fields: {'workerPid': worker.pid, 'error': error},
          );
        },
      );
      _stderrSubscription = worker.stderr.listen(_handleWorkerStderr);
      unawaited(
        worker.exited.then(
          (exit) => _handleWorkerExit(worker, exit),
          onError: (Object error, StackTrace stackTrace) =>
              _handleWorkerExit(worker, const LocalSpeechWorkerExit()),
        ),
      );
      _logger.info(
        'Local speech worker spawned',
        fields: {
          'workerPid': worker.pid,
          'modelsDir': config.modelsDirectory,
          'voiceSttModel': config.voiceSttModel,
          'dictationSttModel': config.dictationSttModel,
          'voiceTtsModel': config.voiceTtsModel,
        },
      );
      return worker;
    } finally {
      if (identical(_startingWorker, future)) _startingWorker = null;
    }
  }

  void _handleWorkerMessage(LocalSpeechWorkerMessage message) {
    if (message is LocalSpeechWorkerResponse) {
      final pending = _pendingRequests.remove(message.requestId);
      if (pending == null) return;
      pending.timeout.cancel();
      _inFlightRequests = _decrement(_inFlightRequests);
      _scheduleIdleShutdownIfReady();
      if (message.ok) {
        pending.completer.complete(message.result);
      } else {
        pending.completer.completeError(StateError(message.error!));
      }
      return;
    }

    final event = message as LocalSpeechWorkerEvent;
    final sink = _sessionSinks[event.sessionId];
    if (sink == null) return;
    try {
      switch (event.eventType) {
        case LocalSpeechWorkerEventType.committed:
          sink.committed(
            StreamingTranscriptionCommittedEvent.fromJson(
              Map<String, Object?>.from(event.payload! as Map),
            ),
          );
        case LocalSpeechWorkerEventType.transcript:
          sink.transcript(
            StreamingTranscriptionEvent.fromJson(
              Map<String, Object?>.from(event.payload! as Map),
            ),
          );
        case LocalSpeechWorkerEventType.speechStarted:
          sink.speechStarted();
        case LocalSpeechWorkerEventType.speechStopped:
          sink.speechStopped();
        case LocalSpeechWorkerEventType.error:
          sink.addError(StateError(event.error!));
      }
    } on Object catch (error) {
      sink.addError(error);
    }
  }

  void _handleWorkerStderr(List<int> chunk) {
    final text = utf8.decode(chunk, allowMalformed: true);
    _stderrTail = _truncateStart(
      '$_stderrTail$text',
      localSpeechWorkerStderrTailMaxChars,
    );
    _stderrLineBuffer += text;
    final lines = _stderrLineBuffer.split(RegExp(r'\r?\n'));
    _stderrLineBuffer = lines.removeLast();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      _logger.warning(
        'Local speech worker stderr',
        fields: {'workerPid': _worker?.pid, 'stderr': trimmed},
      );
    }
  }

  Future<void> _handleWorkerExit(
    LocalSpeechWorkerTransport worker,
    LocalSpeechWorkerExit exit,
  ) async {
    final isCurrent = identical(_worker, worker);
    final intentional = _intentionalWorkerCloses.remove(worker);
    final pendingDescriptions = _describePendingRequests();
    final activeSessionCount = _activeSessionIds.length;
    final stderrTail = _truncateStart(
      _stderrTail.trim(),
      localSpeechWorkerStderrTailMaxChars,
    );
    if (intentional) {
      _logger.info(
        'Local speech worker closed after shutdown',
        fields: {
          'workerPid': worker.pid,
          'exitCode': exit.exitCode,
          'signal': exit.signal,
          'pendingRequests': pendingDescriptions,
          'activeSessionCount': activeSessionCount,
          'stderrTail': stderrTail.isEmpty ? null : stderrTail,
        },
      );
      return;
    }
    if (!isCurrent) {
      _logger.warning(
        'Stale local speech worker closed',
        fields: {
          'workerPid': worker.pid,
          'exitCode': exit.exitCode,
          'signal': exit.signal,
        },
      );
      return;
    }

    final error = StateError(
      _buildWorkerExitMessage(
        exit: exit,
        pendingRequests: pendingDescriptions,
        stderrTail: stderrTail,
      ),
    );
    _logger.error(
      'Local speech worker exited',
      fields: {
        'error': error,
        'workerPid': worker.pid,
        'exitCode': exit.exitCode,
        'signal': exit.signal,
        'pendingRequests': pendingDescriptions,
        'activeSessionCount': activeSessionCount,
        'stderrTail': stderrTail.isEmpty ? null : stderrTail,
      },
    );
    _worker = null;
    await _cancelWorkerSubscriptions();
    _clearIdleTimer();
    _rejectAllPending(error);
    for (final entry in _sessionSinks.entries) {
      if (_activeSessionIds.contains(entry.key)) {
        entry.value.addError(error);
      }
    }
    _activeSessionIds.clear();
    _sessionSinks.clear();
    _inFlightRequests = 0;
  }

  void _sendSessionCommand(String sessionId, String type) {
    _sendSessionRequest(
      sessionId,
      (requestId) => LocalSpeechSessionCommandRequest(
        requestId: requestId,
        sessionId: sessionId,
        type: type,
      ),
    );
  }

  void _sendSessionRequest(
    String sessionId,
    LocalSpeechWorkerRequest Function(String requestId) createRequest,
  ) {
    unawaited(
      _sendRequest(createRequest).catchError((Object error) {
        _sessionSinks[sessionId]?.addError(error);
        return null;
      }),
    );
  }

  List<Map<String, Object?>> _describePendingRequests() {
    final now = DateTime.now();
    return [
      for (final entry in _pendingRequests.entries)
        {
          'requestId': entry.key,
          'type': entry.value.request.type,
          'ageMs': now
              .difference(entry.value.startedAt)
              .inMilliseconds
              .clamp(0, 1 << 30),
          ...entry.value.request.summary,
        },
    ];
  }

  void _rejectAllPending(Object error) {
    final pending = _pendingRequests.values.toList(growable: false);
    _pendingRequests.clear();
    for (final request in pending) {
      request.timeout.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
    _inFlightRequests = 0;
  }

  void _scheduleIdleShutdownIfReady() {
    if (_worker == null ||
        _inFlightRequests > 0 ||
        _activeSessionIds.isNotEmpty) {
      return;
    }
    _clearIdleTimer();
    _idleTimer = Timer(idleTtl, () {
      if (_inFlightRequests == 0 && _activeSessionIds.isEmpty) {
        unawaited(shutdown());
      }
    });
  }

  void _clearIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  Future<void> _cancelWorkerSubscriptions() async {
    await _messageSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _messageSubscription = null;
    _stderrSubscription = null;
  }
}

final class WorkerBackedTextToSpeechProvider implements TextToSpeechProvider {
  const WorkerBackedTextToSpeechProvider(this.client);

  final LocalSpeechWorkerClient client;

  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) =>
      client.synthesizeSpeech(text);
}

final class WorkerBackedSpeechToTextProvider implements SpeechToTextProvider {
  const WorkerBackedSpeechToTextProvider(this.client, this.kind)
    : assert(
        kind == LocalSpeechSessionKind.voiceStt ||
            kind == LocalSpeechSessionKind.dictationStt,
      );

  final LocalSpeechWorkerClient client;
  final LocalSpeechSessionKind kind;

  @override
  String get id => 'local';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => _WorkerBackedTranscriptionSession(client, kind);
}

final class WorkerBackedTurnDetectionProvider implements TurnDetectionProvider {
  const WorkerBackedTurnDetectionProvider(this.client);

  final LocalSpeechWorkerClient client;

  @override
  String get id => 'local';

  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) => _WorkerBackedTurnDetectionSession(client);
}

final class LocalSpeechConnectedSession {
  const LocalSpeechConnectedSession({
    required this.sessionId,
    required this.requiredSampleRate,
  });

  final String sessionId;
  final int requiredSampleRate;
}

abstract interface class LocalSpeechSessionEventSink {
  void committed(StreamingTranscriptionCommittedEvent event);
  void transcript(StreamingTranscriptionEvent event);
  void speechStarted();
  void speechStopped();
  void addError(Object error);
}

final class _WorkerBackedTranscriptionSession
    implements StreamingTranscriptionSession, LocalSpeechSessionEventSink {
  _WorkerBackedTranscriptionSession(this.client, this.kind);

  final LocalSpeechWorkerClient client;
  final LocalSpeechSessionKind kind;
  final StreamController<StreamingTranscriptionCommittedEvent> _committed =
      StreamController.broadcast(sync: true);
  final StreamController<StreamingTranscriptionEvent> _transcripts =
      StreamController.broadcast(sync: true);
  final StreamController<Object?> _errors = StreamController.broadcast(
    sync: true,
  );
  int _requiredSampleRate = defaultLocalSpeechSampleRate;
  String? _sessionId;
  Future<void>? _connecting;

  @override
  int get requiredSampleRate => _requiredSampleRate;

  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      _committed.stream;

  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      _transcripts.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {
    if (_sessionId != null) return;
    final current = _connecting;
    if (current != null) return current;
    final future = _connectRemoteSession();
    _connecting = future;
    try {
      await future;
    } finally {
      if (identical(_connecting, future)) _connecting = null;
    }
  }

  Future<void> _connectRemoteSession() async {
    final result = await client.createSession(kind: kind, sink: this);
    _sessionId = result.sessionId;
    _requiredSampleRate = result.requiredSampleRate;
  }

  @override
  void appendPcm16(List<int> pcm16le) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      addError(StateError('Local STT session not connected'));
      return;
    }
    client.appendSessionAudio(sessionId, pcm16le);
  }

  @override
  void commit() {
    final sessionId = _sessionId;
    if (sessionId == null) {
      addError(StateError('Local STT session not connected'));
      return;
    }
    client.commitSession(sessionId);
  }

  @override
  void clear() {
    final sessionId = _sessionId;
    if (sessionId != null) client.clearSession(sessionId);
  }

  @override
  void close() {
    final sessionId = _sessionId;
    _sessionId = null;
    if (sessionId != null) client.closeSession(sessionId);
  }

  @override
  void committed(StreamingTranscriptionCommittedEvent event) =>
      _committed.add(event);

  @override
  void transcript(StreamingTranscriptionEvent event) => _transcripts.add(event);

  @override
  void addError(Object error) => _errors.add(error);

  @override
  void speechStarted() {}

  @override
  void speechStopped() {}
}

final class _WorkerBackedTurnDetectionSession
    implements TurnDetectionSession, LocalSpeechSessionEventSink {
  _WorkerBackedTurnDetectionSession(this.client);

  final LocalSpeechWorkerClient client;
  final StreamController<void> _speechStarted = StreamController.broadcast(
    sync: true,
  );
  final StreamController<void> _speechStopped = StreamController.broadcast(
    sync: true,
  );
  final StreamController<Object?> _errors = StreamController.broadcast(
    sync: true,
  );
  int _requiredSampleRate = defaultLocalSpeechSampleRate;
  String? _sessionId;
  Future<void>? _connecting;

  @override
  int get requiredSampleRate => _requiredSampleRate;

  @override
  Stream<void> get speechStartedEvents => _speechStarted.stream;

  @override
  Stream<void> get speechStoppedEvents => _speechStopped.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {
    if (_sessionId != null) return;
    final current = _connecting;
    if (current != null) return current;
    final future = _connectRemoteSession();
    _connecting = future;
    try {
      await future;
    } finally {
      if (identical(_connecting, future)) _connecting = null;
    }
  }

  Future<void> _connectRemoteSession() async {
    final result = await client.createSession(
      kind: LocalSpeechSessionKind.vad,
      sink: this,
    );
    _sessionId = result.sessionId;
    _requiredSampleRate = result.requiredSampleRate;
  }

  @override
  void appendPcm16(Uint8List pcm16le) {
    final sessionId = _sessionId;
    if (sessionId == null) {
      addError(StateError('Local turn-detection session not connected'));
      return;
    }
    client.appendSessionAudio(sessionId, pcm16le);
  }

  @override
  void flush() {
    final sessionId = _sessionId;
    if (sessionId != null) client.flushSession(sessionId);
  }

  @override
  void reset() {
    final sessionId = _sessionId;
    if (sessionId != null) client.resetSession(sessionId);
  }

  @override
  void close() {
    final sessionId = _sessionId;
    _sessionId = null;
    if (sessionId != null) client.closeSession(sessionId);
  }

  @override
  void speechStarted() => _speechStarted.add(null);

  @override
  void speechStopped() => _speechStopped.add(null);

  @override
  void addError(Object error) => _errors.add(error);

  @override
  void committed(StreamingTranscriptionCommittedEvent event) {}

  @override
  void transcript(StreamingTranscriptionEvent event) {}
}

final class _PendingRequest {
  const _PendingRequest({
    required this.request,
    required this.completer,
    required this.timeout,
    required this.startedAt,
  });

  final LocalSpeechWorkerRequest request;
  final Completer<Object?> completer;
  final Timer timeout;
  final DateTime startedAt;
}

String _buildWorkerExitMessage({
  required LocalSpeechWorkerExit exit,
  required List<Map<String, Object?>> pendingRequests,
  required String stderrTail,
}) {
  final status = <String>[
    if (exit.exitCode != null) 'code ${exit.exitCode}',
    if (exit.signal != null && exit.signal!.isNotEmpty) 'signal ${exit.signal}',
  ].join(', ');
  final resolvedStatus = status.isEmpty ? 'unknown exit status' : status;
  final pending = pendingRequests.isEmpty
      ? ''
      : ' while handling ${pendingRequests.take(3).map((request) {
          final type = request['type'] is String ? request['type']! as String : 'unknown request';
          final kind = request['kind'] is String ? ' (${request['kind']})' : '';
          return '$type$kind';
        }).join(', ')}';
  final stderr = stderrTail.isEmpty
      ? ' Check daemon.log and platform crash reports for Tinyrack Voice crash details.'
      : ' Last stderr: ${_truncateStart(stderrTail, localSpeechWorkerUserErrorStderrMaxChars)}';
  return 'Local speech worker exited ($resolvedStatus)$pending.$stderr';
}

String _truncateStart(String value, int maxChars) =>
    value.length <= maxChars ? value : value.substring(value.length - maxChars);

int _decrement(int value) => value > 0 ? value - 1 : 0;
