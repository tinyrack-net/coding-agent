import 'package:http/http.dart' as http;

import 'local/config.dart';
import 'local/runtime.dart';
import 'openai/config.dart';
import 'openai/runtime.dart';
import 'speech_provider.dart';
import 'speech_runtime.dart';

SpeechRuntime createConfiguredSpeechRuntime({
  required SpeechRuntimeConfig runtimeConfig,
  required OpenAiSpeechConfig? openAiConfig,
  required LocalSpeechProviderConfig? localConfig,
  SpeechLogger logger = const NullSpeechLogger(),
  http.Client? openAiClient,
}) {
  final sharedOpenAiClient = openAiConfig == null
      ? openAiClient
      : (openAiClient ?? http.Client());
  SpeechRuntimeReconciliation? services;
  return SpeechRuntime(
    config: runtimeConfig,
    logger: logger,
    reconcile: () async => services ??= attachLocalModelManagement(
      services: initializeLocalSpeechServices(
        services: initializeOpenAiSpeechServices(
          providers: runtimeConfig.providers,
          config: openAiConfig,
          logger: logger,
          client: sharedOpenAiClient,
        ),
        providers: runtimeConfig.providers,
        config: localConfig,
        logger: logger,
      ),
      providers: runtimeConfig.providers,
      config: localConfig,
      logger: logger,
    ),
  );
}
