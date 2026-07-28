import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../audio.dart';
import '../../pcm16_resampler.dart';
import '../../speech_provider.dart';
import 'offline_recognizer.dart';

const int defaultParakeetSilencePeakThreshold = 300;
const Duration defaultParakeetDecodeInterval = Duration(milliseconds: 350);

final class SherpaOnnxParakeetStt implements SpeechToTextProvider {
  SherpaOnnxParakeetStt({
    required this.engine,
    this.silencePeakThreshold = defaultParakeetSilencePeakThreshold,
    SpeechLogger logger = const NullSpeechLogger(),
    Uuid uuid = const Uuid(),
  }) : _logger = logger.child({
         'module': 'speech',
         'provider': 'local',
         'component': 'parakeet-stt',
       }),
       _uuid = uuid;

  final SherpaOfflineRecognizerEngine engine;
  final int silencePeakThreshold;
  final SpeechLogger _logger;
  final Uuid _uuid;

  @override
  String get id => 'local';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => _SherpaParakeetTranscriptionSession(
    provider: this,
    logger: parameters.logger.child({
      'provider': 'local',
      'component': 'parakeet-stt-session',
    }),
    uuid: _uuid,
  );

  Future<TranscriptionResult> transcribeAudio(
    Uint8List audioBuffer,
    String format,
  ) async {
    final stopwatch = Stopwatch()..start();
    final normalized = format.toLowerCase();
    late int inputRate;
    late Uint8List pcm16;
    if (normalized.contains('audio/wav')) {
      final parsed = parsePcm16MonoWav(audioBuffer);
      inputRate = parsed.sampleRate;
      pcm16 = parsed.pcm16;
    } else if (normalized.contains('audio/pcm')) {
      inputRate =
          parsePcmRateFromFormat(format, engine.sampleRate) ??
          engine.sampleRate;
      pcm16 = audioBuffer;
    } else {
      throw StateError(
        'Unsupported audio format for sherpa Parakeet STT: $format',
      );
    }

    if (pcm16lePeakAbs(pcm16) < silencePeakThreshold) {
      return TranscriptionResult(
        text: '',
        duration: stopwatch.elapsedMilliseconds.toDouble(),
        isLowConfidence: true,
      );
    }

    if (inputRate != engine.sampleRate) {
      pcm16 = Pcm16MonoResampler(
        inputRate: inputRate,
        outputRate: engine.sampleRate,
      ).processChunk(pcm16);
      inputRate = engine.sampleRate;
    }
    final peakFloat = pcm16lePeakAbs(pcm16) / 32768;
    const targetPeak = 0.6;
    const maxGain = 50.0;
    final gain = peakFloat > 0 && peakFloat < targetPeak
        ? (targetPeak / peakFloat).clamp(1, maxGain).toDouble()
        : 1.0;
    final text = engine.decode(
      pcm16leToFloat32(pcm16, gain: gain),
      inputSampleRate: inputRate,
    );
    final duration = stopwatch.elapsedMilliseconds.toDouble();
    _logger.debug(
      'Parakeet transcription complete',
      fields: {'duration': duration, 'textLength': text.length},
    );
    return TranscriptionResult(
      text: text,
      duration: duration,
      isLowConfidence: text.isEmpty ? true : null,
    );
  }
}

final class _SherpaParakeetTranscriptionSession
    implements StreamingTranscriptionSession {
  _SherpaParakeetTranscriptionSession({
    required this.provider,
    required this.logger,
    required Uuid uuid,
  }) : _uuid = uuid,
       _segmentId = uuid.v4();

  final SherpaOnnxParakeetStt provider;
  final SpeechLogger logger;
  final Uuid _uuid;
  final StreamController<StreamingTranscriptionCommittedEvent> _committed =
      StreamController.broadcast(sync: true);
  final StreamController<StreamingTranscriptionEvent> _transcripts =
      StreamController.broadcast(sync: true);
  final StreamController<Object?> _errors = StreamController.broadcast(
    sync: true,
  );
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  bool _connected = false;
  String _segmentId;
  String? _previousSegmentId;

  @override
  int get requiredSampleRate => provider.engine.sampleRate;

  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      _committed.stream;

  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      _transcripts.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async => _connected = true;

  @override
  void appendPcm16(List<int> pcm16le) {
    if (!_connected) {
      _errors.add(StateError('STT session not connected'));
      return;
    }
    _pcm.add(pcm16le);
  }

  @override
  void commit() {
    if (!_connected) {
      _errors.add(StateError('STT session not connected'));
      return;
    }
    final committedId = _segmentId;
    final previousId = _previousSegmentId;
    final pcm = _pcm.takeBytes();
    _previousSegmentId = committedId;
    _segmentId = _uuid.v4();
    _committed.add(
      StreamingTranscriptionCommittedEvent(
        segmentId: committedId,
        previousSegmentId: previousId,
      ),
    );
    unawaited(_transcribe(committedId, pcm));
  }

  Future<void> _transcribe(String segmentId, Uint8List pcm) async {
    try {
      final result = await provider.transcribeAudio(
        pcm,
        'audio/pcm;rate=$requiredSampleRate',
      );
      _transcripts.add(
        StreamingTranscriptionEvent(
          segmentId: segmentId,
          transcript: result.text,
          isFinal: true,
          language: result.language,
          logprobs: result.logprobs,
          avgLogprob: result.avgLogprob,
          isLowConfidence: result.isLowConfidence,
        ),
      );
    } on Object catch (error) {
      _errors.add(error);
    } finally {
      logger.debug('Parakeet session reset', fields: {'bytes': pcm.length});
    }
  }

  @override
  void clear() {
    _pcm.takeBytes();
    _segmentId = _uuid.v4();
  }

  @override
  void close() {
    _connected = false;
    _pcm.takeBytes();
  }
}

final class SherpaParakeetRealtimeTranscriptionSession
    implements StreamingTranscriptionSession {
  SherpaParakeetRealtimeTranscriptionSession({
    required this.engine,
    this.minDecodeInterval = defaultParakeetDecodeInterval,
    Uuid uuid = const Uuid(),
    DateTime Function()? now,
  }) : _uuid = uuid,
       _now = now ?? DateTime.now;

  final SherpaOfflineRecognizerEngine engine;
  final Duration minDecodeInterval;
  final Uuid _uuid;
  final DateTime Function() _now;
  final StreamController<StreamingTranscriptionCommittedEvent> _committed =
      StreamController.broadcast(sync: true);
  final StreamController<StreamingTranscriptionEvent> _transcripts =
      StreamController.broadcast(sync: true);
  final StreamController<Object?> _errors = StreamController.broadcast(
    sync: true,
  );
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  bool _connected = false;
  String? _currentSegmentId;
  String? _previousSegmentId;
  String _lastPartialText = '';
  DateTime? _lastDecodeAt;
  bool _decoding = false;
  bool _pendingDecode = false;

  @override
  int get requiredSampleRate => engine.sampleRate;

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
    if (_connected) return;
    _currentSegmentId = _uuid.v4();
    _connected = true;
  }

  @override
  void appendPcm16(List<int> pcm16le) {
    if (!_connected || _currentSegmentId == null) {
      _errors.add(StateError('Parakeet realtime session not connected'));
      return;
    }
    try {
      _pcm.add(pcm16le);
      unawaited(_maybeDecode(false));
    } on Object catch (error) {
      _errors.add(_normalizeError(error));
    }
  }

  @override
  void commit() {
    if (!_connected || _currentSegmentId == null) {
      _errors.add(StateError('Parakeet realtime session not connected'));
      return;
    }
    unawaited(_commit());
  }

  Future<void> _commit() async {
    try {
      await _maybeDecode(true);
      final segmentId = _currentSegmentId!;
      _committed.add(
        StreamingTranscriptionCommittedEvent(
          segmentId: segmentId,
          previousSegmentId: _previousSegmentId,
        ),
      );
      _transcripts.add(
        StreamingTranscriptionEvent(
          segmentId: segmentId,
          transcript: _lastPartialText,
          isFinal: true,
        ),
      );
      _previousSegmentId = segmentId;
      _currentSegmentId = _uuid.v4();
      _lastPartialText = '';
      _pcm.takeBytes();
    } on Object catch (error) {
      _errors.add(_normalizeError(error));
    }
  }

  @override
  void clear() {
    if (!_connected) return;
    _pcm.takeBytes();
    _currentSegmentId = _uuid.v4();
    _lastPartialText = '';
  }

  @override
  void close() {
    _connected = false;
    _currentSegmentId = null;
    _pcm.takeBytes();
  }

  Future<void> _maybeDecode(bool force) async {
    if (!_connected || _currentSegmentId == null) return;
    final now = _now();
    final lastDecodeAt = _lastDecodeAt;
    if (!force &&
        lastDecodeAt != null &&
        now.difference(lastDecodeAt) < minDecodeInterval) {
      return;
    }
    if (_decoding) {
      _pendingDecode = true;
      return;
    }
    _decoding = true;
    try {
      final text = await Future<String>.sync(_decodeNow);
      _lastDecodeAt = _now();
      if (text != _lastPartialText) {
        _lastPartialText = text;
        _transcripts.add(
          StreamingTranscriptionEvent(
            segmentId: _currentSegmentId!,
            transcript: text,
            isFinal: false,
          ),
        );
      }
    } finally {
      _decoding = false;
      if (_pendingDecode) {
        _pendingDecode = false;
        await _maybeDecode(true);
      }
    }
  }

  String _decodeNow() {
    final pcm = _pcm.toBytes();
    if (pcm.isEmpty) return '';
    final peakFloat = pcm16lePeakAbs(pcm) / 32768;
    const targetPeak = 0.6;
    const maxGain = 50.0;
    final gain = peakFloat > 0 && peakFloat < targetPeak
        ? (targetPeak / peakFloat).clamp(1, maxGain).toDouble()
        : 1.0;
    return engine.decode(
      pcm16leToFloat32(pcm, gain: gain),
      inputSampleRate: engine.sampleRate,
    );
  }
}

Object _normalizeError(Object error) =>
    error is Error || error is Exception ? error : StateError('$error');
