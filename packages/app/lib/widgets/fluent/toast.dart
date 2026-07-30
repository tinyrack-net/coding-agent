import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

/// Ownership token for one [AppToast].
///
/// A handle only dismisses the toast it created. If a newer toast has
/// replaced it, [dismiss] is an idempotent no-op.
final class AppToastHandle {
  AppToastHandle._(this._owner);

  final Object _owner;

  bool get isActive => AppToast._isCurrent(_owner);

  void dismiss() => AppToast._dismissOwned(_owner);
}

final class _AppToastRecord {
  _AppToastRecord({required this.owner, required this.entry});

  final Object owner;
  final OverlayEntry entry;
  Timer? timer;
}

/// A transient, self-dismissing notification banner — fluent_ui's `InfoBar`
/// is a persistent inline banner, not a toast, so there is no direct
/// `SnackBar` equivalent. This wraps `InfoBar` in an `OverlayEntry` that
/// auto-removes itself after [duration]. Passing `null` keeps the toast visible
/// until its returned [AppToastHandle] is dismissed.
class AppToast {
  AppToast._();

  static _AppToastRecord? _current;

  /// Dismisses the currently-shown toast, if any (mirrors
  /// `ScaffoldMessenger.hideCurrentSnackBar()`).
  static void dismissCurrent() {
    final current = _current;
    if (current == null) return;
    _current = null;
    current.timer?.cancel();
    if (current.entry.mounted) current.entry.remove();
  }

  static AppToastHandle show(
    BuildContext context,
    String message, {
    Key? key,
    InfoBarSeverity severity = InfoBarSeverity.info,
    Duration? duration = const Duration(seconds: 4),
  }) {
    dismissCurrent();
    final overlay = Overlay.of(context, rootOverlay: true);
    final owner = Object();
    final handle = AppToastHandle._(owner);
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
              key: key,
              title: Text(message),
              severity: severity,
              onClose: handle.dismiss,
            ),
          ),
        ),
      ),
    );
    final record = _AppToastRecord(owner: owner, entry: entry);
    _current = record;
    overlay.insert(entry);
    if (duration != null) {
      record.timer = Timer(duration, handle.dismiss);
    }
    return handle;
  }

  static bool _isCurrent(Object owner) => identical(_current?.owner, owner);

  static void _dismissOwned(Object owner) {
    if (!_isCurrent(owner)) return;
    dismissCurrent();
  }
}
