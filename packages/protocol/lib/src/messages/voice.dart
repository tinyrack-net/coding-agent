final class AudioPlayedMessage {
  const AudioPlayedMessage({required this.id});

  static const type = 'audio_played';

  final String id;

  factory AudioPlayedMessage.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected audio played message');
    }
    final id = json['id'];
    if (id is! String) {
      throw const FormatException('id must be a string');
    }
    return AudioPlayedMessage(id: id);
  }

  Map<String, Object?> toJson() => {'type': type, 'id': id};
}

final class AudioOutputPayload {
  const AudioOutputPayload({
    required this.audio,
    required this.format,
    required this.id,
    required this.isVoiceMode,
    this.groupId,
    this.chunkIndex,
    this.isLastChunk,
  });

  final String audio;
  final String format;
  final String id;
  final bool isVoiceMode;
  final String? groupId;
  final int? chunkIndex;
  final bool? isLastChunk;

  factory AudioOutputPayload.fromJson(Map<String, Object?> json) {
    final audio = json['audio'];
    final format = json['format'];
    final id = json['id'];
    final isVoiceMode = json['isVoiceMode'];
    final groupId = json['groupId'];
    final chunkIndex = json['chunkIndex'];
    final isLastChunk = json['isLastChunk'];
    if (audio is! String ||
        format is! String ||
        id is! String ||
        isVoiceMode is! bool ||
        (groupId != null && groupId is! String) ||
        (chunkIndex != null && (chunkIndex is! int || chunkIndex.isNegative)) ||
        (isLastChunk != null && isLastChunk is! bool)) {
      throw const FormatException('Invalid audio output payload');
    }
    return AudioOutputPayload(
      audio: audio,
      format: format,
      id: id,
      isVoiceMode: isVoiceMode,
      groupId: groupId as String?,
      chunkIndex: chunkIndex as int?,
      isLastChunk: isLastChunk as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    'audio': audio,
    'format': format,
    'id': id,
    'isVoiceMode': isVoiceMode,
    if (groupId != null) 'groupId': groupId,
    if (chunkIndex != null) 'chunkIndex': chunkIndex,
    if (isLastChunk != null) 'isLastChunk': isLastChunk,
  };
}

final class AudioOutputMessage {
  const AudioOutputMessage({required this.payload});

  static const type = 'audio_output';

  final AudioOutputPayload payload;

  factory AudioOutputMessage.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected audio output message');
    }
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const FormatException('payload must be an object');
    }
    return AudioOutputMessage(payload: AudioOutputPayload.fromJson(payload));
  }

  Map<String, Object?> toJson() => {'type': type, 'payload': payload.toJson()};
}

final class DictationStreamStartMessage {
  const DictationStreamStartMessage({
    required this.dictationId,
    required this.format,
  });

  static const type = 'dictation_stream_start';
  final String dictationId;
  final String format;

  factory DictationStreamStartMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return DictationStreamStartMessage(
      dictationId: _requiredString(json, 'dictationId'),
      format: _requiredString(json, 'format'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'dictationId': dictationId,
    'format': format,
  };
}

final class DictationStreamChunkMessage {
  const DictationStreamChunkMessage({
    required this.dictationId,
    required this.seq,
    required this.audio,
    required this.format,
  });

  static const type = 'dictation_stream_chunk';
  final String dictationId;
  final int seq;
  final String audio;
  final String format;

  factory DictationStreamChunkMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final seq = json['seq'];
    if (seq is! int || seq.isNegative) {
      throw const FormatException('seq must be a non-negative integer');
    }
    return DictationStreamChunkMessage(
      dictationId: _requiredString(json, 'dictationId'),
      seq: seq,
      audio: _requiredString(json, 'audio'),
      format: _requiredString(json, 'format'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'dictationId': dictationId,
    'seq': seq,
    'audio': audio,
    'format': format,
  };
}

final class DictationStreamFinishMessage {
  const DictationStreamFinishMessage({
    required this.dictationId,
    required this.finalSeq,
  });

  static const type = 'dictation_stream_finish';
  final String dictationId;
  final int finalSeq;

  factory DictationStreamFinishMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final finalSeq = json['finalSeq'];
    if (finalSeq is! int || finalSeq.isNegative) {
      throw const FormatException('finalSeq must be a non-negative integer');
    }
    return DictationStreamFinishMessage(
      dictationId: _requiredString(json, 'dictationId'),
      finalSeq: finalSeq,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'dictationId': dictationId,
    'finalSeq': finalSeq,
  };
}

final class DictationStreamCancelMessage {
  const DictationStreamCancelMessage({required this.dictationId});

  static const type = 'dictation_stream_cancel';
  final String dictationId;

  factory DictationStreamCancelMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return DictationStreamCancelMessage(
      dictationId: _requiredString(json, 'dictationId'),
    );
  }

  Map<String, Object?> toJson() => {'type': type, 'dictationId': dictationId};
}

final class VoiceInputStateMessage {
  const VoiceInputStateMessage({required this.isSpeaking});

  static const type = 'voice_input_state';
  final bool isSpeaking;

  factory VoiceInputStateMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    final isSpeaking = payload['isSpeaking'];
    if (isSpeaking is! bool) {
      throw const FormatException('isSpeaking must be a boolean');
    }
    return VoiceInputStateMessage(isSpeaking: isSpeaking);
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'isSpeaking': isSpeaking},
  };
}

final class DictationStreamAckMessage {
  const DictationStreamAckMessage({
    required this.dictationId,
    required this.ackSeq,
  });

  static const type = 'dictation_stream_ack';
  final String dictationId;
  final int ackSeq;

  factory DictationStreamAckMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    final ackSeq = payload['ackSeq'];
    if (ackSeq is! int) {
      throw const FormatException('ackSeq must be an integer');
    }
    return DictationStreamAckMessage(
      dictationId: _requiredString(payload, 'dictationId'),
      ackSeq: ackSeq,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'dictationId': dictationId, 'ackSeq': ackSeq},
  };
}

final class DictationStreamFinishAcceptedMessage {
  const DictationStreamFinishAcceptedMessage({
    required this.dictationId,
    required this.timeoutMs,
  });

  static const type = 'dictation_stream_finish_accepted';
  final String dictationId;
  final int timeoutMs;

  factory DictationStreamFinishAcceptedMessage.fromJson(
    Map<String, Object?> json,
  ) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    final timeoutMs = payload['timeoutMs'];
    if (timeoutMs is! int || timeoutMs <= 0) {
      throw const FormatException('timeoutMs must be a positive integer');
    }
    return DictationStreamFinishAcceptedMessage(
      dictationId: _requiredString(payload, 'dictationId'),
      timeoutMs: timeoutMs,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'dictationId': dictationId, 'timeoutMs': timeoutMs},
  };
}

final class DictationStreamPartialMessage {
  const DictationStreamPartialMessage({
    required this.dictationId,
    required this.text,
  });

  static const type = 'dictation_stream_partial';
  final String dictationId;
  final String text;

  factory DictationStreamPartialMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    return DictationStreamPartialMessage(
      dictationId: _requiredString(payload, 'dictationId'),
      text: _requiredString(payload, 'text'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'dictationId': dictationId, 'text': text},
  };
}

final class DictationStreamFinalMessage {
  const DictationStreamFinalMessage({
    required this.dictationId,
    required this.text,
    this.debugRecordingPath,
  });

  static const type = 'dictation_stream_final';
  final String dictationId;
  final String text;
  final String? debugRecordingPath;

  factory DictationStreamFinalMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    final debugRecordingPath = payload['debugRecordingPath'];
    if (debugRecordingPath != null && debugRecordingPath is! String) {
      throw const FormatException('debugRecordingPath must be a string');
    }
    return DictationStreamFinalMessage(
      dictationId: _requiredString(payload, 'dictationId'),
      text: _requiredString(payload, 'text'),
      debugRecordingPath: debugRecordingPath as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'dictationId': dictationId,
      'text': text,
      if (debugRecordingPath != null) 'debugRecordingPath': debugRecordingPath,
    },
  };
}

final class DictationStreamErrorMessage {
  const DictationStreamErrorMessage({
    required this.dictationId,
    required this.error,
    required this.retryable,
    this.reasonCode,
    this.missingModelIds,
    this.debugRecordingPath,
  });

  static const type = 'dictation_stream_error';
  final String dictationId;
  final String error;
  final bool retryable;
  final String? reasonCode;
  final List<String>? missingModelIds;
  final String? debugRecordingPath;

  factory DictationStreamErrorMessage.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredPayload(json);
    final retryable = payload['retryable'];
    final reasonCode = payload['reasonCode'];
    final missingModelIds = payload['missingModelIds'];
    final debugRecordingPath = payload['debugRecordingPath'];
    if (retryable is! bool ||
        (reasonCode != null && reasonCode is! String) ||
        (missingModelIds != null &&
            (missingModelIds is! List ||
                missingModelIds.any((value) => value is! String))) ||
        (debugRecordingPath != null && debugRecordingPath is! String)) {
      throw const FormatException('Invalid dictation stream error payload');
    }
    return DictationStreamErrorMessage(
      dictationId: _requiredString(payload, 'dictationId'),
      error: _requiredString(payload, 'error'),
      retryable: retryable,
      reasonCode: reasonCode as String?,
      missingModelIds: missingModelIds == null
          ? null
          : List<String>.from(missingModelIds as List),
      debugRecordingPath: debugRecordingPath as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'dictationId': dictationId,
      'error': error,
      'retryable': retryable,
      if (reasonCode != null) 'reasonCode': reasonCode,
      if (missingModelIds != null)
        'missingModelIds': List<String>.from(missingModelIds!),
      if (debugRecordingPath != null) 'debugRecordingPath': debugRecordingPath,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type message');
}

Map<String, Object?> _requiredPayload(Map<String, Object?> json) {
  final payload = json['payload'];
  if (payload is! Map<String, Object?>) {
    throw const FormatException('payload must be an object');
  }
  return payload;
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}
