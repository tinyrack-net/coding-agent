import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'host_route_browser_adapter_base.dart';

HostRouteBrowserAdapter createHostRouteBrowserAdapter() =>
    const _WebHostRouteBrowserAdapter();

final class _WebHostRouteBrowserAdapter implements HostRouteBrowserAdapter {
  const _WebHostRouteBrowserAdapter();

  @override
  bool get available => true;

  @override
  String getCurrentRoute() =>
      '${web.window.location.pathname}'
      '${web.window.location.search}'
      '${web.window.location.hash}';

  @override
  void replaceRoute(String route) =>
      web.window.history.replaceState(null, '', route);

  @override
  void scheduleAfterCommit(void Function() callback) {
    web.window.setTimeout(callback.toJS, 0.toJS);
  }
}
