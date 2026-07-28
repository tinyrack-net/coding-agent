import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:test/test.dart';

void main() {
  group('daemon password auth', () {
    test('hashes at Paseo cost and verifies without retaining plaintext', () {
      final hash = hashDaemonPassword('correct-password');

      expect(hash, startsWith(r'$2a$12$'));
      expect(hash, isNot(contains('correct-password')));
      expect(isDaemonPasswordHash(hash), isTrue);
      expect(
        isBearerTokenValid(passwordHash: hash, token: 'correct-password'),
        isTrue,
      );
      expect(isBearerTokenValid(passwordHash: hash, token: 'wrong'), isFalse);
      expect(isBearerTokenValid(passwordHash: hash), isFalse);
      expect(isBearerTokenValid(token: 'anything'), isTrue);
    });

    test('extracts HTTP and Paseo/Tinyrack WebSocket bearers', () {
      expect(extractHttpBearerToken('Bearer secret'), 'secret');
      expect(extractHttpBearerToken('bearer secret'), isNull);
      expect(extractHttpBearerToken('Bearer too many parts'), isNull);

      expect(
        extractWsBearerProtocol('chat, paseo.bearer.part.one'),
        'paseo.bearer.part.one',
      );
      expect(extractWsBearerToken('paseo.bearer.part.one'), 'part.one');
      expect(extractWsBearerToken('tinyrack.bearer.secret'), 'secret');
      expect(extractWsBearerToken('other.bearer.secret'), isNull);
    });

    test('matches Paseo HTTP auth bypass paths', () {
      expect(shouldBypassBearerAuth('GET', '/api/health'), isTrue);
      expect(shouldBypassBearerAuth('OPTIONS', '/api/status'), isTrue);
      expect(shouldBypassBearerAuth('GET', '/api/files/download'), isTrue);
      expect(shouldBypassBearerAuth('POST', '/mcp/agents'), isTrue);
      expect(shouldBypassBearerAuth('GET', '/api/status'), isFalse);
    });

    test('authorizes agent MCP with capability or daemon password', () {
      final hash = hashDaemonPassword('correct-password');
      expect(
        isAgentMcpRequestAuthorized(
          capabilityToken: 'cap-token',
          authorizationHeader: 'Bearer anything',
        ),
        isTrue,
      );
      expect(
        isAgentMcpRequestAuthorized(
          capabilityToken: 'cap-token',
          passwordHash: hash,
          authorizationHeader: 'Bearer cap-token',
        ),
        isTrue,
      );
      expect(
        isAgentMcpRequestAuthorized(
          capabilityToken: 'cap-token',
          passwordHash: hash,
          authorizationHeader: 'Bearer correct-password',
        ),
        isTrue,
      );
      expect(
        isAgentMcpRequestAuthorized(
          capabilityToken: 'cap-token',
          passwordHash: hash,
          authorizationHeader: 'Bearer wrong-token',
        ),
        isFalse,
      );
      expect(
        isAgentMcpRequestAuthorized(
          capabilityToken: 'cap-token',
          passwordHash: hash,
        ),
        isFalse,
      );
    });
  });
}
