import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../silero_vad_provider.dart';
import '../silero_vad_session.dart';
import '../speech_provider.dart';
import '../turn_detection_provider.dart';
import 'models.dart';
import 'sherpa/native.dart';
import 'sherpa/offline_recognizer.dart';
import 'sherpa/parakeet_stt.dart';
import 'sherpa/runtime_env.dart';
import 'sherpa/tts.dart';
import 'worker_protocol.dart';

typedef LocalSpeechWorkerSend = void Function(LocalSpeechWorkerMessage message);

final class LocalSpeechWorkerDispatcher {
  LocalSpeechWorkerDispatcher({
    required this.send,
    required SherpaNativeFactory nativeFactory,
    SpeechLogger logger = const NullSpeechLogger(),
    String? sherpaLibraryDirectory,
    String? bundledSileroVadModelPath,
  }) : _nativeFactory = nativeFactory,
       _logger = logger.child({
         'module': 'speech',
         'component': 'local-worker',
       }),
       _sherpaLibraryDirectory =
           sherpaLibraryDirectory ?? resolveSherpaLibraryDirectory(),
       _bundledSileroVadModelPath =
           bundledSileroVadModelPath ?? resolveBundledSileroVadModelPath();

  final LocalSpeechWorkerSend send;
  final SherpaNativeFactory _nativeFactory;
  final SpeechLogger _logger;
  final String? _sherpaLibraryDirectory;
  final String _bundledSileroVadModelPath;
  final Map<String, SherpaOfflineRecognizerEngine> _sttEngines = {};
  final Map<String, SherpaOnnxParakeetStt> _sttProviders = {};
  final Map<String, SherpaOnnxTts> _ttsProviders = {};
  final Map<String, Object> _sessions = {};
  final Map<String, List<StreamSubscription<Object?>>> _subscriptions = {};
  bool _nativeInitialized = false;
  bool _closed = false;

  Future<void> handle(LocalSpeechWorkerRequest request) async {
    if (_closed) {
      send(
        LocalSpeechWorkerResponse.failure(
          requestId: request.requestId,
          error: 'Local speech worker is closed',
        ),
      );
      return;
    }
    try {
      final result = await _dispatch(request);
      send(
        LocalSpeechWorkerResponse.success(
          requestId: request.requestId,
          result: result,
        ),
      );
    } on Object catch (error) {
      send(
        LocalSpeechWorkerResponse.failure(
          requestId: request.requestId,
          error: _errorMessage(error),
        ),
      );
    }
  }

  Future<Object?> _dispatch(LocalSpeechWorkerRequest request) async {
    switch (request) {
      case LocalSpeechTtsSynthesizeRequest():
        final result = await _getTtsProvider(
          request.config,
        ).synthesizeSpeech(request.text);
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in result.stream) {
          bytes.add(chunk);
        }
        return LocalSpeechTtsResult(
          audio: bytes.takeBytes(),
          format: result.format,
        ).toJson();
      case LocalSpeechSttTranscribeRequest():
        final result = await _getSttProvider(
          request.config,
          request.model,
        ).transcribeAudio(request.audio, request.format);
        return result.toJson();
      case LocalSpeechSessionCreateRequest():
        return _createSession(request);
      case LocalSpeechSessionAppendRequest():
        final session = _sessions[request.sessionId];
        switch (session) {
          case StreamingTranscriptionSession():
            session.appendPcm16(request.audio);
          case TurnDetectionSession():
            session.appendPcm16(request.audio);
        }
        return null;
      case LocalSpeechSessionCommandRequest():
        await _handleSessionCommand(request);
        return null;
    }
  }

  Future<Map<String, Object?>> _createSession(
    LocalSpeechSessionCreateRequest request,
  ) async {
    await _cleanupSession(request.sessionId);
    late final Object session;
    if (request.kind == LocalSpeechSessionKind.vad) {
      _ensureNative();
      String? modelPath;
      try {
        modelPath = await ensureSileroVadModel(
          modelsDirectory: request.config.modelsDirectory,
          bundledModelPath: _bundledSileroVadModelPath,
          logger: _logger,
        );
      } on Object catch (error) {
        _logger.warning(
          'Failed to provision Silero VAD model, using bundled asset',
          fields: {'error': error},
        );
        modelPath = _bundledSileroVadModelPath;
      }
      final created = SileroTurnDetectionProvider(
        config: SileroVadSessionConfig(modelPath: modelPath),
        logger: _logger,
        createBackend: _nativeFactory.createVad,
      ).createSession(TurnDetectionSessionParameters(logger: _logger));
      _trackVad(request.sessionId, created);
      await created.connect();
      session = created;
    } else {
      final model = request.kind == LocalSpeechSessionKind.voiceStt
          ? LocalSpeechTranscriptionModel.voice
          : LocalSpeechTranscriptionModel.dictation;
      final engine = _getSttEngine(request.config, model);
      final created = request.kind == LocalSpeechSessionKind.voiceStt
          ? _getSttProvider(
              request.config,
              LocalSpeechTranscriptionModel.voice,
            ).createSession(SpeechSessionParameters(logger: _logger))
          : SherpaParakeetRealtimeTranscriptionSession(engine: engine);
      _trackTranscription(request.sessionId, created);
      await created.connect();
      session = created;
    }
    _sessions[request.sessionId] = session;
    final sampleRate = switch (session) {
      StreamingTranscriptionSession(:final requiredSampleRate) =>
        requiredSampleRate,
      TurnDetectionSession(:final requiredSampleRate) => requiredSampleRate,
      _ => throw StateError('Unexpected local speech session'),
    };
    return LocalSpeechCreateSessionResult(
      requiredSampleRate: sampleRate,
    ).toJson();
  }

  Future<void> _handleSessionCommand(
    LocalSpeechSessionCommandRequest request,
  ) async {
    if (request.type == 'session.close') {
      await _cleanupSession(request.sessionId);
      return;
    }
    final session = _sessions[request.sessionId];
    switch (request.type) {
      case 'session.commit':
        if (session is StreamingTranscriptionSession) session.commit();
      case 'session.clear':
        if (session is StreamingTranscriptionSession) session.clear();
      case 'session.flush':
        if (session is TurnDetectionSession) session.flush();
      case 'session.reset':
        if (session is TurnDetectionSession) session.reset();
    }
  }

  SherpaOfflineRecognizerEngine _getSttEngine(
    LocalSpeechWorkerConfig config,
    LocalSpeechTranscriptionModel model,
  ) {
    _ensureNative();
    final modelId = model == LocalSpeechTranscriptionModel.voice
        ? config.voiceSttModel
        : config.dictationSttModel;
    final key = '${config.modelsDirectory}:$modelId';
    return _sttEngines.putIfAbsent(key, () {
      parseLocalSttModelId(modelId);
      final modelDirectory = getLocalSpeechModelDirectory(
        config.modelsDirectory,
        modelId,
      );
      return SherpaOfflineRecognizerEngine(
        config: SherpaOfflineRecognizerConfig(
          model: SherpaOfflineRecognizerModel(
            encoder: p.join(modelDirectory, 'encoder.int8.onnx'),
            decoder: p.join(modelDirectory, 'decoder.int8.onnx'),
            joiner: p.join(modelDirectory, 'joiner.int8.onnx'),
            tokens: p.join(modelDirectory, 'tokens.txt'),
          ),
          numThreads: 2,
        ),
        nativeFactory: _nativeFactory,
        logger: _logger,
      );
    });
  }

  SherpaOnnxParakeetStt _getSttProvider(
    LocalSpeechWorkerConfig config,
    LocalSpeechTranscriptionModel model,
  ) {
    final modelId = model == LocalSpeechTranscriptionModel.voice
        ? config.voiceSttModel
        : config.dictationSttModel;
    final key = '${config.modelsDirectory}:$modelId';
    return _sttProviders.putIfAbsent(
      key,
      () => SherpaOnnxParakeetStt(
        engine: _getSttEngine(config, model),
        logger: _logger,
      ),
    );
  }

  SherpaOnnxTts _getTtsProvider(LocalSpeechWorkerConfig config) {
    _ensureNative();
    parseLocalTtsModelId(config.voiceTtsModel);
    final key = [
      config.modelsDirectory,
      config.voiceTtsModel,
      config.voiceTtsSpeakerId ?? 0,
      config.voiceTtsSpeed ?? 1,
    ].join(':');
    return _ttsProviders.putIfAbsent(
      key,
      () => SherpaOnnxTts(
        config: SherpaTtsConfig(
          modelDirectory: getLocalSpeechModelDirectory(
            config.modelsDirectory,
            config.voiceTtsModel,
          ),
          speakerId: config.voiceTtsSpeakerId ?? 0,
          speed: config.voiceTtsSpeed ?? 1,
        ),
        nativeFactory: _nativeFactory,
        logger: _logger,
      ),
    );
  }

  void _trackTranscription(
    String sessionId,
    StreamingTranscriptionSession session,
  ) {
    _subscriptions[sessionId] = [
      session.committedEvents.listen(
        (payload) => send(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.committed,
            sessionId: sessionId,
            payload: payload.toJson(),
          ),
        ),
      ),
      session.transcriptEvents.listen(
        (payload) => send(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.transcript,
            sessionId: sessionId,
            payload: payload.toJson(),
          ),
        ),
      ),
      session.errors.listen((error) => _sendSessionError(sessionId, error)),
    ];
  }

  void _trackVad(String sessionId, TurnDetectionSession session) {
    _subscriptions[sessionId] = [
      session.speechStartedEvents.listen(
        (_) => send(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.speechStarted,
            sessionId: sessionId,
          ),
        ),
      ),
      session.speechStoppedEvents.listen(
        (_) => send(
          LocalSpeechWorkerEvent(
            eventType: LocalSpeechWorkerEventType.speechStopped,
            sessionId: sessionId,
          ),
        ),
      ),
      session.errors.listen((error) => _sendSessionError(sessionId, error)),
    ];
  }

  void _sendSessionError(String sessionId, Object? error) {
    send(
      LocalSpeechWorkerEvent(
        eventType: LocalSpeechWorkerEventType.error,
        sessionId: sessionId,
        error: _errorMessage(error),
      ),
    );
  }

  Future<void> _cleanupSession(String sessionId) async {
    final subscriptions = _subscriptions.remove(sessionId) ?? const [];
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    final session = _sessions.remove(sessionId);
    switch (session) {
      case StreamingTranscriptionSession():
        session.close();
      case TurnDetectionSession():
        session.close();
    }
  }

  void _ensureNative() {
    if (_nativeInitialized) return;
    _nativeFactory.initialize(_sherpaLibraryDirectory);
    _nativeInitialized = true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final sessionId in _sessions.keys.toList(growable: false)) {
      await _cleanupSession(sessionId);
    }
    for (final tts in _ttsProviders.values) {
      tts.free();
    }
    for (final engine in _sttEngines.values) {
      engine.free();
    }
    _ttsProviders.clear();
    _sttProviders.clear();
    _sttEngines.clear();
  }
}

String _errorMessage(Object? error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => error?.toString() ?? 'Local speech worker request failed',
};
