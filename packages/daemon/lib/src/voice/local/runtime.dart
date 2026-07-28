import 'dart:async';

import '../speech_provider.dart';
import '../speech_runtime.dart';
import '../speech_types.dart';
import 'config.dart';
import 'model_downloader.dart';
import 'worker_client.dart';
import 'worker_process_transport.dart';
import 'worker_protocol.dart';
import 'worker_transport.dart';

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

SpeechRuntimeReconciliation initializeLocalSpeechServices({
  required SpeechRuntimeReconciliation services,
  required RequestedSpeechProviders providers,
  required LocalSpeechProviderConfig? config,
  SpeechLogger logger = const NullSpeechLogger(),
  LocalSpeechWorkerStarter? startWorker,
}) {
  if (config == null) return services;
  final needsTurnDetection =
      services.turnDetection == null &&
      _activeLocal(providers.voiceTurnDetection);
  final needsVoiceStt =
      services.voiceStt == null && _activeLocal(providers.voiceStt);
  final needsVoiceTts =
      services.voiceTts == null && _activeLocal(providers.voiceTts);
  final needsDictation =
      services.dictationStt == null && _activeLocal(providers.dictationStt);
  if (!needsTurnDetection &&
      !needsVoiceStt &&
      !needsVoiceTts &&
      !needsDictation) {
    return services;
  }

  final client = LocalSpeechWorkerClient(
    config: LocalSpeechWorkerConfig(
      modelsDirectory: config.modelsDirectory,
      voiceSttModel: config.models.voiceStt,
      dictationSttModel: config.models.dictationStt,
      voiceTtsModel: config.models.voiceTts,
      voiceTtsSpeakerId: config.models.voiceTtsSpeakerId,
      voiceTtsSpeed: config.models.voiceTtsSpeed,
    ),
    logger: logger,
    startWorker: startWorker ?? startLocalSpeechWorkerProcess,
  );
  logger.info('Local speech worker provider initialized');
  return SpeechRuntimeReconciliation(
    turnDetection: needsTurnDetection
        ? WorkerBackedTurnDetectionProvider(client)
        : services.turnDetection,
    voiceStt: needsVoiceStt
        ? WorkerBackedSpeechToTextProvider(
            client,
            LocalSpeechSessionKind.voiceStt,
          )
        : services.voiceStt,
    voiceTts: needsVoiceTts
        ? WorkerBackedTextToSpeechProvider(client)
        : services.voiceTts,
    dictationStt: needsDictation
        ? WorkerBackedSpeechToTextProvider(
            client,
            LocalSpeechSessionKind.dictationStt,
          )
        : services.dictationStt,
    modelsDirectory: services.modelsDirectory,
    requiredLocalModelIds: services.requiredLocalModelIds,
    resolveMissingModels: services.resolveMissingModels,
    downloadModels: services.downloadModels,
    cleanup: () {
      services.cleanup();
      unawaited(client.shutdown());
    },
  );
}

bool _activeLocal(RequestedSpeechProvider provider) =>
    provider.enabled != false && provider.provider == SpeechProviderId.local;
