import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/desktop/agent_navigation_inbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds the first valid existing-agent link among launch arguments', () {
    expect(
      parseAgentDeepLinkFromArguments([
        'coding-agent.exe',
        '--hidden',
        'not-a-link',
        'coding-agent://h/server-1/agent/agent-2',
        'coding-agent://h/server-1/agent/agent-3',
      ]),
      const AgentDeepLinkTarget(serverId: 'server-1', agentId: 'agent-2'),
    );
  });

  test('holds navigation until the window is ready', () {
    final inbox = AgentNavigationInbox();
    const target = AgentDeepLinkTarget(
      serverId: 'server-1',
      agentId: 'agent-2',
    );

    expect(inbox.deliverOrQueue(7, target), isNull);
    expect(inbox.windowReady(7), target);
    expect(inbox.deliverOrQueue(7, target), target);
  });

  test('returns only the newest target queued during startup', () {
    final inbox = AgentNavigationInbox();

    inbox.deliverOrQueue(
      7,
      const AgentDeepLinkTarget(serverId: 'server-1', agentId: 'agent-1'),
    );
    inbox.deliverOrQueue(
      7,
      const AgentDeepLinkTarget(serverId: 'server-1', agentId: 'agent-2'),
    );

    expect(
      inbox.windowReady(7),
      const AgentDeepLinkTarget(serverId: 'server-1', agentId: 'agent-2'),
    );
    expect(inbox.windowReady(7), isNull);
  });

  test('loading makes a ready window queue again', () {
    final inbox = AgentNavigationInbox();
    inbox.windowReady(7);
    inbox.windowLoading(7);

    const target = AgentDeepLinkTarget(
      serverId: 'server-1',
      agentId: 'agent-2',
    );
    expect(inbox.deliverOrQueue(7, target), isNull);
    expect(inbox.windowReady(7), target);
  });

  test('windows retain independent readiness and pending targets', () {
    final inbox = AgentNavigationInbox();
    const first = AgentDeepLinkTarget(serverId: 'server-1', agentId: 'agent-1');
    const second = AgentDeepLinkTarget(
      serverId: 'server-2',
      agentId: 'agent-2',
    );
    inbox.windowReady(1);

    expect(inbox.deliverOrQueue(1, first), first);
    expect(inbox.deliverOrQueue(2, second), isNull);
    expect(inbox.windowReady(2), second);
  });

  test('removing a window clears readiness and pending navigation', () {
    final inbox = AgentNavigationInbox();
    const target = AgentDeepLinkTarget(
      serverId: 'server-1',
      agentId: 'agent-2',
    );
    inbox.deliverOrQueue(7, target);
    inbox.removeWindow(7);

    expect(inbox.windowReady(7), isNull);
    inbox.removeWindow(7);
  });
}
