import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/providers/paseo/generic_acp_agent_client.dart';
import 'package:agent_daemon/src/providers/paseo/omp_system_notice.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'omp_system_notice_acp_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'omp_system_notice_acp_child.dart',
  );
}

void main() {
  test('maps OMP task result notice to Paseo task notification semantics', () {
    const text = '''
<system-notice>
Background job DocsSmokeTwo has completed.
<task-result id="DocsSmokeTwo" agent="explore" status="completed" duration="21.6s">
<output>done</output>
</task-result>
</system-notice>''';

    final notice = parseOmpSystemNotice(text);

    expect(notice?.callId, 'omp-notice:DocsSmokeTwo');
    expect(notice?.status, ToolCallStatus.success);
    expect(notice?.label, 'Background job DocsSmokeTwo completed');
    expect(notice?.errorMessage, isNull);
    expect(notice?.metadata, {
      'synthetic': true,
      'source': 'omp_system_notice',
      'taskId': 'DocsSmokeTwo',
      'subagentType': 'explore',
      'status': 'completed',
    });
  });

  test('maps failed and canceled notice lifecycle without raw fallthrough', () {
    final failed = parseOmpSystemNotice(
      '<system-notice>Failed.'
      '<task-result id=“job-f” status=“error”></task-result>'
      '</system-notice>',
    );
    final canceled = parseOmpSystemNotice(
      "<system-notice>Stopped."
      "<task-result id='job-c' status='cancelled'></task-result>"
      '</system-notice>',
    );

    expect(failed?.status, ToolCallStatus.error);
    expect(failed?.errorMessage, 'Background job job-f error');
    expect(canceled?.status, ToolCallStatus.canceled);
    expect(canceled?.errorMessage, isNull);
    expect(parseOmpSystemNotice('plain custom status text'), isNull);
  });

  test(
    'normalizes live OMP ACP notice into task notification timeline item',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('omp-system-notice-');
      addTearDown(() async {
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
      });
      final manager = AgentManager(
        clients: {
          'omp': GenericAcpAgentClient(
            provider: 'omp',
            command: 'omp',
            commandArgs: [_fixturePath()],
            resolveCommand: () async => Platform.resolvedExecutable,
          ),
        },
        store: AgentStore(dataDir: dataDir.path),
      );
      addTearDown(manager.dispose);

      final agent = await manager.createAgent(
        cwd: Directory.current.path,
        provider: 'omp',
        model: '',
        mode: AgentMode.normal,
        initialPrompt: 'run background task',
      );
      for (var attempt = 0; attempt < 100; attempt++) {
        final current = manager.get(agent.agentId);
        final items = manager.fetchTimeline(agent.agentId).items;
        if (current?.runState == AgentRunState.idle &&
            items.whereType<ToolCallItem>().isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final timeline = manager.fetchTimeline(agent.agentId).items;
      final taskNotification = timeline.whereType<ToolCallItem>().single;
      expect(
        timeline.whereType<AssistantMessageItem>().map((item) => item.text),
        ['done', 'plain custom status text'],
      );
      expect(
        taskNotification,
        isA<ToolCallItem>()
            .having((item) => item.id, 'call id', 'omp-notice:DocsSmokeTwo')
            .having((item) => item.toolName, 'tool name', 'task_notification')
            .having((item) => item.status, 'status', ToolCallStatus.success)
            .having(
              (item) => item.detail,
              'detail',
              isA<PlainTextDetail>()
                  .having(
                    (detail) => detail.label,
                    'label',
                    'Background job DocsSmokeTwo completed',
                  )
                  .having((detail) => detail.icon, 'icon', 'wrench'),
            )
            .having((item) => item.metadata, 'metadata', {
              'synthetic': true,
              'source': 'omp_system_notice',
              'taskId': 'DocsSmokeTwo',
              'subagentType': 'explore',
              'status': 'completed',
            }),
      );
      expect(PaseoTimelineCodec.encode(taskNotification), {
        'type': 'tool_call',
        'callId': 'omp-notice:DocsSmokeTwo',
        'name': 'task_notification',
        'detail': {
          'type': 'plain_text',
          'label': 'Background job DocsSmokeTwo completed',
          'text': contains('<system-notice>'),
          'icon': 'wrench',
        },
        'metadata': {
          'synthetic': true,
          'source': 'omp_system_notice',
          'taskId': 'DocsSmokeTwo',
          'subagentType': 'explore',
          'status': 'completed',
        },
        'status': 'completed',
        'error': null,
      });
      expect(
        timeline
            .whereType<AssistantMessageItem>()
            .map((item) => item.text)
            .join('\n'),
        allOf(
          isNot(contains('<system-notice>')),
          isNot(contains('StillRunning')),
        ),
      );
    },
  );
}
