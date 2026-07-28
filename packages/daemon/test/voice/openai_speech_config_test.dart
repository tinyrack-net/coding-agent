import 'package:agent_daemon/src/voice/openai/config.dart';
import 'package:agent_daemon/src/voice/speech_runtime.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:test/test.dart';

void main() {
  const allOpenAi = RequestedSpeechProviders(
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

  test('empty global API key is unset', () {
    expect(
      resolveOpenAiSpeechConfig(
        environment: const {'OPENAI_API_KEY': '  '},
        persisted: const {},
        providers: defaultRequestedSpeechProviders,
      ),
      isNull,
    );
  });

  test('trimmed global key configures both endpoints with defaults', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {'OPENAI_API_KEY': ' sk-test '},
      persisted: const {},
      providers: allOpenAi,
    )!;

    expect(config.stt?.apiKey, 'sk-test');
    expect(config.stt?.model, defaultOpenAiSttModel);
    expect(config.stt?.confidenceThreshold, -3);
    expect(config.tts?.apiKey, 'sk-test');
    expect(config.tts?.model, defaultOpenAiTtsModel);
    expect(config.tts?.voice, defaultOpenAiTtsVoice);
    expect(config.tts?.responseFormat, 'pcm');
  });

  test('nested endpoint credentials beat endpoint and global env', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {
        'OPENAI_STT_API_KEY': 'stt-env',
        'OPENAI_TTS_API_KEY': 'tts-env',
        'OPENAI_API_KEY': 'global-env',
        'OPENAI_STT_BASE_URL': 'https://stt-env.test/v1',
        'OPENAI_TTS_BASE_URL': 'https://tts-env.test/v1',
      },
      persisted: const {
        'providers': {
          'openai': {
            'apiKey': 'global-saved',
            'baseUrl': 'https://global.test/v1',
            'stt': {
              'apiKey': ' stt-saved ',
              'baseUrl': ' https://stt.test/v1 ',
            },
            'tts': {
              'apiKey': ' tts-saved ',
              'baseUrl': ' https://tts.test/v1 ',
            },
          },
        },
      },
      providers: allOpenAi,
    )!;

    expect(config.stt?.apiKey, 'stt-saved');
    expect(config.stt?.baseUrl, 'https://stt.test/v1');
    expect(config.tts?.apiKey, 'tts-saved');
    expect(config.tts?.baseUrl, 'https://tts.test/v1');
  });

  test('endpoint environment beats global saved config', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {
        'OPENAI_STT_API_KEY': 'stt-env',
        'OPENAI_TTS_API_KEY': 'tts-env',
        'OPENAI_STT_BASE_URL': ' https://stt-env.test/v1 ',
        'OPENAI_TTS_BASE_URL': ' https://tts-env.test/v1 ',
      },
      persisted: const {
        'providers': {
          'openai': {
            'apiKey': 'global-saved',
            'baseUrl': 'https://global.test/v1',
          },
        },
      },
      providers: allOpenAi,
    )!;

    expect(config.stt?.apiKey, 'stt-env');
    expect(config.stt?.baseUrl, 'https://stt-env.test/v1');
    expect(config.tts?.apiKey, 'tts-env');
    expect(config.tts?.baseUrl, 'https://tts-env.test/v1');
  });

  test('empty endpoint variables fall back to global environment', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {
        'OPENAI_API_KEY': 'global',
        'OPENAI_BASE_URL': ' https://global.test/v1 ',
        'OPENAI_STT_API_KEY': '',
        'OPENAI_TTS_API_KEY': ' ',
      },
      persisted: const {},
      providers: allOpenAi,
    )!;

    expect(config.stt?.apiKey, 'global');
    expect(config.stt?.baseUrl, 'https://global.test/v1');
    expect(config.tts?.apiKey, 'global');
    expect(config.tts?.baseUrl, 'https://global.test/v1');
  });

  test('STT-only credentials ignore invalid unused TTS options', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {'TTS_VOICE': 'bad', 'TTS_MODEL': 'also-bad'},
      persisted: const {
        'providers': {
          'openai': {
            'stt': {'apiKey': 'stt-only'},
          },
        },
      },
      providers: allOpenAi,
    )!;

    expect(config.stt?.apiKey, 'stt-only');
    expect(config.tts, isNull);
  });

  test('feature options apply only to active OpenAI providers', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {'OPENAI_API_KEY': 'key'},
      persisted: const {
        'features': {
          'voiceMode': {
            'stt': {'model': 'voice-model'},
            'tts': {'voice': 'NOVA', 'model': 'TTS-1-HD'},
          },
          'dictation': {
            'stt': {'model': 'dictation-model', 'confidenceThreshold': '-2.5'},
          },
        },
      },
      providers: allOpenAi,
    )!;

    expect(config.stt?.model, 'voice-model');
    expect(config.stt?.confidenceThreshold, -2.5);
    expect(config.tts?.voice, 'nova');
    expect(config.tts?.model, 'tts-1-hd');
  });

  test('environment feature options have highest priority', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {
        'OPENAI_API_KEY': 'key',
        'STT_MODEL': 'gpt-4o-transcribe',
        'STT_CONFIDENCE_THRESHOLD': '-1.25',
        'TTS_VOICE': ' Shimmer ',
        'TTS_MODEL': ' TTS-1 ',
      },
      persisted: const {},
      providers: allOpenAi,
    )!;

    expect(config.stt?.model, 'gpt-4o-transcribe');
    expect(config.stt?.confidenceThreshold, -1.25);
    expect(config.tts?.voice, 'shimmer');
    expect(config.tts?.model, 'tts-1');
  });

  test('numeric persisted confidence threshold is accepted', () {
    final config = resolveOpenAiSpeechConfig(
      environment: const {'OPENAI_STT_API_KEY': 'key'},
      persisted: const {
        'features': {
          'dictation': {
            'stt': {'confidenceThreshold': -2.25},
          },
        },
      },
      providers: allOpenAi,
    );

    expect(config?.stt?.confidenceThreshold, -2.25);
  });

  test('invalid configured options fail at the matching endpoint boundary', () {
    expect(
      () => resolveOpenAiSpeechConfig(
        environment: const {
          'OPENAI_STT_API_KEY': 'key',
          'STT_CONFIDENCE_THRESHOLD': 'NaN',
        },
        persisted: const {},
        providers: allOpenAi,
      ),
      throwsFormatException,
    );
    expect(
      () => resolveOpenAiSpeechConfig(
        environment: const {'OPENAI_TTS_API_KEY': 'key', 'TTS_VOICE': 'bad'},
        persisted: const {},
        providers: allOpenAi,
      ),
      throwsFormatException,
    );
    expect(
      () => resolveOpenAiSpeechConfig(
        environment: const {'OPENAI_TTS_API_KEY': 'key', 'TTS_MODEL': 'bad'},
        persisted: const {},
        providers: allOpenAi,
      ),
      throwsFormatException,
    );
  });

  test('malformed persisted provider objects are rejected', () {
    expect(
      () => resolveOpenAiSpeechConfig(
        environment: const {},
        persisted: const {'providers': 'bad'},
        providers: allOpenAi,
      ),
      throwsFormatException,
    );
  });
}
