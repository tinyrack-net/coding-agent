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
