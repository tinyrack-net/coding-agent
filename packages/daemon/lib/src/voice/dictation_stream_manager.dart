import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import 'audio.dart';
import 'dictation_debug.dart';
import 'pcm16_resampler.dart';
import 'provider_resolver.dart';
import 'speech_provider.dart';

const defaultDictationFinalTimeout = Duration(seconds: 10);
const double defaultDictationAutoCommitSeconds = 15;
const Duration dictationFinalTimeoutMax = Duration(minutes: 5);
const Duration dictationFinalTimeoutPerPendingSegment = Duration(seconds: 15);
const int dictationFinalTimeoutPerPendingAudioSecondMs = 1500;
const int dictationFinalTimeoutPerMissingSeqMs = 250;

typedef DictationStreamEmitter = void Function(Map<String, Object?> message);
typedef DictationTimeoutScheduler =
    DictationTimeoutHandle Function(Duration delay, void Function() callback);

abstract interface class DictationTimeoutHandle {
  void cancel();
}

final class DictationStreamManager {
  DictationStreamManager({
    required SpeechLogger logger,
    required DictationStreamEmitter emit,
    required this.sessionId,
    required Object? resolveStt,
    this.language = 'en',
    Duration finalTimeout = defaultDictationFinalTimeout,
    double? autoCommitSeconds,
    Map<String, String>? environment,
    String? cwd,
    DictationDebugAudioStore? debugAudioStore,
    DictationTimeoutScheduler? scheduleTimeout,
    String Function()? createActivityId,
    DateTime Function()? now,
  }) : _logger = logger.child(const {'component': 'dictation-stream-manager'}),
       _emit = emit,
       _resolveStt = toResolver<SpeechToTextProvider?>(resolveStt),
       _finalTimeout = finalTimeout,
       _environment = environment ?? Platform.environment,
       _autoCommitSeconds =
           autoCommitSeconds ??
           _parseNonNegativeNumber(
             (environment ??
                 Platform
                     .environment)['TINYRACK_DICTATION_AUTO_COMMIT_SECONDS'],
           ) ??
           defaultDictationAutoCommitSeconds,
       _debugAudioStore =
           debugAudioStore ??
           DictationDebugAudioStore(
             environment: environment ?? Platform.environment,
             cwd: cwd ?? Directory.current.path,
           ),
       _scheduleTimeout =
           scheduleTimeout ??
           ((delay, callback) =>
               _SystemDictationTimeoutHandle(Timer(delay, callback))),
       _createActivityId = createActivityId ?? const Uuid().v4,
       _now = now ?? DateTime.now;

  final SpeechLogger _logger;
  final DictationStreamEmitter _emit;
  final String sessionId;
  final SpeechToTextResolver _resolveStt;
  final String language;
  final Duration _finalTimeout;
  final double _autoCommitSeconds;
  final Map<String, String> _environment;
  final DictationDebugAudioStore _debugAudioStore;
  final DictationTimeoutScheduler _scheduleTimeout;
  final String Function() _createActivityId;
  final DateTime Function() _now;
  final Map<String, _DictationStreamState> _streams = {};

  void cleanupAll() {
    for (final dictationId in _streams.keys.toList(growable: false)) {
      _cleanupDictationStream(dictationId);
    }
  }

  Future<void> handleStart(String dictationId, String format) async {
    _cleanupDictationStream(dictationId);
    final sttProvider = _resolveStt();
    if (sttProvider == null) {
      _failDictationStream(
        dictationId,
        'Dictation STT not configured',
        retryable: false,
      );
      return;
    }
    final transcriptionPrompt =
        _environment['TINYRACK_DICTATION_TRANSCRIPTION_PROMPT'] ??
        'Transcribe only what the speaker says. Do not add words. Preserve punctuation and casing. If the audio is silence or non-speech noise, return an empty transcript.';

    late final StreamingTranscriptionSession stt;
    try {
      stt = sttProvider.createSession(
        SpeechSessionParameters(
          logger: _logger.child({'dictationId': dictationId}),
          language: language,
          prompt: transcriptionPrompt,
        ),
      );
    } on Object catch (error) {
      _failDictationStream(dictationId, _errorMessage(error), retryable: false);
      return;
    }

    stt.committedEvents.listen((event) {
      final state = _streams[dictationId];
      if (state == null) return;
      state.committedSegmentIds.add(event.segmentId);
      state.bytesSinceCommit = 0;
      state.peakSinceCommit = 0;
      if (state.finishRequested && state.awaitingFinalCommit) {
        state.awaitingFinalCommit = false;
      }
      _maybeFinalizeDictationStream(dictationId);
    });
    stt.transcriptEvents.listen((event) {
      final state = _streams[dictationId];
      if (state == null) return;
      state.transcriptsBySegmentId[event.segmentId] = event.transcript;
      if (event.isFinal) {
        state.finalTranscriptSegmentIds.add(event.segmentId);
      }
      if (state.finishRequested && state.awaitingFinalCommit && event.isFinal) {
        state.awaitingFinalCommit = false;
      }
      final orderedIds = state.committedSegmentIds.contains(event.segmentId)
          ? state.committedSegmentIds
          : [...state.committedSegmentIds, event.segmentId];
      final partialText = orderedIds
          .map((id) => state.transcriptsBySegmentId[id] ?? '')
          .join(' ')
          .trim();
      _emit(
        DictationStreamPartialMessage(
          dictationId: dictationId,
          text: partialText,
        ).toJson(),
      );
      _maybeSealDictationStreamFinish(dictationId);
      _maybeFinalizeDictationStream(dictationId);
    });
    stt.errors.listen((error) {
      final message = _errorMessage(error);
      final state = _streams[dictationId];
      if (state != null &&
          state.finishRequested &&
          _isBufferTooSmallError(message)) {
        if (state.awaitingFinalCommit) {
          state.awaitingFinalCommit = false;
        }
        _maybeFinalizeDictationStream(dictationId);
        return;
      }
      unawaited(
        _failAndCleanupDictationStream(dictationId, message, retryable: true),
      );
    });

    try {
      await stt.connect();
    } on Object catch (error) {
      _failDictationStream(dictationId, _errorMessage(error), retryable: true);
      try {
        stt.close();
      } on Object {
        // Best-effort cleanup matches the frozen session boundary.
      }
      return;
    }

    final inputRate = parsePcmRateFromFormat(format, 16000) ?? 16000;
    if (inputRate <= 0) {
      _failDictationStream(
        dictationId,
        'Invalid dictation input rate in format: $format',
        retryable: false,
      );
      try {
        stt.close();
      } on Object {
        // Best-effort cleanup matches the frozen session boundary.
      }
      return;
    }
    final outputRate = stt.requiredSampleRate;
    final autoCommitBytes = _autoCommitSeconds > 0
        ? math.max(1, (_autoCommitSeconds * outputRate * 2).round())
        : 0;
    final debugChunkWriter = _debugAudioStore.createChunkWriter(
      sessionId: sessionId,
      dictationId: dictationId,
      logger: _logger,
    );
    _streams[dictationId] = _DictationStreamState(
      dictationId: dictationId,
      sessionId: sessionId,
      inputFormat: format,
      stt: stt,
      inputRate: inputRate,
      outputRate: outputRate,
      resampler: inputRate == outputRate
          ? null
          : Pcm16MonoResampler(inputRate: inputRate, outputRate: outputRate),
      autoCommitBytes: autoCommitBytes,
      debugChunkWriter: debugChunkWriter,
    );
    _emit(
      DictationStreamAckMessage(dictationId: dictationId, ackSeq: -1).toJson(),
    );
  }

  Future<void> handleChunk({
    required String dictationId,
    required int seq,
    required String audioBase64,
    required String format,
  }) async {
    final state = _streams[dictationId];
    if (state == null) {
      _failDictationStream(
        dictationId,
        'Dictation stream not started',
        retryable: true,
      );
      return;
    }
    if (format != state.inputFormat) {
      unawaited(
        _failAndCleanupDictationStream(
          dictationId,
          'Mismatched dictation stream format: $format',
          retryable: false,
        ),
      );
      return;
    }
    if (seq < state.nextSeqToForward) {
      _emit(
        DictationStreamAckMessage(
          dictationId: dictationId,
          ackSeq: state.ackSeq,
        ).toJson(),
      );
      return;
    }
    if (!state.receivedChunks.containsKey(seq)) {
      try {
        state.receivedChunks[seq] = Uint8List.fromList(
          base64Decode(audioBase64),
        );
      } on Object catch (error) {
        await _failAndCleanupDictationStream(
          dictationId,
          _errorMessage(error),
          retryable: false,
        );
        return;
      }
    }

    while (state.receivedChunks.containsKey(state.nextSeqToForward)) {
      final currentSeq = state.nextSeqToForward;
      final pcm16 = state.receivedChunks.remove(currentSeq)!;
      final resampled = state.resampler?.processChunk(pcm16) ?? pcm16;
      if (resampled.isNotEmpty) {
        try {
          state.stt.appendPcm16(resampled);
          state.debugAudioChunks.add(Uint8List.fromList(resampled));
          state.bytesSinceCommit += resampled.length;
          state.peakSinceCommit = math.max(
            state.peakSinceCommit,
            pcm16lePeakAbs(resampled),
          );
          _maybeAutoCommitDictationSegment(state);
        } on Object catch (error) {
          unawaited(
            _failAndCleanupDictationStream(
              dictationId,
              _errorMessage(error),
              retryable: true,
            ),
          );
          return;
        }
        final writer = state.debugChunkWriter;
        if (writer != null) {
          unawaited(
            writer.writeChunk(currentSeq, resampled).catchError((Object error) {
              _logger.warning(
                'Failed to write debug chunk',
                fields: {
                  'dictationId': dictationId,
                  'seq': currentSeq,
                  'error': error,
                },
              );
            }),
          );
        }
      }
      state.nextSeqToForward += 1;
      state.ackSeq = state.nextSeqToForward - 1;
    }
    _emit(
      DictationStreamAckMessage(
        dictationId: dictationId,
        ackSeq: state.ackSeq,
      ).toJson(),
    );
    _maybeSealDictationStreamFinish(dictationId);
    _maybeFinalizeDictationStream(dictationId);
  }

  Future<void> handleFinish(String dictationId, int finalSeq) async {
    final state = _streams[dictationId];
    if (state == null) {
      _failDictationStream(
        dictationId,
        'Dictation stream not started',
        retryable: true,
      );
      return;
    }
    state.finishRequested = true;
    state.finalSeq = finalSeq;
    if (finalSeq >= 0 &&
        state.ackSeq < 0 &&
        state.nextSeqToForward == 0 &&
        state.receivedChunks.isEmpty) {
      _failDictationStream(
        dictationId,
        'Dictation finished (finalSeq=$finalSeq) but no audio chunks were received',
        retryable: true,
      );
      _cleanupDictationStream(dictationId);
      return;
    }
    _maybeSealDictationStreamFinish(dictationId);
    _maybeFinalizeDictationStream(dictationId);
    final updatedState = _streams[dictationId];
    if (updatedState == null) return;

    final estimate = _estimateFinalizationTimeout(updatedState);
    updatedState.finalTimeout?.cancel();
    updatedState.finalTimeout = _scheduleTimeout(
      Duration(milliseconds: estimate.timeoutMs),
      () {
        unawaited(
          _failAndCleanupDictationStream(
            dictationId,
            'Timed out waiting for final transcription',
            retryable: true,
          ),
        );
      },
    );
    _emit(
      DictationStreamFinishAcceptedMessage(
        dictationId: dictationId,
        timeoutMs: estimate.timeoutMs,
      ).toJson(),
    );
    _logger.debug(
      'Accepted dictation finish request with adaptive timeout budget',
      fields: {
        'dictationId': dictationId,
        'finalSeq': finalSeq,
        'ackSeq': updatedState.ackSeq,
        'pendingSegments': estimate.pendingSegments,
        'pendingAudioSeconds': estimate.pendingAudioSeconds,
        'missingSeqCount': estimate.missingSeqCount,
        'timeoutMs': estimate.timeoutMs,
      },
    );
  }

  void handleCancel(String dictationId) {
    _cleanupDictationStream(dictationId);
  }

  Future<String?> _maybePersistDictationStreamAudio(String dictationId) async {
    final state = _streams[dictationId];
    if (state == null) return null;
    if (state.debugRecordingPath != null) return state.debugRecordingPath;
    if (state.debugAudioChunks.isEmpty) return null;
    final pcm = Uint8List.fromList(
      state.debugAudioChunks.expand((chunk) => chunk).toList(),
    );
    final wav = _convertPcmToWav(pcm, state.outputRate);
    await state.debugChunkWriter?.drain();
    final path = await _debugAudioStore.persist(
      wav,
      DictationDebugAudioMetadata(
        sessionId: state.sessionId,
        dictationId: state.dictationId,
        format: 'audio/wav',
      ),
      _logger,
      chunkWriterFolder: state.debugChunkWriter?.folder,
    );
    state.debugRecordingPath = path;
    return path;
  }

  void _failDictationStream(
    String dictationId,
    String error, {
    required bool retryable,
  }) {
    _emit(
      DictationStreamErrorMessage(
        dictationId: dictationId,
        error: error,
        retryable: retryable,
      ).toJson(),
    );
  }

  Future<void> _failAndCleanupDictationStream(
    String dictationId,
    String error, {
    required bool retryable,
  }) async {
    final debugRecordingPath = await _maybePersistDictationStreamAudio(
      dictationId,
    );
    _emit(
      DictationStreamErrorMessage(
        dictationId: dictationId,
        error: error,
        retryable: retryable,
        debugRecordingPath: debugRecordingPath,
      ).toJson(),
    );
    if (debugRecordingPath != null) {
      _emitSavedAudioActivity(dictationId, debugRecordingPath);
    }
    _cleanupDictationStream(dictationId);
  }

  void _cleanupDictationStream(String dictationId) {
    final state = _streams[dictationId];
    if (state == null) return;
    state.finalTimeout?.cancel();
    try {
      state.stt.close();
    } on Object {
      // Best-effort cleanup matches the frozen session boundary.
    }
    _streams.remove(dictationId);
  }

  _FinalizationEstimate _estimateFinalizationTimeout(
    _DictationStreamState state,
  ) {
    final bytesPerSecond = math.max(1, state.outputRate * 2);
    final pendingCommittedSegments = state.committedSegmentIds
        .where(
          (segmentId) => !state.finalTranscriptSegmentIds.contains(segmentId),
        )
        .length;
    final committedSet = state.committedSegmentIds.toSet();
    final pendingUncommittedTranscriptSegments = state
        .transcriptsBySegmentId
        .keys
        .where(
          (segmentId) =>
              !committedSet.contains(segmentId) &&
              !state.finalTranscriptSegmentIds.contains(segmentId),
        )
        .length;
    final pendingSegments =
        pendingCommittedSegments +
        pendingUncommittedTranscriptSegments +
        (state.awaitingFinalCommit ? 1 : 0);
    final pendingAudioSeconds =
        (math.max(0, state.bytesSinceCommit) / bytesPerSecond).ceil();
    final missingSeqCount = state.finalSeq == null
        ? 0
        : math.max(0, state.finalSeq! - state.ackSeq);
    final extraMs =
        pendingSegments *
            dictationFinalTimeoutPerPendingSegment.inMilliseconds +
        pendingAudioSeconds * dictationFinalTimeoutPerPendingAudioSecondMs +
        missingSeqCount * dictationFinalTimeoutPerMissingSeqMs;
    final timeoutMs = math.max(
      _finalTimeout.inMilliseconds,
      math.min(
        dictationFinalTimeoutMax.inMilliseconds,
        _finalTimeout.inMilliseconds + extraMs,
      ),
    );
    return _FinalizationEstimate(
      timeoutMs: timeoutMs,
      pendingSegments: pendingSegments,
      pendingAudioSeconds: pendingAudioSeconds,
      missingSeqCount: missingSeqCount,
    );
  }

  void _maybeAutoCommitDictationSegment(_DictationStreamState state) {
    if (state.finishRequested ||
        state.autoCommitBytes <= 0 ||
        state.bytesSinceCommit < state.autoCommitBytes) {
      return;
    }
    if (state.peakSinceCommit < _silencePeakThreshold) {
      state.stt.clear();
      state.bytesSinceCommit = 0;
      state.peakSinceCommit = 0;
      return;
    }
    state.bytesSinceCommit = 0;
    state.peakSinceCommit = 0;
    state.stt.commit();
  }

  double get _silencePeakThreshold => _parseJavaScriptInteger(
    _environment['TINYRACK_DICTATION_SILENCE_PEAK_THRESHOLD'] ?? '300',
  );

  void _maybeSealDictationStreamFinish(String dictationId) {
    final state = _streams[dictationId];
    if (state == null ||
        !state.finishRequested ||
        state.finalSeq == null ||
        state.ackSeq < state.finalSeq! ||
        state.finishSealed) {
      return;
    }
    if (state.bytesSinceCommit > 0) {
      if (state.peakSinceCommit < _silencePeakThreshold) {
        state.stt.clear();
        state.bytesSinceCommit = 0;
        state.peakSinceCommit = 0;
        state.awaitingFinalCommit = false;
        _dropUncommittedNonFinalTranscripts(state);
      } else {
        state.awaitingFinalCommit = true;
        try {
          state.stt.commit();
        } on Object catch (error) {
          unawaited(
            _failAndCleanupDictationStream(
              dictationId,
              _errorMessage(error),
              retryable: true,
            ),
          );
          return;
        }
      }
    } else {
      state.awaitingFinalCommit = false;
    }
    state.finishSealed = true;
  }

  int _dropUncommittedNonFinalTranscripts(_DictationStreamState state) {
    final committedSet = state.committedSegmentIds.toSet();
    var dropped = 0;
    for (final segmentId in state.transcriptsBySegmentId.keys.toList(
      growable: false,
    )) {
      if (committedSet.contains(segmentId) ||
          state.finalTranscriptSegmentIds.contains(segmentId)) {
        continue;
      }
      state.transcriptsBySegmentId.remove(segmentId);
      dropped += 1;
    }
    return dropped;
  }

  void _maybeFinalizeDictationStream(String dictationId) {
    final state = _streams[dictationId];
    if (state == null ||
        !state.finishRequested ||
        state.finalSeq == null ||
        state.ackSeq < state.finalSeq! ||
        state.awaitingFinalCommit) {
      return;
    }
    final committedSet = state.committedSegmentIds.toSet();
    final orderedSegmentIds = <String>[...state.committedSegmentIds];
    for (final segmentId in state.transcriptsBySegmentId.keys) {
      if (!committedSet.contains(segmentId)) {
        orderedSegmentIds.add(segmentId);
      }
    }
    if (orderedSegmentIds.isEmpty) {
      unawaited(_finalizeStream(dictationId, ''));
      return;
    }
    if (!orderedSegmentIds.every(state.finalTranscriptSegmentIds.contains)) {
      return;
    }
    final text = orderedSegmentIds
        .map((segmentId) => state.transcriptsBySegmentId[segmentId] ?? '')
        .join(' ')
        .trim();
    unawaited(_finalizeStream(dictationId, text));
  }

  Future<void> _finalizeStream(String dictationId, String text) async {
    final debugRecordingPath = await _maybePersistDictationStreamAudio(
      dictationId,
    );
    if (!_streams.containsKey(dictationId)) return;
    _emit(
      DictationStreamFinalMessage(
        dictationId: dictationId,
        text: text,
        debugRecordingPath: debugRecordingPath,
      ).toJson(),
    );
    if (debugRecordingPath != null) {
      _emitSavedAudioActivity(dictationId, debugRecordingPath);
    }
    _cleanupDictationStream(dictationId);
  }

  void _emitSavedAudioActivity(String dictationId, String recordingPath) {
    _emit({
      'type': 'activity_log',
      'payload': {
        'id': _createActivityId(),
        'timestamp': _now().toUtc().toIso8601String(),
        'type': 'system',
        'content': 'Saved dictation audio: $recordingPath',
        'metadata': {
          'recordingPath': recordingPath,
          'dictationId': dictationId,
        },
      },
    });
  }
}

final class _DictationStreamState {
  _DictationStreamState({
    required this.dictationId,
    required this.sessionId,
    required this.inputFormat,
    required this.stt,
    required this.inputRate,
    required this.outputRate,
    required this.resampler,
    required this.autoCommitBytes,
    required this.debugChunkWriter,
  });

  final String dictationId;
  final String sessionId;
  final String inputFormat;
  final StreamingTranscriptionSession stt;
  final int inputRate;
  final int outputRate;
  final Pcm16MonoResampler? resampler;
  final DictationDebugChunkWriter? debugChunkWriter;
  final List<Uint8List> debugAudioChunks = [];
  String? debugRecordingPath;
  final Map<int, Uint8List> receivedChunks = {};
  int nextSeqToForward = 0;
  int ackSeq = -1;
  final int autoCommitBytes;
  int bytesSinceCommit = 0;
  int peakSinceCommit = 0;
  final List<String> committedSegmentIds = [];
  final Map<String, String> transcriptsBySegmentId = {};
  final Set<String> finalTranscriptSegmentIds = {};
  bool awaitingFinalCommit = false;
  bool finishRequested = false;
  bool finishSealed = false;
  int? finalSeq;
  DictationTimeoutHandle? finalTimeout;
}

final class _FinalizationEstimate {
  const _FinalizationEstimate({
    required this.timeoutMs,
    required this.pendingSegments,
    required this.pendingAudioSeconds,
    required this.missingSeqCount,
  });

  final int timeoutMs;
  final int pendingSegments;
  final int pendingAudioSeconds;
  final int missingSeqCount;
}

final class _SystemDictationTimeoutHandle implements DictationTimeoutHandle {
  const _SystemDictationTimeoutHandle(this.timer);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

double? _parseNonNegativeNumber(String? value) {
  if (value == null) return null;
  final parsed = double.tryParse(value);
  return parsed == null || !parsed.isFinite || parsed < 0 ? null : parsed;
}

String _errorMessage(Object? error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  FileSystemException(:final message) => message,
  null => 'null',
  _ => error.toString(),
};

bool _isBufferTooSmallError(String message) =>
    RegExp('buffer too small', caseSensitive: false).hasMatch(message);

double _parseJavaScriptInteger(String value) {
  final match = RegExp(r'^[\s]*([+-]?\d+)').firstMatch(value);
  return match == null
      ? double.nan
      : (int.tryParse(match.group(1)!)?.toDouble() ?? double.nan);
}

Uint8List _convertPcmToWav(Uint8List pcm, int sampleRate) {
  const headerSize = 44;
  const channels = 1;
  const bitsPerSample = 16;
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
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, pcm.length, Endian.little);
  wav.setRange(44, wav.length, pcm);
  return wav;
}
