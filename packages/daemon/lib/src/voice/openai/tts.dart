import 'dart:convert';

import 'package:http/http.dart' as http;

import '../speech_provider.dart';
import 'config.dart';

final class OpenAiTextToSpeechProvider implements TextToSpeechProvider {
  OpenAiTextToSpeechProvider(
    OpenAiTtsConfig config, {
    http.Client? client,
    SpeechLogger logger = const NullSpeechLogger(),
  }) : config = config,
       _client = client ?? http.Client(),
       _logger = logger.child({
         'module': 'agent',
         'provider': 'openai',
         'component': 'tts',
       });

  final OpenAiTtsConfig config;
  final http.Client _client;
  final SpeechLogger _logger;

  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async {
    if (text.trim().isEmpty) {
      throw StateError('Cannot synthesize empty text');
    }
    final stopwatch = Stopwatch()..start();
    try {
      final request =
          http.Request('POST', _endpoint(config.baseUrl, 'audio/speech'))
            ..headers['authorization'] = 'Bearer ${config.apiKey}'
            ..headers['content-type'] = 'application/json'
            ..body = jsonEncode({
              'model': config.model,
              'voice': config.voice,
              'input': text,
              'response_format': config.responseFormat,
            });
      final response = await _client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw StateError(
          'OpenAI returned HTTP ${response.statusCode}: ${_apiError(body)}',
        );
      }
      _logger.debug(
        'Speech synthesis stream ready',
        fields: {'duration': stopwatch.elapsedMilliseconds},
      );
      return SpeechStreamResult(
        stream: response.stream,
        format: config.responseFormat,
      );
    } on Object catch (error) {
      _logger.error('Speech synthesis error', fields: {'error': error});
      throw StateError('TTS synthesis failed: ${_errorMessage(error)}');
    }
  }
}

Uri _endpoint(String? baseUrl, String path) {
  final base = (baseUrl ?? defaultOpenAiSpeechBaseUrl).trim();
  return Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}/$path');
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
