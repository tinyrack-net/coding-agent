import 'dart:io';

import 'package:agent_daemon/src/voice/configured_speech_runtime.dart';
import 'package:agent_daemon/src/voice/local/config.dart';
import 'package:agent_daemon/src/voice/local/model_catalog.dart';
import 'package:agent_daemon/src/voice/local/model_downloader.dart';
import 'package:agent_daemon/src/voice/local/runtime.dart';
import 'package:agent_daemon/src/voice/local/worker_client.dart';
import 'package:agent_daemon/src/voice/openai/config.dart';
import 'package:agent_daemon/src/voice/openai/stt.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/speech_runtime.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const models = LocalSpeechModelConfig(
    dictationStt: 'parakeet-tdt-0.6b-v2-int8',
    voiceStt: 'parakeet-tdt-0.6b-v3-int8',
    voiceTts: 'kokoro-en-v0_19',
  );

  test('availability reflects optional local provider config', () {
    final missing = getLocalSpeechAvailability(null);
    expect(missing.configured, isFalse);
    expect(missing.modelsDirectory, isNull);

    final configured = getLocalSpeechAvailability(
      const LocalSpeechProviderConfig(
        modelsDirectory: 'models',
        models: models,
      ),
    );
    expect(configured.configured, isTrue);
    expect(configured.modelsDirectory, 'models');
  });

  test('required models preserve feature order and deduplicate ids', () {
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: false,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
    );

    expect(computeRequiredLocalModelIds(providers: providers, models: models), [
      'parakeet-tdt-0.6b-v2-int8',
      'parakeet-tdt-0.6b-v3-int8',
      'kokoro-en-v0_19',
    ]);

    const duplicateModels = LocalSpeechModelConfig(
      dictationStt: 'parakeet-tdt-0.6b-v2-int8',
      voiceStt: 'parakeet-tdt-0.6b-v2-int8',
      voiceTts: 'kokoro-en-v0_19',
    );
    expect(
      computeRequiredLocalModelIds(
        providers: providers,
        models: duplicateModels,
      ),
      ['parakeet-tdt-0.6b-v2-int8', 'kokoro-en-v0_19'],
    );
  });

  test('disabled and OpenAI features do not require local models', () {
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
        enabled: false,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: false,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.openai,
        explicit: true,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
        enabled: false,
      ),
    );

    expect(
      computeRequiredLocalModelIds(providers: providers, models: models),
      isEmpty,
    );
  });

  test('local runtime fills every requested worker-backed service', () {
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
    );
    final result = initializeLocalSpeechServices(
      services: const SpeechRuntimeReconciliation(),
      providers: providers,
      config: const LocalSpeechProviderConfig(
        modelsDirectory: 'models',
        models: models,
      ),
    );

    expect(result.turnDetection, isA<WorkerBackedTurnDetectionProvider>());
    expect(result.voiceStt, isA<WorkerBackedSpeechToTextProvider>());
    expect(result.dictationStt, isA<WorkerBackedSpeechToTextProvider>());
    expect(result.voiceTts, isA<WorkerBackedTextToSpeechProvider>());
    result.cleanup();
  });

  test('local runtime preserves services already supplied by OpenAI', () {
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
    );
    final existingStt = _FakeStt();
    final existingTts = _FakeTts();
    final result = initializeLocalSpeechServices(
      services: SpeechRuntimeReconciliation(
        voiceStt: existingStt,
        voiceTts: existingTts,
      ),
      providers: providers,
      config: const LocalSpeechProviderConfig(
        modelsDirectory: 'models',
        models: models,
      ),
    );

    expect(result.voiceStt, same(existingStt));
    expect(result.voiceTts, same(existingTts));
    expect(result.turnDetection, isA<WorkerBackedTurnDetectionProvider>());
    expect(result.dictationStt, isA<WorkerBackedSpeechToTextProvider>());
    result.cleanup();
  });

  test('model management preserves services and cleanup', () async {
    var cleanups = 0;
    final stt = _FakeStt();
    final tts = _FakeTts();
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: false,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
    );
    final managed = attachLocalModelManagement(
      services: SpeechRuntimeReconciliation(
        voiceStt: stt,
        voiceTts: tts,
        dictationStt: stt,
        cleanup: () => cleanups += 1,
      ),
      providers: providers,
      config: const LocalSpeechProviderConfig(
        modelsDirectory: 'models',
        models: models,
      ),
    );

    expect(managed.voiceStt, same(stt));
    expect(managed.voiceTts, same(tts));
    expect(managed.dictationStt, same(stt));
    expect(managed.modelsDirectory, 'models');
    expect(managed.requiredLocalModelIds, [
      'parakeet-tdt-0.6b-v2-int8',
      'parakeet-tdt-0.6b-v3-int8',
      'kokoro-en-v0_19',
    ]);
    expect(managed.resolveMissingModels, isNotNull);
    expect(managed.downloadModels, isNotNull);
    final home = Directory.systemTemp.createTempSync('tinyrack-managed-model-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    await _writeCompleteModel(home.path, 'kokoro-en-v0_19');
    await managed.downloadModels!(home.path, const ['kokoro-en-v0_19']);
    managed.cleanup();
    expect(cleanups, 1);

    final untouched = SpeechRuntimeReconciliation(voiceStt: stt);
    expect(
      attachLocalModelManagement(
        services: untouched,
        providers: providers,
        config: null,
      ),
      same(untouched),
    );
  });

  test(
    'configured runtime publishes installed local model requirements',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'tinyrack-local-runtime-',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      await _writeCompleteModel(home.path, 'parakeet-tdt-0.6b-v2-int8');
      await _writeCompleteModel(home.path, 'kokoro-en-v0_19');
      const localModels = LocalSpeechModelConfig(
        dictationStt: 'parakeet-tdt-0.6b-v2-int8',
        voiceStt: 'parakeet-tdt-0.6b-v2-int8',
        voiceTts: 'kokoro-en-v0_19',
      );
      final runtime = createConfiguredSpeechRuntime(
        runtimeConfig: const SpeechRuntimeConfig(),
        openAiConfig: null,
        localConfig: LocalSpeechProviderConfig(
          modelsDirectory: home.path,
          models: localModels,
        ),
      );

      runtime.start();
      await runtime.ready;

      expect(runtime.getReadiness().requiredLocalModelIds, [
        'parakeet-tdt-0.6b-v2-int8',
        'kokoro-en-v0_19',
      ]);
      expect(runtime.getReadiness().missingLocalModelIds, isEmpty);
      runtime.stop();
    },
  );

  test(
    'configured runtime composes OpenAI services without local config',
    () async {
      const providers = RequestedSpeechProviders(
        dictationStt: RequestedSpeechProvider(
          provider: SpeechProviderId.openai,
          explicit: true,
        ),
        voiceTurnDetection: RequestedSpeechProvider(
          provider: SpeechProviderId.local,
          explicit: false,
          enabled: false,
        ),
        voiceStt: RequestedSpeechProvider(
          provider: SpeechProviderId.local,
          explicit: false,
          enabled: false,
        ),
        voiceTts: RequestedSpeechProvider(
          provider: SpeechProviderId.local,
          explicit: false,
          enabled: false,
        ),
      );
      final runtime = createConfiguredSpeechRuntime(
        runtimeConfig: const SpeechRuntimeConfig(providers: providers),
        openAiConfig: const OpenAiSpeechConfig(
          stt: OpenAiSttConfig(apiKey: 'key'),
        ),
        localConfig: null,
      );

      runtime.start();
      await runtime.ready;

      expect(runtime.resolveDictationStt(), isA<OpenAiSpeechToTextProvider>());
      expect(runtime.getReadiness().dictation.available, isTrue);
      runtime.stop();
    },
  );
}

Future<void> _writeCompleteModel(String root, String modelId) async {
  final spec = getLocalSpeechModelSpec(modelId);
  final modelDirectory = Directory(getLocalSpeechModelDirectory(root, modelId));
  await modelDirectory.create(recursive: true);
  for (final relative in spec.requiredFiles) {
    final path = p.join(modelDirectory.path, relative);
    if (relative == 'espeak-ng-data') {
      await Directory(path).create(recursive: true);
    } else {
      await File(path).writeAsString('x');
    }
  }
}

final class _FakeStt implements SpeechToTextProvider {
  @override
  String get id => 'fake';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => throw UnimplementedError();
}

final class _FakeTts implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) =>
      throw UnimplementedError();
}
