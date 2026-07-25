import 'package:fluent_ui/fluent_ui.dart';

/// A transient, self-dismissing notification banner — fluent_ui's `InfoBar`
/// is a persistent inline banner, not a toast, so there is no direct
/// `SnackBar` equivalent. This wraps `InfoBar` in an `OverlayEntry` that
/// auto-removes itself after [duration].
class AppToast {
  AppToast._();

  static OverlayEntry? _current;

  /// Dismisses the currently-shown toast, if any (mirrors
  /// `ScaffoldMessenger.hideCurrentSnackBar()`).
  static void dismissCurrent() {
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
    Future.delayed(duration, () {
      if (_current == entry) {
        entry.remove();
        _current = null;
      }
    });
  }
}
