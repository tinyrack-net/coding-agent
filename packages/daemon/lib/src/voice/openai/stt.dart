import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:uuid/uuid.dart';

import '../audio.dart';
import '../speech_provider.dart';
import 'config.dart';

final class OpenAiSpeechToTextProvider implements SpeechToTextProvider {
  OpenAiSpeechToTextProvider(
    this.config, {
    http.Client? client,
    SpeechLogger logger = const NullSpeechLogger(),
    Uuid uuid = const Uuid(),
  }) : _client = client ?? http.Client(),
       _logger = logger.child({
         'module': 'agent',
         'provider': 'openai',
         'component': 'stt',
       }),
       _uuid = uuid;

  final OpenAiSttConfig config;
  final http.Client _client;
  final SpeechLogger _logger;
  final Uuid _uuid;

  @override
  String get id => 'openai';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => _OpenAiStreamingTranscriptionSession(
    provider: this,
    parameters: parameters,
    uuid: _uuid,
  );

  Future<TranscriptionResult> transcribe({
    required Uint8List wav,
    required String language,
    String? prompt,
    SpeechLogger? logger,
  }) async {
    final sessionLogger = logger ?? _logger;
    final stopwatch = Stopwatch()..start();
    try {
      final request =
          http.MultipartRequest(
              'POST',
              _endpoint(config.baseUrl, 'audio/transcriptions'),
            )
            ..headers['authorization'] = 'Bearer ${config.apiKey}'
            ..fields['model'] = config.model
            ..fields['language'] = language
            ..fields['response_format'] = 'json'
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                wav,
                filename: 'audio.wav',
                contentType: MediaType('audio', 'wav'),
              ),
            );
      if (prompt != null && prompt.isNotEmpty) {
        request.fields['prompt'] = prompt;
      }
      if (_supportsLogprobs(config.model)) {
        request.fields['include[]'] = 'logprobs';
      }
      final response = await _client.send(request);
      final body = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'OpenAI returned HTTP ${response.statusCode}: ${_apiError(body)}',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?> || decoded['text'] is! String) {
        throw const FormatException('OpenAI transcription response is invalid');
      }
      final logprobs = _supportsLogprobs(config.model)
          ? _parseLogprobs(decoded['logprobs'])
          : null;
      final avgLogprob = logprobs == null || logprobs.isEmpty
          ? null
          : logprobs.fold<double>(0, (sum, token) => sum + token.logprob) /
                logprobs.length;
      final result = TranscriptionResult(
        text: decoded['text']! as String,
        language: decoded['language'] is String
            ? decoded['language']! as String
            : null,
        duration: stopwatch.elapsedMilliseconds.toDouble(),
        logprobs: logprobs,
        avgLogprob: avgLogprob,
        isLowConfidence:
            avgLogprob != null && avgLogprob < config.confidenceThreshold,
      );
      sessionLogger.debug(
        'Transcription complete',
        fields: {
          'duration': result.duration,
          'text': result.text,
          'avgLogprob': result.avgLogprob,
        },
      );
      return result;
    } on Object catch (error) {
      sessionLogger.error('Transcription error', fields: {'error': error});
      throw StateError('STT transcription failed: ${_errorMessage(error)}');
    }
  }
}

final class _OpenAiStreamingTranscriptionSession
    implements StreamingTranscriptionSession {
  _OpenAiStreamingTranscriptionSession({
    required this.provider,
    required this.parameters,
    required Uuid uuid,
  }) : _uuid = uuid,
       _segmentId = uuid.v4(),
       _logger = parameters.logger.child({
         'provider': 'openai',
         'component': 'stt-session',
       });

  final OpenAiSpeechToTextProvider provider;
  final SpeechSessionParameters parameters;
  final Uuid _uuid;
  final SpeechLogger _logger;
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
  int get requiredSampleRate => 24000;

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
    _connected = true;
  }

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
    _committed.add(
      StreamingTranscriptionCommittedEvent(
        segmentId: committedId,
        previousSegmentId: previousId,
      ),
    );
    unawaited(_transcribeCommit(committedId, pcm));
  }

  Future<void> _transcribeCommit(String committedId, Uint8List pcm) async {
    try {
      if (pcm.isEmpty) {
        _transcripts.add(
          StreamingTranscriptionEvent(
            segmentId: committedId,
            transcript: '',
            isFinal: true,
            language: parameters.language,
            isLowConfidence: true,
          ),
        );
        return;
      }
      final result = await provider.transcribe(
        wav: pcm16MonoToWav(pcm, requiredSampleRate),
        language: parameters.language ?? 'en',
        prompt: parameters.prompt,
        logger: _logger,
      );
      _transcripts.add(
        StreamingTranscriptionEvent(
          segmentId: committedId,
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
      _previousSegmentId = committedId;
      _segmentId = _uuid.v4();
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

Uri _endpoint(String? baseUrl, String path) {
  final base = (baseUrl ?? defaultOpenAiSpeechBaseUrl).trim();
  return Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}/$path');
}

bool _supportsLogprobs(String model) =>
    model == 'gpt-4o-transcribe' || model == 'gpt-4o-mini-transcribe';

List<LogprobToken>? _parseLogprobs(Object? value) {
  if (value is! List) return null;
  final parsed = <LogprobToken>[];
  for (final entry in value) {
    if (entry is! Map) return null;
    try {
      parsed.add(LogprobToken.fromJson(Map<String, Object?>.from(entry)));
    } on FormatException {
      return null;
    }
  }
  return parsed;
}

String _apiError(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map &&
        decoded['error'] is Map &&
        (decoded['error'] as Map)['message'] is String) {
      return (decoded['error'] as Map)['message']! as String;
    }
  } on FormatException {
    // Fall back to the response body.
  }
  return body.trim().isEmpty ? 'empty response' : body.trim();
}

String _errorMessage(Object error) => switch (error) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  _ => error.toString(),
};
