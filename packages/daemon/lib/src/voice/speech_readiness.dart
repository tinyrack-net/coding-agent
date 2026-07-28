final class SpeechReadinessState {
  const SpeechReadinessState({
    required this.enabled,
    required this.available,
    required this.reasonCode,
    required this.message,
    required this.retryable,
    this.missingModelIds = const [],
  });

  final bool enabled;
  final bool available;
  final String reasonCode;
  final String message;
  final bool retryable;
  final List<String> missingModelIds;
}

final class SpeechReadinessSnapshot {
  const SpeechReadinessSnapshot({
    required this.generatedAt,
    required this.realtimeVoice,
    required this.dictation,
    required this.voiceFeature,
    this.requiredLocalModelIds = const [],
    this.missingLocalModelIds = const [],
    this.downloadInProgress = false,
    this.downloadError,
  });

  final String generatedAt;
  final List<String> requiredLocalModelIds;
  final List<String> missingLocalModelIds;
  final bool downloadInProgress;
  final String? downloadError;
  final SpeechReadinessState realtimeVoice;
  final SpeechReadinessState dictation;
  final SpeechReadinessState voiceFeature;
}
