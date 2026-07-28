import 'package:agent_daemon/src/workspace/script_route_branch_handler.dart';
import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:test/test.dart';

void main() {
  test('rewrites routes and invalidates health only when changed', () {
    final routes = ServiceProxyRouteRegistry();
    routes.registerWorkspaceService(
      workspaceId: 'workspace',
      projectSlug: 'repo',
      branchName: 'feature/auth',
      scriptName: 'web',
      port: 4100,
      publicBaseUrl: 'https://services.example.test',
    );
    final changed = <String>[];
    final logs = <(String, String?)>[];
    final handle = createBranchChangeRouteHandler(
      serviceProxy: routes,
      onRoutesChanged: changed.add,
      log: (workspaceId, branch) => logs.add((workspaceId, branch)),
    );

    handle('workspace', 'feature/auth', 'feature/billing');
    expect(routes.findRoute('web--feature-auth--repo.localhost'), isNull);
    expect(
      routes.findRoute('web--feature-billing--repo.localhost')?.port,
      4100,
    );
    expect(
      routes
          .findRoute('web--feature-billing--repo.services.example.test')
          ?.port,
      4100,
    );
    expect(changed, ['workspace']);
    expect(logs, [('workspace', 'feature/billing')]);

    handle('workspace', 'feature/billing', 'feature/billing');
    handle('missing', null, 'main');
    expect(changed, ['workspace']);
    expect(logs, hasLength(1));
  });

  test('collision escapes without invalidating the workspace', () {
    final routes = ServiceProxyRouteRegistry()
      ..registerWorkspaceService(
        workspaceId: 'one',
        projectSlug: 'repo',
        branchName: 'old',
        scriptName: 'web',
        port: 4100,
      )
      ..registerWorkspaceService(
        workspaceId: 'two',
        projectSlug: 'repo',
        branchName: 'new',
        scriptName: 'web',
        port: 4200,
      );
    final changed = <String>[];
    final handle = createBranchChangeRouteHandler(
      serviceProxy: routes,
      onRoutesChanged: changed.add,
    );

    expect(
      () => handle('one', 'old', 'new'),
      throwsA(isA<ServiceProxyRouteCollisionError>()),
    );
    expect(changed, isEmpty);
    expect(routes.findRoute('web--old--repo.localhost')?.port, 4100);
  });
}
