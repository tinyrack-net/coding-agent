import 'dart:async';

abstract interface class SpeechLogger {
  SpeechLogger child(Map<String, Object?> context);

  void debug(String message, {Map<String, Object?> fields = const {}});
  void info(String message, {Map<String, Object?> fields = const {}});
  void warning(String message, {Map<String, Object?> fields = const {}});
  void error(String message, {Map<String, Object?> fields = const {}});
}

final class NullSpeechLogger implements SpeechLogger {
  const NullSpeechLogger();

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}

final class LogprobToken {
  const LogprobToken({required this.token, required this.logprob, this.bytes});

  final String token;
  final double logprob;
  final List<num>? bytes;

  factory LogprobToken.fromJson(Map<String, Object?> json) {
    final token = json['token'];
    final logprob = json['logprob'];
    final bytes = json['bytes'];
    if (token is! String ||
        logprob is! num ||
        (bytes != null &&
            (bytes is! List || bytes.any((value) => value is! num)))) {
      throw const FormatException('Invalid logprob token');
    }
    return LogprobToken(
      token: token,
      logprob: logprob.toDouble(),
      bytes: bytes == null ? null : List<num>.from(bytes as List),
    );
  }

  Map<String, Object?> toJson() => {
    'token': token,
    'logprob': logprob,
    if (bytes != null) 'bytes': List<num>.from(bytes!),
  };
}

final class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    this.language,
    this.duration,
    this.logprobs,
    this.avgLogprob,
    this.isLowConfidence,
  });

  final String text;
  final String? language;
  final double? duration;
  final List<LogprobToken>? logprobs;
  final double? avgLogprob;
  final bool? isLowConfidence;

  factory TranscriptionResult.fromJson(Map<String, Object?> json) {
    final text = json['text'];
    final language = json['language'];
    final duration = json['duration'];
    final rawLogprobs = json['logprobs'];
    final avgLogprob = json['avgLogprob'];
    final isLowConfidence = json['isLowConfidence'];
    if (text is! String ||
        (language != null && language is! String) ||
        (duration != null && duration is! num) ||
        (avgLogprob != null && avgLogprob is! num) ||
        (isLowConfidence != null && isLowConfidence is! bool)) {
      throw const FormatException('Invalid transcription result');
    }
    return TranscriptionResult(
      text: text,
      language: language as String?,
      duration: (duration as num?)?.toDouble(),
      logprobs: _parseLogprobs(rawLogprobs, 'Invalid transcription logprob'),
      avgLogprob: (avgLogprob as num?)?.toDouble(),
      isLowConfidence: isLowConfidence as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    'text': text,
    if (language != null) 'language': language,
    if (duration != null) 'duration': duration,
    if (logprobs != null)
      'logprobs': [for (final token in logprobs!) token.toJson()],
    if (avgLogprob != null) 'avgLogprob': avgLogprob,
    if (isLowConfidence != null) 'isLowConfidence': isLowConfidence,
  };
}

final class StreamingTranscriptionCommittedEvent {
  const StreamingTranscriptionCommittedEvent({
    required this.segmentId,
    required this.previousSegmentId,
  });

  final String segmentId;
  final String? previousSegmentId;

  factory StreamingTranscriptionCommittedEvent.fromJson(
    Map<String, Object?> json,
  ) {
    final segmentId = json['segmentId'];
    final previousSegmentId = json['previousSegmentId'];
    if (segmentId is! String ||
        (previousSegmentId != null && previousSegmentId is! String)) {
      throw const FormatException('Invalid transcription committed event');
    }
    return StreamingTranscriptionCommittedEvent(
      segmentId: segmentId,
      previousSegmentId: previousSegmentId as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'segmentId': segmentId,
    'previousSegmentId': previousSegmentId,
  };
}

final class StreamingTranscriptionEvent {
  const StreamingTranscriptionEvent({
    required this.segmentId,
    required this.transcript,
    required this.isFinal,
    this.language,
    this.logprobs,
    this.avgLogprob,
    this.isLowConfidence,
  });

  final String segmentId;
  final String transcript;
  final bool isFinal;
  final String? language;
  final List<LogprobToken>? logprobs;
  final double? avgLogprob;
  final bool? isLowConfidence;

  factory StreamingTranscriptionEvent.fromJson(Map<String, Object?> json) {
    final segmentId = json['segmentId'];
    final transcript = json['transcript'];
    final isFinal = json['isFinal'];
    final language = json['language'];
    final rawLogprobs = json['logprobs'];
    final avgLogprob = json['avgLogprob'];
    final isLowConfidence = json['isLowConfidence'];
    if (segmentId is! String ||
        transcript is! String ||
        isFinal is! bool ||
        (language != null && language is! String) ||
        (avgLogprob != null && avgLogprob is! num) ||
        (isLowConfidence != null && isLowConfidence is! bool)) {
      throw const FormatException('Invalid streaming transcription event');
    }
    return StreamingTranscriptionEvent(
      segmentId: segmentId,
      transcript: transcript,
      isFinal: isFinal,
      language: language as String?,
      logprobs: _parseLogprobs(
        rawLogprobs,
        'Invalid streaming transcription logprob',
      ),
      avgLogprob: (avgLogprob as num?)?.toDouble(),
      isLowConfidence: isLowConfidence as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    'segmentId': segmentId,
    'transcript': transcript,
    'isFinal': isFinal,
    if (language != null) 'language': language,
    if (logprobs != null)
      'logprobs': [for (final token in logprobs!) token.toJson()],
    if (avgLogprob != null) 'avgLogprob': avgLogprob,
    if (isLowConfidence != null) 'isLowConfidence': isLowConfidence,
  };
}

final class SpeechSessionParameters {
  const SpeechSessionParameters({
    required this.logger,
    this.language,
    this.prompt,
  });

  final SpeechLogger logger;
  final String? language;
  final String? prompt;
}

abstract interface class StreamingTranscriptionSession {
  int get requiredSampleRate;

  Stream<StreamingTranscriptionCommittedEvent> get committedEvents;
  Stream<StreamingTranscriptionEvent> get transcriptEvents;
  Stream<Object?> get errors;

  Future<void> connect();
  void appendPcm16(List<int> pcm16le);
  void commit();
  void clear();
  void close();
}

abstract interface class SpeechToTextProvider {
  String get id;

  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  );
}

typedef SpeechToTextResolver = SpeechToTextProvider? Function();

final class SpeechStreamResult {
  SpeechStreamResult({
    required this.stream,
    required this.format,
    FutureOr<void> Function()? onDestroy,
  }) : _onDestroy = onDestroy;

  final Stream<List<int>> stream;
  final String format;
  final FutureOr<void> Function()? _onDestroy;
  bool _destroyed = false;

  bool get destroyed => _destroyed;

  Future<void> destroy() async {
    if (_destroyed) return;
    _destroyed = true;
    await _onDestroy?.call();
  }
}

abstract interface class TextToSpeechProvider {
  Future<SpeechStreamResult> synthesizeSpeech(String text);
}

typedef TextToSpeechResolver = TextToSpeechProvider? Function();

List<LogprobToken>? _parseLogprobs(Object? value, String errorMessage) {
  if (value == null) return null;
  if (value is! List) throw FormatException(errorMessage);
  return [
    for (final entry in value)
      if (entry is Map<String, Object?>)
        LogprobToken.fromJson(entry)
      else
        throw FormatException(errorMessage),
  ];
}
