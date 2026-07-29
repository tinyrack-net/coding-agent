final class ChatRoom {
  const ChatRoom({
    required this.id,
    required this.name,
    required this.purpose,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? purpose;
  final String createdAt;
  final String updatedAt;

  factory ChatRoom.fromJson(Map<String, Object?> json) => ChatRoom(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    purpose: _nullableString(json, 'purpose'),
    createdAt: _timestamp(json, 'createdAt'),
    updatedAt: _timestamp(json, 'updatedAt'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'purpose': purpose,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
}

final class ChatRoomDetail {
  const ChatRoomDetail({
    required this.id,
    required this.name,
    required this.purpose,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
    required this.lastMessageAt,
  });

  final String id;
  final String name;
  final String? purpose;
  final String createdAt;
  final String updatedAt;
  final int messageCount;
  final String? lastMessageAt;

  factory ChatRoomDetail.fromJson(Map<String, Object?> json) => ChatRoomDetail(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    purpose: _nullableString(json, 'purpose'),
    createdAt: _timestamp(json, 'createdAt'),
    updatedAt: _timestamp(json, 'updatedAt'),
    messageCount: _nonNegativeInt(json, 'messageCount'),
    lastMessageAt: _nullableTimestamp(json, 'lastMessageAt'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'purpose': purpose,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'messageCount': messageCount,
    'lastMessageAt': lastMessageAt,
  };
}

final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.roomId,
    required this.authorAgentId,
    required this.body,
    required this.replyToMessageId,
    required this.mentionAgentIds,
    required this.createdAt,
  });

  final String id;
  final String roomId;
  final String authorAgentId;
  final String body;
  final String? replyToMessageId;
  final List<String> mentionAgentIds;
  final String createdAt;

  factory ChatMessage.fromJson(Map<String, Object?> json) => ChatMessage(
    id: _string(json, 'id'),
    roomId: _string(json, 'roomId'),
    authorAgentId: _string(json, 'authorAgentId'),
    body: _string(json, 'body'),
    replyToMessageId: _nullableString(json, 'replyToMessageId'),
    mentionAgentIds: _strings(json, 'mentionAgentIds'),
    createdAt: _timestamp(json, 'createdAt'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'roomId': roomId,
    'authorAgentId': authorAgentId,
    'body': body,
    'replyToMessageId': replyToMessageId,
    'mentionAgentIds': mentionAgentIds,
    'createdAt': createdAt,
  };
}

sealed class ChatRequest {
  const ChatRequest({required this.requestId});
  final String requestId;
  String get type;
  Map<String, Object?> toJson();
}

final class ChatCreateRequest extends ChatRequest {
  const ChatCreateRequest({
    required super.requestId,
    required this.name,
    this.purpose,
  });
  static const typeName = 'chat/create';
  final String name;
  final String? purpose;
  @override
  String get type => typeName;
  factory ChatCreateRequest.fromJson(Map<String, Object?> json) =>
      ChatCreateRequest(
        requestId: _request(json, typeName),
        name: _string(json, 'name'),
        purpose: _optionalString(json, 'purpose'),
      );
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'name': name,
    if (purpose != null) 'purpose': purpose,
  };
}

final class ChatListRequest extends ChatRequest {
  const ChatListRequest({required super.requestId});
  static const typeName = 'chat/list';
  @override
  String get type => typeName;
  factory ChatListRequest.fromJson(Map<String, Object?> json) =>
      ChatListRequest(requestId: _request(json, typeName));
  @override
  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class ChatRoomRequest extends ChatRequest {
  const ChatRoomRequest({
    required super.requestId,
    required this.typeValue,
    required this.room,
  });
  static const inspectType = 'chat/inspect';
  static const deleteType = 'chat/delete';
  final String typeValue;
  final String room;
  @override
  String get type => typeValue;
  factory ChatRoomRequest.fromJson(Map<String, Object?> json) {
    final type = _string(json, 'type');
    if (type != inspectType && type != deleteType) {
      throw FormatException('invalid chat room request type: $type');
    }
    return ChatRoomRequest(
      requestId: _request(json, type),
      typeValue: type,
      room: _string(json, 'room'),
    );
  }
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'room': room,
  };
}

final class ChatPostRequest extends ChatRequest {
  const ChatPostRequest({
    required super.requestId,
    required this.room,
    required this.body,
    this.authorAgentId,
    this.replyToMessageId,
  });
  static const typeName = 'chat/post';
  final String room;
  final String body;
  final String? authorAgentId;
  final String? replyToMessageId;
  @override
  String get type => typeName;
  factory ChatPostRequest.fromJson(Map<String, Object?> json) =>
      ChatPostRequest(
        requestId: _request(json, typeName),
        room: _string(json, 'room'),
        body: _string(json, 'body'),
        authorAgentId: _optionalString(json, 'authorAgentId'),
        replyToMessageId: _optionalString(json, 'replyToMessageId'),
      );
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'room': room,
    'body': body,
    if (authorAgentId != null) 'authorAgentId': authorAgentId,
    if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
  };
}

final class ChatReadRequest extends ChatRequest {
  const ChatReadRequest({
    required super.requestId,
    required this.room,
    this.limit,
    this.since,
    this.authorAgentId,
  });
  static const typeName = 'chat/read';
  final String room;
  final int? limit;
  final String? since;
  final String? authorAgentId;
  @override
  String get type => typeName;
  factory ChatReadRequest.fromJson(Map<String, Object?> json) =>
      ChatReadRequest(
        requestId: _request(json, typeName),
        room: _string(json, 'room'),
        limit: _optionalNonNegativeInt(json, 'limit'),
        since: _optionalString(json, 'since'),
        authorAgentId: _optionalString(json, 'authorAgentId'),
      );
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'room': room,
    if (limit != null) 'limit': limit,
    if (since != null) 'since': since,
    if (authorAgentId != null) 'authorAgentId': authorAgentId,
  };
}

final class ChatWaitRequest extends ChatRequest {
  const ChatWaitRequest({
    required super.requestId,
    required this.room,
    this.afterMessageId,
    this.timeoutMs,
  });
  static const typeName = 'chat/wait';
  final String room;
  final String? afterMessageId;
  final int? timeoutMs;
  @override
  String get type => typeName;
  factory ChatWaitRequest.fromJson(Map<String, Object?> json) =>
      ChatWaitRequest(
        requestId: _request(json, typeName),
        room: _string(json, 'room'),
        afterMessageId: _optionalString(json, 'afterMessageId'),
        timeoutMs: _optionalNonNegativeInt(json, 'timeoutMs'),
      );
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'room': room,
    if (afterMessageId != null) 'afterMessageId': afterMessageId,
    if (timeoutMs != null) 'timeoutMs': timeoutMs,
  };
}

Map<String, Object?> chatResponse({
  required String requestType,
  required String requestId,
  required Map<String, Object?> payload,
}) => {
  'type': '$requestType/response',
  'payload': {'requestId': requestId, ...payload},
};

String _request(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('expected type $type');
  return _string(json, 'requestId');
}

String _string(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  if (!json.containsKey(field)) return null;
  return _string(json, field);
}

String? _nullableString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String)
    throw FormatException('$field must be a string or null');
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int || value < 0) {
    throw FormatException('$field must be a non-negative integer');
  }
  return value;
}

int? _optionalNonNegativeInt(Map<String, Object?> json, String field) {
  if (!json.containsKey(field)) return null;
  return _nonNegativeInt(json, field);
}

List<String> _strings(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$field must be an array of strings');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

String _timestamp(Map<String, Object?> json, String field) {
  return _string(json, field);
}

String? _nullableTimestamp(Map<String, Object?> json, String field) {
  return _nullableString(json, field);
}
