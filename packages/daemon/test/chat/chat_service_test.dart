import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/chat/chat_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late DateTime now;
  late int id;
  late List<Map<String, Object?>> notifications;
  late FileBackedChatService service;

  setUp(() {
    home = Directory.systemTemp.createTempSync('chat-service-test-');
    now = DateTime.utc(2026, 7, 30);
    id = 0;
    notifications = [];
    service = FileBackedChatService(
      home: home.path,
      now: () => now,
      createId: () => 'id-${++id}',
      notifyMentions:
          ({
            required room,
            required authorAgentId,
            required body,
            required mentionAgentIds,
            required roomPosterAgentIds,
          }) async {
            notifications.add({
              'room': room,
              'author': authorAgentId,
              'body': body,
              'mentions': mentionAgentIds,
              'posters': roomPosterAgentIds,
            });
          },
    );
  });

  tearDown(() {
    service.dispose();
    home.deleteSync(recursive: true);
  });

  test('creates, lists, inspects, persists, and deletes rooms', () async {
    final first = await service.createRoom(
      name: '  Review  ',
      purpose: '  Coordinate review  ',
    );
    now = now.add(const Duration(minutes: 1));
    final second = await service.createRoom(name: 'Ops', purpose: ' ');

    expect(first.name, 'Review');
    expect(first.purpose, 'Coordinate review');
    expect(second.purpose, isNull);
    expect((await service.listRooms()).map((room) => room.name), [
      'Ops',
      'Review',
    ]);
    expect((await service.inspectRoom('review')).id, first.id);
    expect((await service.inspectRoom(second.id)).name, 'Ops');

    final reloaded = FileBackedChatService(home: home.path);
    expect((await reloaded.listRooms()).map((room) => room.name), [
      'Ops',
      'Review',
    ]);
    expect((await reloaded.deleteRoom('Review')).name, 'Review');
    expect((await reloaded.listRooms()).single.name, 'Ops');
    reloaded.dispose();
  });

  test('validates room identity and uniqueness', () async {
    await expectLater(
      service.createRoom(name: ' '),
      throwsA(
        isA<ChatServiceException>().having(
          (error) => error.code,
          'code',
          'invalid_chat_room_name',
        ),
      ),
    );
    await service.createRoom(name: 'Review');
    await expectLater(
      service.createRoom(name: ' review '),
      throwsA(
        isA<ChatServiceException>().having(
          (error) => error.code,
          'code',
          'chat_room_name_taken',
        ),
      ),
    );
    await expectLater(
      service.inspectRoom('missing'),
      throwsA(
        isA<ChatServiceException>().having(
          (error) => error.code,
          'code',
          'chat_room_not_found',
        ),
      ),
    );
  });

  test('posts replies, parses mentions, filters, and limits reads', () async {
    await service.createRoom(name: 'Review');
    final first = await service.postMessage(
      room: 'review',
      authorAgentId: 'agent-1',
      body: ' hello @agent-2 and (@everyone) @agent-2 ',
    );
    now = now.add(const Duration(minutes: 1));
    final second = await service.postMessage(
      room: 'review',
      authorAgentId: 'agent-2',
      body: 'reply',
      replyToMessageId: first.id,
    );
    await Future<void>.delayed(Duration.zero);

    expect(first.body, 'hello @agent-2 and (@everyone) @agent-2');
    expect(first.mentionAgentIds, ['agent-2', 'everyone']);
    expect(second.replyToMessageId, first.id);
    expect((await service.inspectRoom('review')).messageCount, 2);
    expect((await service.readMessages(room: 'review')).length, 2);
    expect(
      (await service.readMessages(room: 'review', limit: 1)).single.id,
      second.id,
    );
    expect(
      (await service.readMessages(
        room: 'review',
        authorAgentId: 'agent-1',
      )).single.id,
      first.id,
    );
    expect(
      (await service.readMessages(
        room: 'review',
        since: second.createdAt,
      )).single.id,
      second.id,
    );
    expect(notifications.single['posters'], isEmpty);
  });

  test('validates message, author, reply, and since fields', () async {
    await service.createRoom(name: 'Review');
    for (final action in <Future<void> Function()>[
      () async {
        await service.postMessage(
          room: 'Review',
          authorAgentId: 'agent',
          body: ' ',
        );
      },
      () async {
        await service.postMessage(
          room: 'Review',
          authorAgentId: ' ',
          body: 'body',
        );
      },
      () async {
        await service.postMessage(
          room: 'Review',
          authorAgentId: 'agent',
          body: 'body',
          replyToMessageId: 'missing',
        );
      },
      () async {
        await service.readMessages(room: 'Review', since: 'invalid');
      },
    ]) {
      await expectLater(action(), throwsA(isA<ChatServiceException>()));
    }
  });

  test('@everyone fanout is bounded before persisting the message', () async {
    await service.createRoom(name: 'Review');
    for (var index = 0; index < chatMentionFanoutLimit + 1; index++) {
      now = now.add(const Duration(seconds: 1));
      await service.postMessage(
        room: 'Review',
        authorAgentId: 'agent-$index',
        body: 'seed',
      );
    }

    await expectLater(
      service.postMessage(
        room: 'Review',
        authorAgentId: 'author',
        body: '@everyone update',
      ),
      throwsA(
        isA<ChatServiceException>().having(
          (error) => error.code,
          'code',
          'chat_mention_fanout_limit_exceeded',
        ),
      ),
    );
    expect((await service.inspectRoom('Review')).messageCount, 26);
  });

  test(
    'wait returns existing/new messages, times out, and rejects deletion',
    () async {
      await service.createRoom(name: 'Review');
      final first = await service.postMessage(
        room: 'Review',
        authorAgentId: 'agent',
        body: 'first',
      );
      final waiting = service.waitForMessages(
        room: 'Review',
        afterMessageId: first.id,
        timeoutMs: 1000,
      );
      final next = await service.postMessage(
        room: 'Review',
        authorAgentId: 'agent',
        body: 'next',
      );
      expect((await waiting).single.id, next.id);
      expect(
        await service.waitForMessages(room: 'Review', afterMessageId: first.id),
        [next],
      );
      expect(
        await service.waitForMessages(
          room: 'Review',
          afterMessageId: next.id,
          timeoutMs: 1,
        ),
        isEmpty,
      );
      await expectLater(
        service.waitForMessages(room: 'Review', afterMessageId: 'missing'),
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            'chat_message_not_found',
          ),
        ),
      );
      final deletedWait = service.waitForMessages(
        room: 'Review',
        afterMessageId: next.id,
      );
      await service.deleteRoom('Review');
      await expectLater(
        deletedWait,
        throwsA(
          isA<ChatServiceException>().having(
            (error) => error.code,
            'code',
            'chat_room_deleted',
          ),
        ),
      );
    },
  );

  test('RPC handler returns exact responses and structured errors', () async {
    final created = await service.handle({
      'type': 'chat/create',
      'requestId': 'create-1',
      'name': 'Review',
    });
    expect(created!['type'], 'chat/create/response');
    final list = await service.handle({
      'type': 'chat/list',
      'requestId': 'list-1',
    });
    expect((list!['payload'] as Map)['rooms'], hasLength(1));
    final posted = await service.handle({
      'type': 'chat/post',
      'requestId': 'post-1',
      'room': 'Review',
      'body': 'hello',
      'authorAgentId': 'agent',
    });
    expect(posted!['type'], 'chat/post/response');
    final clientAuthored = await service.handle({
      'type': 'chat/post',
      'requestId': 'post-2',
      'room': 'Review',
      'body': 'from client',
    }, defaultAuthorAgentId: 'client-agent');
    expect(
      ((clientAuthored!['payload'] as Map)['message'] as Map)['authorAgentId'],
      'client-agent',
    );
    final read = await service.handle({
      'type': 'chat/read',
      'requestId': 'read-1',
      'room': 'Review',
    });
    expect((read!['payload'] as Map)['messages'], hasLength(2));
    final failure = await service.handle({
      'type': 'chat/inspect',
      'requestId': 'inspect-1',
      'room': 'missing',
    });
    expect(failure!['type'], 'rpc_error');
    expect((failure['payload'] as Map)['code'], 'chat_room_not_found');
    expect(await service.handle({'type': 'other'}), isNull);
  });

  test('loads corrupt stores best-effort and rewrites valid state', () async {
    final file = File(p.join(home.path, 'chat', 'rooms.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString('{invalid');
    final errors = <Object>[];
    final recovered = FileBackedChatService(
      home: home.path,
      onError: (error, _) => errors.add(error),
      createId: () => 'recovered',
    );
    expect(await recovered.listRooms(), isEmpty);
    expect(errors, hasLength(1));
    await recovered.createRoom(name: 'Recovered');
    expect(jsonDecode(await file.readAsString()), isA<Map>());
    recovered.dispose();
  });

  test('mention helpers match Paseo syntax and notification copy', () {
    expect(
      parseChatMentionAgentIds(
        '@beta hi (@alpha) email@example.com @beta @bad!',
      ),
      ['alpha', 'bad', 'beta'],
    );
    expect(
      buildChatMentionNotification(
        room: 'review',
        authorAgentId: 'agent-1',
        body: '@agent-2 please review',
        mentionAgentIds: const ['agent-2'],
      ),
      contains('Message:\nplease review'),
    );
    expect(
      buildChatMentionNotification(
        room: 'review',
        authorAgentId: 'agent-1',
        body: '@agent-2',
        mentionAgentIds: const ['agent-2'],
      ),
      contains('Message:\n@agent-2'),
    );
  });
}
