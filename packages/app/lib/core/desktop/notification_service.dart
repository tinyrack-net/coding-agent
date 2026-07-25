import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_notifier/local_notifier.dart';

import 'desktop_shell.dart';

/// Wraps `local_notifier` for OS-level desktop notifications (an agent needs
/// input, or a run finished). No-op off desktop (see [isDesktopShell]) so
/// mobile/web builds never touch the plugin.
class NotificationService {
  /// Initializes the underlying plugin. Call once at startup, alongside
  /// `initDesktopShell`.
  static Future<void> init() async {
    if (!isDesktopShell) return;
    await localNotifier.setup(appName: 'Coding Agent');
  }

  /// Shows a notification with [title]/[body]. [onClick], if given, fires
  /// when the user clicks the notification.
  void notify({
    required String title,
    required String body,
    VoidCallback? onClick,
  }) {
    if (!isDesktopShell) return;
    final notification = LocalNotification(title: title, body: body);
    notification.onClick = onClick;
    notification.show();
  }
}

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());
