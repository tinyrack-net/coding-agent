import 'package:agent_daemon/src/workspace/service_proxy_names.dart';
import 'package:agent_daemon/src/workspace/workspace_service_env.dart';
import 'package:test/test.dart';

void main() {
  test('proxy labels normalize Unicode and cap with stable hashes', () {
    expect(
      buildServiceProxyLabel(
        projectSlug: 'Résumé',
        branchName: 'main',
        scriptName: 'Web App',
      ),
      'web-app--resume',
    );
    expect(
      buildLocalServiceHostname(
        projectSlug: 'paseo',
        branchName: 'feature/x',
        scriptName: 'web',
      ),
      'web--feature-x--paseo.localhost',
    );
    final first = buildServiceProxyLabel(
      projectSlug: 'project-' * 10,
      branchName: 'branch-' * 10,
      scriptName: 'script-' * 10,
    );
    final second = buildServiceProxyLabel(
      projectSlug: 'project-' * 10,
      branchName: 'branch-' * 10,
      scriptName: 'different-${'script-' * 10}',
    );
    expect(first, hasLength(63));
    expect(first.endsWith('-'), isFalse);
    expect(second, isNot(first));
  });

  test('local and public URL projection matches frozen semantics', () {
    final local = projectServiceProxyUrls(
      projectSlug: 'paseo',
      branchName: 'main',
      scriptName: 'web',
      daemonPort: 6767,
    );
    expect(local.localProxyUrl, 'http://web--paseo.localhost:6767');
    expect(local.publicProxyUrl, isNull);
    expect(local.proxyUrl, local.localProxyUrl);

    final public = projectServiceProxyUrls(
      projectSlug: 'paseo',
      branchName: 'feature-x',
      scriptName: 'web',
      daemonPort: null,
      publicBaseUrl: 'https://services.example.com:8443',
    );
    expect(public.localProxyUrl, isNull);
    expect(
      public.publicProxyUrl,
      'https://web--feature-x--paseo.services.example.com:8443',
    );
    expect(
      () => buildPublicServiceHostname(
        publicBaseUrl: 'not a url',
        projectSlug: 'paseo',
        branchName: null,
        scriptName: 'web',
      ),
      throwsFormatException,
    );
  });

  test('builds branded self and peer environment', () {
    expect(
      buildWorkspaceServiceEnv(
        scriptName: 'web',
        projectSlug: 'paseo',
        branchName: 'feature-x',
        daemonPort: 6767,
        daemonListenHost: null,
        peers: const [
          WorkspaceServicePeer(scriptName: 'api', port: 4000),
          WorkspaceServicePeer(scriptName: 'web', port: 5173),
        ],
      ),
      {
        'HOST': '127.0.0.1',
        'TINYRACK_PORT': '5173',
        'TINYRACK_URL': 'http://web--feature-x--paseo.localhost:6767',
        'TINYRACK_SERVICE_API_PORT': '4000',
        'TINYRACK_SERVICE_API_URL':
            'http://api--feature-x--paseo.localhost:6767',
        'TINYRACK_SERVICE_WEB_PORT': '5173',
        'TINYRACK_SERVICE_WEB_URL':
            'http://web--feature-x--paseo.localhost:6767',
      },
    );
  });

  test('host binding, missing URLs, and public URLs are exact', () {
    expect(resolveServiceBindHost('localhost'), '127.0.0.1');
    expect(resolveServiceBindHost('::1'), '127.0.0.1');
    expect(resolveServiceBindHost('[::1]'), '127.0.0.1');
    expect(resolveServiceBindHost('100.64.0.20'), '0.0.0.0');
    final noDaemon = buildWorkspaceServiceEnv(
      scriptName: 'web',
      projectSlug: 'paseo',
      branchName: 'main',
      daemonPort: null,
      daemonListenHost: '127.0.0.1',
      peers: const [WorkspaceServicePeer(scriptName: 'web', port: 5173)],
    );
    expect(noDaemon, {
      'HOST': '127.0.0.1',
      'TINYRACK_PORT': '5173',
      'TINYRACK_SERVICE_WEB_PORT': '5173',
    });
    final public = buildWorkspaceServiceEnv(
      scriptName: 'web',
      projectSlug: 'paseo',
      branchName: 'main',
      daemonPort: 6767,
      daemonListenHost: '0.0.0.0',
      serviceProxyPublicBaseUrl: 'https://services.example.com',
      peers: const [WorkspaceServicePeer(scriptName: 'web', port: 5173)],
    );
    expect(public['TINYRACK_URL'], 'https://web--paseo.services.example.com');
    expect(public.containsKey('PORT'), isFalse);
  });

  test('rejects missing self and normalized name collisions', () {
    expect(normalizeServiceEnvName('  app.server  '), 'APP_SERVER');
    expect(
      () => buildWorkspaceServiceEnv(
        scriptName: 'missing',
        projectSlug: 'paseo',
        branchName: null,
        daemonPort: 6767,
        daemonListenHost: null,
        peers: const [WorkspaceServicePeer(scriptName: 'web', port: 5173)],
      ),
      throwsStateError,
    );
    expect(
      () => assertNoServiceEnvNameCollisions(['app-server', 'app.server']),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains(
            'Service env name collision for APP_SERVER: '
            'app-server, app.server',
          ),
        ),
      ),
    );
  });
}
