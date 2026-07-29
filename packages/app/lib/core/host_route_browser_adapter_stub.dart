import 'host_route_browser_adapter_base.dart';

HostRouteBrowserAdapter createHostRouteBrowserAdapter() =>
    const _UnavailableHostRouteBrowserAdapter();

final class _UnavailableHostRouteBrowserAdapter
    implements HostRouteBrowserAdapter {
  const _UnavailableHostRouteBrowserAdapter();

  @override
  bool get available => false;

  @override
  String? getCurrentRoute() => null;

  @override
  void replaceRoute(String route) {}

  @override
  void scheduleAfterCommit(void Function() callback) {}
}
