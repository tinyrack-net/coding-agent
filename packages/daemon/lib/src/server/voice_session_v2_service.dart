import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../voice/provider_resolver.dart';
import '../voice/speech_provider.dart';
import '../voice/speech_readiness.dart';
import '../voice/turn_detection_provider.dart';
import '../voice/voice_bridge_registry.dart';
import '../voice/voice_session.dart';
import 'connection.dart';

typedef VoiceSessionHostFactory =
    VoiceSessionHost Function(Connection connection);

final class VoiceSessionV2Service {
  VoiceSessionV2Service({
    required VoiceSessionHostFactory createHost,
    required Object? resolveTts,
    required Object? resolveStt,
    required Object? resolveTurnDetection,
    required VoiceBridgeRegistry voiceBridge,
    Object? resolveDictationStt,
    SpeechReadinessSnapshot Function()? getSpeechReadiness,
    SpeechLogger logger = const NullSpeechLogger(),
    this.sttLanguage = 'en',
    this.dictationLanguage = 'en',
    Map<String, String>? environment,
    String? cwd,
  }) : _createHost = createHost,
       _resolveTts = toResolver<TextToSpeechProvider?>(resolveTts),
       _resolveStt = toResolver<SpeechToTextProvider?>(resolveStt),
       _resolveDictationStt = toResolver<SpeechToTextProvider?>(
         resolveDictationStt ?? resolveStt,
       ),
       _resolveTurnDetection = toResolver<TurnDetectionProvider?>(
         resolveTurnDetection,
       ),
       _voiceBridge = voiceBridge,
       _getSpeechReadiness = getSpeechReadiness,
       _logger = logger,
       _environment = environment ?? Platform.environment,
       _cwd = cwd ?? Directory.current.path;

  static const handledMessageTypes = {
    VoiceAudioChunkMessage.type,
    AbortRequestMessage.type,
    AudioPlayedMessage.type,
    SetVoiceModeMessage.type,
    DictationStreamStartMessage.type,
    DictationStreamChunkMessage.type,
    DictationStreamFinishMessage.type,
    DictationStreamCancelMessage.type,
  };

  final VoiceSessionHostFactory _createHost;
  final TextToSpeechResolver _resolveTts;
  final SpeechToTextResolver _resolveStt;
  final SpeechToTextResolver _resolveDictationStt;
  final TurnDetectionResolver _resolveTurnDetection;
  final VoiceBridgeRegistry _voiceBridge;
  final SpeechReadinessSnapshot Function()? _getSpeechReadiness;
  final SpeechLogger _logger;
  final Map<String, String> _environment;
  final String _cwd;
  final String sttLanguage;
  final String dictationLanguage;
  final Map<String, VoiceSession> _sessions = {};
  final Set<Future<void>> _pendingCleanups = {};

  int get activeSessionCount => _sessions.length;

  Future<bool> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    final type = message['type'];
    if (type is! String || !handledMessageTypes.contains(type)) return false;
    final session = _sessions.putIfAbsent(
      connection.id,
      () => _createSession(connection),
    );
    try {
      switch (type) {
        case VoiceAudioChunkMessage.type:
          await session.handleAudioChunk(
            VoiceAudioChunkMessage.fromJson(message),
          );
        case AbortRequestMessage.type:
          AbortRequestMessage.fromJson(message);
          await session.handleAbort();
        case AudioPlayedMessage.type:
          final request = AudioPlayedMessage.fromJson(message);
          session.handleAudioPlayed(request.id);
        case SetVoiceModeMessage.type:
          final request = SetVoiceModeMessage.fromJson(message);
          await session.handleSetVoiceMode(
            request.enabled,
            agentId: request.agentId,
            requestId: request.requestId,
          );
        case DictationStreamStartMessage.type:
          await session.handleDictationStreamStart(
            DictationStreamStartMessage.fromJson(message),
          );
        case DictationStreamChunkMessage.type:
          await session.handleDictationChunk(
            DictationStreamChunkMessage.fromJson(message),
          );
        case DictationStreamFinishMessage.type:
          await session.handleDictationFinish(
            DictationStreamFinishMessage.fromJson(message),
          );
        case DictationStreamCancelMessage.type:
          session.handleDictationCancel(
            DictationStreamCancelMessage.fromJson(message),
          );
      }
      return true;
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      _emitRuntimeError(connection, error);
      return true;
    }
  }

  Future<void> onConnectionClosed(Connection connection) =>
      _trackCleanup(_cleanupSession(connection.id));

  Future<void> dispose() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    await Future.wait([
      for (final session in sessions) _cleanup(session),
      ..._pendingCleanups.toList(growable: false),
    ]);
  }

  VoiceSession _createSession(Connection connection) => VoiceSession(
    host: _createHost(connection),
    logger: _logger.child({
      'component': 'voice-session',
      'connectionId': connection.id,
    }),
    sessionId: connection.id,
    resolveTts: _resolveTts,
    resolveStt: _resolveStt,
    resolveDictationStt: _resolveDictationStt,
    resolveTurnDetection: _resolveTurnDetection,
    sttLanguage: sttLanguage,
    dictationLanguage: dictationLanguage,
    voiceBridge: _voiceBridge,
    getSpeechReadiness: _getSpeechReadiness ?? _deriveReadiness,
    environment: _environment,
    cwd: _cwd,
  );

  SpeechReadinessSnapshot _deriveReadiness() {
    final turnDetection = _resolveTurnDetection();
    final stt = _resolveStt();
    final dictationStt = _resolveDictationStt();
    final tts = _resolveTts();
    final realtime = turnDetection == null
        ? const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'turn_detection_unavailable',
            message:
                'Realtime voice is unavailable: turn-detection service is not ready.',
            retryable: false,
          )
        : stt == null
        ? const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'stt_unavailable',
            message:
                'Realtime voice is unavailable: speech-to-text service is not ready.',
            retryable: false,
          )
        : tts == null
        ? const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'tts_unavailable',
            message:
                'Realtime voice is unavailable: text-to-speech service is not ready.',
            retryable: false,
          )
        : const SpeechReadinessState(
            enabled: true,
            available: true,
            reasonCode: 'ready',
            message: 'Realtime voice is ready.',
            retryable: false,
          );
    final dictation = dictationStt == null
        ? const SpeechReadinessState(
            enabled: true,
            available: false,
            reasonCode: 'stt_unavailable',
            message:
                'Dictation is unavailable: speech-to-text service is not ready.',
            retryable: false,
          )
        : const SpeechReadinessState(
            enabled: true,
            available: true,
            reasonCode: 'ready',
            message: 'Dictation is ready.',
            retryable: false,
          );
    return SpeechReadinessSnapshot(
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      realtimeVoice: realtime,
      dictation: dictation,
      voiceFeature: const SpeechReadinessState(
        enabled: true,
        available: true,
        reasonCode: 'ready',
        message: 'Voice features are ready.',
        retryable: false,
      ),
    );
  }

  Future<void> _cleanupSession(String connectionId) async {
    final session = _sessions.remove(connectionId);
    if (session != null) await _cleanup(session);
  }

  Future<void> _trackCleanup(Future<void> cleanup) {
    _pendingCleanups.add(cleanup);
    cleanup.whenComplete(() => _pendingCleanups.remove(cleanup));
    return cleanup;
  }

  Future<void> _cleanup(VoiceSession session) async {
    try {
      await session.cleanup();
    } on Object catch (error) {
      _logger.warning('Voice session cleanup failed', fields: {'error': error});
    }
  }

  void _emitRuntimeError(Connection connection, Object error) {
    final message = error is StateError
        ? error.message
        : error is VoiceFeatureUnavailableException
        ? error.message
        : error.toString();
    connection.sendJson({
      'type': 'session',
      'message': ActivityLogMessage(
        id: const Uuid().v4(),
        timestamp: DateTime.now().toUtc(),
        logType: 'error',
        content: 'Error: $message',
      ).toJson(),
    });
  }
}
