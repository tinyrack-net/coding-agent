import 'host_route_browser_adapter_base.dart';
import 'host_route_browser_adapter_stub.dart'
    if (dart.library.js_interop) 'host_route_browser_adapter_web.dart'
    as platform;

export 'host_route_browser_adapter_base.dart';

HostRouteBrowserAdapter createHostRouteBrowserAdapter() =>
    platform.createHostRouteBrowserAdapter();
