import '../speech_types.dart';

const defaultOpenAiSpeechBaseUrl = 'https://api.openai.com/v1';
const defaultOpenAiSttModel = 'whisper-1';
const defaultOpenAiTtsModel = 'tts-1';
const defaultOpenAiTtsVoice = 'alloy';
const defaultOpenAiTtsResponseFormat = 'pcm';
const defaultOpenAiSttConfidenceThreshold = -3.0;

const openAiTtsVoices = {'alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer'};
const openAiTtsModels = {'tts-1', 'tts-1-hd'};
const openAiTtsResponseFormats = {'mp3', 'opus', 'aac', 'flac', 'wav', 'pcm'};

final class OpenAiSttConfig {
  const OpenAiSttConfig({
    required this.apiKey,
    this.baseUrl,
    this.model = defaultOpenAiSttModel,
    this.confidenceThreshold = defaultOpenAiSttConfidenceThreshold,
  });

  final String apiKey;
  final String? baseUrl;
  final String model;
  final double confidenceThreshold;
}

final class OpenAiTtsConfig {
  const OpenAiTtsConfig({
    required this.apiKey,
    this.baseUrl,
    this.model = defaultOpenAiTtsModel,
    this.voice = defaultOpenAiTtsVoice,
    this.responseFormat = defaultOpenAiTtsResponseFormat,
  });

  final String apiKey;
  final String? baseUrl;
  final String model;
  final String voice;
  final String responseFormat;
}

final class OpenAiSpeechConfig {
  const OpenAiSpeechConfig({this.stt, this.tts});

  final OpenAiSttConfig? stt;
  final OpenAiTtsConfig? tts;
}

OpenAiSpeechConfig? resolveOpenAiSpeechConfig({
  required Map<String, String> environment,
  required Map<String, Object?> persisted,
  required RequestedSpeechProviders providers,
}) {
  final persistedProviders = _object(persisted['providers'], 'providers');
  final openAi = _object(persistedProviders['openai'], 'providers.openai');
  final stt = _object(openAi['stt'], 'providers.openai.stt');
  final tts = _object(openAi['tts'], 'providers.openai.tts');
  final globalApiKey = _firstString([
    openAi['apiKey'],
    environment['OPENAI_API_KEY'],
  ]);
  final globalBaseUrl = _firstString([
    openAi['baseUrl'],
    environment['OPENAI_BASE_URL'],
  ]);
  final sttApiKey = _firstString([
    stt['apiKey'],
    environment['OPENAI_STT_API_KEY'],
    globalApiKey,
  ]);
  final ttsApiKey = _firstString([
    tts['apiKey'],
    environment['OPENAI_TTS_API_KEY'],
    globalApiKey,
  ]);
  if (sttApiKey == null && ttsApiKey == null) return null;

  return OpenAiSpeechConfig(
    stt: sttApiKey == null
        ? null
        : OpenAiSttConfig(
            apiKey: sttApiKey,
            baseUrl: _firstString([
              stt['baseUrl'],
              environment['OPENAI_STT_BASE_URL'],
              globalBaseUrl,
            ]),
            model:
                _firstString([
                  environment['STT_MODEL'],
                  _ifActive(
                    providers.voiceStt,
                    _nested(persisted, const [
                      'features',
                      'voiceMode',
                      'stt',
                      'model',
                    ]),
                  ),
                  _ifActive(
                    providers.dictationStt,
                    _nested(persisted, const [
                      'features',
                      'dictation',
                      'stt',
                      'model',
                    ]),
                  ),
                ]) ??
                defaultOpenAiSttModel,
            confidenceThreshold: _finiteNumber(
              _first([
                environment['STT_CONFIDENCE_THRESHOLD'],
                _nested(persisted, const [
                  'features',
                  'dictation',
                  'stt',
                  'confidenceThreshold',
                ]),
              ]),
              'STT_CONFIDENCE_THRESHOLD',
            ),
          ),
    tts: ttsApiKey == null
        ? null
        : OpenAiTtsConfig(
            apiKey: ttsApiKey,
            baseUrl: _firstString([
              tts['baseUrl'],
              environment['OPENAI_TTS_BASE_URL'],
              globalBaseUrl,
            ]),
            voice: _enumValue(
              _firstString([
                    environment['TTS_VOICE'],
                    _ifActive(
                      providers.voiceTts,
                      _nested(persisted, const [
                        'features',
                        'voiceMode',
                        'tts',
                        'voice',
                      ]),
                    ),
                  ]) ??
                  defaultOpenAiTtsVoice,
              openAiTtsVoices,
              'TTS_VOICE',
            ),
            model: _enumValue(
              _firstString([
                    environment['TTS_MODEL'],
                    _ifActive(
                      providers.voiceTts,
                      _nested(persisted, const [
                        'features',
                        'voiceMode',
                        'tts',
                        'model',
                      ]),
                    ),
                  ]) ??
                  defaultOpenAiTtsModel,
              openAiTtsModels,
              'TTS_MODEL',
            ),
          ),
  );
}

Object? _ifActive(RequestedSpeechProvider provider, Object? value) =>
    provider.enabled != false && provider.provider == SpeechProviderId.openai
    ? value
    : null;

Object? _nested(Map<String, Object?> root, List<String> path) {
  Object? value = root;
  for (final part in path) {
    if (value is! Map<String, Object?>) return null;
    value = value[part];
  }
  return value;
}

Object? _first(List<Object?> values) {
  for (final value in values) {
    if (value == null) continue;
    if (value is String && value.trim().isEmpty) continue;
    return value;
  }
  return null;
}

String? _firstString(List<Object?> values) {
  final value = _first(values);
  return value is String ? value.trim() : null;
}

double _finiteNumber(Object? value, String name) {
  if (value == null) return defaultOpenAiSttConfidenceThreshold;
  final parsed = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  if (parsed == null || !parsed.isFinite) {
    throw FormatException('$name must be a finite number');
  }
  return parsed;
}

String _enumValue(String value, Set<String> allowed, String name) {
  final normalized = value.trim().toLowerCase();
  if (!allowed.contains(normalized)) {
    throw FormatException('$name must be one of ${allowed.join(', ')}');
  }
  return normalized;
}

Map<String, Object?> _object(Object? value, String path) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  throw FormatException('$path must be an object');
}
