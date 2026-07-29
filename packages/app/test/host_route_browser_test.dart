import 'package:coding_agent_app/core/host_route_browser.dart';
import 'package:coding_agent_app/core/host_route_browser_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unavailable platform adapter is a complete no-op', () {
    final adapter = _FakeBrowserAdapter(available: false)
      ..currentRoute = '/h/local/workspace/164?serverId=local&workspaceId=164';
    final controller = HostRouteBrowserController(adapter);

    controller.replaceBrowserRouteWithCanonicalHostWorkspaceRoute(
      adapter.currentRoute!,
    );
    controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrl();
    controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit();

    expect(adapter.replacements, isEmpty);
    expect(adapter.scheduled, isEmpty);
  });

  test('explicit replacement always writes the canonical workspace route', () {
    final adapter = _FakeBrowserAdapter();
    final controller = HostRouteBrowserController(adapter);

    controller.replaceBrowserRouteWithCanonicalHostWorkspaceRoute(
      '/h/local/workspace/164?serverId=local&workspaceId=164'
      '&open=agent%3Aagent-1#pane',
    );

    expect(adapter.replacements, [
      '/h/local/workspace/164?open=agent%3Aagent-1#pane',
    ]);
  });

  test(
    'current browser route is replaced only when canonicalization changes it',
    () {
      final adapter = _FakeBrowserAdapter();
      final controller = HostRouteBrowserController(adapter);

      adapter.currentRoute = '/h/local/workspace/164?open=agent%3Aagent-1';
      controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrl();
      expect(adapter.replacements, isEmpty);

      adapter.currentRoute =
          '/h/local/workspace/164?pop=true&open=agent%3Aagent-1';
      controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrl();
      expect(adapter.replacements, [
        '/h/local/workspace/164?open=agent%3Aagent-1',
      ]);

      adapter.currentRoute = null;
      controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrl();
      expect(adapter.replacements, hasLength(1));
    },
  );

  test('after-commit variant defers the same canonicalization by one task', () {
    final adapter = _FakeBrowserAdapter()
      ..currentRoute =
          '/h/local/workspace/b64_L3RtcC9yZXBv'
          '?workspaceId=%2Ftmp%2Frepo&pop=true';
    final controller = HostRouteBrowserController(adapter);

    controller.stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit();
    expect(adapter.replacements, isEmpty);
    expect(adapter.scheduled, hasLength(1));

    adapter.runScheduled();
    expect(adapter.replacements, ['/h/local/workspace/b64_L3RtcC9yZXBv']);
  });
}

final class _FakeBrowserAdapter implements HostRouteBrowserAdapter {
  _FakeBrowserAdapter({this.available = true});

  @override
  final bool available;

  String? currentRoute;
  final replacements = <String>[];
  final scheduled = <void Function()>[];

  @override
  String? getCurrentRoute() => currentRoute;

  @override
  void replaceRoute(String route) => replacements.add(route);

  @override
  void scheduleAfterCommit(void Function() callback) => scheduled.add(callback);

  void runScheduled() {
    final callbacks = List<void Function()>.of(scheduled);
    scheduled.clear();
    for (final callback in callbacks) {
      callback();
    }
  }
}
