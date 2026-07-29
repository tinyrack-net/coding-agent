import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips the frozen existing-agent target', () {
    const target = AgentDeepLinkTarget(
      serverId: 'server/main',
      agentId: 'agent 123',
    );

    expect(
      buildAgentDeepLink(target),
      'coding-agent://h/server%2Fmain/agent/agent%20123',
    );
    expect(
      buildAgentDeepLinkRoute(target),
      '/h/server%2Fmain/agent/agent%20123',
    );
    expect(parseAgentDeepLink(buildAgentDeepLink(target)), target);
  });

  test('trims segments and rejects malformed or foreign routes', () {
    expect(
      buildAgentDeepLink(
        const AgentDeepLinkTarget(serverId: ' server ', agentId: ' agent '),
      ),
      'coding-agent://h/server/agent/agent',
    );
    expect(
      () => buildAgentDeepLink(
        const AgentDeepLinkTarget(serverId: ' ', agentId: 'agent'),
      ),
      throwsArgumentError,
    );
    expect(parseAgentDeepLink('https://h/server/agent/agent-1'), isNull);
    expect(
      parseAgentDeepLink('coding-agent://app/h/server/agent/agent-1'),
      isNull,
    );
    expect(
      parseAgentDeepLink('coding-agent://h/server/agent/agent-1?message=hello'),
      isNull,
    );
    expect(
      parseAgentDeepLink('coding-agent://h/server/agent/agent-1/extra'),
      isNull,
    );
  });
}
