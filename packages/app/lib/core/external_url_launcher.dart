// coverage:ignore-file

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class ExternalUrlLauncher {
  Future<bool> open(String url);
}

final class PlatformExternalUrlLauncher implements ExternalUrlLauncher {
  const PlatformExternalUrlLauncher();

  @override
  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return false;
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

final externalUrlLauncherProvider = Provider<ExternalUrlLauncher>(
  (_) => const PlatformExternalUrlLauncher(),
);
