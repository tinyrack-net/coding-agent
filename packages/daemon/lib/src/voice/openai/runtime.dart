import 'package:http/http.dart' as http;

import '../speech_provider.dart';
import '../speech_runtime.dart';
import '../speech_types.dart';
import '../turn_detection_provider.dart';
import 'config.dart';
import 'stt.dart';
import 'tts.dart';

final class OpenAiSpeechAvailability {
  const OpenAiSpeechAvailability({
    required this.stt,
    required this.tts,
    required this.dictationStt,
  });

  final bool stt;
  final bool tts;
  final bool dictationStt;
}

OpenAiSpeechAvailability getOpenAiSpeechAvailability(
  OpenAiSpeechConfig? config,
) => OpenAiSpeechAvailability(
  stt: config?.stt?.apiKey.isNotEmpty == true,
  tts: config?.tts?.apiKey.isNotEmpty == true,
  dictationStt: config?.stt?.apiKey.isNotEmpty == true,
);

void validateOpenAiCredentialRequirements({
  required RequestedSpeechProviders providers,
  required OpenAiSpeechConfig? config,
  required SpeechLogger logger,
}) {
  final availability = getOpenAiSpeechAvailability(config);
  final missing = <String>[
    if (_activeOpenAi(providers.voiceStt) && !availability.stt) 'voice.stt',
    if (_activeOpenAi(providers.voiceTts) && !availability.tts) 'voice.tts',
    if (_activeOpenAi(providers.dictationStt) && !availability.dictationStt)
      'dictation.stt',
  ];
  if (missing.isNotEmpty) {
    logger.warning(
      'Invalid speech configuration: OpenAI provider selected but '
      'credentials are missing — speech features will be unavailable',
      fields: {
        'requestedProviders': {
          'dictationStt': providers.dictationStt.provider.wireName,
          'voiceStt': providers.voiceStt.provider.wireName,
          'voiceTts': providers.voiceTts.provider.wireName,
        },
        'missingOpenAiCredentialsFor': missing,
      },
    );
  }
}

SpeechRuntimeReconciliation initializeOpenAiSpeechServices({
  required RequestedSpeechProviders providers,
  required OpenAiSpeechConfig? config,
  TurnDetectionProvider? existingTurnDetection,
  SpeechToTextProvider? existingVoiceStt,
  TextToSpeechProvider? existingVoiceTts,
  SpeechToTextProvider? existingDictationStt,
  SpeechLogger logger = const NullSpeechLogger(),
  http.Client? client,
}) {
  validateOpenAiCredentialRequirements(
    providers: providers,
    config: config,
    logger: logger,
  );
  var voiceStt = existingVoiceStt;
  var voiceTts = existingVoiceTts;
  var dictationStt = existingDictationStt;
  final needsVoiceStt = voiceStt == null && _activeOpenAi(providers.voiceStt);
  final needsVoiceTts = voiceTts == null && _activeOpenAi(providers.voiceTts);
  final needsDictation =
      dictationStt == null && _activeOpenAi(providers.dictationStt);
  final willInitialize =
      ((needsVoiceStt || needsDictation) && config?.stt != null) ||
      (needsVoiceTts && config?.tts != null);
  if (willInitialize) {
    logger.info('OpenAI speech provider initialized');
  }
  if ((needsVoiceStt || needsDictation) && config?.stt != null) {
    if (needsVoiceStt) {
      voiceStt = OpenAiSpeechToTextProvider(
        config!.stt!,
        client: client,
        logger: logger,
      );
    }
    if (needsDictation) {
      dictationStt = OpenAiSpeechToTextProvider(
        config!.stt!,
        client: client,
        logger: logger,
      );
    }
  }
  if (needsVoiceTts && config?.tts != null) {
    voiceTts = OpenAiTextToSpeechProvider(
      config!.tts!,
      client: client,
      logger: logger,
    );
  }
  return SpeechRuntimeReconciliation(
    turnDetection: existingTurnDetection,
    voiceStt: voiceStt,
    voiceTts: voiceTts,
    dictationStt: dictationStt,
  );
}

SpeechRuntime createOpenAiSpeechRuntime({
  required SpeechRuntimeConfig runtimeConfig,
  required OpenAiSpeechConfig? openAiConfig,
  SpeechLogger logger = const NullSpeechLogger(),
  http.Client? client,
}) {
  final sharedClient = client ?? http.Client();
  SpeechRuntimeReconciliation? services;
  return SpeechRuntime(
    config: runtimeConfig,
    logger: logger,
    reconcile: () async => services ??= initializeOpenAiSpeechServices(
      providers: runtimeConfig.providers,
      config: openAiConfig,
      logger: logger,
      client: sharedClient,
    ),
  );
}

bool _activeOpenAi(RequestedSpeechProvider provider) =>
    provider.enabled != false && provider.provider == SpeechProviderId.openai;
