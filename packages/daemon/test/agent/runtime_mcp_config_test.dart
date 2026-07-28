import 'package:agent_daemon/src/agent/runtime_mcp_config.dart';
import 'package:test/test.dart';

void main() {
  test('injects the branded runtime server with caller and bearer token', () {
    const stored = <String, Object?>{
      'local': {'type': 'stdio', 'command': 'dart'},
    };

    final result = withRuntimeTinyrackMcpServer(
      storedMcpServers: stored,
      agentId: 'agent-1',
      mcpBaseUrl: 'http://127.0.0.1:6868/mcp/agents',
      mcpAuthToken: 'cap-token',
    );

    expect(result, {
      'tinyrack': {
        'type': 'http',
        'url': 'http://127.0.0.1:6868/mcp/agents?callerAgentId=agent-1',
        'headers': {'Authorization': 'Bearer cap-token'},
      },
      ...stored,
    });
    expect(stored, isNot(contains('tinyrack')));
  });

  test('omits auth without a token and skips injection without a base URL', () {
    expect(
      withRuntimeTinyrackMcpServer(
        storedMcpServers: const {},
        agentId: 'agent-1',
        mcpBaseUrl: 'http://localhost/mcp/agents',
        mcpAuthToken: null,
      ),
      {
        'tinyrack': {
          'type': 'http',
          'url': 'http://localhost/mcp/agents?callerAgentId=agent-1',
        },
      },
    );
    expect(
      withRuntimeTinyrackMcpServer(
        storedMcpServers: const {'local': <String, Object?>{}},
        agentId: 'agent-1',
        mcpBaseUrl: null,
        mcpAuthToken: 'token',
      ),
      {'local': <String, Object?>{}},
    );
  });

  test('replaces stale internal servers but preserves user-owned names', () {
    final stripped = stripInternalAgentMcpServers(const {
      'tinyrack': {
        'type': 'http',
        'url': 'http://old:6767/mcp/agents?callerAgentId=stale',
      },
      'paseo': {'type': 'sse', 'url': 'http://old:6767/mcp/agents'},
      'other': {'type': 'http', 'url': 'http://example.test/mcp'},
    });
    expect(stripped, {
      'other': {'type': 'http', 'url': 'http://example.test/mcp'},
    });

    const userOwned = <String, Object?>{
      'tinyrack': {'type': 'http', 'url': 'https://example.test/mcp'},
    };
    expect(
      identical(stripInternalAgentMcpServers(userOwned), userOwned),
      isTrue,
    );
    const relative = <String, Object?>{
      'tinyrack': {'type': 'http', 'url': '/mcp/agents'},
    };
    expect(identical(stripInternalAgentMcpServers(relative), relative), isTrue);
    expect(
      withRuntimeTinyrackMcpServer(
        storedMcpServers: userOwned,
        agentId: 'agent-1',
        mcpBaseUrl: 'http://localhost/mcp/agents',
        mcpAuthToken: 'token',
      ),
      userOwned,
    );
  });
}
