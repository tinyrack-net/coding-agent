import 'package:agent_daemon/src/voice/speech_config_resolver.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('local-first defaults match frozen provider and language config', () {
    final result = resolveSpeechConfiguration(
      tinyrackHome: p.join('tmp', 'home'),
      environment: const {},
      persisted: const {},
    );

    for (final provider in [
      result.runtime.providers.dictationStt,
      result.runtime.providers.voiceTurnDetection,
      result.runtime.providers.voiceStt,
      result.runtime.providers.voiceTts,
    ]) {
      expect(provider.provider, SpeechProviderId.local);
      expect(provider.explicit, isFalse);
      expect(provider.enabled, isTrue);
    }
    expect(result.runtime.dictationSttLanguage, 'en');
    expect(result.runtime.voiceSttLanguage, 'en');
    expect(
      result.local?.modelsDirectory,
      p.join('tmp', 'home', 'models', 'local-speech'),
    );
    expect(result.openAi, isNull);
  });

  test(
    'environment provider and enabled flags override persisted features',
    () {
      final providers = resolveRequestedSpeechProviders(
        environment: const {
          'TINYRACK_DICTATION_STT_PROVIDER': ' OPENAI ',
          'TINYRACK_DICTATION_ENABLED': 'off',
          'TINYRACK_VOICE_MODE_ENABLED': 'YES',
          'TINYRACK_VOICE_STT_PROVIDER': 'openai',
          'TINYRACK_VOICE_TTS_PROVIDER': 'local',
          'TINYRACK_VOICE_TURN_DETECTION_PROVIDER': 'LOCAL',
        },
        persisted: const {
          'features': {
            'dictation': {
              'enabled': true,
              'stt': {'provider': 'local'},
            },
            'voiceMode': {
              'enabled': false,
              'stt': {'provider': 'local'},
              'tts': {'provider': 'openai'},
            },
          },
        },
      );

      expect(providers.dictationStt.provider, SpeechProviderId.openai);
      expect(providers.dictationStt.explicit, isTrue);
      expect(providers.dictationStt.enabled, isFalse);
      expect(providers.voiceTurnDetection.provider, SpeechProviderId.local);
      expect(providers.voiceTurnDetection.enabled, isTrue);
      expect(providers.voiceStt.provider, SpeechProviderId.openai);
      expect(providers.voiceTts.provider, SpeechProviderId.local);
    },
  );

  test(
    'persisted feature providers are explicit and voice enablement is shared',
    () {
      final providers = resolveRequestedSpeechProviders(
        environment: const {},
        persisted: const {
          'features': {
            'dictation': {
              'enabled': false,
              'stt': {'provider': 'openai'},
            },
            'voiceMode': {
              'enabled': false,
              'turnDetection': {'provider': 'local'},
              'stt': {'provider': 'openai'},
              'tts': {'provider': 'openai'},
            },
          },
        },
      );

      expect(providers.dictationStt.explicit, isTrue);
      expect(providers.dictationStt.enabled, isFalse);
      expect(providers.voiceTurnDetection.explicit, isTrue);
      expect(providers.voiceTurnDetection.enabled, isFalse);
      expect(providers.voiceStt.enabled, isFalse);
      expect(providers.voiceTts.enabled, isFalse);
    },
  );

  test(
    'all frozen boolean spellings resolve and unknown strings default on',
    () {
      for (final value in ['0', 'false', 'no', 'n', 'off']) {
        final providers = resolveRequestedSpeechProviders(
          environment: {'TINYRACK_DICTATION_ENABLED': value},
          persisted: const {},
        );
        expect(providers.dictationStt.enabled, isFalse, reason: value);
      }
      for (final value in ['1', 'true', 'yes', 'y', 'on', 'unknown']) {
        final providers = resolveRequestedSpeechProviders(
          environment: {'TINYRACK_DICTATION_ENABLED': value},
          persisted: const {},
        );
        expect(providers.dictationStt.enabled, isTrue, reason: value);
      }
    },
  );

  test('resolved endpoint configs follow selected providers', () {
    final result = resolveSpeechConfiguration(
      tinyrackHome: 'home',
      environment: const {
        'TINYRACK_DICTATION_STT_PROVIDER': 'openai',
        'TINYRACK_VOICE_MODE_ENABLED': 'false',
        'OPENAI_STT_API_KEY': 'stt-key',
      },
      persisted: const {
        'features': {
          'dictation': {
            'stt': {'language': 'fr'},
          },
        },
      },
    );

    expect(
      result.runtime.providers.dictationStt.provider,
      SpeechProviderId.openai,
    );
    expect(result.runtime.dictationSttLanguage, 'fr');
    expect(result.openAi?.stt?.apiKey, 'stt-key');
    expect(result.openAi?.tts, isNull);
    expect(result.local, isNull);
  });

  test('legacy direct speech providers are ignored', () {
    final providers = resolveRequestedSpeechProviders(
      environment: const {},
      persisted: const {
        'speech': {
          'providers': {
            'voiceStt': {'provider': 'openai', 'explicit': true},
          },
        },
      },
    );

    expect(providers.voiceStt.provider, SpeechProviderId.local);
    expect(providers.voiceStt.explicit, isFalse);
  });

  test('malformed feature objects, providers, and flags are rejected', () {
    expect(
      () => resolveRequestedSpeechProviders(
        environment: const {},
        persisted: const {'features': 'bad'},
      ),
      throwsFormatException,
    );
    expect(
      () => resolveRequestedSpeechProviders(
        environment: const {'TINYRACK_VOICE_STT_PROVIDER': 'bad'},
        persisted: const {},
      ),
      throwsFormatException,
    );
    expect(
      () => resolveRequestedSpeechProviders(
        environment: const {},
        persisted: const {
          'features': {
            'dictation': {'enabled': 1},
          },
        },
      ),
      throwsFormatException,
    );
  });
}
