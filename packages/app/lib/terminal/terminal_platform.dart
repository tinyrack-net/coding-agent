import 'terminal_platform_stub.dart'
    if (dart.library.js_interop) 'terminal_platform_web.dart'
    as platform;

bool get currentPlatformIsAppleHandheld =>
    platform.currentPlatformIsAppleHandheld;
