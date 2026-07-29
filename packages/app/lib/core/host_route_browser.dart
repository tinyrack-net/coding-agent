import 'host_route_browser_adapter.dart';
import 'host_routes.dart';

final class HostRouteBrowserController {
  const HostRouteBrowserController(this.adapter);

  final HostRouteBrowserAdapter adapter;

  void replaceBrowserRouteWithCanonicalHostWorkspaceRoute(String route) {
    if (!adapter.available) return;
    adapter.replaceRoute(stripHostWorkspaceRouteEchoSearch(route));
  }

  void stripHostWorkspaceRouteEchoSearchFromBrowserUrl() {
    if (!adapter.available) return;
    final currentRoute = adapter.getCurrentRoute();
    if (currentRoute == null || currentRoute.isEmpty) return;
    final canonicalRoute = stripHostWorkspaceRouteEchoSearch(currentRoute);
    if (canonicalRoute == currentRoute) return;
    adapter.replaceRoute(canonicalRoute);
  }

  void stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit() {
    if (!adapter.available) return;
    adapter.scheduleAfterCommit(
      stripHostWorkspaceRouteEchoSearchFromBrowserUrl,
    );
  }
}

final _defaultHostRouteBrowserController = HostRouteBrowserController(
  createHostRouteBrowserAdapter(),
);

void replaceBrowserRouteWithCanonicalHostWorkspaceRoute(String route) =>
    _defaultHostRouteBrowserController
        .replaceBrowserRouteWithCanonicalHostWorkspaceRoute(route);

void stripHostWorkspaceRouteEchoSearchFromBrowserUrl() =>
    _defaultHostRouteBrowserController
        .stripHostWorkspaceRouteEchoSearchFromBrowserUrl();

void stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit() =>
    _defaultHostRouteBrowserController
        .stripHostWorkspaceRouteEchoSearchFromBrowserUrlAfterCommit();
