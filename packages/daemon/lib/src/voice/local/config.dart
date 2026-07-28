import 'package:path/path.dart' as p;

import '../speech_types.dart';
import 'model_catalog.dart';

const defaultLocalModelsSubdirectory = 'models/local-speech';
const defaultLocalSttLanguage = 'en';

final class LocalSpeechModelConfig {
  const LocalSpeechModelConfig({
    required this.dictationStt,
    required this.voiceStt,
    required this.voiceTts,
    this.voiceTtsSpeakerId,
    this.voiceTtsSpeed,
  });

  final String dictationStt;
  final String voiceStt;
  final String voiceTts;
  final int? voiceTtsSpeakerId;
  final double? voiceTtsSpeed;
}

final class LocalSpeechProviderConfig {
  const LocalSpeechProviderConfig({
    required this.modelsDirectory,
    required this.models,
  });

  final String modelsDirectory;
  final LocalSpeechModelConfig models;
}

final class LocalSpeechLanguageConfig {
  const LocalSpeechLanguageConfig({
    required this.dictation,
    required this.voice,
  });

  final String dictation;
  final String voice;
}

final class ResolvedLocalSpeechConfig {
  const ResolvedLocalSpeechConfig({
    required this.local,
    required this.languages,
  });

  final LocalSpeechProviderConfig? local;
  final LocalSpeechLanguageConfig languages;
}

ResolvedLocalSpeechConfig resolveLocalSpeechConfig({
  required String tinyrackHome,
  required Map<String, String> environment,
  required Map<String, Object?> persisted,
  required RequestedSpeechProviders providers,
}) {
  final persistedProviders = _object(persisted['providers'], 'providers');
  final persistedLocal = _object(
    persistedProviders['local'],
    'providers.local',
  );
  final includeProviderConfig =
      _activeLocal(providers.dictationStt) ||
      _activeLocal(providers.voiceStt) ||
      _activeLocal(providers.voiceTts) ||
      environment.containsKey('TINYRACK_LOCAL_MODELS_DIR') ||
      persistedLocal.containsKey('modelsDir');
  final dictationLanguage = _firstNonEmptyString([
    environment['TINYRACK_DICTATION_LANGUAGE'],
    _nested(persisted, const ['features', 'dictation', 'stt', 'language']),
    defaultLocalSttLanguage,
  ])!;
  final voiceLanguage = _firstNonEmptyString([
    environment['TINYRACK_VOICE_LANGUAGE'],
    environment['TINYRACK_DICTATION_LANGUAGE'],
    _nested(persisted, const ['features', 'voiceMode', 'stt', 'language']),
    _nested(persisted, const ['features', 'dictation', 'stt', 'language']),
    defaultLocalSttLanguage,
  ])!;
  if (!includeProviderConfig) {
    return ResolvedLocalSpeechConfig(
      local: null,
      languages: LocalSpeechLanguageConfig(
        dictation: dictationLanguage,
        voice: voiceLanguage,
      ),
    );
  }

  final modelsDirectory = _requiredString(
    _firstDefined([
      environment['TINYRACK_LOCAL_MODELS_DIR'],
      persistedLocal['modelsDir'],
      p.join(tinyrackHome, 'models', 'local-speech'),
    ]),
    'TINYRACK_LOCAL_MODELS_DIR',
  );
  final dictationModel = parseLocalSttModelId(
    _firstDefined([
      environment['TINYRACK_DICTATION_LOCAL_STT_MODEL'],
      _activeLocal(providers.dictationStt)
          ? _nested(persisted, const ['features', 'dictation', 'stt', 'model'])
          : null,
      defaultLocalSttModel,
    ]),
  );
  final voiceSttModel = parseLocalSttModelId(
    _firstDefined([
      environment['TINYRACK_VOICE_LOCAL_STT_MODEL'],
      _activeLocal(providers.voiceStt)
          ? _nested(persisted, const ['features', 'voiceMode', 'stt', 'model'])
          : null,
      defaultLocalSttModel,
    ]),
  );
  final voiceTtsModel = parseLocalTtsModelId(
    _firstDefined([
      environment['TINYRACK_VOICE_LOCAL_TTS_MODEL'],
      _activeLocal(providers.voiceTts)
          ? _nested(persisted, const ['features', 'voiceMode', 'tts', 'model'])
          : null,
      defaultLocalTtsModel,
    ]),
  );
  final configuredSpeaker = _optionalInteger(
    _firstDefined([
      environment['TINYRACK_VOICE_LOCAL_TTS_SPEAKER_ID'],
      _nested(persisted, const ['features', 'voiceMode', 'tts', 'speakerId']),
    ]),
    'TINYRACK_VOICE_LOCAL_TTS_SPEAKER_ID',
  );
  final speed = _optionalFiniteNumber(
    _firstDefined([
      environment['TINYRACK_VOICE_LOCAL_TTS_SPEED'],
      _nested(persisted, const ['features', 'voiceMode', 'tts', 'speed']),
    ]),
    'TINYRACK_VOICE_LOCAL_TTS_SPEED',
  );

  return ResolvedLocalSpeechConfig(
    local: LocalSpeechProviderConfig(
      modelsDirectory: modelsDirectory,
      models: LocalSpeechModelConfig(
        dictationStt: dictationModel,
        voiceStt: voiceSttModel,
        voiceTts: voiceTtsModel,
        voiceTtsSpeakerId:
            configuredSpeaker ??
            (voiceTtsModel == 'kokoro-en-v0_19' ? 0 : null),
        voiceTtsSpeed: speed,
      ),
    ),
    languages: LocalSpeechLanguageConfig(
      dictation: dictationLanguage,
      voice: voiceLanguage,
    ),
  );
}

bool _activeLocal(RequestedSpeechProvider provider) =>
    provider.enabled != false && provider.provider == SpeechProviderId.local;

Object? _nested(Map<String, Object?> root, List<String> path) {
  Object? value = root;
  for (final part in path) {
    if (value is! Map<String, Object?>) return null;
    value = value[part];
  }
  return value;
}

Object? _firstDefined(List<Object?> values) {
  for (final value in values) {
    if (value != null) return value;
  }
  return null;
}

String? _firstNonEmptyString(List<Object?> values) {
  for (final value in values) {
    if (value is! String) continue;
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _requiredString(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string');
  }
  return value.trim();
}

int? _optionalInteger(Object? value, String name) {
  if (value == null) return null;
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  if (number == null || !number.isFinite || number != number.roundToDouble()) {
    throw FormatException('$name must be an integer');
  }
  return number.toInt();
}

double? _optionalFiniteNumber(Object? value, String name) {
  if (value == null) return null;
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  if (number == null || !number.isFinite) {
    throw FormatException('$name must be a finite number');
  }
  return number;
}

Map<String, Object?> _object(Object? value, String path) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  throw FormatException('$path must be an object');
}
