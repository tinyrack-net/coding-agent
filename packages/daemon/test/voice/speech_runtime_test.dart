import 'dart:async';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/speech_readiness.dart';
import 'package:agent_daemon/src/voice/speech_runtime.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:test/test.dart';

void main() {
  test('speech runtime config preserves frozen defaults and overrides', () {
    final defaults = SpeechRuntimeConfig.fromJson(const {});
    expect(defaults.providers.voiceStt.provider, SpeechProviderId.local);
    expect(defaults.voiceSttLanguage, 'en');

    final configured = SpeechRuntimeConfig.fromJson({
      'providers': <Object?, Object?>{
        'voiceStt': {'provider': 'openai', 'explicit': true, 'enabled': false},
      },
      'sttLanguages': {'voice': ' ko ', 'dictation': 'ja'},
    });
    expect(configured.toJson(), {
      'providers': {
        'dictationStt': {
          'provider': 'local',
          'explicit': false,
          'enabled': true,
        },
        'voiceTurnDetection': {
          'provider': 'local',
          'explicit': false,
          'enabled': true,
        },
        'voiceStt': {'provider': 'openai', 'explicit': true, 'enabled': false},
        'voiceTts': {'provider': 'local', 'explicit': false, 'enabled': true},
      },
      'sttLanguages': {'voice': 'ko', 'dictation': 'ja'},
    });
    expect(
      () => SpeechRuntimeConfig.fromJson(const {'providers': false}),
      throwsFormatException,
    );
    expect(
      () => SpeechRuntimeConfig.fromJson(const {
        'sttLanguages': {'voice': ''},
      }),
      throwsFormatException,
    );
  });

  group('frozen readiness builders', () {
    test('resolves every realtime provider and disabled branch', () {
      expect(
        buildRealtimeVoiceReadiness(
          providers: _providers(voiceEnabled: false),
          turnDetection: null,
          stt: null,
          tts: null,
        ).reasonCode,
        'disabled',
      );
      expect(
        buildRealtimeVoiceReadiness(
          providers: _providers(),
          turnDetection: null,
          stt: null,
          tts: null,
        ).reasonCode,
        'turn_detection_unavailable',
      );
      expect(
        buildRealtimeVoiceReadiness(
          providers: _providers(),
          turnDetection: _TurnProvider(),
          stt: null,
          tts: null,
        ).reasonCode,
        'stt_unavailable',
      );
      expect(
        buildRealtimeVoiceReadiness(
          providers: _providers(),
          turnDetection: _TurnProvider(),
          stt: _SttProvider(),
          tts: null,
        ).reasonCode,
        'tts_unavailable',
      );
      expect(
        buildRealtimeVoiceReadiness(
          providers: _providers(),
          turnDetection: _TurnProvider(),
          stt: _SttProvider(),
          tts: _TtsProvider(),
        ).toJson(),
        {
          'enabled': true,
          'available': true,
          'reasonCode': 'ready',
          'message': 'Realtime voice is ready.',
          'retryable': false,
          'missingModelIds': <String>[],
        },
      );
    });

    test('resolves dictation and aggregate model states exactly', () {
      final disabled = buildDictationReadiness(
        providers: _providers(dictationEnabled: false),
        stt: null,
      );
      final unavailable = buildDictationReadiness(
        providers: _providers(),
        stt: null,
      );
      final ready = buildDictationReadiness(
        providers: _providers(),
        stt: _SttProvider(),
      );
      expect(disabled.reasonCode, 'disabled');
      expect(unavailable.reasonCode, 'stt_unavailable');
      expect(ready.reasonCode, 'ready');

      expect(
        buildVoiceFeatureReadiness(
          realtimeVoice: disabled,
          dictation: disabled,
          missingLocalModelIds: const [],
          backgroundDownloadInProgress: false,
          backgroundDownloadError: null,
        ).reasonCode,
        'disabled',
      );
      expect(
        buildVoiceFeatureReadiness(
          realtimeVoice: ready,
          dictation: ready,
          missingLocalModelIds: const ['vad', 'stt'],
          backgroundDownloadInProgress: true,
          backgroundDownloadError: null,
        ).toJson(),
        containsPair('reasonCode', 'model_download_in_progress'),
      );
      expect(
        buildVoiceFeatureReadiness(
          realtimeVoice: ready,
          dictation: ready,
          missingLocalModelIds: const ['vad'],
          backgroundDownloadInProgress: false,
          backgroundDownloadError: 'network failed',
        ).toJson(),
        containsPair('reasonCode', 'model_download_failed'),
      );
      expect(
        buildVoiceFeatureReadiness(
          realtimeVoice: ready,
          dictation: ready,
          missingLocalModelIds: const ['vad'],
          backgroundDownloadInProgress: false,
          backgroundDownloadError: null,
        ).reasonCode,
        'models_missing',
      );
      expect(
        buildVoiceFeatureReadiness(
          realtimeVoice: unavailable,
          dictation: unavailable,
          missingLocalModelIds: const [],
          backgroundDownloadInProgress: false,
          backgroundDownloadError: null,
        ).reasonCode,
        'ready',
      );
    });

    test('maps readiness to frozen server capability reasons', () {
      final downloading = _snapshot(
        realtime: _state(
          available: false,
          reasonCode: 'turn_detection_unavailable',
          message: 'VAD unavailable',
        ),
        dictation: _state(
          available: false,
          reasonCode: 'stt_unavailable',
          message: 'STT unavailable',
        ),
        feature: _state(
          available: false,
          reasonCode: 'model_download_in_progress',
          message: 'Models downloading.',
        ),
      );
      expect(buildSpeechServerCapabilities(downloading), {
        'voice': {
          'dictation': {
            'enabled': true,
            'reason': 'Models downloading. Try again in a few minutes.',
          },
          'voice': {
            'enabled': true,
            'reason': 'Models downloading. Try again in a few minutes.',
          },
        },
      });
      final alreadyQualified = _snapshot(
        realtime: downloading.realtimeVoice,
        dictation: downloading.dictation,
        feature: _state(
          available: false,
          reasonCode: 'model_download_in_progress',
          message: 'Try again in a few minutes',
        ),
      );
      expect(
        ((buildSpeechServerCapabilities(alreadyQualified)['voice']
                as Map)['voice']
            as Map)['reason'],
        'Try again in a few minutes',
      );
      final ready = _snapshot(
        realtime: _state(),
        dictation: _state(),
        feature: _state(),
      );
      expect(
        ((buildSpeechServerCapabilities(ready)['voice'] as Map)['dictation']
            as Map)['reason'],
        '',
      );
      expect(
        ((buildSpeechServerCapabilities(
                  _snapshot(
                    realtime: downloading.realtimeVoice,
                    dictation: downloading.dictation,
                    feature: _state(
                      available: false,
                      reasonCode: 'models_missing',
                      message: 'Models missing',
                    ),
                  ),
                )['voice']
                as Map)['voice']
            as Map)['reason'],
        'VAD unavailable',
      );
    });
  });

  test('reconciles providers, languages, listeners, and cleanup', () async {
    var cleanupCalls = 0;
    final logger = _Logger();
    final runtime = SpeechRuntime(
      reconcile: () async => SpeechRuntimeReconciliation(
        turnDetection: _TurnProvider(),
        voiceStt: _SttProvider(),
        voiceTts: _TtsProvider(),
        dictationStt: _SttProvider('dictation'),
        cleanup: () => cleanupCalls += 1,
      ),
      config: SpeechRuntimeConfig(
        providers: _providers(),
        voiceSttLanguage: 'ko',
        dictationSttLanguage: 'ja',
      ),
      logger: logger,
      now: () => DateTime.utc(2026, 7, 29),
    );
    final snapshots = <SpeechReadinessSnapshot>[];
    final unsubscribe = runtime.onReadinessChange(snapshots.add);
    runtime.onReadinessChange((_) => throw StateError('listener failed'));

    expect(runtime.getReadiness().realtimeVoice.available, isFalse);
    runtime.start();
    runtime.start();
    await runtime.ready;

    expect(runtime.resolveTurnDetection(), isNotNull);
    expect(runtime.resolveStt()!.id, 'stt');
    expect(runtime.resolveTts(), isNotNull);
    expect(runtime.resolveDictationStt()!.id, 'dictation');
    expect(runtime.resolveSttLanguage(), 'ko');
    expect(runtime.resolveDictationSttLanguage(), 'ja');
    expect(runtime.getReadiness().voiceFeature.reasonCode, 'ready');
    expect(snapshots, hasLength(2));
    expect(logger.warnings, isNotEmpty);

    unsubscribe();
    runtime.stop();
    runtime.stop();
    expect(cleanupCalls, 1);
  });

  test('keeps aggregate available for one enabled ready mode', () async {
    final dictationOnly = SpeechRuntime(
      reconcile: () async =>
          SpeechRuntimeReconciliation(dictationStt: _SttProvider()),
      config: SpeechRuntimeConfig(providers: _providers(voiceEnabled: false)),
    );
    dictationOnly.start();
    await dictationOnly.ready;
    expect(dictationOnly.getReadiness().dictation.available, isTrue);
    expect(dictationOnly.getReadiness().realtimeVoice.reasonCode, 'disabled');
    expect(dictationOnly.getReadiness().voiceFeature.available, isTrue);
    dictationOnly.stop();

    final voiceOnly = SpeechRuntime(
      reconcile: () async => SpeechRuntimeReconciliation(
        turnDetection: _TurnProvider(),
        voiceStt: _SttProvider(),
        voiceTts: _TtsProvider(),
      ),
      config: SpeechRuntimeConfig(
        providers: _providers(dictationEnabled: false),
      ),
    );
    voiceOnly.start();
    await voiceOnly.ready;
    expect(voiceOnly.getReadiness().realtimeVoice.available, isTrue);
    expect(voiceOnly.getReadiness().dictation.reasonCode, 'disabled');
    expect(voiceOnly.getReadiness().voiceFeature.available, isTrue);
    voiceOnly.stop();
  });

  test('downloads missing models and reconciles ready services', () async {
    var modelsMissing = true;
    var reconcileCalls = 0;
    var cleanupCalls = 0;
    final downloadStarted = Completer<void>();
    final releaseDownload = Completer<void>();
    final runtime = SpeechRuntime(
      reconcile: () async {
        reconcileCalls += 1;
        return SpeechRuntimeReconciliation(
          turnDetection: _TurnProvider(),
          voiceStt: _SttProvider(),
          voiceTts: _TtsProvider(),
          dictationStt: _SttProvider(),
          modelsDirectory: 'models',
          requiredLocalModelIds: const ['vad'],
          resolveMissingModels: (_, __) async =>
              modelsMissing ? const ['vad'] : const [],
          downloadModels: (_, modelIds) async {
            expect(modelIds, ['vad']);
            downloadStarted.complete();
            await releaseDownload.future;
            modelsMissing = false;
          },
          cleanup: () => cleanupCalls += 1,
        );
      },
      config: SpeechRuntimeConfig(providers: _providers()),
      monitorInterval: const Duration(milliseconds: 5),
    );
    runtime.start();
    await runtime.ready;
    await downloadStarted.future;

    expect(runtime.getReadiness().downloadInProgress, isTrue);
    expect(
      runtime.getReadiness().voiceFeature.reasonCode,
      'model_download_in_progress',
    );
    releaseDownload.complete();
    await _waitFor(() => runtime.getReadiness().voiceFeature.available);

    expect(runtime.getReadiness().missingLocalModelIds, isEmpty);
    expect(runtime.getReadiness().requiredLocalModelIds, ['vad']);
    expect(reconcileCalls, 2);
    expect(cleanupCalls, 1);
    runtime.stop();
    expect(cleanupCalls, 2);
  });

  test('publishes failed downloads without retrying them', () async {
    var downloadCalls = 0;
    final logger = _Logger();
    final runtime = SpeechRuntime(
      reconcile: () async => SpeechRuntimeReconciliation(
        modelsDirectory: 'models',
        requiredLocalModelIds: const ['vad'],
        resolveMissingModels: (_, __) async => const ['vad'],
        downloadModels: (_, __) async {
          downloadCalls += 1;
          throw StateError('network failed');
        },
      ),
      monitorInterval: const Duration(milliseconds: 5),
      logger: logger,
    );
    runtime.start();
    await expectLater(runtime.ready, completes);
    await _waitFor(
      () =>
          runtime.getReadiness().voiceFeature.reasonCode ==
          'model_download_failed',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(runtime.getReadiness().downloadError, 'network failed');
    expect(runtime.getReadiness().voiceFeature.retryable, isFalse);
    expect(downloadCalls, 1);
    expect(logger.errors, isNotEmpty);
    runtime.stop();
  });

  test('normalizes non-state download errors', () async {
    for (final entry in <(Object, String)>[
      (const FormatException('bad response'), 'bad response'),
      (Exception('socket closed'), 'Exception: socket closed'),
    ]) {
      final runtime = SpeechRuntime(
        reconcile: () async => SpeechRuntimeReconciliation(
          modelsDirectory: 'models',
          requiredLocalModelIds: const ['vad'],
          resolveMissingModels: (_, __) async => const ['vad'],
          downloadModels: (_, __) async => throw entry.$1,
        ),
      );
      runtime.start();
      await runtime.ready;
      await _waitFor(() => runtime.getReadiness().downloadError != null);
      expect(runtime.getReadiness().downloadError, entry.$2);
      runtime.stop();
    }
  });

  test('monitor observes missing models without a downloader', () async {
    var scans = 0;
    final runtime = SpeechRuntime(
      reconcile: () async => SpeechRuntimeReconciliation(
        modelsDirectory: 'models',
        requiredLocalModelIds: const ['vad'],
        resolveMissingModels: (_, __) async {
          scans += 1;
          return const ['vad'];
        },
      ),
      monitorInterval: const Duration(milliseconds: 5),
    );
    runtime.start();
    await runtime.ready;
    await _waitFor(() => scans >= 2);
    expect(runtime.getReadiness().voiceFeature.reasonCode, 'models_missing');
    runtime.stop();
  });

  test('monitor contains repeated model refresh failures', () async {
    var scanCalls = 0;
    final logger = _Logger();
    final runtime = SpeechRuntime(
      reconcile: () async => SpeechRuntimeReconciliation(
        modelsDirectory: 'models',
        requiredLocalModelIds: const ['vad'],
        resolveMissingModels: (_, __) async {
          scanCalls += 1;
          if (scanCalls == 2 || scanCalls == 3) {
            throw StateError('scan failed');
          }
          return const ['vad'];
        },
        downloadModels: (_, __) async => throw StateError('download failed'),
      ),
      monitorInterval: const Duration(milliseconds: 5),
      logger: logger,
    );
    runtime.start();
    await runtime.ready;
    await _waitFor(() => logger.warnings.length >= 2);

    expect(scanCalls, greaterThanOrEqualTo(3));
    expect(runtime.getReadiness().downloadError, 'download failed');
    runtime.stop();
  });

  test(
    'initial reconciliation failure rejects ready and stop wins races',
    () async {
      final logger = _Logger();
      final failed = SpeechRuntime(
        reconcile: () async => throw const FormatException('bad config'),
        logger: logger,
      );
      failed.start();
      await expectLater(failed.ready, throwsFormatException);
      expect(logger.errors, isNotEmpty);
      failed.stop();

      final release = Completer<void>();
      var cleanupCalls = 0;
      final stopped = SpeechRuntime(
        reconcile: () async {
          await release.future;
          return SpeechRuntimeReconciliation(cleanup: () => cleanupCalls += 1);
        },
      );
      stopped.start();
      stopped.stop();
      release.complete();
      await stopped.ready;
      expect(cleanupCalls, 1);
    },
  );
}

RequestedSpeechProviders _providers({
  bool voiceEnabled = true,
  bool dictationEnabled = true,
}) => RequestedSpeechProviders(
  dictationStt: _requested(dictationEnabled),
  voiceTurnDetection: _requested(voiceEnabled),
  voiceStt: _requested(voiceEnabled),
  voiceTts: _requested(voiceEnabled),
);

RequestedSpeechProvider _requested(bool enabled) => RequestedSpeechProvider(
  provider: SpeechProviderId.local,
  explicit: true,
  enabled: enabled,
);

SpeechReadinessState _state({
  bool available = true,
  String reasonCode = 'ready',
  String message = 'Ready',
}) => SpeechReadinessState(
  enabled: true,
  available: available,
  reasonCode: reasonCode,
  message: message,
  retryable: false,
);

SpeechReadinessSnapshot _snapshot({
  required SpeechReadinessState realtime,
  required SpeechReadinessState dictation,
  required SpeechReadinessState feature,
}) => SpeechReadinessSnapshot(
  generatedAt: '2026-07-29T00:00:00.000Z',
  realtimeVoice: realtime,
  dictation: dictation,
  voiceFeature: feature,
);

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for speech runtime state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _SttProvider implements SpeechToTextProvider {
  const _SttProvider([this.id = 'stt']);

  @override
  final String id;

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) => throw UnimplementedError();
}

final class _TtsProvider implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) =>
      throw UnimplementedError();
}

final class _TurnProvider implements TurnDetectionProvider {
  @override
  String get id => 'turn';

  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) => throw UnimplementedError();
}

final class _Logger implements SpeechLogger {
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {
    warnings.add(message);
  }

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {
    errors.add(message);
  }
}
