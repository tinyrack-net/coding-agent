import 'package:coding_agent_app/core/host_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('workspace route codec', () {
    test('keeps URL-safe workspace IDs unencoded', () {
      expect(encodeWorkspaceIdForPathSegment('164'), '164');
      expect(decodeWorkspaceIdFromPathSegment('164'), '164');
      expect(
        decodeWorkspaceIdFromPathSegment('wks_10b3479c955fcc4c'),
        'wks_10b3479c955fcc4c',
      );
    });

    test('encodes non-URL-safe workspace IDs as marked base64url', () {
      expect(encodeWorkspaceIdForPathSegment('/tmp/repo'), 'b64_L3RtcC9yZXBv');
      expect(decodeWorkspaceIdFromPathSegment('L3RtcC9yZXBv'), '/tmp/repo');
      expect(
        decodeWorkspaceIdFromPathSegment('L2hvbWUvdXNlci9kZXYvcGFzZW8'),
        '/home/user/dev/paseo',
      );
    });

    test('encodes and decodes file paths without padding', () {
      final encoded = encodeFilePathForPathSegment('src/index.ts');
      expect(encoded, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(decodeFilePathFromPathSegment(encoded), 'src/index.ts');
    });

    test('parses only the exact host workspace route', () {
      final parsed = parseHostWorkspaceRouteFromUri(
        Uri.parse('/h/local/workspace/164?open=agent%3Aagent-1'),
      );
      expect(parsed?.serverId, 'local');
      expect(parsed?.workspaceId, '164');
      expect(
        parseHostWorkspaceRouteFromUri(
          Uri.parse('/h/local/workspace/164/tab/draft_1'),
        ),
        isNull,
      );
    });

    test('builds canonical plain and legacy-path routes', () {
      expect(buildHostWorkspaceRoute('local', '164'), '/h/local/workspace/164');
      expect(
        buildHostWorkspaceRoute('local', '/tmp/repo'),
        '/h/local/workspace/b64_L3RtcC9yZXBv',
      );
      expect(
        buildHostWorkspaceOpenRoute('local', '164', 'draft:new'),
        '/h/local/workspace/164?open=draft%3Anew',
      );
    });

    test('round-trips opaque IDs and trims their boundary whitespace', () {
      const id = '  team/setup:id#1  ';
      final encoded = encodeWorkspaceIdForPathSegment(id);
      expect(encoded, 'b64_dGVhbS9zZXR1cDppZCMx');
      expect(decodeWorkspaceIdFromPathSegment(encoded), 'team/setup:id#1');
    });
  });

  group('workspace open intent', () {
    test('parses every Paseo 0.2.0 intent shape', () {
      expect(
        parseWorkspaceOpenIntent('agent:agent-1'),
        isA<AgentWorkspaceOpenIntent>().having(
          (intent) => intent.agentId,
          'agentId',
          'agent-1',
        ),
      );
      expect(
        parseWorkspaceOpenIntent('terminal:term-1'),
        isA<TerminalWorkspaceOpenIntent>(),
      );
      expect(
        parseWorkspaceOpenIntent('draft:new'),
        isA<DraftWorkspaceOpenIntent>(),
      );
      expect(
        parseWorkspaceOpenIntent('file:c3JjL2luZGV4LnRz'),
        isA<FileWorkspaceOpenIntent>().having(
          (intent) => intent.path,
          'path',
          'src/index.ts',
        ),
      );
      expect(
        parseWorkspaceOpenIntent('setup:L3RtcC9yZXBv'),
        isA<SetupWorkspaceOpenIntent>().having(
          (intent) => intent.workspaceId,
          'workspaceId',
          '/tmp/repo',
        ),
      );
      expect(parseWorkspaceOpenIntent('unknown:value'), isNull);
      expect(parseWorkspaceOpenIntent('agent:'), isNull);
    });

    test('reads the one-shot intent from a workspace URI', () {
      expect(
        parseHostWorkspaceOpenIntentFromUri(
          Uri.parse('/h/local/workspace/164?open=agent%3Aagent-1'),
        ),
        isA<AgentWorkspaceOpenIntent>(),
      );
    });
  });

  group('known host recovery', () {
    test('renders a saved host', () {
      expect(
        resolveKnownHostRoute(
          routeServerId: 'local',
          serverIds: const ['local'],
        ),
        KnownHostRouteResolution.render,
      );
    });

    test('redirects a removed host to open project', () {
      expect(
        resolveKnownHostRoute(
          routeServerId: 'removed',
          serverIds: const ['local'],
        ),
        KnownHostRouteResolution.openProject,
      );
    });

    test('redirects to welcome when no host exists', () {
      expect(
        resolveKnownHostRoute(routeServerId: 'removed', serverIds: const []),
        KnownHostRouteResolution.welcome,
      );
    });
  });

  test('coding-agent deep links preserve the canonical web route', () {
    final route = buildHostWorkspaceOpenRoute(
      'server/main',
      'workspace-1',
      'agent:agent-1',
    );
    final link = buildCodingAgentDeepLink(route);
    expect(
      link,
      'coding-agent://h/server%2Fmain/workspace/workspace-1'
      '?open=agent%3Aagent-1',
    );
    expect(routeFromCodingAgentDeepLink(link), route);
    expect(routeFromCodingAgentDeepLink('https://example.com/h/a'), isNull);
    expect(routeFromCodingAgentDeepLink('coding-agent://settings'), isNull);
    expect(() => buildCodingAgentDeepLink('settings'), throwsArgumentError);
  });
}
