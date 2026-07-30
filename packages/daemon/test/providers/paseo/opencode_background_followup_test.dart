import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/generic_acp_agent_client.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'opencode_background_followup_acp_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'opencode_background_followup_acp_child.dart',
  );
}

void main() {
  test(
    'OpenCode autonomous follow-up remains visible after foreground completion',
    () async {
      final session =
          await GenericAcpAgentClient(
            provider: 'opencode',
            command: 'opencode',
            commandArgs: [_fixturePath()],
            resolveCommand: () async => Platform.resolvedExecutable,
          ).createSession(
            cwd: Directory.current.path,
            model: '',
            mode: AgentMode.normal,
          );
      addTearDown(session.dispose);

      final events = <ProviderEvent>[];
      final foregroundCompleted = Completer<void>();
      final autonomousFollowUpDrained = Completer<void>();
      final subscription = session.events.listen((event) {
        events.add(event);
        if (event is TurnCompleted && !foregroundCompleted.isCompleted) {
          foregroundCompleted.complete();
        }
        if (event case UsageUpdated(usage: AgentUsage(inputTokens: 41))) {
          autonomousFollowUpDrained.complete();
        }
      });
      addTearDown(subscription.cancel);

      await session.prompt('start background work');
      await foregroundCompleted.future.timeout(const Duration(seconds: 5));
      await autonomousFollowUpDrained.future.timeout(
        const Duration(seconds: 5),
      );

      expect(events.whereType<TurnCompleted>(), hasLength(1));
      expect(events.whereType<AssistantTextDelta>(), [
        isA<AssistantTextDelta>()
            .having(
              (event) => event.itemId,
              'initial message id',
              'assistant-initial',
            )
            .having(
              (event) => event.text,
              'initial text',
              'Initial work complete.',
            ),
        isA<AssistantTextDelta>()
            .having(
              (event) => event.itemId,
              'follow-up message id',
              'assistant-follow-up',
            )
            .having(
              (event) => event.text,
              'follow-up text',
              'I incorporated the completed background result.',
            ),
      ]);
    },
  );
}
