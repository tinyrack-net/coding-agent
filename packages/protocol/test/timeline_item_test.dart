import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('UserMessageItem', () {
    test('round-trips', () {
      const item = UserMessageItem(
        id: 'i1',
        text: 'hello',
        clientMessageId: 'client-1',
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      expect(decoded, isA<UserMessageItem>());
      expect(decoded.id, 'i1');
      expect(decoded.kind, 'user_message');
      expect((decoded as UserMessageItem).text, 'hello');
      expect(decoded.clientMessageId, 'client-1');
    });

    test('fromJson defaults text to empty string', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'i1',
        'kind': 'user_message',
      });
      expect((decoded as UserMessageItem).text, '');
    });

    test('round-trips structured text attachments', () {
      const item = UserMessageItem(
        id: 'i1',
        text: 'Review this',
        attachments: [
          TextAgentAttachment(title: 'PR comment', text: 'context'),
        ],
      );
      final decoded =
          TimelineItem.fromJson(roundTrip(item.toJson())) as UserMessageItem;
      expect(decoded.attachments, hasLength(1));
      expect((decoded.attachments.single as TextAgentAttachment).toJson(), {
        'type': 'text',
        'mimeType': 'text/plain',
        'title': 'PR comment',
        'text': 'context',
      });
    });
  });

  group('AssistantMessageItem', () {
    test('round-trips complete and incomplete', () {
      const complete = AssistantMessageItem(
        id: 'i1',
        text: 'done',
        complete: true,
      );
      const streaming = AssistantMessageItem(
        id: 'i2',
        text: 'partial',
        complete: false,
      );
      final d1 = TimelineItem.fromJson(roundTrip(complete.toJson()));
      final d2 = TimelineItem.fromJson(roundTrip(streaming.toJson()));
      expect((d1 as AssistantMessageItem).complete, isTrue);
      expect((d2 as AssistantMessageItem).complete, isFalse);
    });

    test('fromJson defaults complete to true when missing', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'i1',
        'kind': 'assistant_message',
      });
      expect((decoded as AssistantMessageItem).complete, isTrue);
    });
  });

  group('ReasoningItem', () {
    test('round-trips', () {
      const item = ReasoningItem(
        id: 'i1',
        text: 'thinking...',
        complete: false,
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      expect(decoded, isA<ReasoningItem>());
      expect((decoded as ReasoningItem).text, 'thinking...');
      expect(decoded.complete, isFalse);
    });
  });

  group('ToolCallItem', () {
    test('round-trips with shell detail', () {
      const item = ToolCallItem(
        id: 'i1',
        toolName: 'bash',
        status: ToolCallStatus.success,
        detail: ShellDetail(command: 'ls', output: 'a.txt', exitCode: 0),
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      expect(decoded, isA<ToolCallItem>());
      final tool = decoded as ToolCallItem;
      expect(tool.toolName, 'bash');
      expect(tool.status, ToolCallStatus.success);
      expect(tool.detail, isA<ShellDetail>());
      expect((tool.detail as ShellDetail).command, 'ls');
    });

    test('fromJson defaults status/detail when missing', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'i1',
        'kind': 'tool_call',
      });
      final tool = decoded as ToolCallItem;
      expect(tool.toolName, '');
      expect(tool.status, ToolCallStatus.pending);
      expect(tool.detail, isA<GenericDetail>());
    });

    test('fromJson throws on unknown status', () {
      expect(
        () => TimelineItem.fromJson(const {
          'id': 'i1',
          'kind': 'tool_call',
          'status': 'bogus',
        }),
        throwsArgumentError,
      );
    });
  });

  group('TurnItem', () {
    test('round-trips with error message', () {
      const item = TurnItem(
        id: 'i1',
        phase: TurnPhase.failed,
        errorMessage: 'oops',
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      final turn = decoded as TurnItem;
      expect(turn.phase, TurnPhase.failed);
      expect(turn.errorMessage, 'oops');
    });

    test('omits errorMessage from json when null', () {
      const item = TurnItem(id: 'i1', phase: TurnPhase.completed);
      expect(item.toJson().containsKey('errorMessage'), isFalse);
    });

    test('fromJson defaults phase to started when missing', () {
      final decoded = TimelineItem.fromJson(const {'id': 'i1', 'kind': 'turn'});
      expect((decoded as TurnItem).phase, TurnPhase.started);
      expect(decoded.errorMessage, isNull);
    });
  });

  group('PermissionItem', () {
    test('round-trips with edit detail', () {
      const item = PermissionItem(
        id: 'i1',
        permissionId: 'p1',
        toolName: 'edit',
        status: PermissionStatus.allowed,
        detail: EditDetail(path: 'lib/a.dart', diff: '+ line'),
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      final perm = decoded as PermissionItem;
      expect(perm.permissionId, 'p1');
      expect(perm.status, PermissionStatus.allowed);
      expect(perm.detail, isA<EditDetail>());
      expect((perm.detail as EditDetail).diff, '+ line');
    });

    test('fromJson defaults status to pending when missing', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'i1',
        'kind': 'permission',
      });
      expect((decoded as PermissionItem).status, PermissionStatus.pending);
    });
  });

  group('ErrorItem', () {
    test('round-trips', () {
      const item = ErrorItem(id: 'i1', message: 'boom');
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      expect(decoded, isA<ErrorItem>());
      expect((decoded as ErrorItem).message, 'boom');
    });

    test('unknown kind falls back to ErrorItem with descriptive message', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'i1',
        'kind': 'mystery',
      });
      expect(decoded, isA<ErrorItem>());
      expect((decoded as ErrorItem).message, contains('mystery'));
    });

    test('missing kind falls back to ErrorItem', () {
      final decoded = TimelineItem.fromJson(const {'id': 'i1'});
      expect(decoded, isA<ErrorItem>());
    });
  });

  group('CompactionItem', () {
    test('round-trips status, trigger, and pre-compaction tokens', () {
      const item = CompactionItem(
        id: 'compact-1',
        status: CompactionStatus.loading,
        trigger: CompactionTrigger.manual,
        preTokens: 180000,
      );
      final decoded = TimelineItem.fromJson(roundTrip(item.toJson()));
      final compaction = decoded as CompactionItem;
      expect(compaction.status, CompactionStatus.loading);
      expect(compaction.trigger, CompactionTrigger.manual);
      expect(compaction.preTokens, 180000);
    });

    test('defaults to completed and omits optional fields', () {
      final decoded = TimelineItem.fromJson(const {
        'id': 'compact-2',
        'kind': 'compaction',
      });
      final compaction = decoded as CompactionItem;
      expect(compaction.status, CompactionStatus.completed);
      expect(compaction.trigger, isNull);
      expect(compaction.preTokens, isNull);
      expect(compaction.toJson().containsKey('trigger'), isFalse);
    });
  });

  test('fromJson throws when id is missing', () {
    expect(
      () => TimelineItem.fromJson(const {'kind': 'user_message'}),
      throwsA(anything),
    );
  });
}
