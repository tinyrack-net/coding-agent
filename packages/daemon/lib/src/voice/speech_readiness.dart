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

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'available': available,
    'reasonCode': reasonCode,
    'message': message,
    'retryable': retryable,
    'missingModelIds': List<String>.from(missingModelIds),
  };
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

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt,
    'requiredLocalModelIds': List<String>.from(requiredLocalModelIds),
    'missingLocalModelIds': List<String>.from(missingLocalModelIds),
    'download': {'inProgress': downloadInProgress, 'error': downloadError},
    'realtimeVoice': realtimeVoice.toJson(),
    'dictation': dictation.toJson(),
    'voiceFeature': voiceFeature.toJson(),
  };
}
