import 'package:web/web.dart' as web;

import 'terminal_keys.dart';

bool get currentPlatformIsAppleHandheld => isAppleHandheldPlatform(
  userAgent: web.window.navigator.userAgent,
  platform: web.window.navigator.platform,
  maxTouchPoints: web.window.navigator.maxTouchPoints,
);
