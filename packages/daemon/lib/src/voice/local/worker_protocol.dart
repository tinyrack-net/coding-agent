import 'dart:typed_data';

import '../speech_provider.dart';
import 'worker_bytes.dart';

enum LocalSpeechSessionKind {
  voiceStt('voiceStt'),
  dictationStt('dictationStt'),
  vad('vad');

  const LocalSpeechSessionKind(this.wireName);

  final String wireName;

  static LocalSpeechSessionKind parse(Object? value) {
    for (final kind in values) {
      if (value == kind.wireName) return kind;
    }
    throw const FormatException('Invalid local speech session kind');
  }
}

enum LocalSpeechTranscriptionModel {
  voice('voice'),
  dictation('dictation');

  const LocalSpeechTranscriptionModel(this.wireName);

  final String wireName;

  static LocalSpeechTranscriptionModel parse(Object? value) {
    for (final model in values) {
      if (value == model.wireName) return model;
    }
    throw const FormatException('Invalid local speech transcription model');
  }
}

final class LocalSpeechWorkerConfig {
  const LocalSpeechWorkerConfig({
    required this.modelsDirectory,
    required this.voiceSttModel,
    required this.dictationSttModel,
    required this.voiceTtsModel,
    this.voiceTtsSpeakerId,
    this.voiceTtsSpeed,
  });

  final String modelsDirectory;
  final String voiceSttModel;
  final String dictationSttModel;
  final String voiceTtsModel;
  final int? voiceTtsSpeakerId;
  final double? voiceTtsSpeed;

  factory LocalSpeechWorkerConfig.fromJson(Map<String, Object?> json) {
    final modelsDirectory = json['modelsDir'];
    final voiceSttModel = json['voiceSttModel'];
    final dictationSttModel = json['dictationSttModel'];
    final voiceTtsModel = json['voiceTtsModel'];
    final voiceTtsSpeakerId = json['voiceTtsSpeakerId'];
    final voiceTtsSpeed = json['voiceTtsSpeed'];
    if (modelsDirectory is! String ||
        voiceSttModel is! String ||
        dictationSttModel is! String ||
        voiceTtsModel is! String ||
        (voiceTtsSpeakerId != null && voiceTtsSpeakerId is! int) ||
        (voiceTtsSpeed != null && voiceTtsSpeed is! num)) {
      throw const FormatException('Invalid local speech worker config');
    }
    return LocalSpeechWorkerConfig(
      modelsDirectory: modelsDirectory,
      voiceSttModel: voiceSttModel,
      dictationSttModel: dictationSttModel,
      voiceTtsModel: voiceTtsModel,
      voiceTtsSpeakerId: voiceTtsSpeakerId as int?,
      voiceTtsSpeed: (voiceTtsSpeed as num?)?.toDouble(),
    );
  }

  Map<String, Object?> toJson() => {
    'modelsDir': modelsDirectory,
    'voiceSttModel': voiceSttModel,
    'dictationSttModel': dictationSttModel,
    'voiceTtsModel': voiceTtsModel,
    if (voiceTtsSpeakerId != null) 'voiceTtsSpeakerId': voiceTtsSpeakerId,
    if (voiceTtsSpeed != null) 'voiceTtsSpeed': voiceTtsSpeed,
  };
}

sealed class LocalSpeechWorkerRequest {
  const LocalSpeechWorkerRequest({required this.requestId});

  final String requestId;
  String get type;
  Map<String, Object?> get summary;
  Map<String, Object?> toJson();

  static LocalSpeechWorkerRequest fromJson(Map<String, Object?> json) {
    final requestId = _requiredString(json, 'requestId');
    return switch (_requiredString(json, 'type')) {
      'tts.synthesize' => LocalSpeechTtsSynthesizeRequest(
        requestId: requestId,
        config: _config(json),
        text: _requiredString(json, 'text'),
      ),
      'stt.transcribe' => LocalSpeechSttTranscribeRequest(
        requestId: requestId,
        config: _config(json),
        model: LocalSpeechTranscriptionModel.parse(json['model']),
        audio: workerBytesFromJson(json['audio']),
        format: _requiredString(json, 'format'),
      ),
      'session.create' => LocalSpeechSessionCreateRequest(
        requestId: requestId,
        config: _config(json),
        sessionId: _requiredString(json, 'sessionId'),
        kind: LocalSpeechSessionKind.parse(json['kind']),
      ),
      'session.append' => LocalSpeechSessionAppendRequest(
        requestId: requestId,
        sessionId: _requiredString(json, 'sessionId'),
        audio: workerBytesFromJson(json['audio']),
      ),
      'session.commit' ||
      'session.clear' ||
      'session.flush' ||
      'session.reset' ||
      'session.close' => LocalSpeechSessionCommandRequest(
        requestId: requestId,
        sessionId: _requiredString(json, 'sessionId'),
        type: _requiredString(json, 'type'),
      ),
      _ => throw const FormatException(
        'Invalid local speech worker request type',
      ),
    };
  }
}

final class LocalSpeechTtsSynthesizeRequest extends LocalSpeechWorkerRequest {
  const LocalSpeechTtsSynthesizeRequest({
    required super.requestId,
    required this.config,
    required this.text,
  });

  final LocalSpeechWorkerConfig config;
  final String text;

  @override
  String get type => 'tts.synthesize';

  @override
  Map<String, Object?> get summary => {'textLength': text.length};

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'config': config.toJson(),
    'text': text,
  };
}

final class LocalSpeechSttTranscribeRequest extends LocalSpeechWorkerRequest {
  const LocalSpeechSttTranscribeRequest({
    required super.requestId,
    required this.config,
    required this.model,
    required this.audio,
    required this.format,
  });

  final LocalSpeechWorkerConfig config;
  final LocalSpeechTranscriptionModel model;
  final Uint8List audio;
  final String format;

  @override
  String get type => 'stt.transcribe';

  @override
  Map<String, Object?> get summary => {
    'model': model.wireName,
    'audioBytes': audio.length,
    'format': format,
  };

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'config': config.toJson(),
    'model': model.wireName,
    'audio': workerBytesToJson(audio),
    'format': format,
  };
}

final class LocalSpeechSessionCreateRequest extends LocalSpeechWorkerRequest {
  const LocalSpeechSessionCreateRequest({
    required super.requestId,
    required this.config,
    required this.sessionId,
    required this.kind,
  });

  final LocalSpeechWorkerConfig config;
  final String sessionId;
  final LocalSpeechSessionKind kind;

  @override
  String get type => 'session.create';

  @override
  Map<String, Object?> get summary => {
    'kind': kind.wireName,
    'sessionId': sessionId,
  };

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'config': config.toJson(),
    'sessionId': sessionId,
    'kind': kind.wireName,
  };
}

final class LocalSpeechSessionAppendRequest extends LocalSpeechWorkerRequest {
  const LocalSpeechSessionAppendRequest({
    required super.requestId,
    required this.sessionId,
    required this.audio,
  });

  final String sessionId;
  final Uint8List audio;

  @override
  String get type => 'session.append';

  @override
  Map<String, Object?> get summary => {
    'sessionId': sessionId,
    'audioBytes': audio.length,
  };

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'sessionId': sessionId,
    'audio': workerBytesToJson(audio),
  };
}

const Set<String> localSpeechSessionCommandTypes = {
  'session.commit',
  'session.clear',
  'session.flush',
  'session.reset',
  'session.close',
};

final class LocalSpeechSessionCommandRequest extends LocalSpeechWorkerRequest {
  LocalSpeechSessionCommandRequest({
    required super.requestId,
    required this.sessionId,
    required this.type,
  }) {
    if (!localSpeechSessionCommandTypes.contains(type)) {
      throw ArgumentError.value(type, 'type', 'Invalid session command');
    }
  }

  final String sessionId;

  @override
  final String type;

  @override
  Map<String, Object?> get summary => {'sessionId': sessionId};

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'sessionId': sessionId,
  };
}

sealed class LocalSpeechWorkerMessage {
  const LocalSpeechWorkerMessage();

  String get type;
  Map<String, Object?> toJson();

  static LocalSpeechWorkerMessage fromJson(Map<String, Object?> json) {
    final type = _requiredString(json, 'type');
    if (type == 'response') return LocalSpeechWorkerResponse.fromJson(json);
    return LocalSpeechWorkerEvent.fromJson(json);
  }
}

final class LocalSpeechWorkerResponse extends LocalSpeechWorkerMessage {
  const LocalSpeechWorkerResponse({
    required this.requestId,
    required this.ok,
    this.result,
    this.error,
  });

  final String requestId;
  final bool ok;
  final Object? result;
  final String? error;

  factory LocalSpeechWorkerResponse.success({
    required String requestId,
    Object? result,
  }) =>
      LocalSpeechWorkerResponse(requestId: requestId, ok: true, result: result);

  factory LocalSpeechWorkerResponse.failure({
    required String requestId,
    required String error,
  }) =>
      LocalSpeechWorkerResponse(requestId: requestId, ok: false, error: error);

  factory LocalSpeechWorkerResponse.fromJson(Map<String, Object?> json) {
    final ok = json['ok'];
    if (ok is! bool) {
      throw const FormatException('Invalid local speech worker response');
    }
    final error = json['error'];
    if (!ok && error is! String) {
      throw const FormatException('Invalid local speech worker response error');
    }
    return LocalSpeechWorkerResponse(
      requestId: _requiredString(json, 'requestId'),
      ok: ok,
      result: json['result'],
      error: error as String?,
    );
  }

  @override
  String get type => 'response';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'ok': ok,
    if (ok && result != null) 'result': result,
    if (!ok) 'error': error,
  };
}

enum LocalSpeechWorkerEventType {
  committed('session.committed'),
  transcript('session.transcript'),
  speechStarted('session.speech_started'),
  speechStopped('session.speech_stopped'),
  error('session.error');

  const LocalSpeechWorkerEventType(this.wireName);

  final String wireName;

  static LocalSpeechWorkerEventType parse(Object? value) {
    for (final type in values) {
      if (value == type.wireName) return type;
    }
    throw const FormatException('Invalid local speech worker event type');
  }
}

final class LocalSpeechWorkerEvent extends LocalSpeechWorkerMessage {
  const LocalSpeechWorkerEvent({
    required this.eventType,
    required this.sessionId,
    this.payload,
    this.error,
  });

  final LocalSpeechWorkerEventType eventType;
  final String sessionId;
  final Object? payload;
  final String? error;

  factory LocalSpeechWorkerEvent.fromJson(Map<String, Object?> json) {
    final eventType = LocalSpeechWorkerEventType.parse(json['type']);
    final payload = json['payload'];
    final error = json['error'];
    switch (eventType) {
      case LocalSpeechWorkerEventType.committed:
        if (payload is! Map) {
          throw const FormatException('Invalid committed worker event');
        }
        StreamingTranscriptionCommittedEvent.fromJson(
          Map<String, Object?>.from(payload),
        );
      case LocalSpeechWorkerEventType.transcript:
        if (payload is! Map) {
          throw const FormatException('Invalid transcript worker event');
        }
        StreamingTranscriptionEvent.fromJson(
          Map<String, Object?>.from(payload),
        );
      case LocalSpeechWorkerEventType.error:
        if (error is! String) {
          throw const FormatException('Invalid error worker event');
        }
      case LocalSpeechWorkerEventType.speechStarted ||
          LocalSpeechWorkerEventType.speechStopped:
        break;
    }
    return LocalSpeechWorkerEvent(
      eventType: eventType,
      sessionId: _requiredString(json, 'sessionId'),
      payload: payload,
      error: error as String?,
    );
  }

  @override
  String get type => eventType.wireName;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'sessionId': sessionId,
    if (payload != null) 'payload': payload,
    if (error != null) 'error': error,
  };
}

final class LocalSpeechCreateSessionResult {
  const LocalSpeechCreateSessionResult({required this.requiredSampleRate});

  final int requiredSampleRate;

  factory LocalSpeechCreateSessionResult.fromJson(Object? value) {
    if (value is! Map || value['requiredSampleRate'] is! int) {
      throw const FormatException('Invalid local speech session result');
    }
    return LocalSpeechCreateSessionResult(
      requiredSampleRate: value['requiredSampleRate']! as int,
    );
  }

  Map<String, Object?> toJson() => {'requiredSampleRate': requiredSampleRate};
}

final class LocalSpeechTtsResult {
  const LocalSpeechTtsResult({required this.audio, required this.format});

  final Uint8List audio;
  final String format;

  factory LocalSpeechTtsResult.fromJson(Object? value) {
    if (value is! Map || value['format'] is! String) {
      throw const FormatException('Invalid local speech TTS result');
    }
    return LocalSpeechTtsResult(
      audio: workerBytesFromJson(value['audio']),
      format: value['format']! as String,
    );
  }

  Map<String, Object?> toJson() => {
    'audio': workerBytesToJson(audio),
    'format': format,
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid local speech worker $key');
  }
  return value;
}

LocalSpeechWorkerConfig _config(Map<String, Object?> json) {
  final value = json['config'];
  if (value is! Map) {
    throw const FormatException('Invalid local speech worker config');
  }
  return LocalSpeechWorkerConfig.fromJson(Map<String, Object?>.from(value));
}
