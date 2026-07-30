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
    'opencode_late_metadata_acp_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'opencode_late_metadata_acp_child.dart',
  );
}

void main() {
  test('completed OpenCode turn stays idle after late user metadata', () async {
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
    final firstCompleted = Completer<void>();
    final lateMetadataDrained = Completer<void>();
    final secondCompleted = Completer<void>();
    final subscription = session.events.listen((event) {
      events.add(event);
      final completedCount = events.whereType<TurnCompleted>().length;
      if (completedCount == 1 && !firstCompleted.isCompleted) {
        firstCompleted.complete();
      } else if (completedCount == 2 && !secondCompleted.isCompleted) {
        secondCompleted.complete();
      }
      if (event case UsageUpdated(usage: AgentUsage(inputTokens: 99))) {
        lateMetadataDrained.complete();
      }
    });
    addTearDown(subscription.cancel);

    await session.prompt('first turn');
    await firstCompleted.future.timeout(const Duration(seconds: 5));
    await lateMetadataDrained.future.timeout(const Duration(seconds: 5));

    expect(events.whereType<TurnCompleted>(), hasLength(1));

    // If the late update resurrected the completed turn, the ACP session
    // would reject this prompt as a concurrent foreground turn.
    await session.prompt('second turn');
    await secondCompleted.future.timeout(const Duration(seconds: 5));

    expect(events.whereType<TurnCompleted>(), hasLength(2));
    expect(events.whereType<AssistantTextDelta>().map((event) => event.text), [
      'reply 1',
      'reply 2',
    ]);
  });
}
