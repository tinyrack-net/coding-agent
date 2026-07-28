enum SpeechProviderId {
  openai('openai'),
  local('local');

  const SpeechProviderId(this.wireName);

  final String wireName;

  static SpeechProviderId fromJson(Object? value) {
    for (final provider in values) {
      if (provider.wireName == value) return provider;
    }
    throw const FormatException('Speech provider must be openai or local');
  }
}

final class RequestedSpeechProvider {
  const RequestedSpeechProvider({
    required this.provider,
    required this.explicit,
    this.enabled,
  });

  final SpeechProviderId provider;
  final bool explicit;
  final bool? enabled;

  factory RequestedSpeechProvider.fromJson(Map<String, Object?> json) {
    final explicit = json['explicit'];
    final enabled = json['enabled'];
    if (explicit is! bool || (enabled != null && enabled is! bool)) {
      throw const FormatException('Invalid requested speech provider');
    }
    return RequestedSpeechProvider(
      provider: SpeechProviderId.fromJson(json['provider']),
      explicit: explicit,
      enabled: enabled as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider.wireName,
    'explicit': explicit,
    if (enabled != null) 'enabled': enabled,
  };
}

final class RequestedSpeechProviders {
  const RequestedSpeechProviders({
    required this.dictationStt,
    required this.voiceTurnDetection,
    required this.voiceStt,
    required this.voiceTts,
  });

  final RequestedSpeechProvider dictationStt;
  final RequestedSpeechProvider voiceTurnDetection;
  final RequestedSpeechProvider voiceStt;
  final RequestedSpeechProvider voiceTts;

  factory RequestedSpeechProviders.fromJson(Map<String, Object?> json) {
    return RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider.fromJson(
        _requiredObject(json, 'dictationStt'),
      ),
      voiceTurnDetection: RequestedSpeechProvider.fromJson(
        _requiredObject(json, 'voiceTurnDetection'),
      ),
      voiceStt: RequestedSpeechProvider.fromJson(
        _requiredObject(json, 'voiceStt'),
      ),
      voiceTts: RequestedSpeechProvider.fromJson(
        _requiredObject(json, 'voiceTts'),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'dictationStt': dictationStt.toJson(),
    'voiceTurnDetection': voiceTurnDetection.toJson(),
    'voiceStt': voiceStt.toJson(),
    'voiceTts': voiceTts.toJson(),
  };
}

Map<String, Object?> _requiredObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map<String, Object?>) {
    throw FormatException('$key must be an object');
  }
  return value;
}
