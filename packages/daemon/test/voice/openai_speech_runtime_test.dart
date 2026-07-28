import 'package:agent_daemon/src/voice/openai/config.dart';
import 'package:agent_daemon/src/voice/openai/runtime.dart';
import 'package:agent_daemon/src/voice/openai/stt.dart';
import 'package:agent_daemon/src/voice/openai/tts.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
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
      enabled: false,
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

  test('availability follows endpoint credentials independently', () {
    final none = getOpenAiSpeechAvailability(null);
    expect([none.stt, none.tts, none.dictationStt], [false, false, false]);

    final stt = getOpenAiSpeechAvailability(
      const OpenAiSpeechConfig(stt: OpenAiSttConfig(apiKey: 'key')),
    );
    expect([stt.stt, stt.tts, stt.dictationStt], [true, false, true]);
  });

  test('initializes REST STT separately for voice and dictation plus TTS', () {
    final services = initializeOpenAiSpeechServices(
      providers: allOpenAi,
      config: const OpenAiSpeechConfig(
        stt: OpenAiSttConfig(apiKey: 'stt'),
        tts: OpenAiTtsConfig(apiKey: 'tts'),
      ),
    );

    expect(services.voiceStt, isA<OpenAiSpeechToTextProvider>());
    expect(services.dictationStt, isA<OpenAiSpeechToTextProvider>());
    expect(services.dictationStt, isNot(same(services.voiceStt)));
    expect(services.voiceTts, isA<OpenAiTextToSpeechProvider>());
    expect(services.turnDetection, isNull);
  });

  test('does not replace existing or disabled/local providers', () {
    final stt = _FakeStt();
    final tts = _FakeTts();
    final services = initializeOpenAiSpeechServices(
      providers: const RequestedSpeechProviders(
        dictationStt: RequestedSpeechProvider(
          provider: SpeechProviderId.local,
          explicit: false,
        ),
        voiceTurnDetection: RequestedSpeechProvider(
          provider: SpeechProviderId.local,
          explicit: false,
        ),
        voiceStt: RequestedSpeechProvider(
          provider: SpeechProviderId.openai,
          explicit: true,
          enabled: false,
        ),
        voiceTts: RequestedSpeechProvider(
          provider: SpeechProviderId.openai,
          explicit: true,
        ),
      ),
      config: const OpenAiSpeechConfig(
        stt: OpenAiSttConfig(apiKey: 'stt'),
        tts: OpenAiTtsConfig(apiKey: 'tts'),
      ),
      existingVoiceStt: stt,
      existingVoiceTts: tts,
      existingDictationStt: stt,
    );

    expect(services.voiceStt, same(stt));
    expect(services.voiceTts, same(tts));
    expect(services.dictationStt, same(stt));
  });

  test('warns once with every active OpenAI endpoint missing credentials', () {
    final logger = _RecordingLogger();

    validateOpenAiCredentialRequirements(
      providers: allOpenAi,
      config: null,
      logger: logger,
    );

    expect(logger.warnings, hasLength(1));
    expect(logger.warningFields.single['missingOpenAiCredentialsFor'], [
      'voice.stt',
      'voice.tts',
      'dictation.stt',
    ]);
  });

  test('configured runtime exposes OpenAI dictation readiness', () async {
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
    final runtime = createOpenAiSpeechRuntime(
      runtimeConfig: const SpeechRuntimeConfig(providers: providers),
      openAiConfig: const OpenAiSpeechConfig(
        stt: OpenAiSttConfig(apiKey: 'key'),
      ),
    );

    runtime.start();
    await runtime.ready;

    expect(runtime.resolveDictationStt(), isA<OpenAiSpeechToTextProvider>());
    expect(runtime.getReadiness().dictation.available, isTrue);
    expect(runtime.getReadiness().realtimeVoice.enabled, isFalse);
    runtime.stop();
  });

  test('callback logger preserves child context and fields', () {
    final output = <String>[];
    final logger = CallbackSpeechLogger(output.add, context: const {'a': 1});
    final child = logger.child(const {'b': 2});

    child.debug('d');
    child.info('i', fields: const {'c': 3});
    child.warning('w');
    child.error('e');

    expect(output, [
      '[debug] d {a: 1, b: 2}',
      '[info] i {a: 1, b: 2, c: 3}',
      '[warning] w {a: 1, b: 2}',
      '[error] e {a: 1, b: 2}',
    ]);
  });
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

final class _RecordingLogger implements SpeechLogger {
  final warnings = <String>[];
  final warningFields = <Map<String, Object?>>[];

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {
    warnings.add(message);
    warningFields.add(fields);
  }
}
