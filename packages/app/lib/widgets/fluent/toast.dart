import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

/// A transient, self-dismissing notification banner — fluent_ui's `InfoBar`
/// is a persistent inline banner, not a toast, so there is no direct
/// `SnackBar` equivalent. This wraps `InfoBar` in an `OverlayEntry` that
/// auto-removes itself after [duration].
class AppToast {
  AppToast._();

  static OverlayEntry? _current;

  /// The pending auto-dismiss timer for [_current], cancelled whenever the
  /// toast goes away early. Without this the timer outlives the overlay entry,
  /// which is harmless in the app but trips the "timer still pending" check in
  /// any widget test that dismisses a toast before it expires.
  static Timer? _timer;

  /// Dismisses the currently-shown toast, if any (mirrors
  /// `ScaffoldMessenger.hideCurrentSnackBar()`). Safe to call when nothing is
  /// showing — the destructive flows call it unconditionally.
  static void dismissCurrent() {
    _timer?.cancel();
    _timer = null;
    _current?.remove();
    _current = null;
  }

  static void show(
    BuildContext context,
    String message, {
    InfoBarSeverity severity = InfoBarSeverity.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    dismissCurrent();
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 24,
        right: 24,
        bottom: 24,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: InfoBar(
              title: Text(message),
              severity: severity,
              onClose: dismissCurrent,
            ),
          ),
        ),
      ),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(duration, () {
      if (_current == entry) {
        _timer = null;
        entry.remove();
        _current = null;
      }
    });
  }
}
