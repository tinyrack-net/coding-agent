import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'audio.dart';
import 'pcm16_resampler.dart';
import 'speech_provider.dart';
import 'turn_detection_provider.dart';

const voiceFinalTranscriptTimeout = Duration(seconds: 10);

typedef VoiceAsyncCallback = Future<void> Function();
typedef VoicePartialTranscriptCallback =
    Future<void> Function(VoicePartialTranscript transcript);
typedef VoiceFinalTranscriptCallback =
    Future<void> Function(VoiceFinalTranscript transcript);
typedef VoiceErrorCallback = void Function(Object error);
typedef VoiceTurnClock = DateTime Function();
typedef VoiceTurnIdFactory = String Function();
typedef VoiceTurnTimeoutScheduler =
    VoiceTurnTimeoutHandle Function(Duration delay, void Function() callback);

abstract interface class VoiceTurnTimeoutHandle {
  void cancel();
}

final class VoiceTurnControllerCallbacks {
  const VoiceTurnControllerCallbacks({
    required this.onSpeechStarted,
    required this.onSpeechStopped,
    required this.onPartialTranscript,
    required this.onFinalTranscript,
    required this.onError,
  });

  final VoiceAsyncCallback onSpeechStarted;
  final VoiceAsyncCallback onSpeechStopped;
  final VoicePartialTranscriptCallback onPartialTranscript;
  final VoiceFinalTranscriptCallback onFinalTranscript;
  final VoiceErrorCallback onError;
}

final class VoicePartialTranscript {
  const VoicePartialTranscript({
    required this.segmentId,
    required this.transcript,
  });

  final String segmentId;
  final String transcript;
}

final class VoiceFinalTranscript {
  const VoiceFinalTranscript({
    required this.segmentId,
    required this.transcript,
    required this.durationMs,
    this.language,
    this.avgLogprob,
    this.isLowConfidence,
  });

  final String segmentId;
  final String transcript;
  final String? language;
  final double? avgLogprob;
  final bool? isLowConfidence;
  final int durationMs;
}

abstract interface class VoiceTurnController {
  Future<void> start();
  Future<void> stop();
  Future<void> appendClientChunk({
    required String audioBase64,
    required String format,
  });
}

VoiceTurnController createVoiceTurnController({
  required SpeechLogger logger,
  required TurnDetectionProvider turnDetection,
  required SpeechToTextProvider stt,
  required VoiceTurnControllerCallbacks callbacks,
  String? sttLanguage,
  VoiceTurnClock? now,
  VoiceTurnIdFactory? createTurnId,
  VoiceTurnTimeoutScheduler? scheduleTimeout,
}) {
  return _VoiceTurnController(
    logger: logger,
    turnDetection: turnDetection,
    stt: stt,
    callbacks: callbacks,
    sttLanguage: sttLanguage,
    now: now ?? DateTime.now,
    createTurnId: createTurnId ?? const Uuid().v4,
    scheduleTimeout:
        scheduleTimeout ??
        (delay, callback) =>
            _SystemVoiceTurnTimeoutHandle(Timer(delay, callback)),
  );
}

enum _VoiceInputStatus { idle, listening, capturing }

final class _TranscriptSegmentMeta {
  const _TranscriptSegmentMeta({
    this.language,
    this.avgLogprob,
    this.isLowConfidence,
  });

  final String? language;
  final double? avgLogprob;
  final bool? isLowConfidence;
}

final class _FinalizingVoiceTurn {
  _FinalizingVoiceTurn({
    required this.turnId,
    required this.startedAt,
    required this.timeout,
  });

  final String turnId;
  final DateTime startedAt;
  final List<String> committedSegmentIds = [];
  final Map<String, String> transcriptsBySegmentId = {};
  final Set<String> finalTranscriptSegmentIds = {};
  final Map<String, _TranscriptSegmentMeta> transcriptMetaBySegmentId = {};
  final VoiceTurnTimeoutHandle timeout;
  bool fired = false;
}

final class _VoiceTurnController implements VoiceTurnController {
  _VoiceTurnController({
    required SpeechLogger logger,
    required TurnDetectionProvider turnDetection,
    required this.stt,
    required this.callbacks,
    required this.now,
    required this.createTurnId,
    required this.scheduleTimeout,
    this.sttLanguage,
  }) : logger = logger,
       detector = turnDetection.createSession(
         TurnDetectionSessionParameters(
           logger: logger.child(const {'component': 'turn-detection'}),
         ),
       ) {
    inputRate = detector.requiredSampleRate;
    detector.speechStartedEvents.listen((_) {
      unawaited(_runSerial(_handleSpeechStarted));
    });
    detector.speechStoppedEvents.listen((_) {
      unawaited(_runSerial(_handleSpeechStopped));
    });
    detector.errors.listen(_fail);
  }

  final SpeechLogger logger;
  final TurnDetectionSession detector;
  final SpeechToTextProvider stt;
  final String? sttLanguage;
  final VoiceTurnControllerCallbacks callbacks;
  final VoiceTurnClock now;
  final VoiceTurnIdFactory createTurnId;
  final VoiceTurnTimeoutScheduler scheduleTimeout;

  _VoiceInputStatus status = _VoiceInputStatus.idle;
  String? utteranceId;
  DateTime? startedAt;
  Pcm16MonoResampler? resampler;
  StreamingTranscriptionSession? sttSession;
  Pcm16MonoResampler? sttResampler;
  late int inputRate;
  int sttInputRate = 0;
  Future<void> queued = Future<void>.value();
  String? activeTranscriptSegmentId;
  bool partialTranscriptFired = false;
  bool reconnectAttemptedForTurn = false;
  final Set<String> sealedTranscriptSegmentIds = {};
  _FinalizingVoiceTurn? currentFinalizingTurn;

  void _fail(Object? error) {
    callbacks.onError(error ?? StateError('Unknown voice turn error'));
  }

  Future<void> _runSerial(Future<void> Function() task) {
    final next = queued.then((_) async {
      try {
        await task();
      } on Object catch (error) {
        _fail(error);
      }
    });
    queued = next;
    return next;
  }

  StreamingTranscriptionSession _createSttSession() {
    final session = stt.createSession(
      SpeechSessionParameters(
        logger: logger.child(const {'component': 'stt'}),
        language: sttLanguage ?? 'en',
      ),
    );
    session.transcriptEvents.listen(_handleSttTranscript);
    session.committedEvents.listen((event) {
      sealedTranscriptSegmentIds.add(event.segmentId);
      if (status == _VoiceInputStatus.capturing &&
          activeTranscriptSegmentId == null) {
        activeTranscriptSegmentId = event.segmentId;
      }
      final turn = currentFinalizingTurn;
      if (turn != null && !turn.committedSegmentIds.contains(event.segmentId)) {
        turn.committedSegmentIds.add(event.segmentId);
        _maybeFireFinalTranscript(turn);
      }
    });
    session.errors.listen(_handleSttError);
    return session;
  }

  void _handleSttTranscript(StreamingTranscriptionEvent event) {
    if (event.isFinal) {
      _handleFinalSttTranscript(event);
    } else {
      _handlePartialSttTranscript(event);
    }
  }

  void _handlePartialSttTranscript(StreamingTranscriptionEvent event) {
    if (status != _VoiceInputStatus.capturing ||
        partialTranscriptFired ||
        sealedTranscriptSegmentIds.contains(event.segmentId) ||
        (activeTranscriptSegmentId != null &&
            event.segmentId != activeTranscriptSegmentId)) {
      return;
    }
    final transcript = event.transcript.trim();
    if (transcript.isEmpty) return;
    activeTranscriptSegmentId = event.segmentId;
    if (_isFillerOnlyPartial(transcript)) return;

    partialTranscriptFired = true;
    unawaited(
      _runSerial(
        () => callbacks.onPartialTranscript(
          VoicePartialTranscript(
            segmentId: event.segmentId,
            transcript: transcript,
          ),
        ),
      ),
    );
  }

  void _handleFinalSttTranscript(StreamingTranscriptionEvent event) {
    final turn = _getFinalizingTurnForSegment(event.segmentId);
    if (turn == null || turn.fired) return;
    turn.transcriptsBySegmentId[event.segmentId] = event.transcript;
    turn.finalTranscriptSegmentIds.add(event.segmentId);
    turn.transcriptMetaBySegmentId[event.segmentId] = _TranscriptSegmentMeta(
      language: event.language,
      avgLogprob: event.avgLogprob,
      isLowConfidence: event.isLowConfidence,
    );
    _maybeFireFinalTranscript(turn);
  }

  _FinalizingVoiceTurn? _getFinalizingTurnForSegment(String segmentId) {
    final turn = currentFinalizingTurn;
    if (turn == null) return null;
    if (turn.committedSegmentIds.contains(segmentId)) return turn;
    if (turn.committedSegmentIds.isNotEmpty) return null;
    if (activeTranscriptSegmentId != null &&
        activeTranscriptSegmentId != segmentId) {
      return null;
    }
    return turn;
  }

  List<String> _orderedFinalSegmentIds(_FinalizingVoiceTurn turn) {
    if (turn.committedSegmentIds.isEmpty) {
      return turn.finalTranscriptSegmentIds.toList();
    }
    return turn.committedSegmentIds
        .where(turn.finalTranscriptSegmentIds.contains)
        .toList();
  }

  VoiceFinalTranscript _assembleFinalTranscript(_FinalizingVoiceTurn turn) {
    final orderedIds = _orderedFinalSegmentIds(turn);
    final transcript = orderedIds
        .map((id) => turn.transcriptsBySegmentId[id]?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .join(' ')
        .trim();
    final metadata = orderedIds
        .map((id) => turn.transcriptMetaBySegmentId[id])
        .whereType<_TranscriptSegmentMeta>()
        .toList();
    String? language;
    for (final meta in metadata) {
      if (meta.language != null && meta.language!.isNotEmpty) {
        language = meta.language;
        break;
      }
    }
    final singleMeta = metadata.length == 1 ? metadata.single : null;
    final allLowConfidence =
        metadata.isNotEmpty &&
        metadata.every((meta) => meta.isLowConfidence == true);
    return VoiceFinalTranscript(
      segmentId:
          turn.committedSegmentIds.firstOrNull ??
          orderedIds.firstOrNull ??
          turn.turnId,
      transcript: transcript,
      language: language,
      avgLogprob: singleMeta?.avgLogprob,
      isLowConfidence: allLowConfidence ? true : null,
      durationMs: now()
          .difference(turn.startedAt)
          .inMilliseconds
          .clamp(0, 1 << 62),
    );
  }

  void _maybeFireFinalTranscript(_FinalizingVoiceTurn turn) {
    if (turn.fired || turn.committedSegmentIds.isEmpty) return;
    if (turn.committedSegmentIds.every(
      turn.finalTranscriptSegmentIds.contains,
    )) {
      _fireFinalTranscript(turn, timedOut: false);
    }
  }

  void _fireFinalTranscript(
    _FinalizingVoiceTurn turn, {
    required bool timedOut,
  }) {
    if (turn.fired || currentFinalizingTurn?.turnId != turn.turnId) return;
    turn.fired = true;
    turn.timeout.cancel();
    currentFinalizingTurn = null;
    final transcript = _assembleFinalTranscript(turn);
    if (timedOut) {
      logger.warning(
        'voice_turn.final_transcript_timeout',
        fields: {
          'turnId': turn.turnId,
          'committedSegments': turn.committedSegmentIds.length,
          'receivedFinals': turn.finalTranscriptSegmentIds.length,
          'timeoutMs': voiceFinalTranscriptTimeout.inMilliseconds,
          'transcriptLength': transcript.transcript.length,
        },
      );
    }
    unawaited(_runSerial(() => callbacks.onFinalTranscript(transcript)));
  }

  void _handleSttError(Object? error) {
    _fail(error);
    logger.warning('voice_turn.stt_error', fields: {'error': error});
    if (reconnectAttemptedForTurn) {
      sttSession?.close();
      sttSession = null;
      return;
    }
    reconnectAttemptedForTurn = true;
    unawaited(_runSerial(_reconnectSttSession));
  }

  Future<void> _reconnectSttSession() async {
    final previousSession = sttSession;
    sttSession = null;
    sttResampler = null;
    sttInputRate = 0;
    previousSession?.close();
    try {
      final nextSession = _createSttSession();
      await nextSession.connect();
      sttSession = nextSession;
      logger.info('voice_turn.stt_reconnected');
    } on Object catch (error) {
      _fail(error);
      logger.warning(
        'voice_turn.stt_reconnect_failed',
        fields: {'error': error},
      );
    }
  }

  Future<void> _handleSpeechStarted() async {
    if (status == _VoiceInputStatus.capturing) return;
    await callbacks.onSpeechStarted();
    activeTranscriptSegmentId = null;
    partialTranscriptFired = false;
    reconnectAttemptedForTurn = false;
    currentFinalizingTurn?.timeout.cancel();
    currentFinalizingTurn = null;
    utteranceId = createTurnId();
    startedAt = now();
    status = _VoiceInputStatus.capturing;
    logger.info(
      'voice_turn.speech_started',
      fields: {'utteranceId': utteranceId},
    );
  }

  Future<void> _handleSpeechStopped() async {
    if (status != _VoiceInputStatus.capturing) return;
    final turnId = utteranceId!;
    final turnStartedAt = startedAt!;
    final endedAt = now();
    status = _VoiceInputStatus.listening;

    late final _FinalizingVoiceTurn finalizingTurn;
    final timeout = scheduleTimeout(voiceFinalTranscriptTimeout, () {
      _fireFinalTranscript(finalizingTurn, timedOut: true);
    });
    finalizingTurn = _FinalizingVoiceTurn(
      turnId: turnId,
      startedAt: turnStartedAt,
      timeout: timeout,
    );
    currentFinalizingTurn = finalizingTurn;
    detector.reset();
    try {
      sttSession?.commit();
    } on Object catch (error) {
      _handleSttError(error);
    }
    await callbacks.onSpeechStopped();
    logger.info(
      'voice_turn.speech_stopped',
      fields: {
        'utteranceAgeMs': endedAt
            .difference(turnStartedAt)
            .inMilliseconds
            .clamp(0, 1 << 62),
      },
    );
  }

  void _updateDetectorResampler(int parsedInputRate) {
    if (parsedInputRate == inputRate) return;
    inputRate = parsedInputRate;
    resampler = inputRate == detector.requiredSampleRate
        ? null
        : Pcm16MonoResampler(
            inputRate: inputRate,
            outputRate: detector.requiredSampleRate,
          );
  }

  void _updateSttResampler(
    StreamingTranscriptionSession session,
    int parsedInputRate,
  ) {
    if (parsedInputRate == sttInputRate) return;
    sttInputRate = parsedInputRate;
    sttResampler = sttInputRate == session.requiredSampleRate
        ? null
        : Pcm16MonoResampler(
            inputRate: sttInputRate,
            outputRate: session.requiredSampleRate,
          );
  }

  @override
  Future<void> start() async {
    sttSession = _createSttSession();
    await sttSession!.connect();
    await detector.connect();
    status = _VoiceInputStatus.listening;
  }

  @override
  Future<void> stop() {
    return _runSerial(() async {
      currentFinalizingTurn?.timeout.cancel();
      detector.close();
      sttSession?.close();
      resampler?.reset();
      sttResampler?.reset();
      resampler = null;
      sttResampler = null;
      sttSession = null;
      currentFinalizingTurn = null;
      status = _VoiceInputStatus.idle;
    });
  }

  @override
  Future<void> appendClientChunk({
    required String audioBase64,
    required String format,
  }) {
    return _runSerial(() async {
      if (status == _VoiceInputStatus.idle) return;
      final pcm16 = Uint8List.fromList(base64Decode(audioBase64));
      if (pcm16.isEmpty) return;
      final parsedInputRate =
          parsePcmRateFromFormat(format, detector.requiredSampleRate) ??
          detector.requiredSampleRate;
      _updateDetectorResampler(parsedInputRate);
      final currentSttSession = sttSession;
      if (currentSttSession != null) {
        _updateSttResampler(currentSttSession, parsedInputRate);
      }
      final detectorPcm16 = resampler == null
          ? pcm16
          : resampler!.processChunk(pcm16);
      final Uint8List? sttPcm16;
      if (currentSttSession == null) {
        sttPcm16 = null;
      } else if (currentSttSession.requiredSampleRate ==
          detector.requiredSampleRate) {
        sttPcm16 = detectorPcm16;
      } else {
        sttPcm16 = sttResampler == null
            ? pcm16
            : sttResampler!.processChunk(pcm16);
      }
      if (detectorPcm16.isEmpty && (sttPcm16 == null || sttPcm16.isEmpty)) {
        return;
      }
      if (detectorPcm16.isNotEmpty) detector.appendPcm16(detectorPcm16);
      if (sttPcm16 != null && sttPcm16.isNotEmpty) {
        try {
          currentSttSession?.appendPcm16(sttPcm16);
        } on Object catch (error) {
          _handleSttError(error);
        }
      }
    });
  }
}

final class _SystemVoiceTurnTimeoutHandle implements VoiceTurnTimeoutHandle {
  const _SystemVoiceTurnTimeoutHandle(this.timer);

  final Timer timer;

  @override
  void cancel() => timer.cancel();
}

const _fillerPartialWords = {
  'uh',
  'um',
  'ah',
  'eh',
  'er',
  'hmm',
  'mm',
  'mmm',
  'mhm',
  'huh',
  'uhhuh',
  'uh-huh',
  'oh',
};

bool _isFillerOnlyPartial(String transcript) {
  final normalized = transcript.toLowerCase().replaceAll(
    RegExp(r"[^\p{L}\p{N}\s'-]", unicode: true),
    '',
  );
  final tokens = normalized
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();
  return tokens.isEmpty || tokens.every(_fillerPartialWords.contains);
}
