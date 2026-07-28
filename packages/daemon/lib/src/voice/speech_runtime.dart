import 'dart:async';
import 'dart:convert';

import 'speech_provider.dart';
import 'speech_readiness.dart';
import 'speech_types.dart';
import 'turn_detection_provider.dart';

const speechRuntimeMonitorInterval = Duration(seconds: 3);

typedef SpeechReadinessListener =
    void Function(SpeechReadinessSnapshot snapshot);
typedef SpeechRuntimeReconciler =
    Future<SpeechRuntimeReconciliation> Function();
typedef SpeechMissingModelResolver =
    Future<List<String>> Function(
      String modelsDirectory,
      List<String> requiredModelIds,
    );
typedef SpeechModelDownloader =
    Future<void> Function(String modelsDirectory, List<String> modelIds);

abstract interface class SpeechService {
  SpeechToTextProvider? resolveStt();
  String resolveSttLanguage();
  TextToSpeechProvider? resolveTts();
  TurnDetectionProvider? resolveTurnDetection();
  SpeechToTextProvider? resolveDictationStt();
  String resolveDictationSttLanguage();
  SpeechReadinessSnapshot getReadiness();
  void Function() onReadinessChange(SpeechReadinessListener listener);
  void start();
  void stop();
  Future<void> get ready;
}

final class SpeechRuntimeConfig {
  const SpeechRuntimeConfig({
    this.providers = defaultRequestedSpeechProviders,
    this.voiceSttLanguage = 'en',
    this.dictationSttLanguage = 'en',
  });

  final RequestedSpeechProviders providers;
  final String voiceSttLanguage;
  final String dictationSttLanguage;

  factory SpeechRuntimeConfig.fromJson(Map<String, Object?> json) {
    final providerValues = _object(json['providers'], 'speech.providers');
    final languageValues = _object(json['sttLanguages'], 'speech.sttLanguages');
    RequestedSpeechProvider provider(
      String key,
      RequestedSpeechProvider fallback,
    ) {
      final value = providerValues[key];
      return value == null
          ? fallback
          : RequestedSpeechProvider.fromJson(
              _object(value, 'speech.providers.$key'),
            );
    }

    return SpeechRuntimeConfig(
      providers: RequestedSpeechProviders(
        dictationStt: provider(
          'dictationStt',
          defaultRequestedSpeechProviders.dictationStt,
        ),
        voiceTurnDetection: provider(
          'voiceTurnDetection',
          defaultRequestedSpeechProviders.voiceTurnDetection,
        ),
        voiceStt: provider(
          'voiceStt',
          defaultRequestedSpeechProviders.voiceStt,
        ),
        voiceTts: provider(
          'voiceTts',
          defaultRequestedSpeechProviders.voiceTts,
        ),
      ),
      voiceSttLanguage: _language(languageValues['voice'], 'voice'),
      dictationSttLanguage: _language(languageValues['dictation'], 'dictation'),
    );
  }

  Map<String, Object?> toJson() => {
    'providers': providers.toJson(),
    'sttLanguages': {
      'voice': voiceSttLanguage,
      'dictation': dictationSttLanguage,
    },
  };
}

const defaultRequestedSpeechProviders = RequestedSpeechProviders(
  dictationStt: RequestedSpeechProvider(
    provider: SpeechProviderId.local,
    explicit: false,
    enabled: true,
  ),
  voiceTurnDetection: RequestedSpeechProvider(
    provider: SpeechProviderId.local,
    explicit: false,
    enabled: true,
  ),
  voiceStt: RequestedSpeechProvider(
    provider: SpeechProviderId.local,
    explicit: false,
    enabled: true,
  ),
  voiceTts: RequestedSpeechProvider(
    provider: SpeechProviderId.local,
    explicit: false,
    enabled: true,
  ),
);

final class SpeechRuntimeReconciliation {
  const SpeechRuntimeReconciliation({
    this.turnDetection,
    this.voiceStt,
    this.voiceTts,
    this.dictationStt,
    this.modelsDirectory,
    this.requiredLocalModelIds = const [],
    this.resolveMissingModels,
    this.downloadModels,
    this.cleanup = _noop,
  });

  final TurnDetectionProvider? turnDetection;
  final SpeechToTextProvider? voiceStt;
  final TextToSpeechProvider? voiceTts;
  final SpeechToTextProvider? dictationStt;
  final String? modelsDirectory;
  final List<String> requiredLocalModelIds;
  final SpeechMissingModelResolver? resolveMissingModels;
  final SpeechModelDownloader? downloadModels;
  final void Function() cleanup;
}

final class SpeechRuntime implements SpeechService {
  SpeechRuntime({
    required SpeechRuntimeReconciler reconcile,
    this.config = const SpeechRuntimeConfig(),
    SpeechLogger logger = const NullSpeechLogger(),
    this.monitorInterval = speechRuntimeMonitorInterval,
    DateTime Function()? now,
  }) : _reconciler = reconcile,
       _logger = logger.child({'module': 'speech-runtime'}),
       _now = now ?? DateTime.now;

  final SpeechRuntimeReconciler _reconciler;
  final SpeechRuntimeConfig config;
  final SpeechLogger _logger;
  final Duration monitorInterval;
  final DateTime Function() _now;
  final Completer<void> _ready = Completer<void>();
  final Set<SpeechReadinessListener> _listeners = {};

  TurnDetectionProvider? _turnDetection;
  SpeechToTextProvider? _voiceStt;
  TextToSpeechProvider? _voiceTts;
  SpeechToTextProvider? _dictationStt;
  SpeechRuntimeReconciliation? _reconciliation;
  List<String> _missingLocalModelIds = const [];
  bool _backgroundDownloadInProgress = false;
  String? _backgroundDownloadError;
  bool _started = false;
  bool _stopped = false;
  Timer? _monitorTimer;
  Future<void>? _reconcileInFlight;
  String? _lastReadinessFingerprint;
  SpeechReadinessSnapshot? _lastPublishedReadiness;

  @override
  SpeechToTextProvider? resolveStt() => _voiceStt;

  @override
  String resolveSttLanguage() => config.voiceSttLanguage;

  @override
  TextToSpeechProvider? resolveTts() => _voiceTts;

  @override
  TurnDetectionProvider? resolveTurnDetection() => _turnDetection;

  @override
  SpeechToTextProvider? resolveDictationStt() => _dictationStt;

  @override
  String resolveDictationSttLanguage() => config.dictationSttLanguage;

  @override
  Future<void> get ready => _ready.future;

  @override
  SpeechReadinessSnapshot getReadiness() =>
      _lastPublishedReadiness ?? _computeReadiness();

  @override
  void Function() onReadinessChange(SpeechReadinessListener listener) {
    _listeners.add(listener);
    final snapshot = _lastPublishedReadiness ?? _computeReadiness();
    _lastPublishedReadiness ??= snapshot;
    _lastReadinessFingerprint ??= _readinessFingerprint(snapshot);
    try {
      listener(snapshot);
    } on Object catch (error) {
      _logger.warning(
        'Speech readiness listener threw during subscribe',
        fields: {'error': error},
      );
    }
    return () => _listeners.remove(listener);
  }

  @override
  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _runReconcile();
      final snapshot = _computeReadiness();
      if (snapshot.voiceFeature.enabled && !snapshot.voiceFeature.available) {
        if (_missingLocalModelIds.isNotEmpty) {
          _startBackgroundDownload();
        }
        _scheduleMonitor();
      }
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (error, stackTrace) {
      if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
      _logger.error(
        'Speech runtime failed during initial reconcile',
        fields: {'error': error},
      );
    }
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _reconciliation?.cleanup();
    _reconciliation = null;
  }

  Future<void> _runReconcile() async {
    final existing = _reconcileInFlight;
    if (existing != null) {
      await existing;
      _publishReadinessIfChanged();
      return;
    }
    final task = _reconcileServices();
    _reconcileInFlight = task;
    try {
      await task;
    } finally {
      if (identical(_reconcileInFlight, task)) _reconcileInFlight = null;
    }
    _publishReadinessIfChanged();
  }

  Future<void> _reconcileServices() async {
    final next = await _reconciler();
    if (_stopped) {
      next.cleanup();
      return;
    }
    final previous = _reconciliation;
    _reconciliation = next;
    _turnDetection = next.turnDetection;
    _voiceStt = next.voiceStt;
    _voiceTts = next.voiceTts;
    _dictationStt = next.dictationStt;
    previous?.cleanup();
    await _refreshMissingLocalModels();
  }

  Future<void> _refreshMissingLocalModels() async {
    final reconciliation = _reconciliation;
    final directory = reconciliation?.modelsDirectory;
    final required = reconciliation?.requiredLocalModelIds ?? const <String>[];
    final resolver = reconciliation?.resolveMissingModels;
    if (directory == null || required.isEmpty || resolver == null) {
      _missingLocalModelIds = const [];
      return;
    }
    _missingLocalModelIds = List.unmodifiable(
      await resolver(directory, List<String>.from(required)),
    );
  }

  void _startBackgroundDownload() {
    if (_stopped || _backgroundDownloadInProgress) return;
    final reconciliation = _reconciliation;
    final directory = reconciliation?.modelsDirectory;
    final downloader = reconciliation?.downloadModels;
    final modelIds = List<String>.from(_missingLocalModelIds);
    if (directory == null || downloader == null || modelIds.isEmpty) return;

    _backgroundDownloadInProgress = true;
    _backgroundDownloadError = null;
    _publishReadinessIfChanged();
    unawaited(
      (() async {
        try {
          await downloader(directory, modelIds);
          await _runReconcile();
          _backgroundDownloadError = null;
        } on Object catch (error) {
          _backgroundDownloadError = _errorMessage(error);
          _logger.error(
            'Background local speech model download failed',
            fields: {'error': error, 'modelIds': modelIds},
          );
        } finally {
          _backgroundDownloadInProgress = false;
          try {
            await _refreshMissingLocalModels();
          } on Object catch (error) {
            _logger.warning(
              'Failed to refresh local speech model status after download',
              fields: {'error': error},
            );
          }
          _publishReadinessIfChanged();
          _scheduleMonitor();
        }
      })(),
    );
  }

  void _scheduleMonitor() {
    if (_stopped || _monitorTimer != null) return;
    _monitorTimer = Timer(monitorInterval, () {
      _monitorTimer = null;
      unawaited(_runMonitorTick());
    });
  }

  Future<void> _runMonitorTick() async {
    if (_stopped) return;
    try {
      await _refreshMissingLocalModels();
      final snapshot = _computeReadiness();
      if (snapshot.voiceFeature.enabled &&
          !snapshot.voiceFeature.available &&
          _missingLocalModelIds.isEmpty &&
          !_backgroundDownloadInProgress) {
        await _runReconcile();
      }
      if (_missingLocalModelIds.isNotEmpty &&
          !_backgroundDownloadInProgress &&
          _backgroundDownloadError == null) {
        _startBackgroundDownload();
      }
    } on Object catch (error) {
      _logger.warning(
        'Speech runtime monitor tick failed',
        fields: {'error': error},
      );
    } finally {
      _publishReadinessIfChanged();
      _scheduleMonitor();
    }
  }

  SpeechReadinessSnapshot _computeReadiness() {
    final realtimeVoice = buildRealtimeVoiceReadiness(
      providers: config.providers,
      turnDetection: _turnDetection,
      stt: _voiceStt,
      tts: _voiceTts,
    );
    final dictation = buildDictationReadiness(
      providers: config.providers,
      stt: _dictationStt,
    );
    final voiceFeature = buildVoiceFeatureReadiness(
      realtimeVoice: realtimeVoice,
      dictation: dictation,
      missingLocalModelIds: _missingLocalModelIds,
      backgroundDownloadInProgress: _backgroundDownloadInProgress,
      backgroundDownloadError: _backgroundDownloadError,
    );
    return SpeechReadinessSnapshot(
      generatedAt: _now().toUtc().toIso8601String(),
      requiredLocalModelIds: List.unmodifiable(
        _reconciliation?.requiredLocalModelIds ?? const [],
      ),
      missingLocalModelIds: List.unmodifiable(_missingLocalModelIds),
      downloadInProgress: _backgroundDownloadInProgress,
      downloadError: _backgroundDownloadError,
      realtimeVoice: realtimeVoice,
      dictation: dictation,
      voiceFeature: voiceFeature,
    );
  }

  void _publishReadinessIfChanged() {
    final snapshot = _computeReadiness();
    final fingerprint = _readinessFingerprint(snapshot);
    if (fingerprint == _lastReadinessFingerprint) return;
    _lastReadinessFingerprint = fingerprint;
    _lastPublishedReadiness = snapshot;
    for (final listener in _listeners.toList(growable: false)) {
      try {
        listener(snapshot);
      } on Object catch (error) {
        _logger.warning(
          'Speech readiness listener threw',
          fields: {'error': error},
        );
      }
    }
  }
}

SpeechReadinessState buildRealtimeVoiceReadiness({
  required RequestedSpeechProviders providers,
  required TurnDetectionProvider? turnDetection,
  required SpeechToTextProvider? stt,
  required TextToSpeechProvider? tts,
}) {
  final turnEnabled = providers.voiceTurnDetection.enabled != false;
  final sttEnabled = providers.voiceStt.enabled != false;
  final ttsEnabled = providers.voiceTts.enabled != false;
  if (!turnEnabled && !sttEnabled && !ttsEnabled) {
    return const SpeechReadinessState(
      enabled: false,
      available: false,
      reasonCode: 'disabled',
      message: 'Realtime voice is disabled in daemon config.',
      retryable: false,
    );
  }
  if (turnEnabled && turnDetection == null) {
    return const SpeechReadinessState(
      enabled: true,
      available: false,
      reasonCode: 'turn_detection_unavailable',
      message:
          'Realtime voice is unavailable: turn-detection service is not ready.',
      retryable: false,
    );
  }
  if (sttEnabled && stt == null) {
    return const SpeechReadinessState(
      enabled: true,
      available: false,
      reasonCode: 'stt_unavailable',
      message:
          'Realtime voice is unavailable: speech-to-text service is not ready.',
      retryable: false,
    );
  }
  if (ttsEnabled && tts == null) {
    return const SpeechReadinessState(
      enabled: true,
      available: false,
      reasonCode: 'tts_unavailable',
      message:
          'Realtime voice is unavailable: text-to-speech service is not ready.',
      retryable: false,
    );
  }
  return const SpeechReadinessState(
    enabled: true,
    available: true,
    reasonCode: 'ready',
    message: 'Realtime voice is ready.',
    retryable: false,
  );
}

SpeechReadinessState buildDictationReadiness({
  required RequestedSpeechProviders providers,
  required SpeechToTextProvider? stt,
}) {
  if (providers.dictationStt.enabled == false) {
    return const SpeechReadinessState(
      enabled: false,
      available: false,
      reasonCode: 'disabled',
      message: 'Dictation is disabled in daemon config.',
      retryable: false,
    );
  }
  if (stt == null) {
    return const SpeechReadinessState(
      enabled: true,
      available: false,
      reasonCode: 'stt_unavailable',
      message: 'Dictation is unavailable: speech-to-text service is not ready.',
      retryable: false,
    );
  }
  return const SpeechReadinessState(
    enabled: true,
    available: true,
    reasonCode: 'ready',
    message: 'Dictation is ready.',
    retryable: false,
  );
}

SpeechReadinessState buildVoiceFeatureReadiness({
  required SpeechReadinessState realtimeVoice,
  required SpeechReadinessState dictation,
  required List<String> missingLocalModelIds,
  required bool backgroundDownloadInProgress,
  required String? backgroundDownloadError,
}) {
  if (!realtimeVoice.enabled && !dictation.enabled) {
    return const SpeechReadinessState(
      enabled: false,
      available: false,
      reasonCode: 'disabled',
      message: 'Voice features are disabled in daemon config.',
      retryable: false,
    );
  }
  if (missingLocalModelIds.isNotEmpty) {
    final missing = List<String>.unmodifiable(missingLocalModelIds);
    final joined = missing.join(', ');
    if (backgroundDownloadInProgress) {
      return SpeechReadinessState(
        enabled: true,
        available: false,
        reasonCode: 'model_download_in_progress',
        message:
            'Voice features are unavailable while models download in the '
            'background ($joined).',
        retryable: true,
        missingModelIds: missing,
      );
    }
    if (backgroundDownloadError != null) {
      return SpeechReadinessState(
        enabled: true,
        available: false,
        reasonCode: 'model_download_failed',
        message:
            'Voice features are unavailable: model download failed '
            '($backgroundDownloadError).',
        retryable: false,
        missingModelIds: missing,
      );
    }
    return SpeechReadinessState(
      enabled: true,
      available: false,
      reasonCode: 'models_missing',
      message:
          'Voice features are unavailable: missing local models ($joined).',
      retryable: true,
      missingModelIds: missing,
    );
  }
  return const SpeechReadinessState(
    enabled: true,
    available: true,
    reasonCode: 'ready',
    message: 'Voice features are ready.',
    retryable: false,
  );
}

Map<String, Object?> buildSpeechServerCapabilities(
  SpeechReadinessSnapshot readiness,
) => {
  'voice': {
    'dictation': _capabilityState(readiness.dictation, readiness),
    'voice': _capabilityState(readiness.realtimeVoice, readiness),
  },
};

Map<String, Object?> _capabilityState(
  SpeechReadinessState state,
  SpeechReadinessSnapshot readiness,
) => {'enabled': state.enabled, 'reason': _capabilityReason(state, readiness)};

String _capabilityReason(
  SpeechReadinessState state,
  SpeechReadinessSnapshot readiness,
) {
  if (state.available) return '';
  if (readiness.voiceFeature.reasonCode == 'model_download_in_progress') {
    final message = readiness.voiceFeature.message.trim();
    if (message.contains('Try again in a few minutes')) return message;
    return '$message Try again in a few minutes.';
  }
  return state.message;
}

String _readinessFingerprint(SpeechReadinessSnapshot snapshot) =>
    jsonEncode({...snapshot.toJson(), 'generatedAt': ''});

String _errorMessage(Object error) => switch (error) {
  StateError(:final message) => '$message',
  FormatException(:final message) => '$message',
  _ => '$error',
};

void _noop() {}

Map<String, Object?> _object(Object? value, String path) {
  if (value == null) return const {};
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$path must be an object');
}

String _language(Object? value, String field) {
  if (value == null) return 'en';
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('speech.sttLanguages.$field must be a string');
  }
  return value.trim();
}
