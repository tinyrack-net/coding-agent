import 'package:agent_daemon/src/voice/local/config.dart';
import 'package:agent_daemon/src/voice/local/model_catalog.dart';
import 'package:agent_daemon/src/voice/speech_runtime.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('catalog exactly exposes frozen models, roles, files, and defaults', () {
    expect(localSttModelIds, [
      'parakeet-tdt-0.6b-v2-int8',
      'parakeet-tdt-0.6b-v3-int8',
    ]);
    expect(localTtsModelIds, ['kokoro-en-v0_19']);
    expect(defaultLocalSttModel, 'parakeet-tdt-0.6b-v2-int8');
    expect(defaultLocalTtsModel, 'kokoro-en-v0_19');
    expect(listLocalSpeechModels(), hasLength(3));

    final v2 = getLocalSpeechModelSpec('parakeet-tdt-0.6b-v2-int8');
    expect(v2.kind, LocalSpeechModelKind.sttOffline);
    expect(v2.defaultFor, LocalSpeechModelKind.sttOffline);
    expect(v2.extractedDirectory, contains('parakeet-tdt-0.6b-v2-int8'));
    expect(v2.requiredFiles, [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ]);
    expect(v2.archiveUrl.path, endsWith('.tar.bz2'));
    expect(v2.description, contains('English'));

    final v3 = getLocalSpeechModelSpec('parakeet-tdt-0.6b-v3-int8');
    expect(v3.defaultFor, isNull);
    expect(v3.description, contains('25 European languages'));

    final tts = getLocalSpeechModelSpec('kokoro-en-v0_19');
    expect(tts.kind, LocalSpeechModelKind.tts);
    expect(tts.defaultFor, LocalSpeechModelKind.tts);
    expect(tts.requiredFiles, contains('espeak-ng-data'));
  });

  test('model parsers normalize valid ids and reject wrong roles', () {
    expect(
      parseLocalSttModelId(' PARAKEET-TDT-0.6B-V3-INT8 '),
      'parakeet-tdt-0.6b-v3-int8',
    );
    expect(parseLocalTtsModelId(' KOKORO-EN-V0_19 '), 'kokoro-en-v0_19');
    expect(
      () => parseLocalSttModelId('kokoro-en-v0_19'),
      throwsFormatException,
    );
    expect(
      () => parseLocalTtsModelId('parakeet-tdt-0.6b-v2-int8'),
      throwsFormatException,
    );
    expect(() => parseLocalSttModelId(1), throwsFormatException);
    expect(
      () => getLocalSpeechModelSpec('missing'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'local-first defaults resolve models, languages, and Kokoro speaker',
    () {
      final result = resolveLocalSpeechConfig(
        tinyrackHome: p.join('tmp', 'tinyrack-home'),
        environment: const {},
        persisted: const {},
        providers: defaultRequestedSpeechProviders,
      );

      expect(
        result.local?.modelsDirectory,
        p.join('tmp', 'tinyrack-home', 'models', 'local-speech'),
      );
      expect(result.local?.models.dictationStt, defaultLocalSttModel);
      expect(result.local?.models.voiceStt, defaultLocalSttModel);
      expect(result.local?.models.voiceTts, defaultLocalTtsModel);
      expect(result.local?.models.voiceTtsSpeakerId, 0);
      expect(result.local?.models.voiceTtsSpeed, isNull);
      expect(result.languages.dictation, 'en');
      expect(result.languages.voice, 'en');
    },
  );

  test('environment overrides every feature-scoped local setting', () {
    final result = resolveLocalSpeechConfig(
      tinyrackHome: 'ignored',
      environment: const {
        'TINYRACK_LOCAL_MODELS_DIR': ' custom/models ',
        'TINYRACK_DICTATION_LOCAL_STT_MODEL': 'parakeet-tdt-0.6b-v3-int8',
        'TINYRACK_VOICE_LOCAL_STT_MODEL': 'parakeet-tdt-0.6b-v2-int8',
        'TINYRACK_VOICE_LOCAL_TTS_MODEL': 'kokoro-en-v0_19',
        'TINYRACK_VOICE_LOCAL_TTS_SPEAKER_ID': '5',
        'TINYRACK_VOICE_LOCAL_TTS_SPEED': '1.35',
        'TINYRACK_DICTATION_LANGUAGE': ' es ',
        'TINYRACK_VOICE_LANGUAGE': ' pt ',
      },
      persisted: const {},
      providers: defaultRequestedSpeechProviders,
    );

    expect(result.local?.modelsDirectory, 'custom/models');
    expect(result.local?.models.dictationStt, 'parakeet-tdt-0.6b-v3-int8');
    expect(result.local?.models.voiceStt, 'parakeet-tdt-0.6b-v2-int8');
    expect(result.local?.models.voiceTts, 'kokoro-en-v0_19');
    expect(result.local?.models.voiceTtsSpeakerId, 5);
    expect(result.local?.models.voiceTtsSpeed, 1.35);
    expect(result.languages.dictation, 'es');
    expect(result.languages.voice, 'pt');
  });

  test('active local features consume persisted settings by role', () {
    final result = resolveLocalSpeechConfig(
      tinyrackHome: 'home',
      environment: const {},
      persisted: const {
        'providers': {
          'local': {'modelsDir': ' saved-models '},
        },
        'features': {
          'dictation': {
            'stt': {'model': 'parakeet-tdt-0.6b-v3-int8', 'language': 'fr'},
          },
          'voiceMode': {
            'stt': {'model': 'parakeet-tdt-0.6b-v3-int8', 'language': 'de'},
            'tts': {'model': 'kokoro-en-v0_19', 'speakerId': 2, 'speed': 0.9},
          },
        },
      },
      providers: defaultRequestedSpeechProviders,
    );

    expect(result.local?.modelsDirectory, 'saved-models');
    expect(result.local?.models.dictationStt, 'parakeet-tdt-0.6b-v3-int8');
    expect(result.local?.models.voiceStt, 'parakeet-tdt-0.6b-v3-int8');
    expect(result.local?.models.voiceTtsSpeakerId, 2);
    expect(result.local?.models.voiceTtsSpeed, 0.9);
    expect(result.languages.dictation, 'fr');
    expect(result.languages.voice, 'de');
  });

  test('voice language falls back through dictation env and settings', () {
    final fromEnvironment = resolveLocalSpeechConfig(
      tinyrackHome: 'home',
      environment: const {
        'TINYRACK_DICTATION_LANGUAGE': 'es',
        'TINYRACK_VOICE_LANGUAGE': ' ',
      },
      persisted: const {
        'features': {
          'voiceMode': {
            'stt': {'language': 'de'},
          },
        },
      },
      providers: defaultRequestedSpeechProviders,
    );
    expect(fromEnvironment.languages.voice, 'es');

    const noLocal = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.openai,
        explicit: true,
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
        provider: SpeechProviderId.openai,
        explicit: true,
      ),
    );
    final fromSettings = resolveLocalSpeechConfig(
      tinyrackHome: 'home',
      environment: const {},
      persisted: const {
        'features': {
          'dictation': {
            'stt': {'language': 'fr'},
          },
        },
      },
      providers: noLocal,
    );
    expect(fromSettings.local, isNull);
    expect(fromSettings.languages.dictation, 'fr');
    expect(fromSettings.languages.voice, 'fr');
  });

  test('explicit models directory includes config without local features', () {
    const noLocal = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.openai,
        explicit: true,
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
        provider: SpeechProviderId.openai,
        explicit: true,
      ),
    );

    final result = resolveLocalSpeechConfig(
      tinyrackHome: 'home',
      environment: const {'TINYRACK_LOCAL_MODELS_DIR': 'models'},
      persisted: const {},
      providers: noLocal,
    );

    expect(result.local?.modelsDirectory, 'models');
    expect(result.local?.models.dictationStt, defaultLocalSttModel);
  });

  test(
    'disabled/wrong-provider feature models do not leak into local config',
    () {
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
        ),
      );
      final result = resolveLocalSpeechConfig(
        tinyrackHome: 'home',
        environment: const {},
        persisted: const {
          'features': {
            'dictation': {
              'stt': {'model': 'not-a-model'},
            },
            'voiceMode': {
              'stt': {'model': 'not-a-model'},
            },
          },
        },
        providers: providers,
      );

      expect(result.local?.models.dictationStt, defaultLocalSttModel);
      expect(result.local?.models.voiceStt, defaultLocalSttModel);
    },
  );

  test(
    'invalid model, directory, speaker, speed, and objects are rejected',
    () {
      ResolvedLocalSpeechConfig resolve(Map<String, String> environment) =>
          resolveLocalSpeechConfig(
            tinyrackHome: 'home',
            environment: environment,
            persisted: const {},
            providers: defaultRequestedSpeechProviders,
          );

      expect(
        () => resolve(const {'TINYRACK_LOCAL_MODELS_DIR': ' '}),
        throwsFormatException,
      );
      expect(
        () => resolve(const {'TINYRACK_DICTATION_LOCAL_STT_MODEL': 'unknown'}),
        throwsFormatException,
      );
      expect(
        () => resolve(const {'TINYRACK_VOICE_LOCAL_TTS_SPEAKER_ID': '1.2'}),
        throwsFormatException,
      );
      expect(
        () => resolve(const {'TINYRACK_VOICE_LOCAL_TTS_SPEED': 'NaN'}),
        throwsFormatException,
      );
      expect(
        () => resolveLocalSpeechConfig(
          tinyrackHome: 'home',
          environment: const {},
          persisted: const {'providers': 'bad'},
          providers: defaultRequestedSpeechProviders,
        ),
        throwsFormatException,
      );
    },
  );
}
