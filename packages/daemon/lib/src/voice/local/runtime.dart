import '../speech_provider.dart';
import '../speech_runtime.dart';
import '../speech_types.dart';
import 'config.dart';
import 'model_downloader.dart';

final class LocalSpeechAvailability {
  const LocalSpeechAvailability({
    required this.configured,
    required this.modelsDirectory,
  });

  final bool configured;
  final String? modelsDirectory;
}

LocalSpeechAvailability getLocalSpeechAvailability(
  LocalSpeechProviderConfig? config,
) => LocalSpeechAvailability(
  configured: config != null,
  modelsDirectory: config?.modelsDirectory,
);

List<String> computeRequiredLocalModelIds({
  required RequestedSpeechProviders providers,
  required LocalSpeechModelConfig models,
}) {
  final ids = <String>{};
  if (_activeLocal(providers.dictationStt)) ids.add(models.dictationStt);
  if (_activeLocal(providers.voiceStt)) ids.add(models.voiceStt);
  if (_activeLocal(providers.voiceTts)) ids.add(models.voiceTts);
  return List.unmodifiable(ids);
}

SpeechRuntimeReconciliation attachLocalModelManagement({
  required SpeechRuntimeReconciliation services,
  required RequestedSpeechProviders providers,
  required LocalSpeechProviderConfig? config,
  SpeechLogger logger = const NullSpeechLogger(),
}) {
  if (config == null) return services;
  final requiredModelIds = computeRequiredLocalModelIds(
    providers: providers,
    models: config.models,
  );
  return SpeechRuntimeReconciliation(
    turnDetection: services.turnDetection,
    voiceStt: services.voiceStt,
    voiceTts: services.voiceTts,
    dictationStt: services.dictationStt,
    modelsDirectory: config.modelsDirectory,
    requiredLocalModelIds: requiredModelIds,
    resolveMissingModels: findMissingLocalSpeechModels,
    downloadModels: (modelsDirectory, modelIds) async {
      await ensureLocalSpeechModels(
        modelsDirectory: modelsDirectory,
        modelIds: modelIds,
        logger: logger,
      );
    },
    cleanup: services.cleanup,
  );
}

bool _activeLocal(RequestedSpeechProvider provider) =>
    provider.enabled != false && provider.provider == SpeechProviderId.local;
