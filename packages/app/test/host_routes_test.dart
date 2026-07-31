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

  test('agent routes preserve frozen encoded server and agent IDs', () {
    final route = buildHostAgentRoute('server/main', 'agent 123');
    expect(route, '/h/server%2Fmain/agent/agent%20123');
    final parsed = parseHostAgentRouteFromUri(Uri.parse(route));
    expect(parsed?.serverId, 'server/main');
    expect(parsed?.agentId, 'agent 123');
    expect(
      routeFromCodingAgentDeepLink(
        'coding-agent://h/server%2Fmain/agent/agent%20123',
      ),
      route,
    );
    expect(
      parseHostAgentRouteFromUri(Uri.parse('/h/server/agent/agent/extra')),
      isA<HostAgentRoute>()
          .having((route) => route.serverId, 'serverId', 'server')
          .having((route) => route.agentId, 'agentId', 'agent'),
    );
  });

  group('frozen host route surface', () {
    test('parses host, agent, workspace, and open-intent pathnames', () {
      expect(
        parseServerIdFromPathname('/h/server%2Fmain/sessions?tab=all#top'),
        'server/main',
      );
      expect(
        parseHostAgentRouteFromPathname(
          '/h/server%2Fmain/agent/agent%20123/details?tab=files',
        ),
        isA<HostAgentRoute>()
            .having((route) => route.serverId, 'serverId', 'server/main')
            .having((route) => route.agentId, 'agentId', 'agent 123'),
      );
      expect(
        parseHostWorkspaceRouteFromPathname(
          '/h/server%2Fmain/workspace/b64_L3RtcC9yZXBv?open=draft%3Anew',
        ),
        isA<HostWorkspaceRoute>()
            .having((route) => route.serverId, 'serverId', 'server/main')
            .having((route) => route.workspaceId, 'workspaceId', '/tmp/repo'),
      );
      expect(
        parseHostWorkspaceOpenIntentFromPathname(
          '/h/local/workspace/164?open=terminal%3Aterm-1',
        ),
        isA<TerminalWorkspaceOpenIntent>().having(
          (intent) => intent.terminalId,
          'terminalId',
          'term-1',
        ),
      );
    });

    test('strips only route echo search parameters', () {
      expect(
        stripHostWorkspaceRouteEchoSearch(
          '/h/local/workspace/164?serverId=local&workspaceId=164'
          '&open=agent%3Aagent-1#pane',
        ),
        '/h/local/workspace/164?open=agent%3Aagent-1#pane',
      );
      expect(
        stripHostWorkspaceRouteEchoSearch(
          '/h/local/workspace/164?pop=true&open=agent%3Aagent-1',
        ),
        '/h/local/workspace/164?open=agent%3Aagent-1',
      );
      expect(
        stripHostWorkspaceRouteEchoSearch(
          '/h/local/workspace/b64_L3RtcC9yZXBv'
          '?workspaceId=%2Ftmp%2Frepo',
        ),
        '/h/local/workspace/b64_L3RtcC9yZXBv',
      );
      expect(
        stripHostWorkspaceRouteEchoSearch(
          '/h/local/workspace/164?workspaceId=other&pop=false',
        ),
        '/h/local/workspace/164?workspaceId=other&pop=false',
      );
      expect(
        stripHostWorkspaceRouteEchoSearch('/new?pop=true'),
        '/new?pop=true',
      );
    });

    test('builds host and global navigation routes', () {
      expect(buildHostRootRoute('server/main'), '/h/server%2Fmain');
      expect(
        buildHostOpenProjectRoute('server/main'),
        '/h/server%2Fmain/open-project',
      );
      expect(
        buildHostSessionsRoute('server/main'),
        '/h/server%2Fmain/sessions',
      );
      expect(buildSessionsRoute(), '/sessions');
      expect(buildSchedulesRoute(), '/schedules');
      expect(buildOpenProjectRoute(), '/open-project');
      expect(buildHostRootRoute('  '), '/');
      expect(buildHostOpenProjectRoute('  '), '/');
      expect(buildHostSessionsRoute('  '), '/');
    });

    test('builds agent detail through workspace context when supplied', () {
      expect(
        buildHostAgentDetailRoute('local', 'agent-1', workspaceId: '164'),
        '/h/local/workspace/164?open=agent%3Aagent-1',
      );
      expect(
        buildHostAgentDetailRoute('server/main', 'agent 123'),
        '/h/server%2Fmain/agent/agent%20123',
      );
      expect(buildHostAgentDetailRoute('local', '  '), '/');
    });

    test('builds new-workspace route with every frozen initial value', () {
      expect(buildNewWorkspaceRoute(), '/new');
      expect(
        buildNewWorkspaceRoute(
          const NewWorkspaceRouteOptions(
            serverId: 'local',
            sourceDirectory: '/repo/project',
            displayName: 'Project',
            projectId: 'project-1',
            draftId: 'draft-1',
          ),
        ),
        '/new?serverId=local&dir=%2Frepo%2Fproject&name=Project'
        '&projectId=project-1&draftId=draft-1',
      );
    });
  });

  group('frozen settings route surface', () {
    test('recognizes current and legacy section slugs', () {
      expect(isSettingsSectionSlug('general'), isTrue);
      expect(isSettingsSectionSlug('daemon'), isFalse);
      expect(isHostSectionSlug('terminals'), isTrue);
      expect(
        normalizeHostSectionSlug('connections'),
        HostSectionSlug.connections,
      );
      expect(normalizeHostSectionSlug('orchestration'), HostSectionSlug.agents);
      expect(normalizeHostSectionSlug('daemon'), HostSectionSlug.host);
      expect(normalizeHostSectionSlug('unknown'), isNull);
    });

    test('builds app, host, and project settings routes', () {
      expect(buildSettingsRoute(), '/settings');
      expect(
        buildSettingsSectionRoute(SettingsSectionSlug.appearance),
        '/settings/appearance',
      );
      expect(buildSettingsAddHostRoute(), '/settings/general?addHost=1');
      expect(
        buildSettingsAddHostRoute('retry 1'),
        '/settings/general?addHost=retry%201',
      );
      expect(
        buildSettingsHostRoute('server/main'),
        '/settings/hosts/server%2Fmain',
      );
      expect(
        buildSettingsHostSectionRoute('server/main', HostSectionSlug.providers),
        '/settings/hosts/server%2Fmain/providers',
      );
      expect(buildProjectsSettingsRoute(), '/settings/projects');
      expect(
        buildProjectSettingsRoute('remote:github.com/acme/app'),
        '/settings/projects/remote%3Agithub.com%2Facme%2Fapp',
      );
      expect(() => buildSettingsHostRoute(' '), throwsArgumentError);
      expect(() => buildProjectSettingsRoute(' '), throwsArgumentError);
    });

    test('canonicalizes unknown and legacy settings sections', () {
      expect(canonicalSettingsSectionPath('appearance'), isNull);
      expect(canonicalSettingsSectionPath('keyboard'), '/settings/shortcuts');
      expect(
        canonicalSettingsSectionPath('not-a-section'),
        '/settings/general',
      );
      expect(canonicalSettingsSectionPath('projects'), isNull);
    });

    test('canonicalizes host aliases and unknown sections', () {
      expect(
        canonicalHostSettingsSectionPath('server-a', 'orchestration'),
        '/settings/hosts/server-a/agents',
      );
      expect(
        canonicalHostSettingsSectionPath('server-a', 'daemon'),
        '/settings/hosts/server-a/host',
      );
      expect(
        canonicalHostSettingsSectionPath('server-a', 'unknown'),
        '/settings/hosts/server-a/connections',
      );
      expect(canonicalHostSettingsSectionPath('server-a', 'usage'), isNull);
    });
  });
}
