import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/workspace/script_health_monitor.dart';
import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:test/test.dart';

void main() {
  late ServiceProxyRouteRegistry routes;
  late DateTime now;
  late List<({String workspaceId, List<ScriptHealthEntry> scripts})> changes;

  setUp(() {
    routes = ServiceProxyRouteRegistry();
    now = DateTime.utc(2026);
    changes = [];
  });

  ServiceProxyRouteEntry register({
    String workspaceId = 'workspace-1',
    String scriptName = 'web',
    int port = 4100,
  }) => routes.registerWorkspaceService(
    workspaceId: workspaceId,
    projectSlug: workspaceId,
    branchName: null,
    scriptName: scriptName,
    port: port,
  );

  ScriptHealthMonitor monitor({
    ScriptHealthProbe? probe,
    Duration grace = const Duration(seconds: 5),
    int failures = 2,
  }) => ScriptHealthMonitor(
    serviceProxy: routes,
    onChange: (workspaceId, scripts) =>
        changes.add((workspaceId: workspaceId, scripts: scripts)),
    pollInterval: const Duration(days: 1),
    probeTimeout: const Duration(milliseconds: 50),
    grace: grace,
    failuresBeforeStopped: failures,
    probe: probe,
    clock: () => now,
  );

  test('starts pending, honors grace, and becomes healthy', () async {
    final route = register();
    var probes = 0;
    final health = monitor(
      probe: (_, _) async {
        probes++;
        return true;
      },
    )..start();
    addTearDown(health.stop);

    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.pending,
    );
    await health.pollNow();
    expect(probes, 0);
    expect(changes, isEmpty);

    now = now.add(const Duration(seconds: 5));
    await health.pollNow();
    expect(probes, 1);
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.healthy,
    );
    expect(changes.single.workspaceId, 'workspace-1');
    expect(changes.single.scripts.single.health, ScriptHealthState.healthy);
  });

  test('requires consecutive failures and resets them on success', () async {
    final route = register();
    final results = <bool>[false, true, false, false];
    final health = monitor(
      grace: Duration.zero,
      probe: (_, _) async => results.removeAt(0),
    );

    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.pending,
    );
    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.healthy,
    );
    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.healthy,
    );
    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.unhealthy,
    );
    expect(changes.map((change) => change.scripts.single.health), [
      ScriptHealthState.healthy,
      ScriptHealthState.unhealthy,
    ]);
  });

  test('invalidate deduplicates snapshots and prunes removed routes', () async {
    final first = register();
    register(scriptName: 'api', port: 4200);
    final health = monitor(grace: Duration.zero, probe: (_, _) async => true);

    expect(
      health.getHealthForHostname(first.hostname),
      ScriptHealthState.pending,
    );
    health.invalidateWorkspace('workspace-1');
    health.invalidateWorkspace('workspace-1');
    expect(changes, hasLength(1));
    expect(changes.single.scripts, hasLength(1));

    await health.pollNow();
    expect(changes.last.scripts, hasLength(2));
    routes.removeRoute(first.hostname);
    await health.pollNow();
    expect(health.getHealthForHostname(first.hostname), isNull);

    health.invalidateWorkspace('workspace-1');
    expect(changes.last.scripts.single.scriptName, 'api');
  });

  test('coalesces overlapping polls', () async {
    register();
    final pendingProbe = Completer<bool>();
    var probes = 0;
    final health = monitor(
      grace: Duration.zero,
      probe: (_, _) {
        probes++;
        return pendingProbe.future;
      },
    );

    final first = health.pollNow();
    final second = health.pollNow();
    expect(probes, 1);
    await second;
    pendingProbe.complete(true);
    await first;
    expect(probes, 1);
  });

  test('default probe observes real TCP availability', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final route = register(port: server.port);
    final health = monitor(grace: Duration.zero, failures: 1);

    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.healthy,
    );
    await server.close();
    await health.pollNow();
    expect(
      health.getHealthForHostname(route.hostname),
      ScriptHealthState.unhealthy,
    );
  });

  test('start and stop are idempotent and threshold is validated', () {
    final health = monitor();
    health
      ..start()
      ..start();
    expect(health.isRunning, isTrue);
    health
      ..stop()
      ..stop();
    expect(health.isRunning, isFalse);
    expect(() => monitor(failures: 0), throwsArgumentError);
  });
}
