import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

const chatMentionFanoutLimit = 25;

final class ChatServiceException implements Exception {
  const ChatServiceException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

typedef ChatMentionNotifier =
    Future<void> Function({
      required String room,
      required String authorAgentId,
      required String body,
      required List<String> mentionAgentIds,
      required List<String> roomPosterAgentIds,
    });

typedef ChatMentionPreparer =
    Future<List<String>> Function({
      required String room,
      required String authorAgentId,
      required String body,
      required List<String> mentionAgentIds,
      required List<String> roomPosterAgentIds,
    });

final class FileBackedChatService {
  FileBackedChatService({
    required String home,
    DateTime Function()? now,
    String Function()? createId,
    this.prepareMentions,
    this.notifyMentions,
    this.onError,
  }) : _file = File(p.join(home, 'chat', 'rooms.json')),
       _now = now ?? DateTime.now,
       _createId = createId ?? const Uuid().v4;

  final File _file;
  final DateTime Function() _now;
  final String Function() _createId;
  final ChatMentionPreparer? prepareMentions;
  final ChatMentionNotifier? notifyMentions;
  final void Function(Object error, StackTrace stack)? onError;
  final Map<String, ChatRoom> _rooms = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, Set<_ChatWaiter>> _waiters = {};
  Future<void> _persistQueue = Future<void>.value();
  Future<void>? _loadFuture;

  Future<void> initialize() => _load();

  void dispose() {
    for (final roomId in _waiters.keys.toList(growable: false)) {
      _rejectWaiters(
        roomId,
        const ChatServiceException(
          'chat_service_stopped',
          'Chat service stopped',
        ),
      );
    }
  }

  Future<ChatRoomDetail> createRoom({
    required String name,
    String? purpose,
  }) async {
    await _load();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const ChatServiceException(
        'invalid_chat_room_name',
        'Chat room name is required',
      );
    }
    if (_rooms.values.any(
      (room) => _normalize(room.name) == _normalize(trimmedName),
    )) {
      throw ChatServiceException(
        'chat_room_name_taken',
        'Chat room already exists with name: $trimmedName',
      );
    }
    final timestamp = _now().toUtc().toIso8601String();
    final room = ChatRoom(
      id: _createId(),
      name: trimmedName,
      purpose: _trimToNull(purpose),
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _rooms[room.id] = room;
    await _enqueuePersist();
    return _detail(room);
  }

  Future<List<ChatRoomDetail>> listRooms() async {
    await _load();
    return _rooms.values.map(_detail).toList()
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  }

  Future<ChatRoomDetail> inspectRoom(String selector) async {
    await _load();
    return _detail(_resolveRoom(selector));
  }

  Future<ChatRoomDetail> deleteRoom(String selector) async {
    await _load();
    final room = _resolveRoom(selector);
    final detail = _detail(room);
    _rooms.remove(room.id);
    _messages.remove(room.id);
    await _enqueuePersist();
    _rejectWaiters(
      room.id,
      ChatServiceException(
        'chat_room_deleted',
        'Chat room deleted: ${room.name}',
      ),
    );
    return detail;
  }

  Future<ChatMessage> postMessage({
    required String room,
    required String authorAgentId,
    required String body,
    String? replyToMessageId,
  }) async {
    await _load();
    final resolvedRoom = _resolveRoom(room);
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      throw const ChatServiceException(
        'invalid_chat_message',
        'Chat message body is required',
      );
    }
    final author = authorAgentId.trim();
    if (author.isEmpty) {
      throw const ChatServiceException(
        'invalid_chat_author',
        'Chat message author is required',
      );
    }
    final messages = _messages.putIfAbsent(resolvedRoom.id, () => []);
    final replyTo = _trimToNull(replyToMessageId);
    if (replyTo != null && !messages.any((entry) => entry.id == replyTo)) {
      throw ChatServiceException(
        'chat_message_not_found',
        'Reply target not found: $replyTo',
      );
    }
    final mentions = parseChatMentionAgentIds(trimmedBody);
    final posters = messages
        .map((entry) => entry.authorAgentId)
        .toSet()
        .toList(growable: false);
    final preparedMentions = await (prepareMentions ?? _prepareMentionsDefault)(
      room: room,
      authorAgentId: author,
      body: trimmedBody,
      mentionAgentIds: mentions,
      roomPosterAgentIds: posters,
    );
    final timestamp = _now().toUtc().toIso8601String();
    final message = ChatMessage(
      id: _createId(),
      roomId: resolvedRoom.id,
      authorAgentId: author,
      body: trimmedBody,
      replyToMessageId: replyTo,
      mentionAgentIds: mentions,
      createdAt: timestamp,
    );
    messages.add(message);
    _rooms[resolvedRoom.id] = ChatRoom(
      id: resolvedRoom.id,
      name: resolvedRoom.name,
      purpose: resolvedRoom.purpose,
      createdAt: resolvedRoom.createdAt,
      updatedAt: timestamp,
    );
    await _enqueuePersist();
    _notifyWaiters(resolvedRoom.id);
    final notifier = notifyMentions;
    if (notifier != null && mentions.isNotEmpty) {
      unawaited(
        notifier(
          room: room,
          authorAgentId: author,
          body: trimmedBody,
          mentionAgentIds: preparedMentions,
          roomPosterAgentIds: posters,
        ).catchError((Object error, StackTrace stack) {
          onError?.call(error, stack);
        }),
      );
    }
    return message;
  }

  Future<List<ChatMessage>> readMessages({
    required String room,
    int? limit,
    String? since,
    String? authorAgentId,
  }) async {
    await _load();
    final resolved = _resolveRoom(room);
    final normalizedSince = _trimToNull(since);
    if (normalizedSince != null && DateTime.tryParse(normalizedSince) == null) {
      throw const ChatServiceException(
        'invalid_chat_since',
        'Chat message since must be an ISO timestamp',
      );
    }
    final author = _trimToNull(authorAgentId);
    final filtered = _messagesFor(resolved.id)
        .where(
          (message) =>
              (normalizedSince == null ||
                  message.createdAt.compareTo(normalizedSince) >= 0) &&
              (author == null || message.authorAgentId == author),
        )
        .toList(growable: false);
    final normalizedLimit = limit == null
        ? 20
        : limit < 0
        ? 0
        : limit;
    if (normalizedLimit == 0 || filtered.length <= normalizedLimit) {
      return filtered;
    }
    return filtered.sublist(filtered.length - normalizedLimit);
  }

  Future<List<ChatMessage>> waitForMessages({
    required String room,
    String? afterMessageId,
    int? timeoutMs,
  }) async {
    await _load();
    final resolved = _resolveRoom(room);
    final after = _trimToNull(afterMessageId);
    if (after != null) {
      final existing = _after(resolved.id, after);
      if (existing.isNotEmpty) return existing;
      if (!_messagesFor(resolved.id).any((message) => message.id == after)) {
        throw ChatServiceException(
          'chat_message_not_found',
          'Wait cursor not found: $after',
        );
      }
    }
    final completer = Completer<List<ChatMessage>>();
    final waiter = _ChatWaiter(
      roomId: resolved.id,
      afterMessageId: after,
      completer: completer,
    );
    _waiters.putIfAbsent(resolved.id, () => {}).add(waiter);
    final duration = Duration(milliseconds: (timeoutMs ?? 0).clamp(0, 1 << 31));
    if (duration > Duration.zero) {
      waiter.timer = Timer(duration, () => _resolveWaiter(waiter, const []));
    }
    return completer.future;
  }

  Future<Map<String, Object?>?> handle(
    Map<String, Object?> message, {
    String defaultAuthorAgentId = 'manual',
  }) async {
    final type = message['type'];
    if (type is! String || !type.startsWith('chat/')) return null;
    final requestId = message['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    try {
      final payload = switch (type) {
        ChatCreateRequest.typeName => {
          'room': (await createRoom(
            name: ChatCreateRequest.fromJson(message).name,
            purpose: ChatCreateRequest.fromJson(message).purpose,
          )).toJson(),
          'error': null,
        },
        ChatListRequest.typeName => () {
          ChatListRequest.fromJson(message);
          return <String, Object?>{'rooms': null};
        }(),
        ChatRoomRequest.inspectType => {
          'room': (await inspectRoom(
            ChatRoomRequest.fromJson(message).room,
          )).toJson(),
          'error': null,
        },
        ChatRoomRequest.deleteType => {
          'room': (await deleteRoom(
            ChatRoomRequest.fromJson(message).room,
          )).toJson(),
          'error': null,
        },
        ChatPostRequest.typeName => await _handlePost(
          message,
          defaultAuthorAgentId,
        ),
        ChatReadRequest.typeName => await _handleRead(message),
        ChatWaitRequest.typeName => await _handleWait(message),
        _ => throw StateError('Unsupported chat request $type'),
      };
      if (type == ChatListRequest.typeName) {
        payload['rooms'] = (await listRooms())
            .map((room) => room.toJson())
            .toList(growable: false);
        payload['error'] = null;
      }
      return chatResponse(
        requestType: type,
        requestId: requestId,
        payload: payload,
      );
    } on Object catch (error) {
      final code = error is ChatServiceException
          ? error.code
          : 'chat_request_failed';
      final text = error is ChatServiceException ? error.message : '$error';
      return {
        'type': 'rpc_error',
        'payload': {
          'requestId': requestId,
          'requestType': type,
          'error': text,
          'code': code,
        },
      };
    }
  }

  Future<Map<String, Object?>> _handlePost(
    Map<String, Object?> json,
    String defaultAuthorAgentId,
  ) async {
    final request = ChatPostRequest.fromJson(json);
    return {
      'message': (await postMessage(
        room: request.room,
        body: request.body,
        authorAgentId: request.authorAgentId ?? defaultAuthorAgentId,
        replyToMessageId: request.replyToMessageId,
      )).toJson(),
      'error': null,
    };
  }

  Future<Map<String, Object?>> _handleRead(Map<String, Object?> json) async {
    final request = ChatReadRequest.fromJson(json);
    return {
      'messages': (await readMessages(
        room: request.room,
        limit: request.limit,
        since: request.since,
        authorAgentId: request.authorAgentId,
      )).map((message) => message.toJson()).toList(growable: false),
      'error': null,
    };
  }

  Future<Map<String, Object?>> _handleWait(Map<String, Object?> json) async {
    final request = ChatWaitRequest.fromJson(json);
    final messages = await waitForMessages(
      room: request.room,
      afterMessageId: request.afterMessageId,
      timeoutMs: request.timeoutMs,
    );
    return {
      'messages': messages
          .map((message) => message.toJson())
          .toList(growable: false),
      'timedOut': messages.isEmpty,
      'error': null,
    };
  }

  Future<void> _load() => _loadFuture ??= _loadOnce();

  Future<void> _loadOnce() async {
    if (!await _file.exists()) return;
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) throw const FormatException('chat store');
      final rooms = decoded['rooms'];
      final messages = decoded['messages'];
      if (rooms is! List || messages is! List) {
        throw const FormatException('chat store arrays');
      }
      for (final value in rooms) {
        final room = ChatRoom.fromJson(Map<String, Object?>.from(value as Map));
        _rooms[room.id] = room;
      }
      for (final value in messages) {
        final message = ChatMessage.fromJson(
          Map<String, Object?>.from(value as Map),
        );
        _messages.putIfAbsent(message.roomId, () => []).add(message);
      }
    } on Object catch (error, stack) {
      onError?.call(error, stack);
    }
  }

  Future<void> _enqueuePersist() {
    final next = _persistQueue.then((_) => _persist());
    _persistQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _persist() async {
    await _file.parent.create(recursive: true);
    final rooms = _rooms.values.toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final messages = _messages.values.expand((entries) => entries).toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final temporary = File('${_file.path}.tmp-$pid');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'rooms': rooms.map((room) => room.toJson()).toList(), 'messages': messages.map((message) => message.toJson()).toList()})}\n',
      flush: true,
    );
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }

  ChatRoom _resolveRoom(String selector) {
    final value = selector.trim();
    if (value.isEmpty) {
      throw const ChatServiceException(
        'invalid_chat_room',
        'Chat room name or ID is required',
      );
    }
    final byId = _rooms[value];
    if (byId != null) return byId;
    for (final room in _rooms.values) {
      if (_normalize(room.name) == _normalize(value)) return room;
    }
    throw ChatServiceException(
      'chat_room_not_found',
      'Chat room not found: $value',
    );
  }

  List<ChatMessage> _messagesFor(String roomId) =>
      _messages[roomId] ?? const [];

  ChatRoomDetail _detail(ChatRoom room) {
    final messages = _messagesFor(room.id);
    return ChatRoomDetail(
      id: room.id,
      name: room.name,
      purpose: room.purpose,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt,
      messageCount: messages.length,
      lastMessageAt: messages.isEmpty ? null : messages.last.createdAt,
    );
  }

  List<ChatMessage> _after(String roomId, String messageId) {
    final messages = _messagesFor(roomId);
    final index = messages.indexWhere((message) => message.id == messageId);
    return index < 0 ? const [] : messages.sublist(index + 1);
  }

  void _notifyWaiters(String roomId) {
    for (final waiter in _waiters[roomId]?.toList() ?? const <_ChatWaiter>[]) {
      final messages = waiter.afterMessageId == null
          ? _messagesFor(roomId).reversed.take(1).toList().reversed.toList()
          : _after(roomId, waiter.afterMessageId!);
      if (messages.isNotEmpty) _resolveWaiter(waiter, messages);
    }
  }

  void _resolveWaiter(_ChatWaiter waiter, List<ChatMessage> messages) {
    waiter.timer?.cancel();
    final roomWaiters = _waiters[waiter.roomId];
    roomWaiters?.remove(waiter);
    if (roomWaiters?.isEmpty ?? false) _waiters.remove(waiter.roomId);
    if (!waiter.completer.isCompleted) waiter.completer.complete(messages);
  }

  void _rejectWaiters(String roomId, Object error) {
    final waiters = _waiters.remove(roomId)?.toList() ?? const <_ChatWaiter>[];
    for (final waiter in waiters) {
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
  }
}

Future<List<String>> _prepareMentionsDefault({
  required String room,
  required String authorAgentId,
  required String body,
  required List<String> mentionAgentIds,
  required List<String> roomPosterAgentIds,
}) async {
  final targets = <String>{
    for (final mention in mentionAgentIds)
      if (mention != 'everyone') mention,
    if (mentionAgentIds.contains('everyone')) ...roomPosterAgentIds,
  }..remove(authorAgentId);
  if (mentionAgentIds.contains('everyone') &&
      targets.length > chatMentionFanoutLimit) {
    throw ChatServiceException(
      'chat_mention_fanout_limit_exceeded',
      '@everyone would notify ${targets.length} agents, which exceeds '
          'the limit of $chatMentionFanoutLimit. Narrow the room or '
          'mention specific agents.',
    );
  }
  return targets.toList(growable: false);
}

final class _ChatWaiter {
  _ChatWaiter({
    required this.roomId,
    required this.afterMessageId,
    required this.completer,
  });
  final String roomId;
  final String? afterMessageId;
  final Completer<List<ChatMessage>> completer;
  Timer? timer;
}

List<String> parseChatMentionAgentIds(String body) {
  final pattern = RegExp(r'(?:^|[\s(])@([A-Za-z0-9][A-Za-z0-9._-]*)');
  return {
    for (final match in pattern.allMatches(body))
      if (match.group(1)?.trim() case final value? when value.isNotEmpty) value,
  }.toList()..sort();
}

String buildChatMentionNotification({
  required String room,
  required String authorAgentId,
  required String body,
  required List<String> mentionAgentIds,
}) {
  final mentioned = mentionAgentIds.map((id) => '@$id').join(', ');
  final withoutMentions = body
      .replaceAllMapped(
        RegExp(r'(^|\s)@[A-Za-z0-9][A-Za-z0-9._-]*'),
        (match) => match.group(1) ?? '',
      )
      .trim();
  return [
    'Chat mention from $authorAgentId in room "$room".',
    'Mentioned agents: $mentioned.',
    'Message:',
    withoutMentions.isEmpty ? body : withoutMentions,
    'Read the room with: coding-agent chat read $room --limit 20',
  ].join('\n');
}

String _normalize(String value) => value.trim().toLowerCase();

String? _trimToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
