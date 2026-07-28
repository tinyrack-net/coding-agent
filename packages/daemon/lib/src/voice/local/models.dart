import '../speech_provider.dart';
import 'model_downloader.dart';

export 'model_catalog.dart'
    show
        LocalSpeechModelKind,
        LocalSpeechModelSpec,
        defaultLocalSttModel,
        defaultLocalTtsModel,
        getLocalSpeechModelSpec,
        listLocalSpeechModels,
        localSttModelIds,
        localTtsModelIds,
        parseLocalSttModelId,
        parseLocalTtsModelId;
export 'model_downloader.dart'
    show ensureLocalSpeechModels, getLocalSpeechModelDirectory;

Future<Map<String, String>> ensureConfiguredLocalSpeechModels({
  required String modelsDirectory,
  required List<String> modelIds,
  SpeechLogger logger = const NullSpeechLogger(),
}) => ensureLocalSpeechModels(
  modelsDirectory: modelsDirectory,
  modelIds: modelIds,
  logger: logger,
);
