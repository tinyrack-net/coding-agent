import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceProxyRouteRegistry', () {
    test('registers local and public aliases and projects state', () {
      final registry = ServiceProxyRouteRegistry(
        publicBaseUrl: 'https://services.example.test',
      );
      final route = registry.registerWorkspaceService(
        workspaceId: 'workspace-1',
        projectSlug: 'Tiny Rack',
        branchName: 'feature/auth',
        scriptName: 'Web Dev',
        port: 4310,
        publicBaseUrl: 'https://services.example.test:9443',
      );

      expect(route.hostname, 'web-dev--feature-auth--tiny-rack.localhost');
      expect(
        route.publicHostname,
        'web-dev--feature-auth--tiny-rack.services.example.test',
      );
      expect(registry.findRoute('${route.hostname}:6868')?.port, 4310);
      expect(registry.findRoute(route.publicHostname!)?.port, 4310);
      expect(
        registry.classifyHost('services.example.test').type,
        ServiceProxyHostClassificationType.knownServiceMiss,
      );

      final state = registry.projectWorkspaceServiceState(
        workspaceId: 'workspace-1',
        projectSlug: 'ignored',
        branchName: null,
        scriptName: 'Web Dev',
        daemonPort: 6868,
      );
      expect(state.port, 4310);
      expect(state.urls.localProxyUrl, 'http://${route.hostname}:6868');
      expect(state.urls.publicProxyUrl, 'https://${route.publicHostname}:9443');
      expect(state.urls.proxyUrl, state.urls.publicProxyUrl);
    });

    test('classifies daemon hosts and exact known local misses', () {
      final registry = ServiceProxyRouteRegistry();
      expect(
        registry.classifyHost(null).type,
        ServiceProxyHostClassificationType.daemon,
      );
      expect(
        registry.classifyHost('127.0.0.1:6868').type,
        ServiceProxyHostClassificationType.daemon,
      );
      expect(
        registry.classifyHost('web--repo.localhost:6868').type,
        ServiceProxyHostClassificationType.knownServiceMiss,
      );
      expect(
        registry.classifyHost('single.localhost').type,
        ServiceProxyHostClassificationType.daemon,
      );
    });

    test('rejects local and public alias collisions with exact owners', () {
      final registry = ServiceProxyRouteRegistry();
      final first = ServiceProxyRouteEntry(
        hostname: 'first.localhost',
        publicHostname: 'shared.example.test',
        publicBaseUrl: 'https://example.test',
        port: 4100,
        workspaceId: 'workspace-1',
        projectSlug: 'one',
        scriptName: 'web',
      );
      registry.registerRoute(first);

      expect(
        () => registry.registerRoute(
          const ServiceProxyRouteEntry(
            hostname: 'second.localhost',
            publicHostname: 'shared.example.test',
            publicBaseUrl: 'https://example.test',
            port: 4200,
            workspaceId: 'workspace-2',
            projectSlug: 'two',
            scriptName: 'docs',
          ),
        ),
        throwsA(
          isA<ServiceProxyRouteCollisionError>()
              .having(
                (error) => error.hostname,
                'hostname',
                'shared.example.test',
              )
              .having(
                (error) => error.existing.workspaceId,
                'existing workspace',
                'workspace-1',
              )
              .having(
                (error) => error.incoming.workspaceId,
                'incoming workspace',
                'workspace-2',
              ),
        ),
      );
      expect(registry.listRoutes(), hasLength(1));
      expect(registry.listRoutes().single.hostname, first.hostname);
      expect(registry.listRoutes().single.port, first.port);
    });

    test('same owner registration replaces route and aliases', () {
      final registry = ServiceProxyRouteRegistry();
      registry.registerRoute(
        const ServiceProxyRouteEntry(
          hostname: 'web--repo.localhost',
          publicHostname: 'web--repo.old.test',
          publicBaseUrl: 'https://old.test',
          port: 4100,
          workspaceId: 'workspace-1',
          projectSlug: 'repo',
          scriptName: 'web',
        ),
      );
      registry.registerRoute(
        const ServiceProxyRouteEntry(
          hostname: 'web--repo.localhost',
          publicHostname: 'web--repo.new.test',
          publicBaseUrl: 'https://new.test',
          port: 4200,
          workspaceId: 'workspace-1',
          projectSlug: 'repo',
          scriptName: 'web',
        ),
      );

      expect(registry.findRoute('web--repo.localhost')?.port, 4200);
      expect(registry.findRoute('web--repo.old.test'), isNull);
      expect(registry.findRoute('web--repo.new.test')?.port, 4200);
      expect(
        registry.classifyHost('old.test').type,
        ServiceProxyHostClassificationType.daemon,
      );
    });

    test('replaces all workspace branch routes atomically', () {
      final registry = ServiceProxyRouteRegistry();
      for (final script in ['web', 'api']) {
        registry.registerWorkspaceService(
          workspaceId: 'workspace-1',
          projectSlug: 'repo',
          branchName: 'old',
          scriptName: script,
          port: script == 'web' ? 4100 : 4200,
          publicBaseUrl: 'https://services.example.test',
        );
      }

      expect(
        registry.replaceWorkspaceBranchRoutes(
          workspaceId: 'workspace-1',
          newBranch: 'new',
        ),
        isTrue,
      );
      expect(
        registry.listRoutesForWorkspace('workspace-1').map((e) => e.hostname),
        containsAll(['web--new--repo.localhost', 'api--new--repo.localhost']),
      );
      expect(
        registry.replaceWorkspaceBranchRoutes(
          workspaceId: 'workspace-1',
          newBranch: 'new',
        ),
        isFalse,
      );
      expect(
        registry.replaceWorkspaceBranchRoutes(
          workspaceId: 'missing',
          newBranch: 'new',
        ),
        isFalse,
      );
    });

    test('failed branch replacement leaves existing routes intact', () {
      final registry = ServiceProxyRouteRegistry();
      registry.registerWorkspaceService(
        workspaceId: 'workspace-1',
        projectSlug: 'repo',
        branchName: 'old',
        scriptName: 'web',
        port: 4100,
      );
      registry.registerWorkspaceService(
        workspaceId: 'workspace-2',
        projectSlug: 'repo',
        branchName: 'new',
        scriptName: 'web',
        port: 4200,
      );

      expect(
        () => registry.replaceWorkspaceBranchRoutes(
          workspaceId: 'workspace-1',
          newBranch: 'new',
        ),
        throwsA(isA<ServiceProxyRouteCollisionError>()),
      );
      expect(registry.findRoute('web--old--repo.localhost')?.port, 4100);
      expect(registry.findRoute('web--new--repo.localhost')?.port, 4200);
    });

    test('removes by alias, script, hostname collection, and port', () {
      final registry = ServiceProxyRouteRegistry();
      registry.registerWorkspaceService(
        workspaceId: 'workspace-1',
        projectSlug: 'repo',
        branchName: null,
        scriptName: 'web',
        port: 4100,
        publicBaseUrl: 'https://services.example.test',
      );
      registry.registerWorkspaceService(
        workspaceId: 'workspace-1',
        projectSlug: 'repo',
        branchName: null,
        scriptName: 'api',
        port: 4200,
      );
      registry.registerWorkspaceService(
        workspaceId: 'workspace-2',
        projectSlug: 'other',
        branchName: null,
        scriptName: 'docs',
        port: 4300,
      );

      registry.removeRoute('web--repo.services.example.test:443');
      expect(
        registry.getHealthTargetForHostname('web--repo.localhost'),
        isNull,
      );
      registry.removeWorkspaceService(
        workspaceId: 'workspace-1',
        scriptName: 'api',
      );
      registry.removeServiceRoutesByHostnames([
        'missing',
        'docs--other.localhost',
      ]);
      expect(registry.listRoutes(), isEmpty);

      registry.registerWorkspaceService(
        workspaceId: 'workspace-3',
        projectSlug: 'repo',
        branchName: null,
        scriptName: 'one',
        port: 4400,
      );
      registry.registerWorkspaceService(
        workspaceId: 'workspace-3',
        projectSlug: 'repo',
        branchName: null,
        scriptName: 'two',
        port: 4400,
      );
      registry.removeRoutesForPort(4400);
      expect(registry.getHealthCheckTargets(), isEmpty);
    });

    test('projects an unregistered service without inventing a port', () {
      final registry = ServiceProxyRouteRegistry();
      final state = registry.projectWorkspaceServiceState(
        workspaceId: 'workspace-1',
        projectSlug: 'repo',
        branchName: 'feature',
        scriptName: 'web',
        daemonPort: null,
        publicBaseUrl: 'https://services.example.test',
      );

      expect(state.hostname, 'web--feature--repo.localhost');
      expect(state.port, isNull);
      expect(state.urls.localProxyUrl, isNull);
      expect(
        state.urls.publicProxyUrl,
        'https://web--feature--repo.services.example.test',
      );
    });
  });
}
