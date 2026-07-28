import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import 'dictation_stream_manager.dart';
import 'provider_resolver.dart';
import 'speech_provider.dart';
import 'speech_readiness.dart';
import 'stt_manager.dart';
import 'tts_debug.dart';
import 'tts_manager.dart';
import 'turn_detection_provider.dart';
import 'voice_bridge_registry.dart';
import 'voice_config.dart';
import 'voice_turn_controller.dart';
import 'voice_types.dart';

const int voicePcmSampleRate = 16000;
const int voicePcmChannels = 1;
const int voicePcmBitsPerSample = 16;
const int minimumStreamingSegmentDurationMs = 1000;
const int minimumStreamingSegmentBytes =
    voicePcmSampleRate *
    voicePcmChannels *
    (voicePcmBitsPerSample ~/ 8) *
    minimumStreamingSegmentDurationMs ~/
    1000;
const Duration voiceAudioBufferTimeout = Duration(seconds: 10);

typedef VoiceSessionEmitter = void Function(Map<String, Object?> message);
typedef VoiceSessionTimeoutScheduler =
    VoiceSessionTimeoutHandle Function(
      Duration delay,
      FutureOr<void> Function() callback,
    );

abstract interface class VoiceSessionTimeoutHandle {
  void cancel();
}

final class VoiceSessionAgent {
  const VoiceSessionAgent({required this.id, this.systemPrompt});

  final String id;
  final String? systemPrompt;
}

final class VoiceSessionAgentOverrides {
  const VoiceSessionAgentOverrides({required this.systemPrompt});

  final String systemPrompt;
}

abstract interface class VoiceSessionHost {
  void emit(Map<String, Object?> message);
  Future<VoiceSessionAgent> loadAgent(String agentId);
  Future<VoiceSessionAgent> reloadAgentSession(
    String agentId,
    VoiceSessionAgentOverrides overrides,
  );
  Future<void> sendSpokenInput(String agentId, String text);
  Future<void> interruptAgentIfRunning(String agentId);
  bool hasActiveAgentRun(String? agentId);
}

final class VoiceFeatureUnavailableException implements Exception {
  const VoiceFeatureUnavailableException({
    required this.reasonCode,
    required this.message,
    required this.retryable,
    required this.missingModelIds,
  });

  final String reasonCode;
  final String message;
  final bool retryable;
  final List<String> missingModelIds;

  @override
  String toString() => message;
}

final class VoiceSession {
  VoiceSession({
    required this.host,
    required SpeechLogger logger,
    required this.sessionId,
    required Object? resolveTts,
    required Object? resolveStt,
    required Object? resolveTurnDetection,
    this.sttLanguage = 'en',
    VoiceBridgeRegistry? voiceBridge,
    Object? resolveDictationStt,
    String? dictationLanguage,
    Duration dictationFinalTimeout = defaultDictationFinalTimeout,
    SpeechReadinessSnapshot Function()? getSpeechReadiness,
    Map<String, String>? environment,
    String? cwd,
    DateTime Function()? now,
    String Function()? createId,
    VoiceSessionTimeoutScheduler? scheduleBufferTimeout,
    VoiceTurnTimeoutScheduler? scheduleTurnTimeout,
    TtsDebugAudioStore? ttsDebugAudioStore,
  }) : _logger = logger,
       _resolveTurnDetection = toResolver<TurnDetectionProvider?>(
         resolveTurnDetection,
       ),
       _resolveStt = toResolver<SpeechToTextProvider?>(resolveStt),
       _voiceBridge = voiceBridge,
       _getSpeechReadiness = getSpeechReadiness,
       _now = now ?? DateTime.now,
       _createId = createId ?? const Uuid().v4,
       _scheduleBufferTimeout =
           scheduleBufferTimeout ??
           ((delay, callback) => _SystemVoiceSessionTimeoutHandle(
             Timer(delay, () {
               unawaited(Future<void>.sync(callback));
             }),
           )),
       _scheduleTurnTimeout = scheduleTurnTimeout,
       _ttsDebugAudioStore =
           ttsDebugAudioStore ??
           TtsDebugAudioStore(
             environment: environment ?? Platform.environment,
             cwd: cwd ?? Directory.current.path,
           ),
       _ttsManager = TtsManager(
         sessionId: sessionId,
         resolveTts: resolveTts,
         now: now,
         onWarning: (message) => logger.warning(message),
       ),
       _sttManager = SttManager(
         sessionId: sessionId,
         logger: logger,
         resolveStt: resolveStt,
         language: sttLanguage,
         environment: environment,
         cwd: cwd,
       ) {
    _dictationStreamManager = DictationStreamManager(
      logger: logger,
      emit: _handleDictationManagerMessage,
      sessionId: sessionId,
      resolveStt: resolveDictationStt ?? resolveStt,
      language: dictationLanguage ?? 'en',
      finalTimeout: dictationFinalTimeout,
      environment: environment,
      cwd: cwd,
    );
  }

  final VoiceSessionHost host;
  final SpeechLogger _logger;
  final String sessionId;
  final String sttLanguage;
  final TurnDetectionResolver _resolveTurnDetection;
  final SpeechToTextResolver _resolveStt;
  final VoiceBridgeRegistry? _voiceBridge;
  final SpeechReadinessSnapshot Function()? _getSpeechReadiness;
  final DateTime Function() _now;
  final String Function() _createId;
  final VoiceSessionTimeoutScheduler _scheduleBufferTimeout;
  final VoiceTurnTimeoutScheduler? _scheduleTurnTimeout;
  final TtsDebugAudioStore _ttsDebugAudioStore;
  final TtsManager _ttsManager;
  final SttManager _sttManager;
  late final DictationStreamManager _dictationStreamManager;

  VoiceAbortController _abortController = VoiceAbortController();
  _ProcessingPhase _processingPhase = _ProcessingPhase.idle;
  bool _isVoiceMode = false;
  bool _speechInProgress = false;
  VoiceTurnController? _voiceTurnController;
  String? _voiceModeAgentId;
  String? _voiceModeBaseSystemPrompt;
  final List<_AudioSegment> _pendingAudioSegments = [];
  VoiceSessionTimeoutHandle? _bufferTimeout;
  _AudioBufferState? _audioBuffer;
  final Map<String, _TtsDebugStream> _ttsDebugStreams = {};

  bool isActiveForAgent(String agentId) =>
      _isVoiceMode && _voiceModeAgentId == agentId;

  Future<void> handleDictationStreamStart(
    DictationStreamStartMessage message,
  ) async {
    final unavailable = _resolveVoiceFeatureUnavailable('dictation');
    if (unavailable != null) {
      _emit(
        DictationStreamErrorMessage(
          dictationId: message.dictationId,
          error: unavailable.message,
          retryable: unavailable.retryable,
          reasonCode: unavailable.reasonCode,
          missingModelIds: unavailable.missingModelIds,
        ).toJson(),
      );
      return;
    }
    await _dictationStreamManager.handleStart(
      message.dictationId,
      message.format,
    );
  }

  Future<void> handleDictationChunk(DictationStreamChunkMessage message) {
    return _dictationStreamManager.handleChunk(
      dictationId: message.dictationId,
      seq: message.seq,
      audioBase64: message.audio,
      format: message.format,
    );
  }

  Future<void> handleDictationFinish(DictationStreamFinishMessage message) {
    return _dictationStreamManager.handleFinish(
      message.dictationId,
      message.finalSeq,
    );
  }

  void handleDictationCancel(DictationStreamCancelMessage message) {
    _dictationStreamManager.handleCancel(message.dictationId);
  }

  Future<void> handleSetVoiceMode(
    bool enabled, {
    String? agentId,
    String? requestId,
  }) async {
    try {
      if (enabled) {
        final unavailable = _resolveVoiceFeatureUnavailable('voice_mode');
        if (unavailable != null) throw unavailable;
        final normalizedAgentId = _parseVoiceTargetAgentId(
          agentId ?? '',
          'set_voice_mode',
        );
        if (_isVoiceMode &&
            _voiceModeAgentId != null &&
            _voiceModeAgentId != normalizedAgentId) {
          await _disableVoiceModeForActiveAgent(restoreAgentConfig: true);
        }
        if (!_isVoiceMode || _voiceModeAgentId != normalizedAgentId) {
          _voiceModeAgentId = await _enableVoiceModeForAgent(normalizedAgentId);
        }
        await _startVoiceTurnController();
        _isVoiceMode = true;
        if (requestId != null) {
          _emit(
            SetVoiceModeResponseMessage(
              requestId: requestId,
              enabled: true,
              agentId: _voiceModeAgentId,
              accepted: true,
              error: null,
            ).toJson(),
          );
        }
        return;
      }

      await _disableVoiceModeForActiveAgent(restoreAgentConfig: true);
      _isVoiceMode = false;
      if (requestId != null) {
        _emit(
          SetVoiceModeResponseMessage(
            requestId: requestId,
            enabled: false,
            agentId: null,
            accepted: true,
            error: null,
          ).toJson(),
        );
      }
    } on Object catch (error) {
      _logger.error(
        'set_voice_mode failed',
        fields: {'error': error, 'enabled': enabled, 'agentId': agentId},
      );
      if (requestId == null) rethrow;
      final unavailable = error is VoiceFeatureUnavailableException
          ? error
          : null;
      _emit(
        SetVoiceModeResponseMessage(
          requestId: requestId,
          enabled: _isVoiceMode,
          agentId: _voiceModeAgentId,
          accepted: false,
          error: _errorMessage(error),
          reasonCode: unavailable?.reasonCode,
          retryable: unavailable?.retryable,
          missingModelIds: unavailable?.missingModelIds,
        ).toJson(),
      );
    }
  }

  VoiceFeatureUnavailableException? _resolveVoiceFeatureUnavailable(
    String mode,
  ) {
    final readiness = _getSpeechReadiness?.call();
    if (readiness == null) return null;
    final modeReadiness = mode == 'voice_mode'
        ? readiness.realtimeVoice
        : readiness.dictation;
    for (final state in [
      if (!modeReadiness.enabled) modeReadiness,
      if (modeReadiness.enabled && !readiness.voiceFeature.available)
        readiness.voiceFeature,
      if (modeReadiness.enabled &&
          readiness.voiceFeature.available &&
          !modeReadiness.available)
        modeReadiness,
    ]) {
      return VoiceFeatureUnavailableException(
        reasonCode: state.reasonCode,
        message: state.message,
        retryable: state.retryable,
        missingModelIds: List<String>.from(state.missingModelIds),
      );
    }
    return null;
  }

  String _parseVoiceTargetAgentId(String rawId, String source) {
    final normalized = rawId.trim();
    final valid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(normalized);
    if (!valid) throw FormatException('$source: agentId must be a UUID');
    return normalized;
  }

  Future<String> _enableVoiceModeForAgent(String agentId) async {
    final existing = await host.loadAgent(agentId);
    _registerVoiceBridgeForAgent(agentId);
    _voiceModeBaseSystemPrompt = stripVoiceModeSystemPrompt(
      existing.systemPrompt,
    );
    try {
      final refreshed = await host.reloadAgentSession(
        agentId,
        VoiceSessionAgentOverrides(
          systemPrompt: buildVoiceModeSystemPrompt(
            _voiceModeBaseSystemPrompt,
            true,
          ),
        ),
      );
      return refreshed.id;
    } on Object {
      _voiceBridge?.unregisterSpeakHandler(agentId);
      _voiceBridge?.unregisterCallerContext(agentId);
      _voiceModeBaseSystemPrompt = null;
      rethrow;
    }
  }

  Future<void> _disableVoiceModeForActiveAgent({
    required bool restoreAgentConfig,
  }) async {
    await _stopVoiceTurnController();
    final agentId = _voiceModeAgentId;
    if (agentId == null) {
      _voiceModeBaseSystemPrompt = null;
      return;
    }
    _voiceBridge?.unregisterSpeakHandler(agentId);
    _voiceBridge?.unregisterCallerContext(agentId);
    if (restoreAgentConfig && _voiceModeBaseSystemPrompt != null) {
      try {
        await host.reloadAgentSession(
          agentId,
          VoiceSessionAgentOverrides(
            systemPrompt: buildVoiceModeSystemPrompt(
              _voiceModeBaseSystemPrompt,
              false,
            ),
          ),
        );
      } on Object catch (error) {
        _logger.warning(
          'Failed to restore agent config while disabling voice mode',
          fields: {'error': error, 'agentId': agentId},
        );
      }
    }
    _voiceModeBaseSystemPrompt = null;
    _voiceModeAgentId = null;
  }

  Future<void> _startVoiceTurnController() async {
    if (_voiceTurnController != null) return;
    final turnDetection = _resolveTurnDetection();
    if (turnDetection == null) {
      throw StateError('Voice turn detection is not configured');
    }
    final stt = _resolveStt();
    if (stt == null) {
      throw StateError('Voice speech-to-text is not configured');
    }
    final controller = createVoiceTurnController(
      logger: _logger.child(const {'component': 'voice-turn-controller'}),
      turnDetection: turnDetection,
      stt: stt,
      sttLanguage: sttLanguage,
      scheduleTimeout: _scheduleTurnTimeout,
      callbacks: VoiceTurnControllerCallbacks(
        onSpeechStarted: () async {},
        onPartialTranscript: (partial) async {
          _emit(const VoiceInputStateMessage(isSpeaking: true).toJson());
          await _handleVoiceSpeechStart();
        },
        onSpeechStopped: () async {
          _handleVoiceSpeechStopped();
          _setPhase(_ProcessingPhase.transcribing);
          _emitActivity('system', 'Transcribing audio...');
        },
        onFinalTranscript: (result) async {
          final transcript = result.isLowConfidence == true
              ? ''
              : result.transcript.trim();
          await _handleTranscriptionResult(
            _VoiceTranscriptionResult(
              text: transcript,
              requestId: _createId(),
              language: result.language,
              duration: result.durationMs,
              avgLogprob: result.avgLogprob,
              isLowConfidence: result.isLowConfidence,
            ),
          );
        },
        onError: (error) {
          _logger.error(
            'Voice turn controller failed',
            fields: {'error': error},
          );
        },
      ),
    );
    await controller.start();
    _voiceTurnController = controller;
  }

  Future<void> _stopVoiceTurnController() async {
    final controller = _voiceTurnController;
    if (controller == null) return;
    _voiceTurnController = null;
    await controller.stop();
  }

  void _handleVoiceSpeechStopped() {
    _emit(const VoiceInputStateMessage(isSpeaking: false).toJson());
  }

  Future<void> handleAudioChunk(VoiceAudioChunkMessage message) async {
    final format = message.format.isEmpty ? 'audio/wav' : message.format;
    if (_isVoiceMode) {
      final controller = _voiceTurnController;
      if (controller == null) {
        throw StateError(
          'Voice mode is enabled but the voice turn controller is not running',
        );
      }
      await controller.appendClientChunk(
        audioBase64: message.audio,
        format: format,
      );
      return;
    }
    final chunk = Uint8List.fromList(base64Decode(message.audio));
    final isPcm = format.toLowerCase().contains('pcm');
    final buffer = await _ensureAudioBufferForFormat(format, isPcm);
    buffer.chunks.add(chunk);
    if (buffer.isPcm) buffer.totalPcmBytes += chunk.length;
    final reachedStreamingThreshold =
        buffer.isPcm && buffer.totalPcmBytes >= minimumStreamingSegmentBytes;
    if (!message.isLast && reachedStreamingThreshold) return;
    final finalized = _finalizeBufferedAudio();
    if (finalized == null) return;
    await _processCompletedAudio(finalized.audio, finalized.format);
  }

  Future<_AudioBufferState> _ensureAudioBufferForFormat(
    String format,
    bool isPcm,
  ) async {
    final current = _audioBuffer;
    if (current == null) {
      return _audioBuffer = _AudioBufferState(format: format, isPcm: isPcm);
    }
    if (current.isPcm != isPcm) {
      final finalized = _finalizeBufferedAudio();
      if (finalized != null) {
        await _processCompletedAudio(finalized.audio, finalized.format);
      }
      return _audioBuffer = _AudioBufferState(format: format, isPcm: isPcm);
    }
    if (!current.isPcm) current.format = format;
    return current;
  }

  _AudioSegment? _finalizeBufferedAudio() {
    final state = _audioBuffer;
    if (state == null) return null;
    _audioBuffer = null;
    final combined = Uint8List.fromList(
      state.chunks.expand((chunk) => chunk).toList(),
    );
    if (state.isPcm) {
      return _AudioSegment(_convertPcmToWav(combined), 'audio/wav');
    }
    return _AudioSegment(combined, state.format);
  }

  Future<void> _processCompletedAudio(Uint8List audio, String format) async {
    if (_processingPhase == _ProcessingPhase.transcribing) {
      _pendingAudioSegments.add(_AudioSegment(audio, format));
      _setBufferTimeout();
      return;
    }
    if (_pendingAudioSegments.isNotEmpty) {
      _pendingAudioSegments.add(_AudioSegment(audio, format));
      final pending = List<_AudioSegment>.from(_pendingAudioSegments);
      _pendingAudioSegments.clear();
      _clearBufferTimeout();
      await _processAudio(
        Uint8List.fromList(pending.expand((segment) => segment.audio).toList()),
        pending.last.format,
      );
      return;
    }
    await _processAudio(audio, format);
  }

  Future<void> _flushPendingAudioSegments(String reason) async {
    if (_processingPhase == _ProcessingPhase.transcribing ||
        _pendingAudioSegments.isEmpty) {
      return;
    }
    final pending = List<_AudioSegment>.from(_pendingAudioSegments);
    _pendingAudioSegments.clear();
    _clearBufferTimeout();
    await _processAudio(
      Uint8List.fromList(pending.expand((segment) => segment.audio).toList()),
      pending.last.format,
    );
  }

  Future<void> _processAudio(Uint8List audio, String format) async {
    _setPhase(_ProcessingPhase.transcribing);
    _emitActivity('system', 'Transcribing audio...');
    try {
      final requestId = _createId();
      final result = await _sttManager.transcribe(
        audio,
        format,
        metadata: TranscriptionMetadata(
          requestId: requestId,
          label: _isVoiceMode ? 'voice' : 'buffered',
        ),
      );
      await _handleTranscriptionResult(
        _VoiceTranscriptionResult(
          text: result.text,
          requestId: requestId,
          language: result.language,
          duration: result.duration,
          avgLogprob: result.avgLogprob,
          isLowConfidence: result.isLowConfidence,
          byteLength: result.byteLength,
          format: result.format,
          debugRecordingPath: result.debugRecordingPath,
        ),
      );
    } on Object catch (error) {
      _setPhase(_ProcessingPhase.idle);
      _clearSpeechInProgress();
      await _flushPendingAudioSegments('transcription error');
      _emitActivity('error', 'Transcription error: ${_errorMessage(error)}');
      rethrow;
    }
  }

  Future<void> _handleTranscriptionResult(
    _VoiceTranscriptionResult result,
  ) async {
    _emit(
      TranscriptionResultMessage(
        text: result.text,
        requestId: result.requestId,
        language: result.language,
        duration: result.duration,
        avgLogprob: result.avgLogprob,
        isLowConfidence: result.isLowConfidence,
        byteLength: result.byteLength,
        format: result.format,
        debugRecordingPath: result.debugRecordingPath,
      ).toJson(),
    );
    final transcript = result.text.trim();
    if (transcript.isEmpty) {
      _setPhase(_ProcessingPhase.idle);
      _clearSpeechInProgress();
      await _flushPendingAudioSegments('empty transcription');
      return;
    }
    _createAbortController();
    if (result.debugRecordingPath != null) {
      _emitActivity(
        'system',
        'Saved input audio: ${result.debugRecordingPath}',
        metadata: {
          'recordingPath': result.debugRecordingPath,
          if (result.format != null) 'format': result.format,
          'requestId': result.requestId,
        },
      );
    }
    _emitActivity(
      'transcript',
      result.text,
      metadata: {
        if (result.language != null) 'language': result.language,
        if (result.duration != null) 'duration': result.duration,
      },
    );
    _clearSpeechInProgress();
    _setPhase(_ProcessingPhase.idle);
    if (!_isVoiceMode) {
      await _flushPendingAudioSegments('voice mode disabled');
      return;
    }
    final agentId = _voiceModeAgentId;
    if (agentId == null) {
      await _flushPendingAudioSegments('no active voice agent');
      return;
    }
    await host.sendSpokenInput(agentId, result.text);
    await _flushPendingAudioSegments('transcription complete');
  }

  void _registerVoiceBridgeForAgent(String agentId) {
    _voiceBridge?.registerSpeakHandler(agentId, ({
      required String text,
      required String callerAgentId,
      VoiceAbortSignal? signal,
    }) async {
      await _ttsManager.generateAndWaitForPlayback(
        text: text,
        emitMessage: (message) => _emit(message.toJson()),
        abortSignal: signal ?? _abortController.signal,
        isVoiceMode: true,
      );
      _emitActivity('assistant', text);
    });
    _voiceBridge?.registerCallerContext(
      agentId,
      const VoiceCallerContext(
        childAgentDefaultLabels: {},
        allowCustomCwd: false,
        enableVoiceTools: true,
      ),
    );
  }

  Future<void> handleAbort() async {
    _abortController.abort();
    _ttsManager.cancelPendingPlaybacks('abort request');
    if (_isVoiceMode && _voiceModeAgentId != null) {
      try {
        await host.interruptAgentIfRunning(_voiceModeAgentId!);
      } on Object catch (error) {
        _emitActivity(
          'error',
          'Voice interruption failed: ${_errorMessage(error)}',
          metadata: const {'voiceAbortFailed': true},
        );
        rethrow;
      }
    }
    if (_processingPhase == _ProcessingPhase.transcribing) return;
    _setPhase(_ProcessingPhase.idle);
    _pendingAudioSegments.clear();
    _clearBufferTimeout();
  }

  void handleAudioPlayed(String id) {
    _ttsManager.confirmAudioPlayed(id);
  }

  Future<void> _handleVoiceSpeechStart() async {
    if (_speechInProgress) return;
    _speechInProgress = true;
    _pendingAudioSegments.clear();
    _audioBuffer = null;
    _clearBufferTimeout();
    _abortController.abort();
    await handleAbort();
  }

  void _clearSpeechInProgress() {
    _speechInProgress = false;
  }

  VoiceAbortController _createAbortController() {
    _abortController.abort();
    _abortController = VoiceAbortController();
    _ttsDebugStreams.clear();
    return _abortController;
  }

  void _setPhase(_ProcessingPhase phase) {
    _processingPhase = phase;
  }

  void _setBufferTimeout() {
    _clearBufferTimeout();
    _bufferTimeout = _scheduleBufferTimeout(voiceAudioBufferTimeout, () async {
      if (_processingPhase == _ProcessingPhase.transcribing) {
        _setBufferTimeout();
        return;
      }
      if (_pendingAudioSegments.isEmpty) return;
      final pending = List<_AudioSegment>.from(_pendingAudioSegments);
      _pendingAudioSegments.clear();
      _bufferTimeout = null;
      await _processAudio(
        Uint8List.fromList(pending.expand((segment) => segment.audio).toList()),
        pending.first.format,
      );
    });
  }

  void _clearBufferTimeout() {
    _bufferTimeout?.cancel();
    _bufferTimeout = null;
  }

  void _handleDictationManagerMessage(Map<String, Object?> message) {
    _emit(message);
  }

  void _emitActivity(
    String type,
    String content, {
    Map<String, Object?>? metadata,
  }) {
    _emit(
      ActivityLogMessage(
        id: _createId(),
        timestamp: _now(),
        logType: type,
        content: content,
        metadata: metadata,
      ).toJson(),
    );
  }

  void _emit(Map<String, Object?> message) {
    if (_ttsDebugAudioStore.enabled &&
        message['type'] == AudioOutputMessage.type) {
      final payload = message['payload'];
      if (payload is Map<String, Object?>) {
        final groupId = payload['groupId'];
        final audio = payload['audio'];
        final format = payload['format'];
        if (groupId is String && audio is String && format is String) {
          try {
            final stream = _ttsDebugStreams.putIfAbsent(
              groupId,
              () => _TtsDebugStream(format),
            );
            stream
              ..format = format
              ..chunks.add(Uint8List.fromList(base64Decode(audio)));
            if (payload['isLastChunk'] == true) {
              _ttsDebugStreams.remove(groupId);
              unawaited(_persistTtsDebugStream(groupId, stream));
            }
          } on Object {
            // Malformed debug capture must not affect live audio delivery.
          }
        }
      }
    }
    host.emit(message);
  }

  Future<void> _persistTtsDebugStream(
    String groupId,
    _TtsDebugStream stream,
  ) async {
    if (stream.chunks.isEmpty) return;
    final path = await _ttsDebugAudioStore.persist(
      Uint8List.fromList(stream.chunks.expand((chunk) => chunk).toList()),
      TtsDebugAudioMetadata(
        sessionId: sessionId,
        groupId: groupId,
        format: stream.format,
      ),
      _logger,
    );
    if (path != null) {
      host.emit(
        ActivityLogMessage(
          id: _createId(),
          timestamp: _now(),
          logType: 'system',
          content: 'Saved TTS audio: $path',
          metadata: {
            'recordingPath': path,
            'format': stream.format,
            'groupId': groupId,
          },
        ).toJson(),
      );
    }
  }

  Future<void> cleanup() async {
    _abortController.abort();
    _clearBufferTimeout();
    _pendingAudioSegments.clear();
    _audioBuffer = null;
    await _stopVoiceTurnController();
    _ttsManager.cleanup();
    _sttManager.cleanup();
    _dictationStreamManager.cleanupAll();
    await _disableVoiceModeForActiveAgent(restoreAgentConfig: true);
    _isVoiceMode = false;
  }
}

enum _ProcessingPhase { idle, transcribing }

final class _AudioSegment {
  const _AudioSegment(this.audio, this.format);
  final Uint8List audio;
  final String format;
}

final class _AudioBufferState {
  _AudioBufferState({required this.format, required this.isPcm});
  final List<Uint8List> chunks = [];
  String format;
  final bool isPcm;
  int totalPcmBytes = 0;
}

final class _VoiceTranscriptionResult {
  const _VoiceTranscriptionResult({
    required this.text,
    required this.requestId,
    this.language,
    this.duration,
    this.avgLogprob,
    this.isLowConfidence,
    this.byteLength,
    this.format,
    this.debugRecordingPath,
  });
  final String text;
  final String requestId;
  final String? language;
  final num? duration;
  final double? avgLogprob;
  final bool? isLowConfidence;
  final int? byteLength;
  final String? format;
  final String? debugRecordingPath;
}

final class _TtsDebugStream {
  _TtsDebugStream(this.format);
  String format;
  final List<Uint8List> chunks = [];
}

final class _SystemVoiceSessionTimeoutHandle
    implements VoiceSessionTimeoutHandle {
  const _SystemVoiceSessionTimeoutHandle(this.timer);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

String _errorMessage(Object error) => switch (error) {
  VoiceFeatureUnavailableException(:final message) => message,
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => error.toString(),
};

Uint8List _convertPcmToWav(Uint8List pcm) {
  const headerSize = 44;
  final wav = Uint8List(headerSize + pcm.length);
  final bytes = ByteData.sublistView(wav);
  void ascii(int offset, String value) {
    wav.setRange(offset, offset + value.length, value.codeUnits);
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, voicePcmChannels, Endian.little);
  bytes.setUint32(24, voicePcmSampleRate, Endian.little);
  bytes.setUint32(
    28,
    voicePcmSampleRate * voicePcmChannels * (voicePcmBitsPerSample ~/ 8),
    Endian.little,
  );
  bytes.setUint16(
    32,
    voicePcmChannels * (voicePcmBitsPerSample ~/ 8),
    Endian.little,
  );
  bytes.setUint16(34, voicePcmBitsPerSample, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, wav.length, pcm);
  return wav;
}
