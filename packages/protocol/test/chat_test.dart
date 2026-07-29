import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const timestamp = '2026-07-30T00:00:00.000Z';

  test('chat room and message wire models round trip', () {
    final baseRoom = ChatRoom.fromJson({
      'id': 'room-1',
      'name': 'Review',
      'purpose': 'Coordinate',
      'createdAt': timestamp,
      'updatedAt': timestamp,
    });
    expect(baseRoom.toJson(), {
      'id': 'room-1',
      'name': 'Review',
      'purpose': 'Coordinate',
      'createdAt': timestamp,
      'updatedAt': timestamp,
    });
    final room = ChatRoomDetail.fromJson({
      'id': 'room-1',
      'name': 'Review',
      'purpose': null,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'messageCount': 1,
      'lastMessageAt': timestamp,
    });
    expect(room.toJson(), {
      'id': 'room-1',
      'name': 'Review',
      'purpose': null,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'messageCount': 1,
      'lastMessageAt': timestamp,
    });

    final message = ChatMessage.fromJson({
      'id': 'message-1',
      'roomId': 'room-1',
      'authorAgentId': 'agent-1',
      'body': 'hello @agent-2',
      'replyToMessageId': null,
      'mentionAgentIds': ['agent-2'],
      'createdAt': timestamp,
    });
    expect(message.toJson()['mentionAgentIds'], ['agent-2']);
  });

  test('all chat request shapes match frozen wire names', () {
    final requests = <ChatRequest>[
      const ChatCreateRequest(requestId: '1', name: 'room', purpose: 'purpose'),
      const ChatListRequest(requestId: '2'),
      const ChatRoomRequest(
        requestId: '3',
        typeValue: ChatRoomRequest.inspectType,
        room: 'room',
      ),
      const ChatRoomRequest(
        requestId: '4',
        typeValue: ChatRoomRequest.deleteType,
        room: 'room',
      ),
      const ChatPostRequest(
        requestId: '5',
        room: 'room',
        body: 'body',
        authorAgentId: 'agent',
        replyToMessageId: 'parent',
      ),
      const ChatReadRequest(
        requestId: '6',
        room: 'room',
        limit: 20,
        since: timestamp,
        authorAgentId: 'agent',
      ),
      const ChatWaitRequest(
        requestId: '7',
        room: 'room',
        afterMessageId: 'message',
        timeoutMs: 1000,
      ),
    ];
    expect(requests.map((request) => request.type), [
      'chat/create',
      'chat/list',
      'chat/inspect',
      'chat/delete',
      'chat/post',
      'chat/read',
      'chat/wait',
    ]);
    expect(ChatCreateRequest.fromJson(requests[0].toJson()).purpose, 'purpose');
    expect(ChatListRequest.fromJson(requests[1].toJson()).requestId, '2');
    expect(ChatRoomRequest.fromJson(requests[2].toJson()).room, 'room');
    expect(ChatPostRequest.fromJson(requests[4].toJson()).body, 'body');
    expect(ChatReadRequest.fromJson(requests[5].toJson()).limit, 20);
    expect(ChatWaitRequest.fromJson(requests[6].toJson()).timeoutMs, 1000);
  });

  test('chat schemas reject invalid boundaries', () {
    expect(
      () => ChatRoomDetail.fromJson({
        'id': 'room',
        'name': 'name',
        'purpose': null,
        'createdAt': 'invalid',
        'updatedAt': timestamp,
        'messageCount': -1,
        'lastMessageAt': null,
      }),
      throwsFormatException,
    );
    expect(
      () => ChatRoomRequest.fromJson({
        'type': 'chat/nope',
        'requestId': '1',
        'room': 'room',
      }),
      throwsFormatException,
    );
    expect(
      () => ChatReadRequest.fromJson({
        'type': 'chat/read',
        'requestId': '1',
        'room': 'room',
        'limit': -1,
      }),
      throwsFormatException,
    );
    expect(
      () => ChatRoom.fromJson({
        'id': 'room',
        'name': 'name',
        'purpose': 42,
        'createdAt': timestamp,
        'updatedAt': timestamp,
      }),
      throwsFormatException,
    );
    expect(
      () => ChatMessage.fromJson({
        'id': 'message',
        'roomId': 'room',
        'authorAgentId': 'agent',
        'body': 'body',
        'replyToMessageId': null,
        'mentionAgentIds': [42],
        'createdAt': timestamp,
      }),
      throwsFormatException,
    );
  });

  test('response wrapper retains request correlation', () {
    expect(
      chatResponse(
        requestType: ChatWaitRequest.typeName,
        requestId: 'request-1',
        payload: {'messages': const [], 'timedOut': true, 'error': null},
      ),
      {
        'type': 'chat/wait/response',
        'payload': {
          'requestId': 'request-1',
          'messages': const [],
          'timedOut': true,
          'error': null,
        },
      },
    );
  });
}
