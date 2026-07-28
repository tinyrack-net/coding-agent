import 'local/config.dart';
import 'openai/config.dart';
import 'speech_runtime.dart';
import 'speech_types.dart';

final class ResolvedSpeechConfiguration {
  const ResolvedSpeechConfiguration({
    required this.runtime,
    required this.local,
    required this.openAi,
  });

  final SpeechRuntimeConfig runtime;
  final LocalSpeechProviderConfig? local;
  final OpenAiSpeechConfig? openAi;
}

ResolvedSpeechConfiguration resolveSpeechConfiguration({
  required String tinyrackHome,
  required Map<String, String> environment,
  required Map<String, Object?> persisted,
}) {
  final providers = resolveRequestedSpeechProviders(
    environment: environment,
    persisted: persisted,
  );
  final local = resolveLocalSpeechConfig(
    tinyrackHome: tinyrackHome,
    environment: environment,
    persisted: persisted,
    providers: providers,
  );
  final openAi = resolveOpenAiSpeechConfig(
    environment: environment,
    persisted: persisted,
    providers: providers,
  );
  return ResolvedSpeechConfiguration(
    runtime: SpeechRuntimeConfig(
      providers: providers,
      voiceSttLanguage: local.languages.voice,
      dictationSttLanguage: local.languages.dictation,
    ),
    local: local.local,
    openAi: openAi,
  );
}

RequestedSpeechProviders resolveRequestedSpeechProviders({
  required Map<String, String> environment,
  required Map<String, Object?> persisted,
}) {
  final features = _object(persisted['features'], 'features');
  final dictation = _object(features['dictation'], 'features.dictation');
  final dictationStt = _object(dictation['stt'], 'features.dictation.stt');
  final voiceMode = _object(features['voiceMode'], 'features.voiceMode');
  final turnDetection = _object(
    voiceMode['turnDetection'],
    'features.voiceMode.turnDetection',
  );
  final voiceStt = _object(voiceMode['stt'], 'features.voiceMode.stt');
  final voiceTts = _object(voiceMode['tts'], 'features.voiceMode.tts');
  final voiceEnabled = _resolveOptionalBoolean(
    _firstDefined([
      environment['TINYRACK_VOICE_MODE_ENABLED'],
      voiceMode['enabled'],
    ]),
    'TINYRACK_VOICE_MODE_ENABLED',
  );

  RequestedSpeechProvider provider({
    required String envName,
    required Object? persistedProvider,
    required bool enabled,
  }) {
    final configured = _firstDefined([environment[envName], persistedProvider]);
    return RequestedSpeechProvider(
      provider: configured == null
          ? SpeechProviderId.local
          : _parseProvider(configured, envName),
      explicit: configured != null,
      enabled: enabled,
    );
  }

  return RequestedSpeechProviders(
    dictationStt: provider(
      envName: 'TINYRACK_DICTATION_STT_PROVIDER',
      persistedProvider: dictationStt['provider'],
      enabled: _resolveOptionalBoolean(
        _firstDefined([
          environment['TINYRACK_DICTATION_ENABLED'],
          dictation['enabled'],
        ]),
        'TINYRACK_DICTATION_ENABLED',
      ),
    ),
    voiceTurnDetection: provider(
      envName: 'TINYRACK_VOICE_TURN_DETECTION_PROVIDER',
      persistedProvider: turnDetection['provider'],
      enabled: voiceEnabled,
    ),
    voiceStt: provider(
      envName: 'TINYRACK_VOICE_STT_PROVIDER',
      persistedProvider: voiceStt['provider'],
      enabled: voiceEnabled,
    ),
    voiceTts: provider(
      envName: 'TINYRACK_VOICE_TTS_PROVIDER',
      persistedProvider: voiceTts['provider'],
      enabled: voiceEnabled,
    ),
  );
}

SpeechProviderId _parseProvider(Object value, String name) {
  if (value is! String) {
    throw FormatException('$name must be local or openai');
  }
  return SpeechProviderId.fromJson(value.trim().toLowerCase());
}

bool _resolveOptionalBoolean(Object? value, String name) {
  if (value == null) return true;
  if (value is bool) return value;
  if (value is! String) {
    throw FormatException('$name must be a boolean flag');
  }
  switch (value.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'y':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'n':
    case 'off':
      return false;
    default:
      return true;
  }
}

Object? _firstDefined(List<Object?> values) {
  for (final value in values) {
    if (value != null) return value;
  }
  return null;
}

Map<String, Object?> _object(Object? value, String path) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  throw FormatException('$path must be an object');
}
